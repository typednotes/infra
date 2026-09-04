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
  /-- The *value* of one of this fleet's secrets, read at apply time.

      `Expr K String` rather than `ObservedOf .secrets`, because nothing
      observable carries a value — `.secrets`' `read` deliberately never
      fetches one. This is what lets a target hold a composed value (a
      connection string built from a password and a post-apply endpoint) as a
      *function* rather than a literal, so it needs one apply instead of two.

      Still `map`/`ap` only: the plan's shape does not depend on this, only a
      field's value does, so the applicative-only rule above is intact. -/
  | secretValue (p : ProviderId) : K p .secrets → Expr K String
  | map      {α β : Type} : (α → β) → Expr K α → Expr K β
  | ap       {α β : Type} : Expr K (α → β) → Expr K α → Expr K β

/-- What a spec reads from a resource it names.

    Tagged because the two have different costs: a handle is free, a value is
    a plaintext read. `Infra.Core.needsSecretValues` uses this to tell whether
    an action needs the one inbound plaintext path at all. -/
inductive Need | handle | secretValue
  deriving Repr, DecidableEq, BEq

/-- One reference, and what it is read for.

    A structure rather than a nested sigma so that reading one does not mean
    counting projections: `d.key` and `d.need` say what `d.2.2.1` and `d.2.2.2`
    used to need a comment to explain. The anonymous constructor still accepts
    the positional form, so `⟨p, k, key, .handle⟩` is unchanged. -/
structure Dep (K : ProviderId → Kind → Type) where
  provider : ProviderId
  kind     : Kind
  key      : K provider kind
  need     : Need

/-- What an expression can be evaluated against.

    A structure rather than a bare function because `.secretValue` needs a
    second, very different lookup. `secretValue` is **defaulted to "knows
    nothing"**, which is what makes the planning path structurally unable to
    hold a real one: `envOfWorld` builds an `Env` without mentioning the
    field, so no amount of care is required to keep plaintext out of `plan`. -/
structure Env (K : ProviderId → Kind → Type) where
  observed    : (p : ProviderId) → (k : Kind) → K p k → Option (ObservedOf k)
  secretValue : (p : ProviderId) → K p .secrets → Option String := fun _ _ => none

/-- The only string the pure planning path can produce for a secret value. -/
def Env.redacted : String := "<redacted>"

/-- An environment that can settle a composed value's *shape* without access
    to any real one — so a dry run exercises the same code path as an apply,
    and still cannot print a secret. -/
def Env.withRedactedSecrets {K : ProviderId → Kind → Type} (e : Env K) : Env K :=
  { e with secretValue := fun _ _ => some Env.redacted }

namespace Expr

variable {K : ProviderId → Kind → Type}

/-- Every reference this expression makes. Used for the dependency DAG. -/
def deps {α : Type} : Expr K α → List (Dep K)
  | .lit _           => []
  | .observed p k r  => [⟨p, k, r, .handle⟩]
  | .secretValue p r => [⟨p, .secrets, r, .secretValue⟩]
  | .map _ e         => deps e
  | .ap f e          => deps f ++ deps e

/-- The handle of a referenced resource — by far the commonest projection, so it gets a name
    rather than making every caller write the `map` out. -/
def handle (p : ProviderId) (k : Kind) (r : K p k) : Expr K (Handle k) :=
  .map (observedHandle k) (.observed p k r)

/-- Evaluate against an environment that may not know every reference.

    `none` means a referenced resource has not been created yet, which during a
    push is a schedule error rather than a failure of the expression — so the
    caller gets to decide, instead of this having to demand a total
    environment it cannot supply mid-apply. -/
def eval? {α : Type} (env : Env K) : Expr K α → Option α
  | .lit a           => some a
  | .observed p k r  => env.observed p k r
  | .secretValue p r => env.secretValue p r
  | .map f e         => (eval? env e).map f
  | .ap f e          => match eval? env f, eval? env e with
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
