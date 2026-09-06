# Object Persistence

## Problem

Per the "Definitions" section of `docs/architecture.md`, there are two kinds of objects:
target state and current (remote) state. Target state is already handled: it is authored
by hand as Lean source and versioned in git. The open question is the other direction —
when the engine pulls current state from a remote provider, in what form does it get
written to local disk, and where does it live?

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

**Recommendation at the time: Option A, generated to be legible.** *Superseded — see
"Decision" below: the cache is JSON.* Elaborating Lean to read a cache proved to buy nothing,
since nothing but `infra` itself reads it, and `ToJson`/`FromJson` derive for free from the
state structures. The reasoning is kept because the trade-off still stands if the cache ever
needs to be human-edited. The original argument was that this matches the request directly —
persist state as Lean source that can be elaborated, formatted so a human can read a
snapshot next to the target definition. If elaboration cost on read becomes a real
bottleneck at scale, a serialized index (Option B) can be layered in later as a read cache
in front of the Lean source, rather than replacing it as the source of truth.

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

## Resolved decisions

These were previously open questions; each is now settled and implemented in
`Infra.Core.Persistence`.

- **Location: a gitignored local directory, not the git working tree.** Both
  the observation cache and the membership ledger live under `.infra/`, and
  neither is committed. Drift is therefore not visible via `git diff`;
  surfacing it is the engine's job (`Infra.Core.actions`), not source
  control's.

  A committed ledger was tried and reverted; see "Membership is not a committed
  ledger" below for why, because the reasoning generalises.

  *This bullet used to say the cache is gitignored because it "can hold values
  pulled through the `secrets` kind". That was never true, and it mattered,
  because it was the stated reason for the layout.* `SecretsObserved` is
  `{ handle, version }`, no `ObservedOf` has a value field, `Backend.read` for
  `.secrets` deliberately never fetches one, and `Backend.secretValue`'s result
  is handed to one create/update call and "never stored, cached, or returned
  outward". The cache cannot leak a secret because it never holds one. It stays
  gitignored for a different and weaker reason: it is provider-computed noise
  that changes on every pull, and nothing is lost by regenerating it.
- **Layout: one JSON file per `(provider, kind)`, object-keyed by the fleet key's name.**
  `Persistence.statePath root p k` resolves to `<root>/<provider>/<kind>.json`, e.g.
  `.infra/aws/object-store.json`. One file per object would fragment into many trivially small
  files for no benefit; one file per provider spanning multiple unrelated resource shapes can't
  be typed uniformly. Per-kind is the natural grain, since that is already the unit `SpecOf` and
  `ObservedOf` are keyed on. Within a file the JSON object's keys come from `Keys.name` — the
  stable string a fleet assigns to each key, which is how a cached entry is matched back to the
  key it realises on the next pull.
- **Only `(provider, kind)` pairs with something in them get a file**, so the cache does not
  fill with empty objects for every unused kind. A missing file means "nothing cached yet",
  which is exactly the state before the first pull, and is not an error.
- **Only half of a `Sighting` is cached.** A pulled resource carries both its
  provider-computed `ObservedOf` and its `Reported` configuration; the cache
  keeps the first. Configuration is re-read on every pull, so persisting it
  would add a JSON codec per kind and buy nothing — and a loaded entry
  genuinely has no reported half to offer, which is why `Persistence` uses a
  distinct `CachedEntry` rather than pretending otherwise.
- **What is cached is `ObservedOf`, never a target.** Observed state is provider-computed and so
  never `Partial`; targets live in Lean source under version control. `Partial` does have a JSON
  encoding (`unknown` ↦ `null`) for when a partially-known target does need serialising.
- **Membership is a committed ledger, and it *is* the source of truth.**
  Superseded decision: this bullet used to say the opposite, that the key types
  alone decide what a target manages and `load` skips any cached name the
  current fleet no longer declares. That is what made deleting a line from a
  declaration leave the resource running, which is not what a declarative tool
  should do. See "Membership is a committed ledger" below for the replacement.
- **Backend: plain files, no DB, for now.** There's no concrete scale or concurrent-access
  requirement yet (single operator, not a team or CI fleet sharing state). Plain files satisfy
  today's need; the DB option from the section above remains available as a second
  implementation behind the same `load`/`save` interface if that need materializes.

# Decision

We will serialize the state as JSON to start with (`Lean.Data.Json`'s `ToJson`/`FromJson`,
via `deriving ToJson, FromJson` on each state structure). `Infra.Core.Persistence.load`/`save`
implement the "small storage interface with a filesystem implementation" described above.

