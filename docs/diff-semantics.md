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

An earlier core had a `Delta` type per state struct, computed by `diff` and
consumed by `apply`. It is gone. With `⊑`, **the target is the patch**: what a
target says is exactly what must be made true, and what it leaves `unknown` is
exactly what must be left alone. The old `Delta` structs each had precisely
their target's field set, which was the same observation without the theory.

## From target to action

Deciding what to do needs both halves of a `Sighting` — the provider-computed
`ObservedOf` and the configuration actually in force, `Reported`. Existence
alone can only ever produce create and delete.

`Infra/Core/Diverge.lean` carries a per-kind table naming each field and
whether it can be changed in place:

```lean
class Divergent (k : Kind) where
  divergence : ProviderSpec k → Reported k → List (String × Mutability)
```

from which `repairOf` gives four outcomes:

| divergence | outcome |
|---|---|
| empty | **nothing** — already right |
| all `mutable` | `update` |
| any `forcesReplace` | `replace` |
| resource absent | `create` |

The first row is the one an extent-only comparison could never produce, and it
is what makes a second apply come back empty.

### `unknown` is not drift

A field the provider did not report contributes nothing to the divergence list.
This is the same asymmetry the field level derives: the comparison runs
*observed ⊑ target*, not the reverse. Treating "could not see" as "differs"
would rewrite every resource on every apply — and several fields are genuinely
unreportable (see `docs/providers.md`).

### Lists compare as sets

Tags, policies and environment variables come back in whatever order the
service felt like. Positional comparison would report drift on untouched
resources, for ever.

## Settling: what a backend actually receives

`Plan.assign` yields `SpecOf k κ.Key Partial (Expr κ.Key)`; `Backend.create`
wants `ProviderSpec k = SpecOf k Resolved Conc Conc`. Two substitutions
separate them:

- `Partial → Conc`, which `Fillable.fill` has always done.
- `Expr κ.Key → Conc`, **and** rewriting residual `κ.Key p k` references into
  the `Handle k` the cloud assigned — which nothing did.

`Infra/Core/Settle.lean` adds the second. It cannot be generic — Lean cannot
traverse an arbitrary record's fields — so it is one instance per kind, like
`Fillable`, `HasDeps` and `Divergent`. It is indexed by `Kind` rather than by
`SpecShape` because the input sits at universe 1 and the output at universe 0;
a shape-parameterised class would have to fix one.

`settle` returns `Option`: a reference to a resource that does not exist yet is
a scheduling fact, not a failure, and `push` creates dependencies first
precisely so it becomes `some` in time.

## Ordering

`push` schedules creates by the `HasDeps` graph and deletions by its transpose
— create B then A means delete A then B — which is why `Action` carries its
direction rather than letting the scheduler infer it.

The sort is Kahn's algorithm bounded by the step count. The bound is a genuine
measure, not fuel: every round removes at least one step, so exhausting it means
a cycle, and the same argument gives both termination and the diagnosis.

Dry run is the default, and performs **no** backend IO — it returns before
reaching one. `actions` derives deletions from the target, so a mistaken key
type would otherwise destroy live resources on a first run.

## Ledger: what is a compile error, and what is not

**Structurally impossible** — no check, no proof, simply not representable:

