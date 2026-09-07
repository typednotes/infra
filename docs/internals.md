# How it works

`docs/architecture.md` says what the design *is* and why each decision was
taken. This file traces what actually happens, component by component, when you
run `lake exe my_infra apply` — the call chain, the types it moves through, and
the shape of each piece. It is the document to read before changing the engine.

Everything here is checked against the code rather than remembered; where a
mechanism has a gap, the gap is named.

## The whole pipeline

One apply, end to end. Each box is a real function; the names are searchable.

```
  Fleet.lean (your source)
  ────────────────────────
  fleet myApp in paris where
    resource aws objectStore "assets" { versioning := true }
                 │
                 │  ELABORATION — happens while the file compiles.
                 │  Infra/Core/Declare.lean's `fleet` command.
                 ▼
  ┌──────────────────────────────────────────────────────────┐
  │  myApp.keys     : Keys      one finite key type per      │
  │                             (provider, kind)             │
  │  myApp.plan     : Plan κ    a total function from keys    │
  │                             to Status (SpecOf k …)        │
  │  myApp.regions  : Regions   where each slot lives         │
  │  myApp.forgets  : List (Released κ)                       │
  └──────────────────────────────────────────────────────────┘
                 │
                 │  Everything above is a *value*. Nothing has run.
                 │  A wrong region, a dangling reference or a
                 │  nonexistent instance size never gets this far —
                 │  see "Where the compiler stops you" below.
                 ▼
  Infra.Cli.run                                    Infra/Cli.lean
       │
       ├─ Ansi.wanted ......... colour on, only if stdout is a terminal
       ├─ liveFor κ regions ... build Backends; authenticate ONLY the
       │                        clouds κ declares resources in
       ├─ checkAccounts ....... refuse the wrong account before touching it
       └─ Ledger.load ......... what this fleet already manages
                 │
                 ▼
  ┌─ OBSERVE ─────────────────────────────────────────────────┐
  │  Engine.observe → Engine.pullEntries                      │
  │                                                            │
  │    for each (provider, kind) with keys:                    │
  │      for each region in bs.listers p k:                    │
  │        b.list k ................. what is out there        │
  │        match names against κ.name                          │
  │        for each match: b.read k handle ... its config      │
  │                                                            │
  │  → List (Entry κ) = (p, k, key, {observed, reported})      │
  │  → Persistence.save (the cache)                            │
  └───────────────────────────────────────────────────────────┘
                 │
                 │  worldOf entries : World κ
                 │  (a *function* from key to Option Sighting)
                 ▼
  ┌─ DIFF ────────────────────────────────────────────────────┐
  │  Engine.plan → Action.actions                             │
  │                                                            │
  │    actionsDeclared T W    ... over κ's keys                │
  │  ++ actionsOrphaned κ rows forgets  ... over ledger rows   │
  │                                                            │
  │  → List (Action κ)                                         │
  └───────────────────────────────────────────────────────────┘
                 │
                 ▼
  ┌─ ORDER ───────────────────────────────────────────────────┐
  │  Engine.orderActions                                      │
  │    builds  = non-destructive, Kahn-sorted by HasDeps       │
  │    kills   = destructive, Kahn-sorted then REVERSED        │
  │  → builds ++ kills.reverse                                 │
  └───────────────────────────────────────────────────────────┘
                 │
                 ▼
  ┌─ APPLY ───────────────────────────────────────────────────┐
  │  Engine.push                                              │
  │    1. dry run? print "would …" and return. No writes.     │
  │    2. brake: refuse to destroy most of the ledger while    │
  │       still declaring things (T.declaresAnything)          │
  │    3. ADOPT: record every declared resource that exists,   │
  │       even with no action to take                          │
  │    4. for each action: runAction, then persist both        │
  │       records if they changed                              │
  └───────────────────────────────────────────────────────────┘
                 │
                 ▼
        .infra/<exe>/infra.ledger.json   what is managed
        .infra/<exe>/<cloud>/<kind>.json what was last seen
```

## The type stack

Four layers, each of which the one above cannot see through. This is the part
worth understanding first, because every guarantee in the ledger of
`docs/diff-semantics.md` is a consequence of it.

