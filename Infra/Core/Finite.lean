/-
  General-purpose pieces the rest of the core needs, kept in one place so `Infra.Core.Refine`
  and `Infra.Core.Fleet` don't each grow their own copy.

  Core Lean 4 only — no Mathlib.
-/

namespace Infra.Core

universe u

/-- The identity functor. `Id` is core Lean's identity *monad*, so we can't reuse that name.
    `Conc` = "concrete": no wrapper, value is known now. -/
@[reducible] def Conc (α : Type u) : Type u := α

/-- Duplicate-freeness, spelled out so we don't depend on `List.Nodup`. -/
def Nodup {α : Type u} : List α → Prop
  | []      => True
  | a :: as => a ∉ as ∧ Nodup as

/-- So a `Finite` instance can discharge its own `nodup` field with `by decide`. -/
instance decidableNodup {α : Type u} [DecidableEq α] : (l : List α) → Decidable (Nodup l)
  | []      => isTrue trivial
  | a :: as =>
    match decidableNodup as with
    | isTrue h  => if ha : a ∈ as then isFalse (fun hn => hn.1 ha) else isTrue ⟨ha, h⟩
    | isFalse h => isFalse (fun hn => h hn.2)

/-- A type with a known, finite, duplicate-free enumeration.

    This is the backbone of the whole design. Because keys form a `Finite` type and a fleet is
    a *total function* out of it (see `Infra.Core.Plan`), we get for free:

      * exhaustiveness  — forget a key and the function is incomplete, which is an error
      * no duplicates   — a function cannot have two values at one argument
      * a known cardinality, at compile time.

    This is exactly `Σ (I : FinSet), (I → T)` — the container shape. -/
class Finite (α : Type u) where
  elems    : List α
  complete : ∀ a : α, a ∈ elems
  nodup    : Nodup elems

/-- Cardinality. Reducible so `by decide` can see through it. -/
@[reducible] def card (α : Type u) [Finite α] : Nat :=
  (Finite.elems (α := α)).length

/-- A decidable side condition discharged at elaboration time.

    Used as an auto-param: `(h : Assert (acyclic t) := by decide)`. The caller writes nothing;
    a violation is a compile error, via evaluation rather than typing. -/
@[reducible] def Assert (b : Bool) : Prop := b = true

/-- `Void`, for `(provider, kind)` pairs a fleet does not use.

    This is what makes "a plan cannot mention what its provider lacks" a typing fact rather
    than a validation pass: an unsupported pair gets `Nothing` as its key type, and there is
    no key to write down. -/
inductive Nothing : Type where

instance : DecidableEq Nothing := fun a => nomatch a

instance : Repr Nothing := ⟨fun a => nomatch a⟩

instance : Finite Nothing where
  elems := []
  complete := fun a => nomatch a
  nodup := trivial

end Infra.Core
