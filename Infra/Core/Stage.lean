import Infra.Specs.Basic

/-
  The stages a spec passes through between being authored and being observed.

  `Infra.Core.Spec` gives the general shape; this names the three concrete
  instantiations the engine and the providers actually exchange, so they can be
  referred to by name rather than by a wall of type arguments.

  It sits between `Infra.Specs.Basic` and `Infra.Core.Fleet` because both the
  fleet (which records what was observed) and the backends (which are handed
  what to create) need the same vocabulary.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

/-- The key family a provider sees: fleet keys already resolved to the physical
    handles the cloud assigned.

    Substituting the key family is all it takes — `SpecOf` is parameterised by
    it, so a spec whose references were `κ.Key p k` at plan time becomes one
    whose references are `Handle k` by the time a backend sees it. -/
@[reducible] def Resolved : ProviderId → Kind → Type := fun _ k => Handle k

/-- A spec as a backend receives it: defaults filled, expressions evaluated,
    references resolved. Nothing partial and nothing deferred is left. -/
@[reducible] def ProviderSpec (k : Kind) : Type := SpecOf.{0} k Resolved Conc Conc

/-- A spec as a backend *reports* it: the configuration actually in force on
    the cloud.

    Optional fields are `Partial` because a provider need not report
    everything, and `unknown` must mean "could not see" rather than "absent" —
    the difference between leaving a resource alone and rewriting it on every
    apply. See `docs/diff-semantics.md`. -/
@[reducible] def Reported (k : Kind) : Type := SpecOf.{0} k Resolved Partial Conc

/-- Whether a field can be changed on a resource that already exists.

    Lives here rather than beside `Action`, where it started: `Infra.Core.Diverge`
    needs it to build its per-kind tables, and `Action` needs `Diverge`, so
    keeping it there made a cycle. -/
inductive Mutability
  | mutable
  | forcesReplace
  deriving Repr, DecidableEq, BEq

end Infra.Core
