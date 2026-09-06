import Infra.Core.Action

/-
  What a cloud has to be able to do, and how the engine reaches several of them at once.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

/-- Whether a provider's error says the resource is not there.

    Matched on the rendered message because `Http.sendChecked` flattens its
    structured `ApiError` into an `IO.userError`, and `Infra.Core` sits below
    `Infra.Providers` so the structure is not reachable from here anyway.
    Substring matching on a curated list of codes is the honest version of
    that: narrow, and wrong only by omission — an unrecognised not-found code
    surfaces as a hard error, which is the safe direction.

    It must stay narrow. Treating a *permission* error as "absent" would make
    the engine propose creating a resource that already exists, which on a
    second apply means a duplicate rather than a failure. -/
def readsAsAbsent (msg : String) : Bool :=
  let codes :=
    [ "NoSuchBucket", "NoSuchKey", "NoSuchEntity", "QueueDoesNotExist"
    , "ResourceNotFoundException", "ResourceNotFound", "NotFoundException"
    , "InvalidAMIID.NotFound", "InvalidGroup.NotFound", "InvalidInstanceID.NotFound"
    , "DBInstanceNotFound", "RepositoryNotFoundException"
    , "HTTP 404" ]
  codes.any fun c => (msg.splitOn c).length > 1

/-- One cloud's CRUD surface, defunctionalised as a record rather than a class so that
    `Backends` can be a total function over `ProviderId` without sigma gymnastics. -/
structure Backend where
  /-- Everything of this kind the credentials can see. -/
  list   : (k : Kind) → IO (List (ObservedOf k))
  /-- The configuration actually in force for one resource.

      Separate from `list` because listing rarely reports configuration:
      S3's `ListBuckets` gives names and nothing else, so versioning and
      tagging need their own calls. Splitting them means the per-resource
      cost is paid only for resources the fleet actually claims. -/
  read   : (k : Kind) → Handle k → IO (Reported k)
  create : (k : Kind) → ProviderSpec k → IO (ObservedOf k)
  update : (k : Kind) → Handle k → ProviderSpec k → IO (ObservedOf k)
  delete : (k : Kind) → Handle k → IO Unit
  /-- Read one secret's value.

      The **only** inbound plaintext path in this interface, and deliberately
      separate from `read`, which never fetches a value. Its only sanctioned
      caller is `Engine.settleFor`, on the apply path, to resolve an
      `Expr.secretValue` in a composed target; the planning path cannot reach
      it at all (`envOfWorld` leaves `Env.secretValue` at its default). What it
      returns is handed to one create/update call and never stored, cached, or
      returned outward — the same discipline as
      `Infra.Providers.Kinds.Postgres.fetchMasterPassword`. -/
  secretValue : Handle .secrets → IO String

/-- Every cloud the engine can reach. Total over `ProviderId`, matching `Plan.assign`'s
    totality over the same index.

    `backend` is the cloud's default — for a fleet in one region per cloud, it
    is the whole story and the two fields below default to it, so every
    existing `Backends` keeps working unchanged.

    The two below exist because a region is not a property of a *cloud* but of
    a *resource*: a fleet may put one bucket in Ireland and one instance in
    Paris, and an endpoint is built per region. Routing lives here rather than
    in the engine because the engine has no credentials and no idea what a
    region is — it knows only slots. See `Infra.Core.Region`. -/
structure Backends where
  backend : ProviderId → Backend
  /-- The backend for one slot, addressed the way the engine already addresses
      everything: cloud, kind, and the slot's `Keys.name`. Used for every
      per-resource call — `read`, `create`, `update`, `delete`, `secretValue`. -/
  backendFor : ProviderId → Kind → String → Backend := fun p _ _ => backend p
  /-- How to enumerate a `(provider, kind)` bucket that may span regions: one
      entry per region in play, each paired with the test for which slot names
      belong to it.

      A pair rather than a bare list because `list` is the one call with no
      slot to route on — it asks a *region* what is in it — and its answers
      must then be matched only against the slots placed there. Without that
      pairing, a bucket named `assets` in one region would satisfy a key
      placed in another, and the engine would believe it already existed. -/
  listers : ProviderId → Kind → List (Backend × (String → Bool)) :=
    fun p _ => [(backend p, fun _ => true)]
  /-- The backend for a *region named directly*, for the one caller that has a
      region and no slot to look it up from: destroying a resource whose
      declaration is gone.

      `backendFor` cannot serve that case. It resolves the region by looking
      the slot name up in the fleet's placement table, and the whole premise of
      an orphan is that the declaration no longer names it — so the lookup
      misses and falls back to the credentials' region, which is the wrong
      endpoint for anything placed anywhere else. The region comes from the
      ledger row instead, which is why the row records one. -/
  backendAt : ProviderId → String → Backend := fun p _ => backend p

/-- One observed resource, tied back to the fleet key it realises.

    Non-dependent in `p` and `k` at the list level but dependent inside, which is why this is a
    sigma rather than a plain tuple: `ObservedOf k` genuinely varies with the kind. -/
abbrev Entry (κ : Keys) := (p : ProviderId) × (k : Kind) × κ.Key p k × Sighting k

/-- A cached entry: only the observed half.

    Distinct from `Entry` on purpose. The on-disk cache records what was last
    *seen*, and configuration is re-read on every pull, so a loaded entry
    genuinely has no reported half to offer — giving it one would mean
    inventing it. -/
abbrev CachedEntry (κ : Keys) := (p : ProviderId) × (k : Kind) × κ.Key p k × ObservedOf k

/-- Drop the reported half, for caching. -/
def Entry.cached {κ : Keys} (e : Entry κ) : CachedEntry κ :=
  ⟨e.1, e.2.1, e.2.2.1, e.2.2.2.observed⟩

/-- Look one `(p, k, key)` up in a list of entries that each carry their own
    indices.

    The one dependent cast in the library, and it is here rather than written
    out per caller: an entry carries its own `(p, k)`, and answering a query at
    some other `(p, k)` requires knowing they coincide. Generalised over the
    payload `β` so that `Entry` (payload `Sighting`) and `CachedEntry` (payload
    `ObservedOf`) share it — `worldOf` and `Engine.pullEntries` are the two
    callers, and writing the cast twice is how the two would drift. -/
def lookupAt {κ : Keys} {β : Kind → Type}
    (es : List ((p : ProviderId) × (k : Kind) × κ.Key p k × β k))
    (p : ProviderId) (k : Kind) (key : κ.Key p k) : Option (β k) :=
  es.findSome? fun e =>
    match e with
    | ⟨p', k', key', o⟩ =>
      if hp : p' = p then
        if hk : k' = k then by
          subst hp; subst hk
          exact (if key' = key then some o else none)
        else none
      else none

/-- Assemble a `World` from entries. -/
def worldOf {κ : Keys} (es : List (Entry κ)) : World κ where
  sighting := lookupAt es

end Infra.Core
