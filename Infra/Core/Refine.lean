import Infra.Core.Finite
import Lean.Data.Json

/-
  The refinement axis: how much of a spec has been pinned down.

  This is a *value-level* order, deliberately kept apart from the nominal axis
  (`Infra.Core.Kind`, where subtyping is the right tool and everything is settled
  statically). A target is a value — it can be serialised, stored, diffed and merged.
  See `docs/diff-semantics.md`.
-/

namespace Infra.Core

universe u

open Lean (Json ToJson FromJson toJson fromJson?)

/-! ## The refinement order `⊑` -/

/-- "Less determined than."

    Deliberately NOT core's `≤`. `Nat`, `String`, `Int` already have a `≤` meaning something
    else; reusing it would silently give `"a" ⊑ "b"`, i.e. "a is less determined than b",
    which is nonsense.

    `Bool`-valued rather than `Prop`-valued so that every instance is automatically decidable
    and usable both from `by decide` and from the runtime differ, with no `Decidable`
    boilerplate. -/
class Refines (α : Type u) where
  refines : α → α → Bool

/-- `a ⊑ b` : `b` pins down everything `a` pins down, and possibly more. -/
def refines {α : Type u} [Refines α] (a b : α) : Prop :=
  Refines.refines a b = true

scoped infix:50 " ⊑ " => Infra.Core.refines

instance {α : Type u} [Refines α] (a b : α) : Decidable (a ⊑ b) :=
  inferInstanceAs (Decidable (_ = true))

/-- The order laws, split off from the data à la `BEq`/`LawfulBEq`, so you can compute long
    before you have proved anything. -/
class LawfulRefines (α : Type u) [Refines α] : Prop where
  refl     : ∀ a : α, a ⊑ a
  trans    : ∀ {a b c : α}, a ⊑ b → b ⊑ c → a ⊑ c
  antisymm : ∀ {a b : α}, a ⊑ b → b ⊑ a → a = b

/-- Ground types are **flat**: you either know the value or you don't.
    Note `(3 : Nat) ⊑ 5` is *false* here — that is the point of not reusing `≤`. -/
@[reducible] def flat (α : Type u) [BEq α] : Refines α := ⟨fun a b => a == b⟩

section Flat
variable {α : Type u} [BEq α] [LawfulBEq α]

theorem flat_lawful : @LawfulRefines α (flat α) := by
  letI := flat α
  constructor
  · intro a; show (a == a) = true; simp
  · intro a b c h₁ h₂
    have h₁' : a = b := eq_of_beq h₁
    have h₂' : b = c := eq_of_beq h₂
    subst h₁'; subst h₂'; show (a == a) = true; simp
  · intro a b h _
    exact eq_of_beq h

end Flat

instance : Refines String := flat String
instance : LawfulRefines String := flat_lawful
instance : Refines Nat := flat Nat
instance : LawfulRefines Nat := flat_lawful
instance : Refines Bool := flat Bool
instance : LawfulRefines Bool := flat_lawful

/-! ## `Partial` — the hole -/

/-- A value that may not be determined yet.

    `unknown` is ⊥. It is deliberately ONE constructor covering three situations that all
    behave identically under merge and diff:

      * the author chose not to specify (the controller may pick)
      * the value is only known after apply (a provider-assigned handle)
      * the observation of the world is incomplete or stale

    Note the contrast with `Option` in a spec field: `unknown` means "not yet said", whereas
    `Option`'s `none` means "said: nothing". They are not the same and are not conflated. -/
inductive Partial (α : Type u) where
  | unknown
  | known (a : α)
  deriving Repr, DecidableEq, BEq

namespace Partial

def refinesB {α : Type u} [Refines α] : Partial α → Partial α → Bool
  | unknown, _        => true
  | known _, unknown  => false
  | known a, known b  => Refines.refines a b

def isKnown {α : Type u} : Partial α → Bool
  | unknown => false
  | known _ => true

/-- Fill a hole with a default. -/
def getD {α : Type u} : Partial α → α → α
  | unknown, d => d
  | known a, _ => a

end Partial

instance {α : Type u} [Refines α] : Refines (Partial α) := ⟨Partial.refinesB⟩

instance {α : Type u} [Refines α] [LawfulRefines α] : LawfulRefines (Partial α) where
  refl a := by
    cases a with
    | unknown => rfl
    | known x => exact LawfulRefines.refl x
  trans {a b c} h₁ h₂ := by
    cases a with
    | unknown => rfl
    | known x =>
      cases b with
      | unknown => exact absurd h₁ (by simp [refines, Refines.refines, Partial.refinesB])
      | known y =>
        cases c with
        | unknown => exact absurd h₂ (by simp [refines, Refines.refines, Partial.refinesB])
        | known z => exact LawfulRefines.trans (a := x) (b := y) (c := z) h₁ h₂
  antisymm {a b} h₁ h₂ := by
    cases a with
    | unknown =>
      cases b with
      | unknown => rfl
      | known y => exact absurd h₂ (by simp [refines, Refines.refines, Partial.refinesB])
    | known x =>
      cases b with
      | unknown => exact absurd h₁ (by simp [refines, Refines.refines, Partial.refinesB])
      | known y => exact congrArg Partial.known (LawfulRefines.antisymm h₁ h₂)

