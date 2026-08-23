import Infra.Core.Expr
import Infra.Core.Refine

/-
  How a spec's fields are shaped at each stage of the pipeline.
-/

namespace Infra.Core

universe u

/-- Whether a field must be given by the author. -/
inductive Slot
  | required
  | optional
  deriving Repr, DecidableEq

/-- The type of a field at a given stage.

    * `o` is the optionality wrapper (`Partial` while authoring, `Conc` once defaults are
      filled).
    * `f` is the staging wrapper (`Expr K` while planning, `Conc` after apply).

    A `required` field is never wrapped in `o`. That is what makes "target that cannot be
    created because a mandatory field is missing" a *structure-literal* error rather than a
    runtime check.

    Universe-polymorphic because `Expr K : Type → Type 1` — see `Infra.Core.Expr`. -/
@[reducible] def Field (s : Slot) (o : Type u → Type u) (f : Type → Type u) (α : Type) :
    Type u :=
  match s with
  | .required => f α
  | .optional => o (f α)

/-- The shape every spec structure has: parameterised by the fleet's key family and by the two
    stage wrappers. -/
@[reducible] def SpecShape :=
  (ProviderId → Kind → Type) → (Type u → Type u) → (Type → Type u) → Type u

/-- Authoring stage: holes allowed on optional fields, expressions everywhere. -/
@[reducible] def Authored (K : ProviderId → Kind → Type) (S : SpecShape.{1}) : Type 1 :=
  S K Partial (Expr K)

/-- Post-defaulting: every optional hole has been given a default, but values that only exist
    after apply are still expressions. -/
@[reducible] def Filled (K : ProviderId → Kind → Type) (S : SpecShape.{1}) : Type 1 :=
  S K Conc (Expr K)

/-- Post-apply: everything concrete. -/
@[reducible] def Settled (K : ProviderId → Kind → Type) (S : SpecShape.{0}) : Type :=
  S K Conc Conc

end Infra.Core
