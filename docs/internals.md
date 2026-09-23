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
  │  myApp.plan     : Plan κ    a total function from keys   │
  │                             to Status (SpecOf k …)       │
  │  myApp.regions  : Regions   where each slot lives        │
  │  myApp.forgets  : List (Released κ)                      │
  │                                                          │
  │  myApp          : Fleet     the four above, as one value │
  │                             with name := "my-app" (the   │
  │                             identifier, in kebab-case)   │
  └──────────────────────────────────────────────────────────┘
                 │
                 │  Everything above is a *value*. Nothing has run.
                 │  A wrong region, a dangling reference or a
                 │  nonexistent instance size never gets this far —
                 │  see "Where the compiler stops you" below.
                 ▼
  Infra.Cli.run myApp                              Infra/Cli.lean
       │
       ├─ Ansi.wanted ......... colour on, only if stdout is a terminal
       ├─ name ................ boundary.fleetName.getD myApp.name, put
       │                        back into the boundary; refused unless
       │                        Ownership.validFleetName
       ├─ liveFor κ regions ... build Backends; authenticate the clouds
       │                        κ declares resources in, plus any cloud
       │                        `accounts` names (scan only)
       └─ checkAccounts ....... refuse the wrong account before touching it
                 │
                 ▼
  ┌─ OBSERVE ─────────────────────────────────────────────────┐
  │  Engine.pullEntries                ... what is declared    │
  │                                                            │
  │    for each (provider, kind) with keys:                    │
  │      for each region in bs.listers p k:                    │
  │        b.list k ................. what is out there        │
  │        match names against κ.name                          │
  │        for each match: b.read k handle ... its config      │
  │                                                            │
  │  → List (Entry κ) = (p, k, key, {observed, reported})      │
  │                                                            │
  │  Engine.claimUndeclared            ... what is not         │
  │                                                            │
  │    for each cloud bs has scanners for, each region in      │
  │    bs.scanners p, each kind scannableUndeclared allows     │
  │    (all but postgresMigrations):                           │
  │      b.list k, skip names declared (any kind of the same   │
  │      physicalClass), b.ownershipInfo k h                   │
  │      forgotten → a release if still ours on a tag rung     │
  │      otherwise → Orphan if Ownership.claimsUndeclared,     │
  │        else a warning if it carries the retired `true`     │
  │                                                            │
  │  → orphans, releases : List Orphan                         │
  │      (Orphan = {cloud, kind, name, region})                │
  │  Nothing is written to disk.                               │
  └───────────────────────────────────────────────────────────┘
                 │
                 │  worldOf entries : World κ
                 │  (a *function* from key to Option Sighting)
                 ▼
  ┌─ DIFF ────────────────────────────────────────────────────┐
  │  Engine.plan → Action.actions                             │
  │                                                            │
  │    actionsDeclared T W        ... over κ's keys            │
  │  ++ actionsOrphaned κ orphans ... over the scan's orphans  │
  │  ++ .release per release     ... RELEASE, nothing deleted  │
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
  │    1. foreignDeclared: declared names that exist but are   │
  │       not verifiably ours (.unreadable included) — warn,   │
  │       and drop their update/replace/delete. Plan too.      │
  │    2. dry run? print "would …" and return. No writes.     │
  │    3. brake: refuse to destroy most of what is managed     │
  │       (declared + existing + marked, plus orphans) while   │
  │       still declaring things (T.declaresAnything)          │
  │    4. for each action: runStep. An orphan's marker is      │
  │       re-read (claimsUndeclared) before its delete; a      │
  │       refused orphan delete is retried after the rest.     │
  │       A release re-reads it too, and reports "already not  │
  │       this fleet's" rather than unmarking a stranger's     │
  └───────────────────────────────────────────────────────────┘
                 │
                 ▼
        the cloud — and nothing else. There is no local state.
