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

**Recommendation: Option A, generated to be legible.** This matches the request directly —
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

## Open questions

- Should the current-state cache live in the same git repo as target state (so drift shows
  up in `git diff`), or somewhere separate, possibly gitignored?
- One file per object, or one file per service/module?
- Is there a concrete scale or performance requirement yet, or should we default to plain
  files and revisit only if it becomes a bottleneck?

# Decision

We will serialize the state as JSON or JSONB to start with.