## An emptied pair deletes its file

`save` writes the `(provider, kind)` pairs that have rows and **removes the
file for a pair that has none**. The second half was missing until 0.3.1, and
its absence made the cache lie in a specific and misleading way: skipping an
emptied pair left the previous contents on disk untouched, mtime and all, so
after a `destroy` the cache went on listing every resource that had just been
deleted — indefinitely, because nothing ever wrote that path again.

No plan was ever wrong because of it. `load` has no callers; the engine plans
from a fresh `pull`, and the cache is a *record* rather than an input. But a
record that reports deleted resources as present is worse than no record: it is
the file a human reads to see what a fleet last observed, and it will be
believed.

`Main.lean` checks it — saving nothing must load back nothing — and the live
test asserts the same after a real `destroy`.

## Membership is not a committed ledger

Two questions were conflated, and separating them is the whole of this section:

: *What does this fleet manage?*

    Intent. It changes only when a human edits something. Answered by the
    **ledger**.

: *What did the cloud last look like?*

    Observation. It changes on every pull, and is provider-computed. Answered
    by the **cache**.

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

So the ledger is local and disposable, and membership is *derived* instead,
from three things a human authors and no run has to write back: the realm, an
inclusion marker on each created resource, and an exclusion snapshot. See
`Infra.Core.Ownership`, which also records which way each of those fails.

| | Ledger | Cache |
|---|---|---|
| Holds | `(provider, kind, name, region)` | `ObservedOf` per resource |
| Path | `.infra/<exe>/infra.ledger.json` | `.infra/<exe>/<provider>/<kind>.json` |
| Committed | no | no |
| Written by | `apply` and `destroy`, never `refresh` | every `refresh` |
| If lost | a `discover` rebuilds it from the marker | nothing. One re-read restores it |

Three consequences worth stating outright.

**A row is keyed by name, not by a fleet key.** `CachedEntry κ` is indexed by
`κ.Key p k`, so it structurally cannot hold a row for a resource the current
declaration does not mention — which is exactly the row that matters here.
`Ledger.Row` is therefore a plain record of strings and enums, deliberately
outside the key family. This is the one place in the library where *not* using
a dependent index is the point: the ledger has to be able to name something the
types no longer can.

**The region is part of the row, and has to be.** Placement comes from the
declaration (`myFleet.regions`). Once the line is deleted there is nothing left
to say where the resource was, and `Backends.backendFor` needs that to route
the delete. A ledger row without a region is undeletable in a multi-region
fleet.

**Deleting an orphan needs no observation at all.** `Backend.delete` takes a
`Handle k`, and `Handle` is a wrapper over `String`. So `(provider, kind, name,
region)` is sufficient for the entire destroy path, which is why the ledger can
be this small and why losing the cache is survivable.

### Leaving the ledger without being destroyed

`forget` in a declaration drops a row from the ledger and does not touch the
cloud. It is the counterpart of Terraform's `removed { … lifecycle { destroy =
false } }`, and it is spelled as a declaration rather than a command for the
reason HashiCorp gives for preferring `removed` over `terraform state rm`: it
shows up in a plan before it happens, and in a diff when it is reviewed.

### Concurrency, stated rather than solved

Nothing here locks. Two applies at once against one account can interleave, and
the local ledger of each will disagree with the other. What keeps that from
being silent is that neither is authoritative: the marker on the resource is,
and a `discover` reconciles both. This is inside the scope this document
already assumes (single operator, not a team or CI fleet sharing state). Remote
state with a lock remains available behind the same `load`/`save` interface as
the DB option above, and is the answer if that scope grows.

### The safety gate

An authoritative ledger has a known failure shape, and it is not hypothetical:
HashiCorp deprecated `terraform refresh` because misconfigured credentials could
make it read every managed object as deleted, then destroy them all with no
confirmation. The same hazard exists here the moment the ledger decides
membership and an observation can mean "gone".

Two defences, both required:

1. `Engine.readsAsAbsent` stays as narrow as it is: a curated list of
   not-found codes, matched by substring, wrong only by omission. A permission
   error must never read as absent. An unrecognised code surfaces as a hard
   error, which is the safe direction.
2. `apply` refuses a plan that would delete more than half the ledger unless
   the operator passes a flag. A plan that deletes everything is either a real
   teardown, in which case `destroy` is the verb for it, or a credentials
   problem.
