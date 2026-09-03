import Infra.Core.Expr
import Infra.Core.Spec

/-
  Authoring a field without naming its wrappers.

  A spec field at the authoring stage is `Expr K α` when required and
  `Partial (Expr K α)` when optional (see `Infra.Core.Field`), so writing one
  out means naming one or two wrappers that carry no information:

      name := .lit "secrets-db"
      port := .known (.lit 8200)

  Both wrappers are the *only* way to get from a value to a field of that
  type — `Expr.lit` is the sole non-reference constructor and `Partial.known`
  the sole "yes, I am specifying this" one — so inserting them is mechanical,
  which makes it a coercion's job rather than an author's.

  `Coe α (Expr K α)` is the chainable middle link and `CoeTail (Expr K α)
  (Partial (Expr K α))` the last one, so a bare value reaches a required field
  in one step and an optional field in two.

  This deliberately does NOT make every wrapper implicit. `.unknown` has no
  coercion: "I am not specifying this" is a real choice and stays visible.
  Nor is anything lost — `.lit`/`.known` remain writable, and a field holding
  a genuine expression (`.observed`, `map`/`ap`) is unaffected, since no
  coercion is inserted when the type already matches.

  ## Two shapes that do not coerce

  An *empty* `[]` and a bare `none` do not, because their own type is a
  metavariable and instance search will not assign one, so no chain is found.
  Write the type (`([] : List String)`) or the wrappers (`.known (.lit [])`).
  A non-empty list literal is fine, as is `some x`.

  Dot-notation also does not see through the wrapper: at an expected type of
  `Expr K SecretSource`, `.foo` resolves against `Expr`, not `SecretSource`.
  Payload constructors therefore need qualifying, or a helper.
-/

namespace Infra.Core

variable {K : ProviderId → Kind → Type}

/-- A value is a literal expression. The chainable link, so it composes with
    the one below to reach an optional field. -/
instance instCoeExpr {α : Type} : Coe α (Expr K α) := ⟨Expr.lit⟩

/-- An expression is a specified optional field.

    Deliberately pinned to `Expr`, not the general `CoeTail α (Partial α)`.
    `Partial` and `Option` mean genuinely different things here — "not yet
    said" versus "said: nothing" (see `SecretsSpec`'s and `Partial`'s own doc
    comments) — and `Partial` also means "could not see" in a `Reported`
    position. A general instance would let one keystroke cross those lines
    outside the authoring layer, e.g. `(h : Handle .s3Bucket)` standing for
    `Partial (Option (Handle .s3Bucket))`. Restricting the *tail* costs
    nothing at the authoring sites this exists for, because the chainable
    `Coe` link above stays generic. -/
instance instCoeTailPartialExpr {α : Type} :
    CoeTail (Expr K α) (Partial (Expr K α)) := ⟨Partial.known⟩

/-
  Numerals need their own instances rather than riding the coercions above.

  Lean elaborates a numeral against the *expected* type via `OfNat` before it
  will consider inserting a coercion, so `port := 8200` fails on a missing
  `OfNat (Partial (Expr K Nat)) 8200` without ever reaching `instCoeExpr` —
  whereas `versioning := true` and `tags := [...]` do reach it, since `Bool`
  and list literals are not numerals. These two restore the symmetry.
-/

instance instOfNatExpr {α : Type} {n : Nat} [OfNat α n] : OfNat (Expr K α) n :=
  ⟨Expr.lit (OfNat.ofNat n)⟩

/-- Pinned to `Expr` for the same reason as `instCoeTailPartialExpr`. -/
instance instOfNatPartialExpr {α : Type} {n : Nat} [OfNat α n] :
    OfNat (Partial (Expr K α)) n :=
  ⟨Partial.known (Expr.lit (OfNat.ofNat n))⟩

end Infra.Core
