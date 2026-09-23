# Object Persistence

## Current state (0.16.0)

**Nothing is stored locally.** infra keeps no ledger and no cache: there is no
`.infra/` directory, nothing to gitignore, and nothing a machine can lose or
disagree about. Every run asks the cloud.

- **Membership is the markers.** What a fleet manages is decided only by the
  ownership evidence on the resources themselves — the ladder of tag, then
  description marker, then name prefix (`Boundary.namePrefix` /
  `namePrefixes`; see `Infra.Core.Ownership`) — read on every run. `plan`,
  `apply` and `destroy` call `Engine.claimUndeclared`, which lists every region
  the fleet uses and every kind that exists on those clouds, and returns the
  resources carrying this fleet's marker that the declaration does not name;
  `push` destroys them. It changes or destroys nothing that does not carry the
  marker (`Engine.foreignDeclared`). So a laptop and a fresh CI runner reach
  the same plan, and deleting a line destroys the resource from either.
- **`dump` is the snapshot, when one is wanted.** `infra dump [FILE]` writes
  JSON (`Infra.Providers.Snapshot`): every resource with its cloud, kind,
  name, region, ownership evidence and observed state; the `undeclared` slots
  the next apply would destroy; the `foreign` ones; the warnings. It is a
  record produced on request, never an input to a plan.
- **Snapshots double as test fixtures.** `Snapshot.load` and
  `Snapshot.backends` replay a snapshot as in-memory backends, so a real
  account can be dumped once and planned, applied and destroyed against
  offline.
- **A cache may come back, but only as a true cache** — something whose
  deletion could never change a result. That is the test the ledger failed,
  and the rest of this document is how it came to fail it.

Much of what follows is history. The sections on the cache and the ledger
describe things that no longer exist, and are kept because the reasons they
were removed are the reasons not to reinstate them; each says so. The
sections on the marker — two fleets in one account, the ladder, the declared
resource without the marker, `forget`, and the safety gate — describe current
behaviour.

## Problem

Per the "Definitions" section of `docs/architecture.md`, there are two kinds of objects:
target state and current (remote) state. Target state is already handled: it is authored
by hand as Lean source and versioned in git. The open question was the other direction —
when the engine pulls current state from a remote provider, in what form does it get
written to local disk, and where does it live? (The answer, since 0.16.0, is that it does
not get written at all unless someone asks for a `dump`.)

## Representation: Lean source vs. a serialized format

**Option A — persist as elaborable Lean source.** Every pulled object is written out as a
literal `.lean` file defining a term of the corresponding state type.

- Pros: one language end-to-end; the cache is diffable with plain `git diff`; dependent
  types keep enforcing well-formedness on cached state, not just on target state; a
  snapshot can be hand-edited if needed; no separate schema layer has to be kept in sync
  with the Lean types.
- Cons: elaborating Lean is slower than parsing something like JSON, which could matter
  once a snapshot holds thousands of objects; producing legible, deterministic Lean
  (stable formatting, field order, naming) from an arbitrary term is itself a
  pretty-printing problem to solve; a cached term can go stale if the type it instantiates
  changes shape across a library upgrade, with no built-in versioning/migration story the
  way a tagged serialization format would have.

**Option B — serialize to a different representation** (e.g. JSON), via `ToJson`/`FromJson`
derived from the state types.

- Pros: fast to read/write; consumable by non-Lean tooling; schema versioning and
  backward-compatible migration are well-trodden for this kind of format.
- Cons: gives up the "single source language" property; gives up dependent-type
  guarantees on load unless paired with a validating decoder; not directly comparable to
  target-state Lean source without a second toolchain.

**Recommendation at the time: Option A, generated to be legible.** *Superseded twice: the
cache became JSON, and then was removed; `dump` writes JSON for the same reasons.*
Elaborating Lean to read a cache proved to buy nothing, since nothing but `infra` itself
read it, and `ToJson`/`FromJson` derive for free from the state structures. The reasoning
is kept because the trade-off still stands if a snapshot ever needs to be human-edited. The
original argument was that this matches the request directly — persist state as Lean
source that can be elaborated, formatted so a human can read a snapshot next to the target
definition. If elaboration cost on read becomes a real bottleneck at scale, a serialized
index (Option B) can be layered in later as a read cache in front of the Lean source,
rather than replacing it as the source of truth.

