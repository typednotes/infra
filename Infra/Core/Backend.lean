import Infra.Core.Action

/-
  What a cloud has to be able to do, and how the engine reaches several of them at once.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

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

/-- Assemble a `World` from entries. The one place a dependent cast is needed: an entry carries
    its own `(p, k)`, and answering a query at some other `(p, k)` requires knowing they
    coincide. -/
def worldOf {κ : Keys} (es : List (Entry κ)) : World κ where
  sighting p k key := es.findSome? fun e =>
    match e with
    | ⟨p', k', key', o⟩ =>
      if hp : p' = p then
        if hk : k' = k then by
          subst hp; subst hk
          exact (if key' = key then some o else none)
        else none
      else none

end Infra.Core
