import Std.Data.HashMap

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

/-- Reconciling a keyed *collection* of target specs against a keyed collection of current
    objects — see `docs/diff-semantics.md`. Matched by a local, user-assigned key (e.g.
    `"my_bucket"`), analogous to Terraform's resource address: distinct from `Keyed`/
    `ObjectKey`, which only exists for objects that already have a provider-assigned id.
    Implements the three rules directly: a key present only in `targets` has nothing to
    reconcile it against, so it must be created; a key present only in `currents` is no
    longer wanted, so it must be deleted; a key present in both is reconciled at the field
    level via the existing `Diffable.diff`. -/
structure CollectionDelta (Target Current : Type) [Diffable Target Current] where
  toCreate : List (String × Target)
  toUpdate : List (String × Current × Diffable.Delta (Target := Target) (Current := Current))
  toDelete : List (String × Current)

/-- `toUpdate` includes every shared key, even when its computed `Delta` is the all-`none`
    "nothing to push" value — callers already know to skip an empty `Delta` (see
    `SyncEngine`), so reconciliation doesn't need a second notion of "unchanged". -/
def reconcile [Diffable Target Current]
    (targets  : List (String × Target))
    (currents : List (String × Current)) :
    CollectionDelta Target Current :=
  let currentMap := Std.HashMap.ofList currents
  let targetMap  := Std.HashMap.ofList targets
  { toCreate := targets.filter fun (k, _) => !currentMap.contains k
    toDelete := currents.filter fun (k, _) => !targetMap.contains k
    toUpdate := targets.filterMap fun (k, t) =>
      (currentMap.get? k).map fun c => (k, c, Diffable.diff t c) }

end Infra.Core