```

`dump` runs the same OBSERVE box plus `foreignDeclared`, and prints the result
as a `Snapshot` (`Infra.Cli.snapshotOf`, `dumpJson`) instead of diffing it.

*The fleet's name.* `Fleet.name` has no default: the `fleet` command fills it
from the identifier (`Infra.Core.fleetNameOfIdent`: `crossCloud` →
`cross-cloud`, `myHTTPFleet` → `my-http-fleet`, a namespace dot → a hyphen).
`Boundary.fleetName` is an override. `Infra.Cli.run` resolves
`boundary.fleetName.getD F.name` once and writes it back into the boundary, so
every reader downstream — `liveFor`, which stamps it on what is created, and
`ownershipOf`, which requires it back — sees `some` and the same string.
Before any live command (`plan`, `apply`, `destroy`, `dump`) the name is
checked with `Ownership.validFleetName`, and the refusal says whether to
rename the declaration or fix `fleetName`. A hand-built `Boundary` with
`fleetName := none`, reachable only by calling the engine directly, claims
nothing by tag.

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
     myApp                       : Fleet         the four, bundled, and
                                                 name := "my-app"
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
                   ├─ builds (create/update/replace, and
                   │      release, which has no edges)
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

*Orphans have no edges, and are ordered by the provider instead.* An orphan
carries no spec — its declaration is gone — so it contributes nothing to sort
by (`stepOf`'s `.deleteOrphan` case returns `[]`), and the scan that finds it
(`claimUndeclared`) yields a name and a region, not references — the cloud does
not know what a deleted line referred to, and keeping a record of it would be a
second copy of the declaration. So `push` does not compute that order, it
finds it out: a refused `deleteOrphan` is held back rather than fatal, and
tried again after the rest of the work-list has run.

```
  main pass ─── orphan delete refused ("DependencyViolation") ──┐
                                                                │ held
  ┌─── retry round: everything still deferred ◄─────────────────┘
  │         │                        │
  │    one went                 none went
  │         │                        │
  └─────────┘                        ▼
   (bounded by the number       throw the provider's
    of deferred orphans)        own words, naming the slot
```

Every other verb keeps edges and keeps failing immediately; only orphan
deletion converges by repetition. That is the same answer `test/Live.lean`'s
`sweepPass` gives to the same question — a sweep has no declaration at all —
and the same one AWS's security-group delete already gave for one kind on one
cloud (`docs/providers.md`). A refusal that never clears still fails the apply,
so a real error is delayed rather than swallowed.

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
answered by the **marker on the resource**, read from the cloud on every run,
and by nothing else — there is no local record (`docs/persistence.md`).

```
  Infra.Core.Slot
  ┌─────────────────────────────────────────────┐
  │  Orphan = cloud, kind, name, region         │
  │                                              │
  │  NOT indexed by κ.Key — deliberately.        │
  │  A key structurally cannot name a resource   │
  │  the current declaration no longer names,    │
  │  which is exactly the resource that matters. │
  └─────────────────────────────────────────────┘
```

Three cases, decided per resource on every run:

```
  DECLARED  the declaration names it, and it exists
            → managed if it carries this fleet's marker
              (Ownership.ownershipOf); otherwise foreignDeclared
              warns and push drops its update/replace/delete.

  ORPHAN    it carries a marker that NAMES this fleet
            (Ownership.claimsUndeclared), and the declaration does
            not name it under any kind of its physicalClass
            → Action.deleteOrphan, addressed by name and routed on
              the region the scan found it in, because the placement
              table cannot answer for a slot it does not contain.
              The marker is re-checked at delete time (runStep).

  FORGOTTEN `forget <cloud> <kind> "<name>"` in the declaration
            → never an orphan. If it still carries this fleet's
              marker on a tag or description rung: Action.release
              (RELEASE, blue — Backend.release removes the marker,
              nothing else), re-checked at release time; afterwards
              it is no fleet's and the line can go. On the name rung
              nothing can be removed, so nothing is planned and the
              line must stay while the resource exists.