```
  ProviderId × Kind          .aws, .scaleway, .gcp  ×  14 kinds
        │                    Infra/Core/Kind.lean
        │  SpecOf is indexed by Kind ALONE, never by provider.
        │  That is what makes a spec portable.
        ▼
  SpecOf : Kind → …          ObjectStoreSpec, QueuesSpec, …
        │                    Infra/Specs/Basic.lean
        │  Each field is wrapped by `Field`:
        │
        │    Field .required o f α  =  f α        ← NOT wrapped in `o`
        │    Field .optional o f α  =  o (f α)
        │
        │  so a required field cannot be "unsaid". Omitting one leaves
        │  you holding a function, not an incomplete record.
        ▼
  Partial α                  unknown  │  known α
        │                    the "author chose not to say" modality
        │
  Expr K α                   lit │ observed │ secretValue │ map │ ap
        │                    the "not known until apply" modality
        │                    Infra/Core/Expr.lean
        ▼
  Status V                   unmanaged  │  absent  │  present V
                             ⊥             DELETE     CREATE/UPDATE
```

Two modalities, and they are not interchangeable:

| | `Partial` | `Expr` |
|---|---|---|
| Means | you did not say | nobody can know yet |
| Resolved by | `Fillable`, at plan time | `settleSpec`, at apply time |
| Comparable? | yes — `unknown` refines anything | no — it holds functions |

`unknown` is not drift. The comparison is *observed ⊑ target*, never the
reverse, so a field the target does not mention is never a reason to change
anything.

## The `fleet` command

A macro, and the only place in the library that manipulates syntax. It runs at
elaboration and emits ordinary definitions.

```
  fleet myApp in paris where
    provider aws where
      resource objectStore "assets" as a { versioning := true }
      in oregon where
        resource s3Bucket "logs" { }
    forget aws queues "old"
                       │
                       ▼
   flatten  ── walks the item tree, carrying the enclosing
              `provider` and `in` context DOWN into each item.
              Blocks are *scoping*, and scoping is finished
              before anything is generated.
                       │
                       ├──▶ Array Res   (cloud, kind, name, binding, fields, place)
                       └──▶ Array Rel   (cloud, kind, name)
                       │
                       ▼
   group by (provider, kind), preserving declaration order
                       │
                       ▼
   emits:
     myApp.names.aws.objectStore : List String   ["assets"]
     myApp.keys                  : Keys          via Keys.build
     myApp.regions               : Regions       via Regions.covering
     myApp.plan                  : Plan          via assignFromNamed
     myApp.forgets               : List (Released myApp.keys)
     a                           : myApp.keys.Key .aws .objectStore
```

Indentation is load-bearing: `withPosition`/`colGt` is what makes a `provider`
block a block. Without it the item list is greedy and a block swallows every
sibling that follows it — which it did, silently, putting a later
`provider scaleway` group inside an earlier `in oregon` one.

## Where the compiler stops you

Two different mechanisms, and the difference matters when you add a check.

```
  STRUCTURAL — there is nothing to write down
  ───────────────────────────────────────────
  a reference        : κ.Key p k          an index into THIS fleet
  a missing required : Field .required    unwrapped, so the literal
    field                                  is incomplete
  a kind a cloud     : Key p k = Nothing  no inhabitant, so no key
    lacks
  a plan whose shape : Expr has no `bind` cardinality cannot depend
    depends on an                          on a post-apply value
    unknown

  DECIDABLE — you can write it, and `decide` refuses it
  ─────────────────────────────────────────────────────
  @[reducible] def Assert (b : Bool) : Prop := b = true

  used as an auto-param nobody types:

    (h : Assert (f.sizes.contains s) := by decide)

  InstanceType.of  .t3 .xlarge32     ← t3 has no 32xlarge
  Region.of  .aws "fr-par"           ← not an AWS code
  Locality.covers                    ← AWS has no Warsaw region
  releasing (forget)                 ← still declared by this fleet
  NamedKey.of                        ← name not in this fleet
```

The error is the compiler evaluating your own predicate:

```
  could not synthesize default value for parameter '_h' using tactics
  Tactic `decide` proved that the proposition
    Assert (InstanceFamily.t3.sizes.contains InstanceSize.xlarge32)
  is false
```