## Storage backend: files vs. DB vs. pluggable

- Local files (either the same git working tree as target state, or a dedicated directory,
  e.g. `.infra/state/`) are the natural default: target state is already file-based Lean,
  cached state as files can be diffed and versioned the same way, and no extra service
  needs to run.
- A DB (e.g. sqlite) buys concurrent/locked access and queryability — relevant once
  multiple engineers or CI jobs pull/apply against the same state concurrently, or once
  object counts make scanning files slow.
- The access pattern this project will actually have (single operator vs. team, local vs.
  CI-driven) isn't settled yet. Rather than commit to one backend, define a small storage
  interface (get/put/list/diff by object key) with a filesystem implementation to start.
  A DB or other backend can then be added as a second implementation later without
  changing the callers.

The access pattern did settle, and it settled against all three: CI runners start
empty, so any state a run depends on has to be either remote or derivable. infra
chose derivable.

## Resolved decisions (to 0.14; superseded)

These were settled and implemented in `Infra.Core.Persistence`, which 0.16.0
deleted along with `Infra.Core.Ledger`. They are kept as the record of what
was tried.

- **Location: a gitignored local directory, not the git working tree.** Both
  the observation cache and the membership ledger lived under `.infra/`, and
  neither was committed. Drift was therefore not visible via `git diff`;
  surfacing it is the engine's job (`Infra.Core.actions`), not source
  control's — which is still true.

  A committed ledger was tried and reverted; see "Membership is not a committed
  ledger" below for why, because the reasoning generalises.

  *This bullet used to say the cache is gitignored because it "can hold values
  pulled through the `secrets` kind". That was never true, and it mattered,
  because it was the stated reason for the layout.* `SecretsObserved` is
  `{ handle, version }`, no `ObservedOf` has a value field, `Backend.read` for
  `.secrets` deliberately never fetches one, and `Backend.secretValue`'s result
  is handed to one create/update call and "never stored, cached, or returned
  outward". The cache could not leak a secret because it never held one, and
  the same holds for a `dump`. It stayed gitignored for a different and weaker
  reason: it was provider-computed noise that changed on every pull, and
  nothing was lost by regenerating it.
- **Layout: one JSON file per `(provider, kind)`, object-keyed by the fleet key's name.**
  `Persistence.statePath root p k` resolved to `<root>/<provider>/<kind>.json`, e.g.
  `.infra/aws/object-store.json`. One file per object would fragment into many trivially small
  files for no benefit; one file per provider spanning multiple unrelated resource shapes can't
  be typed uniformly. Per-kind was the natural grain, since that is already the unit `SpecOf` and
  `ObservedOf` are keyed on. Within a file the JSON object's keys came from `Keys.name` — the
  stable string a fleet assigns to each key.
- **Only `(provider, kind)` pairs with something in them got a file**, so the cache did not
  fill with empty objects for every unused kind. A missing file meant "nothing cached yet".
- **Only half of a `Sighting` was cached.** A pulled resource carries both its
  provider-computed `ObservedOf` and its `Reported` configuration; the cache
  kept the first. Configuration is re-read on every pull, so persisting it
  would have added a JSON codec per kind and bought nothing.
- **What was cached is `ObservedOf`, never a target.** Observed state is provider-computed and so
  never `Partial`; targets live in Lean source under version control. `Partial` does have a JSON
  encoding (`unknown` ↦ `null`) for when a partially-known target does need serialising.
- **Membership is not decided by the key types, and is not a file either.**
  Superseded decision, three times over: this bullet first said the key types
  alone decide what a target manages, which is what made deleting a line from
  a declaration leave the resource running. The fix that followed put
  membership in a ledger committed next to the declaration, which turned out
  to be its own mistake — see "Membership is not a committed ledger" below.
  Membership was then *derived*, from the marker tag `infra` writes and the
  boundary a human authors (`Infra.Core.Ownership`), with the ledger kept as a
  local cache of that decision. In 0.16.0 the ledger went too: the derivation
  runs on every plan, and there is nothing to cache.
- **Backend: plain files, no DB.** There was no concrete scale or concurrent-access
  requirement (single operator, not a team or CI fleet sharing state).

# Decision