```

A marker names this fleet only if its value equals the fleet's name — the
resolved `Boundary.fleetName`, which `Infra.Cli.run` always sets. That is one
rule for declared and undeclared resources alike, so `claimsUndeclared` now
returns `ownershipOf`'s verdict. The retired value `true` (written by unnamed
fleets before 0.17.0) matches no fleet: a declared resource carrying it is
foreign and `foreignDeclared` warns with the retag to perform; an undeclared
one gets a warning from `claimUndeclared` and is never destroyed. The name
rung claims by prefix, as it does everywhere.

`destroy` passes the releases to `push` as well: a fleet being torn down
should not leave claims on the resources it forgot. `dump` lists them under
`released`.

The five-stage live test is this mechanism as a sequence (AWS's counts; see
`test/Live.lean`):

```
  stage 1  full       declare 12 ──▶ 12 managed
  stage 2  ramp-up    declare 12 ──▶ 12 managed
                      same names, same graph, larger numbers → UPDATE
  stage 3  ramp-down  declare 12 ──▶ 12 managed
                      the same paths back down
  stage 4  trimmed    declare 11 ──▶ 11 managed
                      │   drops 2 (lines GONE — found by their marker)
                      └── adds 1             → CREATE
  stage 5  empty      declare 0  ──▶ 0 managed
                      everything is an orphan; this is `apply` reaching
                      the same place `destroy` does, and it is
                      `Plan.absent` over stage 1's own key family — see
                      "Which clouds get authenticated" below for why that
                      last clause is load-bearing
```

*Why nothing is stored.* A local record does not survive a CI job, and until
0.15.0 that is exactly what went wrong: plans read orphans from a local
ledger, so a CI runner deleting a line abandoned the resource.
`Infra.Core.Ownership` is what decides membership — a marker written on
create, plus a realm and an exclusion list — and it is read where it lives.
Every `(cloud, kind)` pair reports evidence, on one of three rungs: real tags,
a marker serialised into the object's one writable free-text field, or — for
the two Scaleway products with neither (Serverless SQL Database and Queues) —
the resource's own name, checked against `Boundary.prefixes` — the fleet's
name and a hyphen by default, or `namePrefix` then `namePrefixes` when either
is set, which replaces the default. `docs/coverage.md` has the table of which
pair is on which rung. No marker names debris that a create left without its
marker, or a resource named outside the prefix, which is why `lake test --
<cloud> sweep` remains what finds such debris: it asks the account, matching
on the `ci-tests-infra-` prefix. The
procedure — that verb versus `destroy`, the Cleanup workflow and its review
gate, and the three things a sweep structurally cannot reach — is in
[`../ci/README.md`](../ci/README.md).

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
    scanners   : ProviderId → List (String × Backend)
                 one entry per region the fleet uses, with its code;
                 none for a cloud whose credentials were not loaded.
                 For claimUndeclared, which has no slots at all: it
                 asks each region for everything, and records the
                 region an orphan was found in for backendAt.
```

Routing lives here rather than in the engine because the engine has no
credentials and no idea what a region is. It knows only slots.

`Backend` itself is a record rather than a class, so `Backends` can be a total
function over `ProviderId` without sigma gymnastics.

### The one backend that is not a cloud: `postgresMigrations`

Every other backend answers to a cloud's control plane. This kind answers to
the Postgres wire protocol (`Kinds/Migrations.lean`, over `linen`'s
`Database.SQL`), and two things follow from that, both visible in the call
chain:

**Where the route table comes from.** A `Handle` for this kind is only a name,
and the database, the two URL-secret names and the schema cannot be recovered
from it — there is no cloud-side record to ask. So `Infra.Cli.run` walks the
declaration (`migrationRoutesOf`, one row per declared migration set) and
hands the table to `liveFor`, which closes over it per backend. A backend
built without routes is honest about the gap: its `list` returns what the
(empty) table names, and its `read` refuses with a message naming the missing
route rather than fabricating a sighting. The engine itself learns nothing —
`pullEntries` and `remember` run unchanged, and the route table never reaches
them.

