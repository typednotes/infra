import Infra.Core.Action
import Linen.Cloud.Error
import Infra.Core.Ownership

/-
  What a cloud has to be able to do, and how the engine reaches several of them at once.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

/-- The `(status, code)` pairs a rendered failure carries, read back from
    infra's `HTTP <status> <code>: <message>` form (`Http.render`) — every
    occurrence, since a message may wrap another. The code is the token
    between the status and the next `:`, minus any `namespace#` an AWS JSON
    service puts in front of it; `""` when there is none (`(HTTP 404)`,
    `HTTP 403 : …`).

    Matched on the rendered message because `Http.sendChecked` raises an
    `IO.userError`, and `Infra.Core` sits below the providers anyway: the
    structure does not reach here, so it is re-read, narrowly. -/
def failuresIn (msg : String) : List (Nat × String) :=
  (msg.splitOn "HTTP ").drop 1 |>.filterMap fun rest =>
    let digits := rest.toList.takeWhile Char.isDigit
    if digits.length != 3 then none else
    let status := (String.ofList digits).toNat!
    let after := (rest.drop 3).toString
    let code :=
      if after.startsWith " " && !after.startsWith " :" then
        let raw := ((after.drop 1).toString.splitOn ":").headD ""
        -- A code is one token; anything with a space in it is prose.
        if (raw.splitOn " ").length == 1 then (raw.splitOn "#").getLastD raw else ""
      else ""
    some (status, code)

#guard failuresIn "s3 GET x: HTTP 404 NoSuchBucket: gone (request r)" == [(404, "NoSuchBucket")]
#guard failuresIn "HTTP 403 com.amazonaws.secretsmanager#AccessDeniedException: no" == [(403, "AccessDeniedException")]
#guard failuresIn "kubernetes-object/x: not found (HTTP 404)" == [(404, "")]
#guard failuresIn "HTTP 403 : AccessDenied" == [(403, "")]
#guard failuresIn "connection reset by peer" == []

/-- Whether a provider's error says the resource is not there: linen's
    classification (`Cloud.classify`) of a status and code this message
    carries is `notFound`.

    It must stay narrow — linen's not-found list is explicit on purpose.
    Treating a *permission* error as "absent" would make the engine propose
    creating a resource that already exists, which on a second apply means a
    duplicate rather than a failure. -/
def readsAsAbsent (msg : String) : Bool :=
  (failuresIn msg).any fun (status, code) => Cloud.classify status code == .notFound

/-- Whether a provider's error says *this caller may not see this resource*:
    a 403 whose code is one of linen's `Cloud.deniedCodes`, and that linen —
    reading the message too — classifies as `denied`, not `serviceDisabled`.

    Used for exactly one decision (`Engine.claimUndeclared`): an undeclared
    resource whose marker read is refused is not this fleet's — warned about by
    name and left alone — rather than a failed run. Every other caller keeps
    treating a refusal as the error it is.

    Narrow in the same direction as `readsAsAbsent`: the code must be one of
    the denied codes, *and* the status a 403 — linen's own `classify` falls
    back on the status and would call any 403 `denied`, which here would read
    an unrecognised refusal as "not ours". So:

    * **not** a signature or credential failure (`SignatureDoesNotMatch`,
      `InvalidAccessKeyId`, …) — linen's `unauthenticated`, nothing to do with
      this resource;
    * **not** a Google API that is switched off, which Google answers as
      `PERMISSION_DENIED` too — linen's `serviceDisabled`, and "unreadable, so
      not ours" must never widen from one resource to a whole kind.

    Observed refusals: `HTTP 403 AccessDenied` from `GetBucketTagging` on a
    Scaleway bucket whose bucket policy does not name the caller (2026-09-24);
    `HTTP 403 permissions_denied` from Scaleway (2026-09-23);
    `PERMISSION_DENIED` from Google. -/
def readsAsRefused (msg : String) : Bool :=
  (failuresIn msg).any fun (status, code) =>
    status == 403 && Cloud.deniedCodes.contains code
      && Cloud.classifyMessage status code msg == .denied