**No local state (0.16.0).** Membership is the markers on the resources, read
from the cloud on every run; nothing about a fleet is written to disk by
`plan`, `apply` or `destroy`. When a record is wanted, `dump` writes one — a
JSON `Snapshot` — and a snapshot is also how an account is replayed offline in
tests (`Snapshot.load`, `Snapshot.backends`), so a real dump can be a fixture.

A cache may be reinstated later, for speed, on one condition: it is a *true*
cache, meaning deleting it can never change a plan, an apply or a destroy.
The ledger looked like that and was not — see "Derived on every run" below
for the resource it left standing.

## Before 0.15.0: a JSON cache and a ledger

infra serialized observed state as JSON (`Lean.Data.Json`'s `ToJson`/`FromJson`,
via `deriving ToJson, FromJson` on each state structure), and
`Infra.Core.Persistence.load`/`save` implemented the "small storage interface
with a filesystem implementation" described above. The subsections that
follow describe that design; where they state a lesson that still applies,
they say so.

## An emptied pair deletes its file

*(History: the cache has since been removed.)* `save` wrote the
`(provider, kind)` pairs that had rows and **removed the file for a pair that
had none**. The second half was missing until 0.3.1, and its absence made the
cache lie in a specific and misleading way: skipping an emptied pair left the
previous contents on disk untouched, mtime and all, so after a `destroy` the
cache went on listing every resource that had just been deleted —
indefinitely, because nothing ever wrote that path again.

No plan was ever wrong because of it. `load` had no callers; the engine planned
from a fresh `pull`, and the cache was a *record* rather than an input. But a
record that reports deleted resources as present is worse than no record: it is
the file a human reads to see what a fleet last observed, and it will be
believed. The lesson carries over to `dump`, which is why it is written only
when asked for and from a fresh read.

## Membership is not a committed ledger

Two questions were conflated, and separating them is the whole of this section:

: *What does this fleet manage?*

    Intent. It changes only when a human edits something. Answered, until
    0.16.0, by the **ledger**; now by the markers.

: *What did the cloud last look like?*

    Observation. It changes on every pull, and is provider-computed. Answered,
    until 0.16.0, by the **cache**; now by reading it again.

Terraform keeps both in one `.tfstate`. Splitting them made it *look* as
though the membership half could be committed, because it holds nothing but
names and demonstrably no secrets. That was the wrong conclusion, and the
reason is worth stating plainly because it is easy to talk yourself into:

**Membership is not intent.** Intent is what you wrote in the declaration. A
ledger row appears because a resource *was created*, which is an event at apply
time on whatever machine ran the apply. Committing it therefore requires a run
to write back to the branch it was applied from: push permissions for CI, races
with concurrent merges, and a loop unless carefully guarded. Terraform keeps
state remote rather than committed for exactly this reason.

So the ledger became local and disposable, and membership was derived instead,
from three things a human authors and no run has to write back: the realm, an
inclusion marker on each created resource, and an exclusion snapshot. See
`Infra.Core.Ownership`, which also records which way each of those fails.

**Derived on every run (0.15.0), and the ledger removed (0.16.0).** Until 0.15.0 the
derivation above existed only as the `discover` command; `plan` and `apply`
read orphans from the ledger alone. So on a machine without the ledger — every
CI runner — deleting a line from the declaration abandoned the resource. It
was found on `typednotes-infra`, whose CI applies left a retired IAM
application and its live API key standing. That is a "cache" whose absence
changed a result, which is to say not a cache. Now `Infra.Cli.run` asks the
cloud for every undeclared resource carrying this fleet's marker before
planning (`Engine.claimUndeclared`), and `push` changes or destroys only what
carries it (`Engine.foreignDeclared`). With nothing left depending on the
ledger, 0.16.0 deleted it, and `discover` with it: every `plan` now does what
`discover` did.

The scan's scope is every region the fleet uses (`Backends.scanners`) and
every kind `Engine.scannableUndeclared` allows — every kind that exists on
that cloud, except `postgresMigrations`, which is rows in a database rather
than a cloud object. "Undeclared" is about the physical resource: kinds that
list the same thing share a class (`Engine.physicalClass` — an S3 bucket is
both `objectStore` and `s3Bucket`), so declaring it under either kind is
declaring it. Two limits follow from asking the cloud rather than a record:
only clouds whose credentials are loaded are asked, and a cloud the
declaration no longer names at all is not scanned. Retire a cloud with
`destroy` before deleting its last line.