**What runs on which path.** An apply routes through `Engine.runAction` like
any other create/update: settle (plain names, no `.observed` nodes to
resolve), backend `create`/`update` — one body, because the resource *is* its
history — which reads the read-write URL secret, takes a session-level
`pg_advisory_lock` keyed by the resource name, re-reads the applied history,
re-checks the prefix contract, and applies the pending suffix one transaction
per migration. The connection's release is what frees the lock, so a crash
mid-apply cannot hold it. Observation runs through the same `list`/`read`
every other kind uses, except that the URL it reads is the **read-only**
secret's — the one widening of the planning path's secret-blindness, scoped
and recorded (architecture.md, `docs/diff-semantics.md`'s ledger). Wake-up
retries bound the serverless-database cold start; a database that will not
wake is an error, never an empty history.

The append-only contract is checked at three tiers, in order: `Engine.push`
refuses the plan before deriving actions (`Plan.migrationsAppendOnly`, which
needs the observed history and so cannot be compile-time), the `Divergent`
table answers any caller that reaches `repairOf` directly (conflict is
`forcesReplace`, never quietly fixable), and the backend re-checks against
the database rather than any cache before applying. A `delete` for this kind
touches no cloud: the plan prints `FORGET` (`Action.verb`), the backend's
delete is a no-op, and the schema dies with its parent `postgres` resource
when that one's own delete runs — which the teardown graph orders last.

**Where its edges come from.** None from `HasDeps`: every cross-resource
field is a plain name. `Engine.impliedByName` turns `database`,
`connectionSecret` and `observerSecret` into slot ids. The edges *between*
histories need the whole plan, so `dependsOn` adds them from
`Plan.historyDeps` — read from the SQL (`Infra.Core.SqlDeps`): a history
follows every other history on its database that creates a table it
references. Only resolved SQL has edges, which is why `Infra.Cli.run`
fetches URL sources (`fetchMigrationSources`, `withFetchedSources`) before
building the plan it pushes, and why `push` refuses unfetched sources and
`Plan.migrationDepsProblem` (an unresolved or ambiguous reference) before
deriving any action.

### Which clouds get authenticated, and the hole that leaves

`Infra.Cli.liveFor` builds all four of those from **`κ.providers`** — the
clouds the declaration's key family names — plus, since 0.17.0, the `extra`
clouds `Infra.Cli.run` passes: every cloud the fleet's `accounts` names
(`Accounts.expect p = some _`). That is what lets an all-Scaleway fleet run
without AWS credentials, and it is deliberate. A declared cloud without
credentials is an error; an extra one without credentials (or without a
region — it is scanned in the fleet's region for that cloud, else the
credentials') gets a note and is skipped, and `scanners` gives it nothing.
`checkAccounts` covers every cloud `accounts` names, declared or not.

The consequence is not: a provider `κ` does not name gets
`Infra.Providers.placeholderBackend`, whose `delete` returns `()` and whose
`list` returns `[]`. Before 0.16.0, for a declaration that named *nothing at
all* — which is the same statement as a teardown, see `Plan.absent` — that
meant every backend was a placeholder, and a teardown of a full ledger became a
loop of successful no-ops that emptied the ledger and touched no cloud. It took
milliseconds and reported success.

That was not a hypothetical: it is what the 2026-09-08 live runs did on GCP and
Scaleway. Both printed `ok — all 5 stages`, both left their whole estate
standing, and only AWS came out clean — because its run *failed*, and the
workflow's backstop sweep deleted the twelve resources the teardown had not.
(The ledger, and the `Backend.unreachable` refusal that fixed this, have since
been removed; see below.)

With no ledger, that failure has nothing left to feed on. Orphans come only
from `claimUndeclared`, which scans every cloud the backends give scanners for
— the clouds whose credentials were loaded — so a placeholder is never asked
for orphans and never "deletes" one. The price is the mirror image, and it is
stated rather than hidden: **a cloud named neither by the declaration nor by
`accounts` is not scanned**, so its resources are left standing rather than
destroyed. To retire a cloud, delete its lines but keep it in `accounts` until
the apply that empties it, then drop it from `accounts`. (Before 0.17.0 only
`κ.providers` was scanned, and a cloud had to be retired with `destroy`
before its last line went.)

Why `accounts`, and not every cloud whose credentials happen to load: a
laptop often holds credentials for unrelated accounts, and scanning those
would put a stranger's estate one marker-collision away from a fleet's
deletes. `accounts` is the checked statement of where the fleet lives, and
`checkAccounts` verifies it before anything is listed.

The other half of the old fix is still load-bearing, in the test driver:
`Live.emptyStage` builds its teardown as `Plan.absent κ` over the cloud's *own*
key family rather than as an empty `fleet` of its own, so `κ.providers` still
names the cloud, the credentials still load, and the scan still runs.
`#guard (at! awsStages 4).κ.providers = [.aws]` is what stops that regressing
— `declared = []`, the guard that was already there, cannot see the
difference.

The general shape is worth naming: **a placeholder is indistinguishable from a
cloud that agreed.** Every placeholder method answers the way a successful call
would. That is the right default for an offline suite and a live-fire hazard
everywhere else, so the question to ask of any new path through `Backends` is
what it does when the credentials for a cloud were never loaded.

## No local records

Before 0.16.0 infra kept two local records under `.infra/<exe>/`: a ledger
(what do I manage?) and a cache (what did I last see?). Both are gone. The
first question is answered by the markers, on every run; the second by reading
again. When a record is wanted, `dump` writes one:

```
  infra dump [FILE]  →  JSON (Infra.Providers.Snapshot)
    resources   cloud, kind, name, region, ownership evidence,
                observed state — declared-and-existing, plus orphans
    undeclared  the slots the next apply destroys
    released    forgotten slots the next apply unmarks
    foreign     declared names that exist but are not ours
    warnings    what the scan saw but may not claim
```

`Snapshot.load` and `Snapshot.backends` replay that file as in-memory
backends, so a real account's dump can be a test fixture.

A snapshot cannot hold a secret. `SecretsObserved` is a handle and a version,
no `ObservedOf` has a value field, and `Backend.read` for `.secrets`
deliberately never fetches one — `Backend.secretValue` is the only inbound
plaintext path, its result goes straight to one create call, and it is never
stored. (One other secret value is read back, below the engine: infra's own
Scaleway Queues credential, from its shared `infra-sqs-credential` copy —
`Infra.Providers.Scaleway.Sqs`. It signs queue calls and never reaches a
sighting or a snapshot.)

## The CLI verbs

```
  check      offline. Placeholder backends, no credentials, no charges.
  plan       observe + claimUndeclared + diff + print. No mutation,
             and it does not reach a write — a dry run returns before
             them. --destroy plans the teardown instead.
  apply      the pipeline above. --force overrides the brake.
  destroy    apply against Plan.absent, which is the empty declaration.
             Not a second mechanism: `.delete` and `.deleteOrphan`
             share one body and one `Backend.delete` call, addressed
             by name. Pending releases run too.
  dump       observe + claimUndeclared + foreignDeclared, written as a
             JSON Snapshot to FILE or stdout. Read-only, like plan.
```

## Reading order

- `docs/architecture.md` — what the design is, and why
- `docs/diff-semantics.md` — the two axes, the refinement order, and the
  ledger of what is a compile error and what is not
- `docs/persistence.md` — why nothing is stored locally, and why membership is
  not intent
- `docs/coverage.md` — what actually exists and how far it has been run
- `docs/tutorial.md` — how to use it
