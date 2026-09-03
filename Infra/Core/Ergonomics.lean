import Infra.Core.Fleet

/-
  Ergonomic fleet declaration.

  `Infra.Demo` is a demonstration, not a template: every resource-set there gets a hand-written
  `inductive` enum plus a hand-proved `Finite` instance, then a hand-written `(provider, kind) →
  key-type` match, a `name` match, and an `assign` match arm per resource. That is proportionate
  ceremony for one demo fleet and disproportionate for a real consumer project declaring dozens
  of resources.

  This module adds three additive combinators that collapse that ceremony without changing any
  of the theory in `Infra.Core.Fleet`: `NamedKey` gives `Finite`+`DecidableEq` generically for
  any `List String`, `Keys.build` collapses the `Key`/`finite`/`decEq`/`name` quadruple into one
  table, and `Keys.assignFromNamed` collapses a `Plan.assign` bucket into a name-indexed
  association list. A hand-rolled `inductive` remains available, and `Keys`/`Plan` remain
  ordinary values either way — nothing here is a new mechanism, only less boilerplate to reach
  the existing one.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

/-! ## `NamedKey` — a generic, list-backed key type -/

/-- Every reference this expression makes, generalised to "no duplicates in a mapped list",
    proved once here rather than per use of `NamedKey`. -/