**Two fleets in one account, and the marker's value.** The marker's *key* is
constant, and its *value* is where a fleet writes its own name
(`Boundary.fleetName`, threaded to the backends by `Infra.Cli.liveFor` so the
write and the check are one setting). Unset — the default — the value is not
read when judging a declared resource, which is the behaviour that existed
before the field. Set, a resource carrying another fleet's name reads as
`foreign`, and foreign resources are left alone.

Destroying a resource the declaration does *not* name asks more
(`Ownership.claimsUndeclared`): the marker must name this fleet. With
`fleetName := some me`, only the tag value `me` licenses it. A fleet with no
`fleetName` destroys no undeclared resource on the strength of a tag at all —
it cannot tell its resources from another fleet's in a shared account, and
"destroy everything marked" is what `infra`'s own live tests would otherwise
have done to `typednotes-infra`. Such resources are warned about by name,
never destroyed. The name rung still claims by prefix, since the prefix *is*
the declaration's claim.

Three honest limits on it. It is **opt-in on both sides**: a fleet that names
itself is protected from one that does not, not the reverse, so isolation needs
both to set it. It is **one string, not an identity** — nothing stops a second
fleet writing the same name, so it separates fleets that agree to be separate,
and `Accounts` is still the hard container. And the old value `true` is
**grandfathered for ever** for declared resources: one tagged before the name
existed matches every fleet, because the alternative is that naming your fleet
turns your whole estate foreign in one step. `Ownership.legacyMarkerValue`
records that, and `Main.lean`'s `checkFleetIsolation` asserts it. An
*undeclared* resource carrying `true` is warned about and never destroyed,
because that value cannot say whose it is.

The key stays constant deliberately: it is what makes "what did this tool
create in this account?" answerable at all, which is what
`claimUndeclared`, `dump` and any audit of the account rest on. A
configurable key would take that away, and a key with a typo in it would
leave an entire estate looking like it belonged to nobody.

`checkAccounts` enforces the realm before anything is listed. The marker and
the boundary are wired into `Engine.push` — `foreignDeclared` for declared
names, `claimUndeclared` for undeclared ones, and the recheck before an
orphan's delete (`runStep`) all consult the ownership verdict — for **every**
`(cloud, kind)` pair; `Backend.ownershipInfo` reports evidence on one of three
rungs, and `docs/coverage.md` has the table of which pair is on which:

1. **tags** — real key/value tags or labels, which most objects have;
2. **a description** — the object has no tags but one writable free-text
   field, and the marker is serialised into it. Identical semantics: what
   reaches `ownershipOf` is the same tag list either way;
3. **the name** — Scaleway's Serverless SQL Database and its Queues have
   neither, so ownership rests on `Boundary.namePrefix`, and infra *verifies*
   the name rather than writing it.

There is no "not migrated" state left. A backend that cannot answer at all
(`.unreadable`) is refused rather than falling back to the older rule, which
was a rule about names: a declaration adopted a resource because it named it
and the cloud had it, unable to distinguish a resource of yours from a
stranger's with the same name. `foreignDeclared` counts `.unreadable` as not
verifiably ours, so its update, replace and delete actions are dropped, with
a warning, on `plan` as well as `apply`.

**A declared resource that exists without the marker is not managed, and is
told to you.** This is the case the engine used to pass over in silence, and
the one `push`'s warning names:

    warning: scaleway/object-store/my-bucket is declared and exists, but is
    not carrying the 'managed-by-infra' tag, so not ours. It will not be
    changed or destroyed by this fleet, which therefore manages less than it
    declares. …

Nothing else about that state is observable. The resource exists, so there is
no `create`; it is not managed, so there is no `update` and never a `delete` —
so no plan line, and a fleet quietly doing less than its declaration says.
Every path reaches the same verdict, because every path reads the same
marker; only a name-based sweep can see it at all (`lake test -- <cloud>
sweep`; the procedure is in [`../ci/README.md`](../ci/README.md)). `dump`
lists it under `foreign`.

