# Diff Semantics

## Problem

`docs/architecture.md` calls for objects to "be diff-able at their structure level" so an
engine can move current state to target, and for dependent types to make impossible states
non-representable. Two questions had to be settled before either could be implemented:

1. What does a target that only says *some* of what it wants actually mean, and what should the
   engine do about the parts it leaves unsaid?
2. What does a target say about resources it does not mention at all?

An earlier draft of this document answered the first by treating a target type as a *supertype*
of its state type, with each field widened to `Option`. **That framing is superseded.** It
conflated two things that need to be kept apart, and it had no good answer to the second
question.

## Two axes, kept apart

- The **nominal** axis — `Kind`, and specs indexed by it (`Infra/Core/Kind.lean`,
  `Infra/Specs/Basic.lean`). Which sort of thing a resource is. Different kinds have different
  field sets and different behaviour. This is where subtyping is the right tool, and it is
  settled statically.
- The **refinement** axis — `Partial`, ordered by `⊑` (`Infra/Core/Refine.lean`). How much of a
  given kind's spec has been pinned down. **A target is a value, not a type**: it can be
  serialised, stored, diffed and merged.

The supertype framing put the second axis on the first, which is why it kept running into
trouble. Nothing about "how much has been said" belongs in a type relation.

The design rule running through all of it: **an unrealisable target should not be
representable.** The ledger at the end records exactly what that buys and what it does not.

## The refinement order `⊑`

```lean
class Refines (α : Type u) where
  refines : α → α → Bool

def refines [Refines α] (a b : α) : Prop := Refines.refines a b = true
infix:50 " ⊑ " => refines
```

`a ⊑ b` reads "`b` pins down everything `a` pins down, and possibly more."

**It is `Bool`-valued, not `Prop`-valued.** Every instance is then automatically decidable and
usable from both `by decide` and the runtime differ, with no `Decidable` boilerplate. The order
laws live in a separate `LawfulRefines` class, split off à la `BEq`/`LawfulBEq`, so you can
compute long before you have proved anything.

**It is deliberately not `≤`.** `Nat`, `String` and `Int` already have a `≤` meaning something
else, and reusing it would silently give `"a" ⊑ "b"`. Ground types are **flat** — you either
know the value or you don't:

```lean
@[reducible] def flat (α : Type u) [BEq α] : Refines α := ⟨fun a b => a == b⟩
```

so `(3 : Nat) ⊑ 5` is **false**, and there is a `#guard` in `Infra/Core/Refine.lean` saying so.

### `Partial` — the hole

```lean
inductive Partial (α : Type u)
  | unknown        -- ⊥
  | known (a : α)
```

`unknown` is ⊥, below everything. It is deliberately *one* constructor covering three
situations that behave identically under merge and diff: the author chose not to specify, the
value is only known after apply, or the observation of the world is incomplete.

Note what `Partial` is **not**: a spec field of type `Option τ` means "said: nothing", whereas
`Partial τ`'s `unknown` means "not yet said". `ScalewayFunctionSpec.sourceBucket` is
`Field .optional o f (Option (K .aws .s3Bucket))` precisely so both are expressible and neither
is faked with an `Inhabited` witness.

## Merge is partial

```lean
class Merge (α : Type u) [Refines α] where
  merge : α → α → Option α
```

`{port := 80}` and `{port := 443}` have no common upper bound, so `merge` returns `none` rather
than saturating to an uninformative ⊤. `none` is also where you attach *which* field and
*which* writers collided, which is what multi-writer reconciliation needs. `LawfulMerge` states
that a successful merge really is a least upper bound.

## Collection level: `Status` and totality

The second question — what a target says about what it does not mention — is answered by making
it impossible not to mention things.

```lean
inductive Status (V : Type u)
  | unmanaged        -- ⊥: not my business. Anything goes.
  | absent           -- must not exist  ⇒ DELETE
  | present (v : V)  -- must exist, refining `v`  ⇒ CREATE / UPDATE
```

and, in `Infra/Core/Fleet.lean`, `Plan.assign` is a **total function** over a `Finite` key type:

```lean
structure Plan (κ : Keys) where
  assign  : (p : ProviderId) → (k : Kind) → (key : κ.Key p k) → Status (SpecOf k …)
  outside : Status Unit
```

Totality is the single decision doing most of the work:

- **total** ⇒ no key can be forgotten, and `absent` is expressible, so **deletion is part of the
  target rather than an inference from omission**. A partial map can only ever say "at least
  these".
