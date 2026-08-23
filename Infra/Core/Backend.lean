import Infra.Core.Action

/-
  What a cloud has to be able to do, and how the engine reaches several of them at once.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

/-- The key family a provider sees: fleet keys already resolved to physical handles.

    Substituting the key family is all it takes — `SpecOf` is parameterised by it, so a spec
    whose references were `κ.Key p k` at plan time becomes one whose references are `Handle k`
    by the time a backend sees it. -/
@[reducible] def Resolved : ProviderId → Kind → Type := fun _ k => Handle k

/-- A spec as a backend receives it: defaults filled, expressions evaluated, references
    resolved to handles. Nothing partial and nothing deferred is left. -/
@[reducible] def ProviderSpec (k : Kind) : Type := SpecOf.{0} k Resolved Conc Conc

/-- One cloud's CRUD surface, defunctionalised as a record rather than a class so that
    `Backends` can be a total function over `ProviderId` without sigma gymnastics. -/
structure Backend where
  list   : (k : Kind) → IO (List (ObservedOf k))
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
abbrev Entry (κ : Keys) := (p : ProviderId) × (k : Kind) × κ.Key p k × ObservedOf k

/-- Assemble a `World` from entries. The one place a dependent cast is needed: an entry carries
    its own `(p, k)`, and answering a query at some other `(p, k)` requires knowing they
    coincide. -/
def worldOf {κ : Keys} (es : List (Entry κ)) : World κ where
  observed p k key := es.findSome? fun e =>
    match e with
    | ⟨p', k', key', o⟩ =>
      if hp : p' = p then
        if hk : k' = k then by
          subst hp; subst hk
          exact (if key' = key then some o else none)
        else none
      else none

end Infra.Core
