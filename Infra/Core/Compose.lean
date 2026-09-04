import Lean
import Infra.Core.Expr

/-
  Writing a value that is composed from post-apply state.

  `Expr` is applicative on purpose — no `bind`, so a plan's *shape* can never
  depend on a value that does not exist yet (see `Infra.Core.Expr`). The price
  is that composing a string out of two unknowns has to be spelled `map` and
  `ap`:

      .ap (.map (fun password db =>
                  s!"postgres://admin:{password}@{db.endpoint}/main")
                (.secretValue .scaleway dbPassword))
          (.observed .scaleway .postgres mainDb)

  Every character of which is plumbing. The interesting part — the shape of
  the connection string — is buried inside a lambda whose parameters have to
  be threaded to the right `ap` in the right order, and adding a third unknown
  means another nested `ap` and another parameter.

  `expr!` is the same thing written the way the analogous `s!` is:

      expr!"postgres://admin:{secretValueOf dbPassword}@{endpointOf mainDb}/main"

  It expands to exactly that `map`/`ap` chain — nothing is added to `Expr` and
  no evaluation rule changes, so `Expr.deps` still reports every reference and
  the scheduler still orders them first. The applicative restriction is not
  loosened, only made invisible: there is still no way to branch on an unknown
  value, because there is nowhere in the syntax to put a branch.
-/

namespace Infra.Core

variable {K : ProviderId → Kind → Type}

/-- Concatenate two plan-time strings. The `ap` in `expr!`'s expansion. -/
def Expr.append (a b : Expr K String) : Expr K String :=
  .ap (.map (fun x y => x ++ y) a) b

/-- Render a plan-time value as a string, for interpolation. A hole in `expr!`
    goes through this, so anything with a `ToString` can appear in one — and,
    via `Infra.Core.Coe`, so can an ordinary value that is not an `Expr` yet. -/
def Expr.interp {α : Type} [ToString α] (e : Expr K α) : Expr K String :=
  .map toString e

/-! ## Naming the two things worth interpolating

  Both take a key and give back an `Expr`, so the provider and kind are
  recovered by unification rather than written out again at the use site. -/

/-- The value of one of this fleet's secrets, read at apply time. -/
def secretValueOf {p : ProviderId} (key : K p .secrets) : Expr K String :=
  .secretValue p key

/-- Everything the cloud reports about a resource, once it exists. Project a
    field with `Expr.map`: `(observedOf b).map (·.url)`. -/
def observedOf {p : ProviderId} {k : Kind} (key : K p k) : Expr K (ObservedOf k) :=
  .observed p k key

/-- A database's endpoint — the commonest projection by far, and the reason
    composed values exist at all, so it gets a name. -/
def endpointOf {p : ProviderId} (key : K p .postgres) : Expr K String :=
  (observedOf key).map (·.endpoint)

/-- A plan-time string built from literals and post-apply values.

    Reads like `s!`, elaborates to `map`/`ap`. A hole may hold any
    `Expr K α` with `ToString α` — typically `secretValueOf` or `endpointOf` —
    or a plain value, which the wrapper coercions lift for you.

    With no holes it is just a literal, so `expr!"fixed"` is `.lit "fixed"`. -/
syntax:max "expr!" interpolatedStr(term) : term

macro_rules
  | `(expr! $s) => do
    -- The chunk callbacks are handed raw `Syntax`; quotations want `TSyntax`,
    -- hence the explicit wrapping rather than `open TSyntax.Compat`.
    Lean.TSyntax.expandInterpolatedStrChunks s.raw.getArgs
      (fun a b => do
        let a : Lean.Term := ⟨a⟩
        let b : Lean.Term := ⟨b⟩
        `(Infra.Core.Expr.append $a $b))
      (fun e => do
        let e : Lean.Term := ⟨e⟩
        `(Infra.Core.Expr.interp $e))
      (fun lit => `(Infra.Core.Expr.lit $(Lean.Syntax.mkStrLit lit)))

end Infra.Core