- **a function** ⇒ duplicate keys are unrepresentable.
- **finite domain** ⇒ cardinality is known at compile time even when every field inside is
  `unknown`. Shape outside the modality, contents inside: a fleet may have three unknown
  handles, never an unknown number of instances.

`outside` is the disposition of keys outside the fleet's key types: `absent` for a closed world
that garbage-collects, `unmanaged` for an open one.

Because `unmanaged` is ⊥, a plan whose every key is `unmanaged` is satisfied by *any* world and
produces an empty work-list — `Infra/Demo.lean` guards exactly that. This is also what makes a
real `list` safe to plug in: `pullEntries` keeps only resources some fleet key claims, so an
account full of unmanaged buckets cannot become a pile of proposed deletions.

`Status` has **no ⊤ constructor**. An inconsistent target is therefore not a value you can hold;
inconsistency surfaces only as `Merge.merge = none`, at the moment two writers collide, with the
collision site available for a diagnostic.

## Why there is no `Delta`

An earlier core had a `Delta` type per state struct, computed by `diff` and consumed by
`apply`. It is gone. With `⊑`, **the target is the patch**: what a target says is exactly what
must be made true, and what it leaves `unknown` is exactly what must be left alone. The old
`Delta` structs each had precisely their target's field set, which was the same observation
without the theory behind it.

## Ledger: what is a compile error, and what is not

**Structurally impossible** — no check, no proof, simply not representable:

| | |
|---|---|
| Dangling reference | a reference is `κ.Key p k`, an index into this very fleet; there is no "not found" case |
| Mistyped reference | `Handle` and `Key` are `Kind`-indexed |
| Duplicate key | `Plan.assign` is a function |
| Forgotten key | `assign` is total over a `Finite` domain |
| Missing required field | `Field .required` is unwrapped, so the structure literal is incomplete |
| Conflicting status | `Status` has no ⊤ constructor |
| Unknown-dependent shape | `Expr` has no `bind`, so cardinality can never depend on a post-apply value |
| Unhandled kind | `SpecOf`, `ObservedOf`, `fillableOf` and `hasDepsOf` are total over `Kind` |
| Using a kind a provider lacks | that `(provider, kind)` pair's `Key` is `Nothing`, so there is no key to write down |

**Decidable**, dischargeable with `(h : Assert … := by decide)` — still a compile error, but via
evaluation rather than typing: acyclicity of the dependency graph, quota bounds such as
`Assert (κ.count .aws .compute ≤ 20)`, name-format constraints.

**Genuinely runtime** — no type system reaches these: global uniqueness of bucket names, quota
and capacity, eventual consistency, whether an `absent` resource is still referenced from
outside the fleet.

### Known soft spots

- **`Refines` is not given for spec structures.** `satisfies` therefore checks only the
  *extent* half — existence and non-existence — not that the observed spec refines the target
  spec. An authored field holds an `Expr`, which contains functions and so has no decidable
  order until it has been evaluated against a world; the field-wise instance belongs at a
  resolved stage. Until then a new spec field is silently not compared. A `deriving` handler
  would fix the fragility; the alternative is the dependent-record encoding
  `(fld : Fld k) → Partial (Ty fld)`, which derives `⊑` once and for all at the cost of
  dot-notation.
- **`LawfulMerge` has no instances yet** — `Merge` computes, but nothing proves it is a least
  upper bound.
- **Antisymmetry of `⊑` on `Plan`** needs `funext` plus antisymmetry at each kind. It holds; it
  is not proved.
- **`HasDeps` only sees literal references.** `Expr.asLit` reads a key back out of a `.lit`,
  which is sound because keys are plan-time constants, but a reference smuggled through
  `map`/`ap` would go unnoticed.
- **No realisability check at the fleet level.** `Fillable` certifies that each *kind* can be
  filled, but nothing yet forces a `Plan` through `fill` before apply.

## Not yet adopted

- **Executing the plan.** `actions` produces the work-list and `Action` carries its direction
  explicitly, but nothing runs it. Ordering needs the creation DAG from `HasDeps` unioned with
  the reversed deletion DAG; executing needs live provider clients. Neither exists yet.
- **`Mutability.forcesReplace`** is defined but unused: no per-field mutability table means
  `Action.replace` is never produced.
- **Field-level constraints richer than "exact value or nothing"** — `AtLeast 4`, a region set,
  a version range: targets a provider could satisfy several ways. `Refines` is general enough
  to host them (nothing about the class demands flatness), but every current instance is flat.