The sentence after the comma differs by rung, because the fix does. A tagged
kind is told it is "not carrying the 'managed-by-infra' tag". A name-rung
resource in a fleet with a prefix set is told its name "does not start with
this fleet's `namePrefix`", and one in a fleet without is told there is no
prefix set and to set one. Three remedies, three sentences — a reader told to
retag a resource on a cloud that cannot tag it has been sent to fix the wrong
thing.

Refusing to claim it is deliberate — a marker is the *only* positive evidence
of ownership, and adopting on a name match is how you delete a stranger's
bucket. The two ways out are both a human's decision: add it to the boundary's
exclusions, which puts the intent on the record, or delete the resource and let
the fleet create it, marker and all. There is deliberately no "adopt this"
flag; writing a marker onto something because it was in the way is the same
mistake spelled differently.

This is what a fleet adopted after the fact will see for its whole
pre-existing estate, and it is why the live test asserts that everything its
stage declares carries the marker: the assertion is what turns the warning
into a failed build rather than a line in a log nobody reads.

Three consequences worth stating outright. They were written about the
ledger's row; each now applies to `Orphan` (`Infra.Core.Slot`), the record
`claimUndeclared` returns.

**An orphan is keyed by name, not by a fleet key.** A key (`κ.Key p k`)
structurally cannot name a resource the current declaration does not mention —
which is exactly the resource that matters here. `Orphan` is therefore a plain
record `{cloud, kind, name, region}`, deliberately outside the key family.
This is the one place in the library where *not* using a dependent index is
the point: it has to be able to name something the types no longer can.

**The region is part of the orphan, and has to be.** Placement comes from the
declaration (`myFleet.regions`). Once the line is deleted there is nothing left
to say where the resource was, and `Backends.backendAt` needs that to route
the delete. The scan records the region it found the resource in.

**Deleting an orphan needs no observation beyond its marker.** `Backend.delete`
takes a `Handle k`, and `Handle` is a wrapper over `String`. So
`(cloud, kind, name, region)` is sufficient for the entire destroy path. What
`runStep` does add is a recheck: the marker is read again, with
`claimsUndeclared`, at the moment of deleting, so a resource retagged between
plan and apply is not destroyed. A refused orphan delete (a
`DependencyViolation` while something still uses it) is retried after the
rest of the plan, and fails the apply if it never clears.

### Leaving management without being destroyed

`forget` in a declaration releases a resource from management and does not
touch the cloud. It is the counterpart of Terraform's `removed { … lifecycle {
destroy = false } }`, and it is spelled as a declaration rather than a command
for the reason HashiCorp gives for preferring `removed` over `terraform state
rm`: it is in the declaration, so it shows up in a diff when it is reviewed.

There is no FORGET action for it any more — there is no row to drop. A
forgotten name is simply skipped by `claimUndeclared`. The consequence is that
the `forget` line must **stay** in the declaration for as long as the resource
exists: the resource still carries the marker, so deleting the line makes it
an orphan again, and the next apply destroys it. (Before 0.16.0, `forget`
dropped a ledger row once and could then be deleted.)

### Concurrency, stated rather than solved

Nothing here locks. Two applies at once against one account can interleave.
What keeps that from being silent is that there is no local record for either
to disagree with: each reads the markers, and the next run of either sees what
the other did. The exception is a resource on the name rung in a fleet with no
`namePrefix`, where there is no marker at all, so nothing can claim it once
it is undeclared (see `docs/coverage.md`). Remote state with a lock remains
available as the answer if two operators applying at the same moment becomes
a real pattern.

### The safety gate

Deciding membership from observation has a known failure shape, and it is not
hypothetical: HashiCorp deprecated `terraform refresh` because misconfigured
credentials could make it read every managed object as deleted, then destroy
them all with no confirmation. The same hazard exists here wherever an
observation can mean "gone" or "not ours".

Two defences, both required:

1. `Engine.readsAsAbsent` stays as narrow as it is: a curated list of
   not-found codes, matched by substring, wrong only by omission. A permission
   error must never read as absent. An unrecognised code surfaces as a hard
   error, which is the safe direction.
2. `apply` refuses a plan that would delete more than half of what is managed
   unless the operator passes `--force`. "Managed" is the declared resources
   that exist and carry the marker, plus the orphans. A plan that deletes
   everything is either a real teardown, in which case `destroy` is the verb
   for it, or a credentials problem.