/-- `unknown` serialises as `null`. `Cloud.lean` has no persistence layer; this is what
    `docs/persistence.md` needs to cache a partially-known world. -/
instance {α : Type} [ToJson α] : ToJson (Partial α) where
  toJson
    | .unknown => Json.null
    | .known a => toJson a

instance {α : Type} [FromJson α] : FromJson (Partial α) where
  fromJson?
    | Json.null => .ok .unknown
    | j         => (fromJson? j).map .known

/-! ## Merge — partial, because `⊔` is not total -/

/-- Least upper bound, when one exists.

    `{port := 80}` and `{port := 443}` have no common upper bound, so this returns `none`
    rather than saturating to an uninformative ⊤. `none` is also where you attach *which*
    field and *which* owners collided, which is what multi-writer (server-side-apply style)
    reconciliation needs. -/
class Merge (α : Type u) [Refines α] where
  merge : α → α → Option α

/-- Soundness of a `Merge`: when it succeeds it really is a least upper bound. -/
class LawfulMerge (α : Type u) [Refines α] [Merge α] : Prop where
  ub    : ∀ {a b c : α}, Merge.merge a b = some c → a ⊑ c ∧ b ⊑ c
  least : ∀ {a b c d : α}, Merge.merge a b = some c → a ⊑ d → b ⊑ d → c ⊑ d

/-- Flat leaves merge iff they agree. -/
@[reducible] def flatMerge (α : Type u) [Refines α] [BEq α] : Merge α :=
  ⟨fun a b => if a == b then some a else none⟩

instance : Merge String := flatMerge String
instance : Merge Nat := flatMerge Nat
instance : Merge Bool := flatMerge Bool

instance {α : Type u} [Refines α] [Merge α] : Merge (Partial α) where
  merge
    | .unknown, y => some y
    | x, .unknown => some x
    | .known a, .known b => (Merge.merge a b).map .known

/-! ## `Status` — creation and deletion in one lattice -/

/-- Per-key intent.

    NOTE the absent constructor: there is no `conflict`/⊤. An inconsistent target is
    therefore not a *value you can hold*; inconsistency shows up only as
    `Merge.merge = none`, at the moment two writers collide, with the collision site
    available for a diagnostic.

    `unmanaged` is ⊥ and is what makes open-world scoping expressible alongside closed-world
    deletion — the distinction `docs/diff-semantics.md` derives at the collection level. -/
inductive Status (V : Type u) where
  | unmanaged          -- ⊥: not my business. Anything goes.
  | absent             -- must not exist  ⇒ DELETE
  | present (v : V)    -- must exist, refining `v`  ⇒ CREATE / UPDATE
  deriving Repr, DecidableEq, BEq

namespace Status

def refinesB {V : Type u} [Refines V] : Status V → Status V → Bool
  | unmanaged, _           => true
  | absent,    absent      => true
  | present a, present b   => Refines.refines a b
  | _,         _           => false

def merge {V : Type u} [Refines V] [Merge V] :
    Status V → Status V → Option (Status V)
  | unmanaged, y => some y
  | x, unmanaged => some x
  | absent, absent => some absent
  | present a, present b => (Merge.merge a b).map present
  | _, _ => none            -- absent vs present: genuine cross-writer conflict

end Status

instance {V : Type u} [Refines V] : Refines (Status V) := ⟨Status.refinesB⟩
instance {V : Type u} [Refines V] [Merge V] : Merge (Status V) := ⟨Status.merge⟩

section Guards

-- Flatness: the whole reason `⊑` is not `≤`.
#guard !(Refines.refines (3 : Nat) 5)
#guard Refines.refines (3 : Nat) 3

-- `unknown` is ⊥: below anything, and nothing but itself is below it.
#guard Refines.refines (Partial.unknown : Partial Nat) (.known 7)
#guard Refines.refines (Partial.unknown : Partial Nat) .unknown
#guard !(Refines.refines (Partial.known 7 : Partial Nat) .unknown)
#guard !(Refines.refines (Partial.known 7 : Partial Nat) (.known 8))

-- Merge is a least upper bound where one exists, and reports collisions rather than
-- saturating to an uninformative top.
#guard Merge.merge (Partial.unknown : Partial Nat) (.known 80) = some (.known 80)
#guard (Merge.merge (Partial.known 80 : Partial Nat) (.known 443)).isNone
#guard Merge.merge (Partial.known 80 : Partial Nat) (.known 80) = some (.known 80)

-- `Status`: `unmanaged` is ⊥, and `absent` vs `present` is a genuine conflict.
#guard Refines.refines (Status.unmanaged : Status Nat) .absent
#guard Refines.refines (Status.unmanaged : Status Nat) (.present 1)
#guard !(Refines.refines (Status.absent : Status Nat) (.present 1))
#guard Status.merge (Status.unmanaged : Status Nat) .absent = some .absent
#guard (Status.merge (Status.absent : Status Nat) (.present 1)).isNone

end Guards

end Infra.Core