#guard readsAsRefused "s3 GET s3.fr-par.scw.cloud/docs.typednotes.org?tagging: HTTP 403 AccessDenied: Access Denied (request tx1)"
#guard readsAsRefused "HTTP 403 AccessDenied: Access Denied (request tx1)"
#guard readsAsRefused "secretsmanager POST …: HTTP 403 com.amazonaws.secretsmanager#AccessDeniedException: no"
#guard readsAsRefused "scaleway GET /secret-manager/v1beta1/regions/fr-par/secrets/x: HTTP 403 permissions_denied: insufficient permissions"
#guard readsAsRefused "HTTP 403 PERMISSION_DENIED: Permission 'storage.buckets.get' denied on resource"
#guard readsAsRefused "ec2 POST …: HTTP 403 UnauthorizedOperation: You are not authorized"
-- A whole service switched off is not one resource hidden.
#guard !readsAsRefused "HTTP 403 PERMISSION_DENIED: Cloud SQL Admin API has not been used in project 1 before or it is disabled."
-- Credential and signature failures are not about the resource.
#guard !readsAsRefused "HTTP 403 SignatureDoesNotMatch: The request signature we calculated does not match"
#guard !readsAsRefused "HTTP 403 InvalidAccessKeyId: The AWS Access Key Id you provided does not exist"
-- The code must be a 403's, and must be the code, not a word in the message.
#guard !readsAsRefused "HTTP 401 AccessDenied: nope"
#guard !readsAsRefused "HTTP 500 InternalError: AccessDenied upstream"
#guard !readsAsRefused "HTTP 403 : AccessDenied"
#guard !readsAsRefused "connection reset by peer"

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
      separate from `read`, which never fetches a value. Its sanctioned
      callers are `Engine.settleFor`, on the apply path, to resolve an
      `Expr.secretValue` in a composed target, and `Engine.refreshSecrets`,
      only under `--refresh-secrets`, to compare a stored value with the
      declared one. The ordinary planning path cannot reach it at all
      (`envOfWorld` leaves `Env.secretValue` at its default). What it returns
      is handed to one create/update call or one comparison and never stored,
      cached, or returned outward — the same discipline as
      `Infra.Providers.Kinds.Postgres.fetchMasterPassword`. -/
  secretValue : Handle .secrets → IO String
  /-- What this backend can find out about one resource's ownership, as
      evidence for `Ownership.ownershipOf`.

      An `Evidence` rather than tags alone, because a `(cloud, kind)` that
      *cannot* carry a marker and one that nobody has taught to read one are
      different situations: the first is permanent and has a remedy
      (`Boundary.namePrefix`), the second is a gap to close. See the ladder in
      `Infra.Core.Ownership`'s module note for which rung each pair is on.

      The default answers `.unreadable` so that a backend which never
      overrides this field is unaffected — and so that a kind added later is
      refused rather than silently claimed. -/
  ownershipInfo : (k : Kind) → Handle k → IO Evidence := fun _ _ => pure .unreadable
  /-- Remove the ownership marker from one resource, leaving it — and every
      other tag, label or word of its description — exactly as it was. What a
      `forget` does on apply: the resource stops being any fleet's, and the
      `forget` line can then be deleted.

      Only asked of a resource whose marker is on a rung that can be
      rewritten — tags, labels, a description. A name cannot be unwritten
      (`Engine.claimUndeclared` never plans a release for a `.named`
      resource). The default refuses, loudly, so that a kind nobody has
      taught to release cannot report a release it did not do. -/
  release : (k : Kind) → Handle k → IO Unit := fun k h =>
    throw (IO.userError s!"{k.name}/{h.raw}: this backend cannot remove the ownership marker \
from this kind")

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
      endpoint for anything placed anywhere else. The region comes from where
      the orphan was found (`Orphan.region`). -/
  backendAt : ProviderId → String → Backend := fun p _ => backend p
  /-- Every region this fleet uses on a cloud, each with its code and backend:
      where to look for resources carrying this fleet's marker that the
      declaration does **not** name (`Engine.claimUndeclared`).

      Not `listers`: those are derived from the declaration's own slots, per
      kind, so a kind the fleet no longer declares anything of has none — and
      that is exactly the kind whose last resource was just removed and must
      now be destroyed. The code is recorded on the row, so the delete goes to
      the region the resource was found in (`backendAt`). -/
  scanners : ProviderId → List (String × Backend) := fun p => [("", backend p)]

/-- One observed resource, tied back to the fleet key it realises.

    Non-dependent in `p` and `k` at the list level but dependent inside, which is why this is a
    sigma rather than a plain tuple: `ObservedOf k` genuinely varies with the kind. -/
abbrev Entry (κ : Keys) := (p : ProviderId) × (k : Kind) × κ.Key p k × Sighting k

/-- Look one `(p, k, key)` up in a list of entries that each carry their own
    indices.

    The one dependent cast in the library, and it is here rather than written
    out per caller: an entry carries its own `(p, k)`, and answering a query at
    some other `(p, k)` requires knowing they coincide. Generalised over the
    payload `β` so that any per-resource payload can share it, and writing
    the cast twice is how two copies would drift. -/
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