## Expressions, and the constructor that is missing

```
  inductive Expr (K : ProviderId → Kind → Type) : Type → Type 1
    │
    ├─ lit          α                     a value you have
    ├─ observed     K p k → ObservedOf k  what the cloud will report
    ├─ secretValue  K p .secrets → String this fleet's own secret
    ├─ map          (α → β) → …           put a recipe through a function
    └─ ap           Expr (α → β) → …      combine two recipes

  and deliberately NOT:
       bind : Expr K α → (α → Expr K β) → Expr K β
```

`K` is the load-bearing parameter. `observed` and `secretValue` both take a
`K p k` — an index into this fleet — so a recipe can only ever read from a
resource that exists in this file. That is where "a reference cannot dangle"
comes from.

The missing `bind` is the whole design. With `map` and `ap` an unknown value
can flow into a *field*; nothing lets it decide *how many things exist*, so the
dependency graph is fixed before anything runs. Terraform has the same rule and
enforces it per attribute at plan time (`for_each` over an unknown fails); here
there is no syntax in which to write it.

`expr!` is sugar over exactly that `map`/`ap` chain:

```
  expr!"postgres://{secretValueOf pw}@{endpointOf db}/main"

    ┌─ secrets "pw" ──secretValueOf──┐
    │                                ├──▶ secrets "db-url"
    └─ postgres "db" ──endpointOf────┘

  Two holes → two dependency edges → both created first, one apply.
```

## The scheduler

Edges come from `HasDeps`, one instance per spec, which reports every reference
a spec holds. `Need` distinguishes a handle from a value; ordering ignores the
distinction, because both are the same edge.

```
  actions ──▶ List (Action κ)
                   │
                   ├─ builds (create/update/replace/forget)
                   │      stepOf ── dependsOn ── HasDeps
                   │         │
                   │         ▼
                   │      schedule (Kahn's algorithm, bounded by
                   │      the step count so the measure is real and
                   │      exhausting it *is* the cycle diagnosis)
                   │         │
                   │         ▼   dependencies first
                   │
                   └─ kills (delete/deleteOrphan)
                          same sort, then REVERSED
                             │
                             ▼   a resource goes before what it needs
```

Reversing a topological sort is the answer wherever the enum happens to sit.
Deletion order used to come from the reverse of the `Kind` enumeration, and
that deleted a database before the secret that read its endpoint, because
`secrets` precedes `postgres` in the enum.

