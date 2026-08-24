import Infra.Core.Kind

/-
  The "known only after apply" modality.

  A spec field holds an `Expr`, not a value, because some of what a target says depends on
  identifiers the provider has not assigned yet.
-/

namespace Infra.Core

/-- Plan-time expressions.

    `K` is the fleet's own key family. A cross-resource reference is an element of `K p k` — an
    *index into this very fleet* — so a dangling reference is not representable. There is
    nothing to validate.

    APPLICATIVE ONLY. There is deliberately no

        bind : Expr K α → (α → Expr K β) → Expr K β

    because `bind` would let the *shape* of the plan depend on a value that is not known until
    apply, and then "plan" ceases to exist as a phase. With only `map`/`ap` the dependency
    graph is static and unknown values flow along fixed edges.

    Because `map`/`ap` quantify over an intermediate type, `Expr K` lands in `Type 1`. That is
    why `Infra.Core.Field` and every spec shape are universe-polymorphic. -/
inductive Expr (K : ProviderId → Kind → Type) : Type → Type 1 where
  | lit      {α : Type} : α → Expr K α
  | observed (p : ProviderId) (k : Kind) : K p k → Expr K (ObservedOf k)
  | map      {α β : Type} : (α → β) → Expr K α → Expr K β
  | ap       {α β : Type} : Expr K (α → β) → Expr K α → Expr K β

namespace Expr

variable {K : ProviderId → Kind → Type}

/-- Every reference this expression makes. Used for the dependency DAG. -/
def deps {α : Type} : Expr K α → List ((p : ProviderId) × (k : Kind) × K p k)
  | .lit _          => []
  | .observed p k r => [⟨p, k, r⟩]
  | .map _ e        => deps e
  | .ap f e         => deps f ++ deps e

/-- Evaluate, once every referenced resource has been observed. -/
def eval {α : Type} (env : (p : ProviderId) → (k : Kind) → K p k → ObservedOf k) :
    Expr K α → α
  | .lit a          => a
  | .observed p k r => env p k r
  | .map f e        => f (eval env e)
  | .ap f e         => (eval env f) (eval env e)

/-- The handle of a referenced resource — by far the commonest projection, so it gets a name
    rather than making every caller write the `map` out. -/
def handle (p : ProviderId) (k : Kind) (r : K p k) : Expr K (Handle k) :=
  .map (observedHandle k) (.observed p k r)

/-- Evaluate against an environment that may not know every reference.

    `none` means a referenced resource has not been created yet, which during a
    push is a schedule error rather than a failure of the expression — so the
    caller gets to decide, instead of this having to demand a total
    environment it cannot supply mid-apply. -/
def eval? {α : Type} (env : (p : ProviderId) → (k : Kind) → K p k → Option (ObservedOf k)) :
    Expr K α → Option α
  | .lit a          => some a
  | .observed p k r => env p k r
  | .map f e        => (eval? env e).map f
  | .ap f e         => match eval? env f, eval? env e with
                       | some g, some x => some (g x)
                       | _,      _      => none

/-- The value of an expression that is already a literal.

    Keys are plan-time constants — you know which resource you mean when you write the target —
    so a *key-typed* field is always a `.lit`, and `HasDeps` reads structural references out of
    it with this. Deliberately gives up on `map`/`ap`: a key computed from a post-apply value
    would be exactly the unknown-dependent shape `Expr` exists to rule out. -/
def asLit {α : Type} : Expr K α → Option α
  | .lit a => some a
  | _      => none

end Expr

end Infra.Core
