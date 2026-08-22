/-
  Object-level structural diff between a (partial) target state and a concrete current
  (remote) state, per `docs/architecture.md`'s "Definitions" section.

  A diff is only ever computed between a `Target` and a `Current` — never between two
  values of the same type, and never composed with another diff. A target field left unset
  means "use the provider default on create, or leave as-is if already set" — not "no
  opinion forever."
-/

namespace Infra.Core

/-- A single field's patch: `none` means "nothing to do" — either the target left this
    field unset, or it's already what `current` has; `some v` means "call the API to set
    this field to `v`." This is the piece a `push` implementation pattern-matches on to
    decide which requests to build. -/
def fieldDiff [DecidableEq β] (target : Option β) (current : β) : Option β :=
  target.bind fun v => if v = current then none else some v

/-- What `current`'s field becomes after the patch is applied. -/
def fieldApply (current : β) (patch : Option β) : β :=
  patch.getD current

/-- Whether an optionally-specified target field is honored by a concrete current value:
    trivially true if the target left it unset. -/
def fieldSatisfied (target : Option β) (current : β) : Prop :=
  target.isNone ∨ target = some current

/-- The real content of a field-level diff: applying it always satisfies the target,
    regardless of what `current` started as. Proved once, reused by every instance below. -/
theorem fieldSatisfies_fieldApply [DecidableEq β] (target : Option β) (current : β) :
    fieldSatisfied target (fieldApply current (fieldDiff target current)) := by
  cases target with
  | none => exact Or.inl rfl
  | some v => by_cases h : v = current <;> simp [fieldDiff, fieldApply, fieldSatisfied, h]

/-- `diff` computes the patch needed to bring `current` in line with `target` — carrying
    per-field values, not just changed-flags, so `push` implementations have what they need
    to build API requests directly off `Delta`. `apply` is the pure "what current becomes"
    side, used to state the one law every instance must prove: applying the computed diff
    always reaches a state that honors everything the target actually specified. The
    all-`none`/`{}` value of `Delta` is "nothing to push" — the target is already realized.
    No composition, no associativity: a `Delta` is never combined with another `Delta`. -/
class Diffable (Target Current : Type) where
  Delta                : Type
  diff                 : Target → Current → Delta
  apply                : Current → Delta → Current
  Satisfies            : Target → Current → Prop
  satisfies_apply_diff : ∀ t c, Satisfies t (apply c (diff t c))

end Infra.Core
