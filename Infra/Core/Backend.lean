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

/-- Every cloud the engine can reach. Total over `ProviderId`, matching `Plan.assign`'s
    totality over the same index. -/
structure Backends where
  backend : ProviderId → Backend

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