private theorem nodupMapOfInjective {α β : Type u} {f : α → β}
    (hf : ∀ a a', f a = f a' → a = a') :
    ∀ l : List α, Nodup l → Nodup (l.map f)
  | [], _ => trivial
  | a :: as, ⟨ha, hrest⟩ => by
      refine ⟨?_, nodupMapOfInjective hf as hrest⟩
      intro hmem
      obtain ⟨a', ha', heq⟩ := List.mem_map.mp hmem
      have haa' : a' = a := hf a' a heq
      exact ha (haa' ▸ ha')

private theorem finRangeNodup : ∀ n : Nat, Nodup (List.finRange n)
  | 0 => trivial
  | n + 1 => by
      rw [List.finRange_succ]
      refine ⟨?_, nodupMapOfInjective (fun _ _ h => Fin.succ_inj.mp h) _ (finRangeNodup n)⟩
      intro hmem
      obtain ⟨a, _, heq⟩ := List.mem_map.mp hmem
      exact Fin.succ_ne_zero a heq

/-- A key backed by an index into a fixed list of resource names.

    Replaces the need for a bespoke `inductive` plus a hand-proved `Finite` instance per
    resource-set: `NamedKey ["assets", "logs"]` gives exactly the two-element finite,
    decidable-equality key type `Infra.Demo.Bucket` does by hand, for any `names` literal.

    Trade-off, spelled out rather than hidden: a hand-rolled `inductive`'s constructors are
    structurally distinct, so "no duplicate key" is unconditional. Here it is a decidable
    side-condition on `names` instead — see `KeySpec.named` below and the ledger entry in
    `docs/diff-semantics.md`. A hand-rolled `inductive` stays available for anyone who wants
    the stronger, unconditional guarantee. -/
structure NamedKey (names : List String) where
  idx : Fin names.length
  deriving DecidableEq

namespace NamedKey

variable {names : List String}

instance : Finite (NamedKey names) where
  elems := (List.finRange names.length).map (⟨·⟩)
  complete a := List.mem_map.mpr ⟨a.idx, List.mem_finRange a.idx, rfl⟩
  nodup :=
    nodupMapOfInjective (fun _ _ h => congrArg NamedKey.idx h)
      (List.finRange names.length) (finRangeNodup names.length)

/-- The name this key was given. -/
def name (k : NamedKey names) : String := names[k.idx.val]'k.idx.isLt

private def indexOfAux : (ns : List String) → String → Option (Fin ns.length)
  | [], _ => none
  | n :: ns, s =>
    if n = s then
      some ⟨0, Nat.zero_lt_succ _⟩
    else
      (indexOfAux ns s).map Fin.succ

/-- Pick a key by its string name, checked decidably against `names` at elaboration time —
    a typo or a renamed resource is a compile error, not a runtime `none`. -/
def of (names : List String) (s : String)
    (h : Assert (indexOfAux names s).isSome := by decide) : NamedKey names :=
  ⟨(indexOfAux names s).get h⟩

end NamedKey

/-! ## `Keys.build` — one table instead of a `Key`/`finite`/`decEq`/`name` quadruple -/

/-- Whether a list of names has no duplicate. Decidable and evaluable on a literal, which is
    what lets `KeySpec.named`'s side-condition be discharged by `by decide` at the call site. -/
def namesNodup : List String → Bool
  | []      => true
  | n :: ns => !ns.contains n && namesNodup ns

/-- One row of a `Keys.build` table.

    `.unused` gives the `(provider, kind)` pair `Nothing` as its key type — **this is the
    scoping mechanism**: a pair a fleet does not list has no key to assign anything to, so
    `Plan.assign` cannot mention it, and whatever exists there in the cloud is left alone
    unconditionally. To manage some resources of a kind while leaving others alone, list only
    the managed ones' names; there is no separate "unmanaged within a kind" flag, and none is
    needed — see `docs/diff-semantics.md`.

    `.named names` gives the pair a `NamedKey names`. `names` must be duplicate-free: two equal
    names would let `Keys.name` map two distinct keys to the same on-disk cache string (see
    `docs/persistence.md`), so the check is a decidable side-condition on the constructor rather
    than skippable. -/
inductive KeySpec where
  | unused
  | named (names : List String) (h : Assert (namesNodup names) := by decide)

@[reducible] def KeySpec.Ty : KeySpec → Type
  | .unused        => Nothing
  | .named names _ => NamedKey names

@[instance_reducible] def KeySpec.finite : (spec : KeySpec) → Finite spec.Ty
  | .unused        => inferInstanceAs (Finite Nothing)
  | .named names _ => inferInstanceAs (Finite (NamedKey names))

@[instance_reducible] def KeySpec.decEq : (spec : KeySpec) → DecidableEq spec.Ty
  | .unused        => inferInstanceAs (DecidableEq Nothing)
  | .named names _ => inferInstanceAs (DecidableEq (NamedKey names))

def KeySpec.name : (spec : KeySpec) → spec.Ty → String
  | .unused,       key => nomatch key
  | .named _ _,    key => key.name

attribute [instance] KeySpec.finite KeySpec.decEq

/-- Collapse the `Key`/`finite`/`decEq`/`name` quadruple `Infra.Demo` writes by hand into one
    total table over `(ProviderId, Kind)` — still compiler-checked complete, because `table` is
    an ordinary total function. See `KeySpec`'s doc comment for the scoping mechanism this
    gives for free. -/
def Keys.build (table : ProviderId → Kind → KeySpec) : Keys where
  Key    p k := (table p k).Ty
  finite p k := (table p k).finite
  decEq  p k := (table p k).decEq
  name   p k := (table p k).name

/-! ## `Keys.assignFromNamed` — one association list instead of a `match` arm per resource -/

/-- Build one `Plan.assign` bucket at `(p, k)` from a name-indexed association list, checked
    decidably for covering every key `κ.name p k` can produce — instead of a hand-written
    `match` arm per resource. Works over `NamedKey` or a hand-rolled `inductive` alike, since
    both go through `Keys.name`.

    The `.unmanaged` fallback is not a scoping device — see `KeySpec`'s doc comment for the
    actual one — it is only what a key `h` failed to cover would fall back to; `h` is what
    makes that unreachable in practice. -/
def Keys.assignFromNamed {κ : Keys} (p : ProviderId) (k : Kind)
    (entries : List (String × Status (SpecOf.{1} k κ.Key Partial (Expr κ.Key))))
    (_h : Assert ((Finite.elems (α := κ.Key p k)).all fun key =>
           entries.any fun e => e.1 == κ.name p k key) := by decide) :
    (key : κ.Key p k) → Status (SpecOf.{1} k κ.Key Partial (Expr κ.Key)) :=
  fun key => ((entries.find? fun e => e.1 == κ.name p k key).map (·.2)).getD .unmanaged

/-! ## Self-checks -/

private def testNames : List String := ["master-key", "db-password"]

#guard (Finite.elems (α := NamedKey testNames)).length = 2
#guard (NamedKey.of testNames "master-key").name = "master-key"
#guard (NamedKey.of testNames "db-password").name = "db-password"

private def testTable : ProviderId → Kind → KeySpec
  | .aws, .secrets => .named testNames
  | _,    _        => .unused

private def testKeys : Keys := Keys.build testTable

#guard (Finite.elems (α := testKeys.Key .aws .secrets)).length = 2
#guard (Finite.elems (α := testKeys.Key .aws .compute)).length = 0
#guard testKeys.name .aws .secrets (NamedKey.of testNames "master-key") = "master-key"

-- A `.named` list with a duplicate is rejected at elaboration time, not at runtime:
-- `KeySpec.named ["a", "a"]` would fail to compile, because `namesNodup ["a", "a"] = false`
-- and `by decide` cannot close `Assert false`.
#guard namesNodup testNames = true
#guard namesNodup ["dup", "dup"] = false

end Infra.Core