| | |
|---|---|
| Dangling reference | a reference is `κ.Key p k`, an index into this very fleet; there is no "not found" case |
| Mistyped reference | `Handle` and `Key` are `Kind`-indexed |
| Duplicate key | `Plan.assign` is a function |
| Duplicate key, structurally | a hand-rolled `inductive` key type (`Infra/Demo.lean`'s style): constructors are structurally distinct |
| Forgotten key | `assign` is total over a `Finite` domain |
| Missing required field | `Field .required` is unwrapped, so the structure literal is incomplete |
| A resource that needs another but names none | a *required* reference — `awsInstance.securityGroup` is `Field .required` holding `K .aws .securityGroup`, so an instance with no security group is not a value that exists |
| Conflicting status | `Status` has no ⊤ constructor |
| Unknown-dependent shape | `Expr` has no `bind`, so cardinality can never depend on a post-apply value |
| Unhandled kind | `SpecOf`, `ObservedOf`, `fillableOf`, `hasDepsOf`, `divergentOf`, `settleableOf` and `Live.lean` are all total over `Kind` |
| Using a kind a provider lacks | that `(provider, kind)` pair's `Key` is `Nothing`, so there is no key to write down |
| A secret's *source* being ambiguous | `SecretSource` has two constructors, so "an env var name" and "a composed value" cannot both be given, nor neither |

**Decidable**, dischargeable with `(h : Assert … := by decide)`: acyclicity,
quota bounds such as `Assert (κ.count .aws .compute ≤ 20)`, name formats,
and — for `Infra.Core.Ergonomics`'s `NamedKey` — duplicate resource *names*.
`Infra/Demo.lean`'s hand-rolled `inductive` keys get "no duplicate key" for
free from constructor distinctness (the row above); `NamedKey (names : List
String)` is `Fin names.length` underneath, so two equal strings in `names`
would give two distinct keys the same `Keys.name`, and `KeySpec.named`'s
`Assert (namesNodup names)` is what catches that at the call site instead. A
consumer project that wants the stronger, unconditional guarantee can still
write a hand-rolled `inductive` — `NamedKey` trades that for less boilerplate,
not the other way round.

**A plaintext secret in the target** used to sit in the table above, on the
grounds that `secrets.valueFrom` and `postgres.masterPasswordSecret` hold
*names* and no field of either spec could hold a value. `Expr.secretValue`
changed that, and the honest statement is now weaker.

The reason for the change: a secret whose value is composed from post-apply
state — a connection string needing a master password and the endpoint a cloud
assigns at creation — previously took two `apply` runs with an operator
composing the string in between. A target can now hold the *function* instead
(`map`/`ap` over `.secretValue` and `.observed`), which is one apply and no
manual step. The applicative-only rule is intact: the plan's *shape* still
never depends on a post-apply value, only a field's value does.

The cost is that `SecretsSpec.valueFrom := .lit (.composed "hunter2")` is now
*expressible*. So the guarantee moves down one tier, to **decidable**:
`SecretsSpec.sourceIsSound` rejects a composed value with no dependencies
(a plaintext constant, whether written directly or laundered through `map`),
and `Plan.secretsAreSound` lifts that over a whole fleet — so
`#guard myPlan.secretsAreSound` restores a compile-time guarantee for anyone
who wants it, and `Infra.Core.Declare`'s `fleet` command makes it easy to
assert. What remains *structural* is that a secret value cannot be observed,
cached, or reported: `SecretsObserved` carries a version, never a value;
`.secrets`' `read` returns `valueFrom := .fromEnv ""`; and `Env.secretValue`
defaults to knowing nothing, so the planning path cannot hold one at all —
only `Engine.settleFor`, on the apply path, ever fills it in.

**Decidable, but not embeddable in the structure**: `PostgresSpec.hasCapacityChoice` — "at least
one of `instanceClass` or `{minCapacity, maxCapacity}` is set" — is a decidable `Bool` function,
same tier as the row above, but it cannot become a proof *field* on `PostgresSpec` the way
`KeySpec.named`'s check is a proof argument to a constructor. `PostgresSpec` is instantiated at
both the authoring stage (`o = Partial`, where `.isKnown` is meaningful) and the settled stage
(`o = Conc`, where optionality has already been erased); a field only well-typed at one stage
doesn't typecheck across both. The fix is a standalone function plus two smart constructors
(`PostgresSpec.classic`/`PostgresSpec.serverless`) that most authors use instead of ever seeing
the raw literal — the check stays available as `Assert spec.hasCapacityChoice` for anyone who
writes the structure literal directly.

**Changes nothing in this ledger**, and worth saying so explicitly, because
both are recent and both look like they might: `Infra.Core.Coe`'s wrapper
coercions and `Infra.Core.Declare`'s `fleet` command are *sugar*.

The coercions let a bare value stand for `.lit v` on a required field and
`.known (.lit v)` on an optional one; they are pinned to the `Expr` shape
precisely so they cannot blur the `Partial`-versus-`Option` distinction
("not yet said" versus "said: nothing") outside the authoring layer. Numerals
need their own `OfNat` instances, because Lean resolves a numeral against the
expected type before considering a coercion. `.unknown` deliberately has no
coercion: declining to specify a field stays visible. Neither `[]` nor a bare
`none` coerces, because their own type is a metavariable.

The `fleet` command expands to `Keys.build`, `NamedKey.of`,
`Keys.assignFromNamed` and `Infra.Specs.Build.*` — the same combinators a
hand-written fleet uses, all of which remain public and supported. Its
guarantees are therefore exactly theirs: duplicate names still hit
`namesNodup`'s `by decide`, a reference of the wrong `Kind` is still a type
error, and a missing required field is still an ordinary missing-argument
error. What it *adds* is single-mention: the bucket's name list is derived
from the resources, so a name absent from its own bucket stops being
expressible. `Infra/Demo.lean` declares one fleet both ways and `#guard`s that
they agree on cardinalities, providers, names, and the ordered action list.

**Genuinely runtime**: global uniqueness of bucket names, quota and capacity,
eventual consistency, whether an `absent` resource is still referenced from
outside the fleet.

### Known soft spots

- **`Refines` is still not given for spec structures.** `Divergent` supersedes
  it in practice — `realises` is derived from `divergence`, so the boolean and
  the field list cannot disagree — but the `⊑` machinery is not what decides
  reconciliation. A new spec field silently escapes comparison until it is
  added to the kind's table.
- **`LawfulMerge` has no instances.** `Merge` computes; nothing proves it is a
  least upper bound.
- **Antisymmetry of `⊑` on `Plan`** needs `funext` plus antisymmetry at each
  kind. It holds; it is not proved.
- **`HasDeps` only sees literal references in a key-typed *payload*.** This
  entry used to read as though `Expr.deps` would fix it. It would not, and
  saying so was a mistake worth recording: `asLit` and `deps` answer different
  questions. `Expr.asLit` reads a key out of a field's payload — a key-typed
  field like `sourceBucket` holds `Expr K (Option (K .aws .s3Bucket))`, where
  the key *is* the value — while `Expr.deps` collects `.observed`/
  `.secretValue` *nodes* inside an expression and returns `[]` for
  `.lit (some key)`. Replacing one with the other would have deleted both
  dependency edges in the repo. `HasDeps` now takes the **union** of the two
  readings over every field, so a `.secretValue` in a plain `String` field is
  ordered correctly — which is why "portable specs have no references by
  construction" no longer holds, and any kind can contribute edges. What is
  still unnoticed is narrower than it looked: a *key* smuggled through
  `map`/`ap` in a key-typed payload. A key is a plan-time constant, so a
  computed one would be the unknown-dependent shape `Expr` exists to rule out;
  closing it properly means a non-`Expr` slot for reference fields, recorded
  under "Not yet adopted" below.
- **Nothing forces a `Plan` through `fill` before apply.** `settleSpec` does
  it, and `push` goes through `settleSpec`, but the type system does not
  require that route.
- **Unreportable fields are unenforced, not rejected.** A target asking for
  something a cloud cannot express is accepted and quietly ignored; see
  `docs/providers.md` for the list.
- **`Plan.outside` is declared but not consumed.** Nothing in `satisfiesAt`,
  `satisfies`, `actions`, or `pullEntries` reads it — a key type's absence
  from `Keys.build`'s table (`Nothing`) is what actually leaves a resource
  alone today, regardless of what `outside` is set to, and `.absent`'s
  documented "closed-world garbage-collect" is not implemented anywhere. This
  has been raised with the user and is intentionally left alone pending a
  decision, per `AGENTS.md`; `Infra.Core.Ergonomics`'s `Keys.build` gives the
  real scoping mechanism (an unlisted `(provider, kind)` pair, or an unlisted
  name within one) and documents it as such rather than pointing at `outside`.

## Not yet adopted

- **A non-`Expr` slot for reference fields.** Would make a key-typed field
  structurally incapable of holding a computed key, closing the `HasDeps` soft
  spot above outright rather than by convention. Touches `Field`, every spec
  with a reference, and their `Fillable`/`Settleable`/`Divergent` entries.
- **Comparing a composed secret.** Neither cloud reports a secret's value, so
  a composed one is create-only: once it exists there is nothing to diff, and
  a second apply asks for nothing. Rotating one is therefore an explicit act,
  not a reconciliation, and there is no `--rotate-secrets` yet.
- **Parallel execution.** The scheduler orders; it does not fan out.
- **Field-level constraints richer than "exact value or nothing"** — `AtLeast
  4`, a region set, a version range: targets a provider could satisfy several
  ways. `Refines` is general enough to host them; every instance is flat.
- **Drift in fields no cloud reports** — secret values, master passwords. See
  `docs/providers.md`; detecting these would mean holding plaintext.