*The one gap.* An orphan carries no spec — its declaration is gone — so it
contributes no edges (`stepOf`'s `.deleteOrphan` case returns `[]`). Delete two
mutually-dependent lines in one go and the provider may refuse the second until
the first is done. The ledger records names and regions, not references, and
recording references too would make it a second copy of the declaration.

## Divergence: the four outcomes

```
  Divergent k : ProviderSpec k → Reported k → List (String × Mutability)
                                    │
                       divergence ──┤
                                    ▼
                             repairOf k t r
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
     empty                    all .mutable            any .forcesReplace
        │                           │                           │
        ▼                           ▼                           ▼
     NOTHING                    UPDATE                      REPLACE
  already right                                        destroy + create

  and separately, from extent alone:
     target present, world absent  ──▶  CREATE
     target absent,  world present  ──▶  DELETE
```

The first outcome is the one an extent-only comparison could never produce, and
it is what makes a second apply come back empty.

Two rules that Terraform providers implement ad hoc per attribute, stated once
here:

- **`unknown` is not drift.** Treating "could not see" as "differs" would
  rewrite every resource on every apply.
- **Lists compare as sets.** Tags, policies and environment variables come back
  in whatever order the service felt like. `Diverge.lean` sorts first, and the
  comment there says it is not cosmetic.

## Membership: what is mine

The question that decides whether deleting a line destroys the resource. It is
answered by the **ledger**, and by nothing else.

```
  .infra/<exe>/infra.ledger.json
  ┌─────────────────────────────────────────────┐
  │  Ledger.Row = cloud, kind, name, region     │
  │                                              │
  │  NOT indexed by κ.Key — deliberately.        │
  │  A CachedEntry κ is, so it structurally      │
  │  cannot hold a row for a resource the        │
  │  current declaration no longer names,        │
  │  which is exactly the row that matters.      │
  └─────────────────────────────────────────────┘
```

Three ways a row appears or leaves:

```
  ADOPT     apply, and the declaration names it, and it exists
            → recorded, even when there is nothing to do.
              (An apply that only recorded what it *changed* would
               never claim a converged resource, and nothing could
               then destroy it. That was a real leak.)

  ORPHAN    the declaration no longer names it
            → Action.deleteOrphan, addressed by name and routed on
              the region the row recorded, because the placement
              table cannot answer for a slot it does not contain.

  FORGET    `forget <cloud> <kind> "<name>"` in the declaration
            → the row goes, the cloud is untouched.
```

The three-stage live test is this mechanism as a sequence:

```
  stage 1  full      declare 11 ──▶ 11 managed
  stage 2  trimmed   declare 10 ──▶ 10 managed
                     │   drops 2 (lines GONE — only the ledger knows)
                     │   changes 1 field    → UPDATE
                     └── adds 1             → CREATE
  stage 3  empty     declare 0  ──▶ 0 managed
                     everything is an orphan; this is `apply` reaching
                     the same place `destroy` does
```

*What the ledger is not.* It is local and gitignored, so it does not survive a
CI job. `Infra.Core.Ownership` sketches the replacement — a marker tag on each
created resource, plus a realm and an exclusion list, so that membership is
derived and nothing has to be written back. Nothing writes the marker yet, so
it decides nothing today. Until it does, `lake test -- <cloud> sweep` is what
finds debris a ledger cannot name: it asks the account, matching on the
`ci-tests-infra-` prefix.

## Backends: three ways to reach a cloud

```
  structure Backends where
    backend    : ProviderId → Backend
                 the cloud's default region
    backendFor : ProviderId → Kind → String → Backend
                 by SLOT — resolves the region from `Regions.codeFor`.
                 Used for read/create/update/delete/secretValue.
    backendAt  : ProviderId → String → Backend
                 by REGION, named directly. For an orphan, whose slot
                 the placement table no longer contains.
    listers    : ProviderId → Kind → List (Backend × (String → Bool))
                 one entry per region in play, each paired with the
                 test for which slot names belong to it. `list` is the
                 one call with no slot to route on: it asks a REGION
                 what is in it, and its answers must be matched only
                 against the slots placed there.
```

Routing lives here rather than in the engine because the engine has no
credentials and no idea what a region is. It knows only slots.

`Backend` itself is a record rather than a class, so `Backends` can be a total
function over `ProviderId` without sigma gymnastics.

## The two records

```
                    LEDGER                      CACHE
  Holds       cloud, kind, name, region    ObservedOf per resource
  Answers     what do I manage?            what did I last see?
  Path        .infra/<exe>/                .infra/<exe>/<cloud>/<kind>.json
                infra.ledger.json
  Written by  apply and destroy            every refresh
  Committed   no                           no
  If lost     orphans: resources           nothing. One re-read
              nothing can name             restores it
```

Neither can hold a secret. `SecretsObserved` is a handle and a version, no
`ObservedOf` has a value field, and `Backend.read` for `.secrets` deliberately
never fetches one — `Backend.secretValue` is the only inbound plaintext path,
its result goes straight to one create call, and it is never stored.

## The CLI verbs

```
  check      offline. Placeholder backends, no credentials, no charges.
  refresh    observe + write the CACHE. Never the ledger: observing is
             not a decision about what is managed.
  plan       observe + diff + print. No mutation, and it does not
             reach a write — a dry run returns before them.
  apply      the pipeline above. --force overrides the brake.
  destroy    apply against Plan.absent, which is the empty declaration.
             Not a second mechanism: `.delete` and `.deleteOrphan`
             share one body and one `Backend.delete` call, addressed
             by name.
```

## Reading order

- `docs/architecture.md` — what the design is, and why
- `docs/diff-semantics.md` — the two axes, the refinement order, and the
  ledger of what is a compile error and what is not
- `docs/persistence.md` — the two records, and why membership is not intent
- `docs/coverage.md` — what actually exists and how far it has been run
- `docs/tutorial.md` — how to use it
