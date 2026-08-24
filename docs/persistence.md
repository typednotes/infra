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

- **Location: a gitignored local directory, not the git working tree.** The cache lives
  under `.infra/` (`.gitignore`d), not alongside target-state Lean source. Unlike target
  state, the current-state cache can hold values pulled through the `secrets` kind — committing
  it would leak secrets into git history. This matches Terraform's own guidance against
  committing `terraform.tfstate`. Drift is therefore not visible via `git diff`; surfacing it is
  the engine's job (`Infra.Core.actions`), not source control's.
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
- **The cache is not the source of truth about fleet membership.** `load` skips a cached name
  the current fleet no longer declares, and `pullEntries` keeps only resources some fleet key
  claims. The key types decide what a target manages — which is what stops a real `list` against
  a populated account from turning into a pile of proposed deletions.
- **Backend: plain files, no DB, for now.** There's no concrete scale or concurrent-access
  requirement yet (single operator, not a team or CI fleet sharing state). Plain files satisfy
  today's need; the DB option from the section above remains available as a second
  implementation behind the same `load`/`save` interface if that need materializes.

# Decision

We will serialize the state as JSON to start with (`Lean.Data.Json`'s `ToJson`/`FromJson`,
via `deriving ToJson, FromJson` on each state structure). `Infra.Core.Persistence.load`/`save`
implement the "small storage interface with a filesystem implementation" described above.