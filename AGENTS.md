# AGENTS.md — infra

<!-- agents-md standard v6 — github.com/ngrislain/agents. Refresh with the agents-md skill. -->

Instructions for coding agents (Claude Code, Codex, pi, opencode, …) and for humans working on
this project. `CLAUDE.md` imports this file; edit this one.

## Project

Terraform-style infrastructure as code in Lean 4: target and observed cloud state are
dependently-typed Lean values, so an unrealisable target is a compile error. The repository
ships the `Infra` library, the `infra` executable (offline self-checks, the `new`/`init`
scaffolder, and `plan`/`apply`/`destroy`/`dump`/`render` over a demo fleet) and the example
fleets under `example/`. Consumers such as `typednotes-infra` pin it to a version tag and get
the same CLI through `Infra.Cli.run`. Done means: `lake build --wfail`, the offline self-checks, the
test driver, every example and the `ci/` checks pass, and code, `docs/`, examples and
`site/` agree (see "Code, docs, examples and the page move together" below).

| Task | Command |
| --- | --- |
| Install | toolchain from `lean-toolchain` via `elan`; native FFI deps: `sudo apt-get install -y libpq-dev libssl-dev libsecret-1-dev pkg-config` (Linux) or `brew install libpq openssl pkg-config` with `PKG_CONFIG_PATH` set to their `lib/pkgconfig` (macOS) — see `.github/workflows/lean_action_ci.yml` |
| Type-check | `lake build --wfail` (also runs every `#guard`; warnings fail it) |
| Test | `lake exe infra check && lake test` (offline), then every example executable — see "The examples must work" |
| Lint / format | `./ci/check-aws-policy.sh && ./ci/check-scaleway-scoping.sh && ./ci/check-lakefile-sync.sh && ./ci/check-site-assets-sync.sh`; `./ci/check-workflows.sh <path-to-actionlint>` (pinned actionlint 1.7.7 in CI); no Lean formatter or linter is configured |
| Build / release | `lake build --wfail`; release: `ci/check-release-version.sh <version>`, then a `vX.Y.Z` tag — `release.yml` publishes when the tag is pushed; push only when explicitly requested |
| CLI (applications) | `lake exe infra` (bare invocation runs the offline `check`; there is no `--help` flag yet — an unrecognised argument prints the usage) |

Before declaring a change done, run type-check, tests and lint, and report their real output.

## Permissions: what to do freely, when asked, and only after confirming

**Do freely** — reversible and local:
- read, search, and run type-checkers, tests, linters, formatters and local builds;
- edit files in the working tree within the scope of the task, including `docs/`, `reviews/`,
  `NOTES.md`, `TODO.md`, specs and tests;
- create scratch files in git-ignored directories (`output/`, `.cache/`, `tmp/`);
- read shell history and logs to spot repetitive work (see "Suggest automating repeated work").

**Only when the user asks** — do not initiate:
- `git commit`, creating or switching branches, stashing, rebasing a local branch;
- adding, removing or upgrading dependencies (propose the change and why);
- changing the machine outside the repository — global installs, dotfiles, symlinks, services,
  shell profiles — and recording each change in the manifest (see "Manifest of system changes");
- runs that are long (> ~10 min), costly (GPU, cluster, cloud, paid APIs) or touch shared
  resources (shared caches, staging data);
- clearing `.cache/` or `output/`, or forcing a cache refresh, when the content is slow or costly
  to produce again.

**Confirm explicitly every time**, even if a similar action was approved earlier — approval does
not carry over to a new context:
- `git push` only when explicitly requested by the user for that operation. Direct pushes to
  `main`/`master` are permitted only when explicitly specified. A request specifying the push
  scope (repositories, remote, branches and any tags), including an explicit command or batch,
  counts as confirmation; do not ask again for the same operation. Approval does not extend to
  later pushes. Never force-push or rewrite pushed history;
- opening, merging or closing a PR/MR, posting review comments, tagging, releasing, publishing a
  package or image;
- deploying to any environment (dev, staging, prod);
- publishing outside the repo: Confluence, Google Docs/Sheets, Slack, email, issue trackers;
- deleting or overwriting anything not recreated by a command in this repo: branches, remote
  resources, datasets, buckets, tables, experiment outputs;
- changing infrastructure, permissions, secrets or credentials.

**Never**: commit secrets or customer data; skip hooks (`--no-verify`); rewrite pushed history;
weaken a type-check, a test or a lint rule to make it pass; claim a check passed without running it.

## Repository layout and the documents it keeps

| Path | Audience | Content | Keep in sync with |
| --- | --- | --- | --- |
| `docs/` | humans, high level | project, architecture, algorithms, code map — a hierarchy of Markdown files illustrated with SVG figures | the code, every change |
| `README.md` (root and per package) | users and contributors, close to the code | install, usage, examples, how the code is organised | the code it sits next to |
| `SPEC.md` (per module/package) | humans first | the contract the code must fulfil | types and tests check it |
| `scripts/` | contributors | repository-maintenance helpers, including `rebase-on-main.sh` | developer workflow and tests |
| `reviews/` (git-ignored) | reviewers | reviews of commits and PRs: explanation, SVG figures, suggested comments and fixes | — (dated snapshots) |
| `output/` (git-ignored) | users of the application | large, binary or reproducible outputs of runs | — (regenerated by the CLI) |
| `.cache/` (git-ignored) | the code | cached results of slow downloads and computations | — (safe to delete) |
| `CHANGELOG.md` | users of a released artifact | one entry per version, newest on top | every release |
| `LOGBOOK.md` | humans re-running experiments | one entry per experiment, newest on top, with repeatability info | every experiment |
| `TODO.md` | everyone | planned but not executed work | when planning or finishing work |
| `NOTES.md` (anywhere) | humans and agents | things worth knowing that are not definitive documentation | when something surprising is learned |

### `docs/` — high-level documentation

- A hierarchy with an index at `docs/README.md` linking every page. Typical sections:
  `docs/project/` (goals, scope, decisions, roadmap), `docs/architecture/` (components, data
  flow, deployment), `docs/algorithms/` (methods, math, complexity, trade-offs), `docs/code/`
  (module map, key types, extension points).
- Illustrate with SVG figures stored next to the page that uses them (`docs/architecture/figures/`).
  SVG is the editable source: hand-written or generated by a committed script, legible at page
  width, in light and dark backgrounds, with a `<title>` and `<desc>`. Do not commit rendered PNGs.
- `docs/` explains *why* and *how it fits together*; `README.md` files explain *how to use and
  modify* the code next to them. Link rather than repeat; one canonical page per subject.
- Keep `docs/` in sync: a change to behaviour, architecture, an algorithm or a public interface
  updates the affected pages and figures **in the same change**. Separate measured results from
  expectations and proposals.

### `scripts/` — repository maintenance

- All runnable helpers follow the same interface standard as the application CLI:
  a colourful, structured terminal UI (plain when piped, `TERM=dumb` or `NO_COLOR` is set),
  self-documenting `--help` with examples and effective defaults plus their sources, and
  actionable errors. Missing arguments use safe defaults or prompt interactively on a TTY;
  non-interactive runs never hang waiting for input and identify any required flag explicitly.
- Keep editable defaults in a TOML file, normally `scripts/defaults.toml`, grouped by command.
  If a script manages multiple runs/sessions, organise their defaults under named TOML tables
  and select them explicitly with `--run` / `--session`; do not duplicate scripts or hard-code
  session settings. Document precedence: flags > environment > selected run/session >
  command defaults > built-in fallbacks. Help shows the resolved values and their sources.
- State-changing helpers show the resolved plan, prompt before applying it and support `--yes`
  for non-interactive use and `--dry-run` for a non-mutating preview. Defaults never bypass
  confirmation or the Permissions section.
- Git repositories keep an executable `scripts/rebase-on-main.sh`: fast-forward local `main`
  from `origin/main`, return to the original branch, and rebase it onto the updated `main`.
  Allow an explicit remote override; on `main`, only fast-forward it. In a monorepo, share one
  helper at the Git root rather than adding a copy per package.
- Provide `--help` and a non-mutating `--dry-run`. Refuse a dirty working tree (including
  untracked files), detached HEAD, and unfinished Git operations. Never stash, reset, discard
  changes or push automatically. If updating `main` fails, return to the original branch;
  if rebasing conflicts, stop there and explain `git rebase --continue` / `--abort`.
- Document how to invoke it and test it against temporary local repositories, never the working
  checkout. Preserve existing helpers rather than overwriting them blindly. Creating the helper
  is not permission to execute a rebase: the Permissions section still applies.

### `SPEC.md` — one contract per module/package

- Every module, package or component with a public surface has a `SPEC.md` beside its code: a short,
  human-readable statement of what it guarantees — purpose, inputs/outputs, invariants, error
  behaviour, performance bounds, what it explicitly does not do.
- The spec is the source of truth. Types encode as much of it as the language allows; tests check
  the rest. When code and spec disagree, fix one of them deliberately and say which.
- Number the clauses (`S1`, `S2`, …) so tests and reviews can cite them.

### `reviews/` — reviews of commits and PRs

One directory per review, `reviews/YYYY-MM-DD-<slug>/`, with a `README.md` (summary, walkthrough,
findings ranked by severity, suggested comments ready to paste, suggested fixes as diffs) and
`figures/*.svg`. A video only when the user asks for one. `reviews/` is **git-ignored**: reviews
are local working documents, not project history. Posting them anywhere requires confirmation
(see Permissions).

### `output/` — generated results, git-ignored

What an application produces that is large, not text (images, videos, models, archives, binary
tables) or reproducible from the code and its inputs goes to `output/`, which is **git-ignored**.
Organise it by command and run (`output/<command>/<run-id>/`), write next to each result what
produced it (command, parameters, commit), and make the location a CLI option with `output/` as
the default. Anything worth keeping is either reproducible from the repo (then it stays in
`output/`) or published deliberately (a release, a bucket, a document — see Permissions); small,
reviewed, hand-curated text results may be committed elsewhere, e.g. in `docs/`.

### `.cache/` — caching slow objects, git-ignored

Anything slow or costly to obtain — a large download, a long computation, a remote query — is
cached under `.cache/` (**git-ignored**), with the most idiomatic library of the language: in
Python `joblib.Memory` for function results, Parquet (or JSON for small, human-readable data) for
tables keyed by their parameters; elsewhere the equivalent (`cacache`/file caches in JS, `cached`
or file caches in Rust, …).
- The cache key covers everything that determines the result: parameters, input versions or
  checksums, and a code version. Cache only results that cannot change for a given key — never
  "the latest" of something live (pin a date, a version or a completed time window instead).
- Deleting `.cache/` must always be safe: it costs time, never correctness. Downloads are
  verified (checksum or size) before being cached.
- The CLI offers `--no-cache` and `--refresh`, and the location is configurable (config file or
  environment variable), with `.cache/` as the default.

### `CHANGELOG.md` — only if the project is released as a versioned artifact

Library, image, executable, model: one section per version, newest on top, following
[Keep a Changelog](https://keepachangelog.com) and [SemVer](https://semver.org). Unreleased changes
accumulate under `## [Unreleased]`. Bump the version and the changelog in the same change.

### `LOGBOOK.md` — only if the project runs experiments

One entry per experiment, newest on top, readable by a human who was not there: date, question,
setup, result (with numbers), conclusion, and how to repeat it — commit hash, exact command,
parameters, seeds, data snapshot, links to outputs and dashboards. Failed and inconclusive
experiments are logged too.

### `TODO.md` and `NOTES.md`

- `TODO.md`: planned but not executed work, as a checklist grouped by theme, with enough context to
  pick an item up cold. Remove items when done (the history is in git and the changelog).
- `NOTES.md`: anywhere something should be known by a human or an agent and is not definitive
  documentation — gotchas, findings, dead ends, external constraints, open questions. Promote a note
  to `docs/` or a `README.md` once it becomes definitive.

## Code

### Types: use the strongest standard checking the language offers, maximally

- Use the standard type-checker of the language/framework in its strictest practical mode, run it in
  CI, and keep it at zero errors.
  In this project: Lean 4 (`leanprover/lean4:v4.36.0`) with `autoImplicit` on (Lean's default: it only automates implicit binders, which are still fully checked),
  and `lake build --wfail` in CI (the ubuntu-24.04/macos-latest matrix of
  `.github/workflows/lean_action_ci.yml`, plus the live-test and cleanup workflows): warnings,
  including `sorry`, fail the build. `infra new` scaffolds projects with
  `--wfail` CI (`Infra/Cli/New.lean`); the scaffold step in CI builds one with `--wfail`.
- Make illegal states unrepresentable: precise types, enums/sum types over strings and flags, new
  types for identifiers and units, immutable data by default. Avoid `Any`, casts and ignores; when
  one is unavoidable, scope it narrowly and justify it in a comment.

### Modularity and docstrings

- Organise the code in cohesive modules with explicit, minimal public interfaces and acyclic
  dependencies. One canonical implementation per concern; delete dead paths rather than keep them.
- Every public module, class and function has a docstring written for a human user: what it is
  for, how to call it, what it returns or raises, and an example when usage is not obvious. Explain
  *why* in comments, not *what*.

### One CLI per application

An application project (anything run rather than imported) exposes **a single command-line entry
point** with a short name, e.g. `uv run infra <command>` in Python (a `[project.scripts]` entry),
`npx infra`, `cargo run --bin infra`. Every operation — run, train, evaluate, serve, inspect,
publish — is a subcommand of it, not a loose script. Repository-maintenance helpers in
`scripts/` are a narrow exception, not alternative application entry points.

- **Self-documented**: `infra`, `infra --help` and `infra <command> --help` at every level list
  the commands, arguments, defaults and an example. Running a command with no arguments prints help
  rather than doing something surprising.
- **No dead ends on missing arguments**: each argument either has a default or is asked for
  interactively. Defaults live preferably in a TOML config (`infra.toml`, or `[tool.infra]` in
  `pyproject.toml`), with hard-coded fallbacks in the code; precedence is
  flag > environment variable > config file > hard-coded default, and `--help` shows the effective
  value and where it came from.
- Interactive prompts only when stdin is a TTY; otherwise (CI, agents, pipes) fail fast with a message
  naming the missing flag. Destructive or outward-facing commands ask for confirmation and accept
  `--yes` and `--dry-run`.
- **Rich, colourful terminal UI** preferably: coloured and structured help, tables, progress bars,
  spinners, syntax-highlighted output and interactive prompts/selections (Python: `rich` +
  `rich-argparse`, Typer, Textual for full TUIs; JS: `@clack/prompts`, `ink`; Rust: `clap` with
  colours, `indicatif`, `ratatui`; Go: Charm's `bubbletea`/`lipgloss`). Degrade gracefully: plain
  output when not a TTY, and honour `NO_COLOR`.
- Large, binary or reproducible results go to `output/` (overridable with `--output`); slow
  intermediate results are cached in `.cache/` (`--no-cache`, `--refresh`) — see above.
- Data goes to stdout, logs and progress to stderr; exit codes are non-zero on failure. Offer
  `--json` where the output is consumed by other programs.

### Tests

- Tests do two jobs: **illustrate** every unit and higher-level functionality working (they are
  executable examples — readable, named after the behaviour), and **check** that the code fulfils its
  `SPEC.md` (cite clause ids, e.g. `test_s3_rejects_empty_window`).
- Cover unit, integration and end-to-end levels as relevant; prefer property-based tests for
  invariants. Every bug fix comes with a regression test. Tests are deterministic and fast by default;
  slow or networked tests are marked and opt-in.

## Working style

- Keep changes focused on the task; mention unrelated issues in `TODO.md` or `NOTES.md` instead of
  fixing them silently.
- Update code, types, tests, `SPEC.md`, `docs/`, `README.md`, `CHANGELOG.md` and figures together.
- Report faithfully: what was run, what passed, what failed, what was skipped.

### Manifest of system changes

Changes to the machine outside the repository are recorded so they can be tracked and reverted:
installing or upgrading tools globally (`brew`, `uv tool`, `pipx`, `npm -g`, `cargo install`),
editing dotfiles and configuration under `$HOME`, creating symlinks, services, launch agents or
cron jobs, changing shell profiles or system settings. (Changes inside the repo are tracked by
git; cloud resources by their own infrastructure-as-code.)
- **Where**: the XDG state directory, `${XDG_STATE_HOME:-~/.local/state}/<tool>/` — an
  application uses its own name; an agent acting by hand uses `agents/`, appending one JSON
  object per line to `manifest.jsonl`:
  `{"time": "…", "project": "…", "command": "…", "changes": ["…"], "revert": "…"}`.
- **What**: the exact command, every path or setting it changed, and what reverting needs — the
  inverse command, the backup path or the previous value. Back up a file before overwriting it.
- **Applications** that make such changes (installers, linkers, setup commands) write the
  manifest themselves and offer `history` and `revert` subcommands. A revert undoes newest first,
  skips an action whose path changed since, and is itself recorded.

### Undo log for mutating actions

An application whose actions mutate state — files, configuration, links, services, databases,
anything not regenerated by a command — keeps an **undo log**: one record per mutation, enough to
revert it.
- **At the scope of what changed**, so the log sits next to the state it can restore:

  | Scope of the mutation | Undo log |
  | --- | --- |
  | system-wide (`/etc`, `/usr/local`, system services) | `/var/lib/<app>/undo.jsonl` (Linux), `/Library/Application Support/<app>/undo.jsonl` (macOS) |
  | user-wide (`$HOME`, dotfiles, user services) | `${XDG_STATE_HOME:-~/.local/state}/<app>/undo.jsonl` |
  | project or folder (files under a working directory) | `<folder>/.<app>/undo.jsonl`, git-ignored — not in `.cache/`, which must stay safe to delete |

  An action spanning several scopes writes a record in each.
- **A record** holds: id, time, the command and run it belongs to, the target (path, key, row),
  its state before (a backup path, the previous value, or "absent") and after, and the inverse
  operation. Back up anything overwritten or deleted, next to the log (`backups/<id>/`).
- **Write-ahead**: write the record *before* mutating and mark it done after, so an interrupted
  action can still be undone or completed.
- **Undo** (`<cli> undo [id|run]`, default: the latest run): newest first, only if the target
  is still in its recorded "after" state — otherwise skip and say why; the undo is itself
  logged. Backups are kept until the user prunes them (`<cli> undo --prune …`).

### Suggest automating repeated work

Look out for tasks the user does by hand again and again, and propose to automate them.
- **Where to look**: the current session (the same commands or edits requested several times);
  the shell history (`~/.zsh_history`, `~/.bash_history`), for commands touching this project;
  CI and run logs; `LOGBOOK.md`, `NOTES.md` and `README.md` steps that are long manual sequences;
  `git log` (recurring chore commits, repeated fix-ups).
- **History and logs are sensitive**: read them locally and only for this purpose, extract
  command *patterns*, and never copy secrets, tokens, hostnames of customers or personal data into
  files, messages or suggestions.
- **Suggest, don't impose**: at a natural break, propose briefly what is repeated, how often, the
  automation (preferably a subcommand of the project's CLI; otherwise a script, a git hook, a CI
  job, a scheduled job or an agent skill) and what it saves. Implement it only if the user agrees;
  note accepted-but-deferred ideas in `TODO.md`, and do not repeat a suggestion the user declined.

## Project-specific notes

### Overrides of the standard rules above

Pushes follow the explicit-request rule in the Permissions section above.
Commits and tags follow the standard: commit only when the user asks, and confirm every tag.

**Push only when explicitly requested by the user.** A release request or version bump
does not itself authorize a push. Without an explicit push request, prepare the work
so that a push is the only thing left: run the checks, commit and tag as asked, and
say what is ready and what the push will trigger.

Approval for one release was previously carried forward into the next on the reasoning
that a version bump implies a release. Do not repeat that mistake: require an explicit
request for each push operation. A tag under this repository's ruleset is immutable and
a push to `main` is public; neither is the assistant's to decide the timing of.

### Code: features, ownership and markers

**No half-implemented features.** If a feature (a safety check, a tagging
scheme, an ownership model, ...) is only wired up for some of the kinds/cases
it should logically cover, that is not "done for now" — it is a trap for
whoever assumes the feature applies uniformly. A 2026-09-10 incident: the
ownership/tag system (`Infra/Core/Ownership.lean`) was wired for `.objectStore`
and `.awsInstance` only, with every other kind silently falling back to
matching the (since removed) ledger; `destroy` on a Scaleway container namespace cascaded
Scaleway-side and deleted an unmanaged sibling container that a user
reasonably assumed the tag system would have protected. Either implement a
feature for every case it claims to cover in the same change, or say loudly
in the code, the docs, and to the user exactly which cases it does **not**
cover yet — never let partial coverage look complete. When you can only do
part of a feature, stop and get explicit agreement from the user on the
partial scope before shipping it, rather than deciding unilaterally that
"the common case" is good enough.

**The marker decides what a fleet manages — never local state, never a name.**
This is the principle everything else rests on, and it cuts both ways:

1. **Every fleet has a name, and every resource it creates carries it** — in
   a tag, the description rung, or the name prefix (the ladder below). The
   name is the `fleet` declaration's identifier in kebab-case
   (`Fleet.name`), overridable with `Boundary.fleetName`; `Infra.Cli.run`
   resolves it once and checks it is a valid marker value on every cloud.
   The name prefix defaults to the name and a hyphen. There is no unnamed
   fleet and no marker that matches every fleet: the old value `true` is
   retired (`retiredMarkerValue`) and matches none — a resource carrying it
   is warned about, never touched.
2. **A resource carrying this fleet's marker that the declaration no longer
   names is destroyed on the next apply — on any machine.** Deleting a line
   must destroy the resource from a fresh CI runner exactly as from the
   laptop that created it. `push`'s callers
   find these by asking the cloud (`Engine.claimUndeclared`), across every
   region and every kind of every cloud the fleet declares *or names in
   `accounts`* — including a kind, or a cloud, the declaration no longer has
   anything of, which is exactly the case where the last resource of it was
   just removed. `accounts`, not "whatever credentials are loaded", because a
   laptop holds credentials for unrelated accounts and `accounts` is the
   checked statement of where the fleet lives.
3. **Only a resource carrying this fleet's marker is changed or destroyed.** A
   declared name is not evidence: a resource holding a declared name without
   the marker is warned about by name and left alone — `update`, `replace` and
   `delete` included, on the plan path too (`Engine.foreignDeclared`).
4. **There is no ledger, and no local state at all.** Every run reads the
   markers from the cloud. The ledger and the observed-state cache were
   removed in 0.16.0 because each was a second source of truth that could
   disagree with the first. A cache may come back only as a *real* cache —
   deleting it can never change a plan — and the structure that shape wants
   already exists as `Infra.Providers.Snapshot`: what `dump` writes, and what
   tests replay as in-memory backends (`Snapshot.backends`). Build test
   accounts from it rather than hand-rolling a `Backends`.
5. **"Undeclared" is about the physical resource.** Two kinds that list the
   same thing (an S3 bucket as `objectStore` and `s3Bucket`; a Scaleway
   container as `compute` and `scalewayContainer`) share a physical class
   (`Engine.physicalClass`); a resource declared under one is not an orphan of
   the other. Adding a kind means checking whether it overlaps an existing one.
6. **Changing and destroying need a marker that names this fleet** — the same
   test for both (`ownershipOf`, `claimsUndeclared`). A `Boundary` without a
   name (only reachable by calling the engine directly) claims nothing by tag.
7. **`forget` releases.** A forgotten resource that still carries this
   fleet's marker on a rung that can be rewritten has the marker removed on
   the next apply (`Action.release`, `Backend.release`, re-checked just
   before) — after which it is no fleet's and the line can go. Every
   taggable `(cloud, kind)` pair implements `release`; a name cannot be
   unwritten, so a name-rung resource keeps its marker and its `forget` line
   must stay while it exists.

The cases this cannot cover are **enumerated, in `Engine.scannableUndeclared`
and `docs/coverage.md`**, never left to a catch-all: `postgresMigrations` has
nothing to find (its delete is a FORGET that does nothing); a cloud named
neither in the declaration nor in `accounts` is not scanned, nor is a named
one without credentials here (said out loud); a name-rung resource's `forget`
line stays; a resource carrying the retired `true` is warned about, never
touched; an undeclared resource whose marker read is refused (access denied,
`readsAsRefused`) is warned about, never touched — what infra may not read it
does not manage — but only when another marker of that kind in that region
was read: reading the marker is required to handle a kind that carries one, so
a kind whose every read is refused fails the run (`refusedWithoutPermission`),
as does a refused *listing*, because "unreadable, so not ours" must never
widen from one resource to a whole kind.
Scaleway queues are no exception: listing checks, read-only, whether
Queues is enabled, and only then uses the dedicated `infra` SQS credential —
shared between machines as the unmarked secret `infra-sqs-credential`, a cache
that costs one mint to lose. Every change near this principle is tested
against a snapshot of an account (`checkMarkerDecides`, `checkDumpReplays`,
`checkRetiredCloud`, `checkForgetReleases`, `checkRefusedIsNotManaged` in
`Main.lean`) — never with
remembered state, which hides
exactly the bug this section exists to prevent: before 0.15.0, removing a line
from `typednotes-infra` left an IAM application and its live API key standing
after a CI apply, because only the laptop's ledger knew they existed.

**Ownership falls back down a ladder, and never off the end.** When a feature
needs to mark a resource — ownership being the one that matters — not every
cloud offers the same place to put the mark, and "this object has no tags" is
not a reason to leave the feature unimplemented for that kind. Take the
strongest rung the object supports, and say in the code which rung it is on:

1. **tags or labels**, where they exist;
2. **the object's one writable free-text field** — a `description`, a
   `displayName` — with the marker serialised into it
   (`Ownership.encodeMarkerText`). Identical semantics to a tag; only the
   address differs;
3. **the resource's own name**, checked against a prefix the declaration
   configures (`Boundary.namePrefix`), for the objects that have neither.

Rung 3 is weaker than the other two and must stay opt-in and *verifying*: the
evidence is something the declaration wrote rather than something this tool
did, and renaming a resource to fit is not infra's to do — a fleet key is the
cloud-side name. By default the prefix is the fleet's name and a hyphen; a
resource outside it is `foreign`: never changed, never deleted as an orphan. Never treat an empty prefix as matching everything.

Two rules that come out of the 2026-09-19 pass over this:

- **"Cannot be tagged" is a provider fact, so check it, do not recall it.**
  Three files said a Scaleway IAM application could not be tagged. It always
  could. The claim had been copied between code, `docs/providers.md` and
  `docs/coverage.md` until it looked well established. Check the provider's
  *generated SDK or discovery document* — not its prose documentation, which
  is where the wrong reading came from — and write down the date and the
  source, as `Region.lean` already requires for its tables.
- **A kind that answers "I cannot tell you" is a hole, not a design.** Before
  that pass, eight `(cloud, kind)` pairs reported no ownership evidence — plus
  one within-pair gap, Scaleway's Serverless SQL half of `postgres`. Four of
  the nine had a stated permanent reason (one of them false) and five had
  none; `imageRegistry` was not mentioned in the dispatch at all, so all three
  of its clouds fell to a catch-all. From the outside a carefully argued
  exception and a case nobody had got to were indistinguishable — both
  answered `none`, both refused — so the documented ones made the
  undocumented ones look deliberate. Either every pair answers, or the ones
  that cannot are enumerated: in the code, in `docs/coverage.md`, and to the
  user.

### CI scripts are bash

Everything under `ci/`, and every inline `run:` block in a workflow, is
**bash**. One language, so that reading a check does not mean switching
dialects, and so that a fix to one is not blocked on knowing another.

The single exception is a check whose *subject* is Python — a script that
exercises a Python program or SDK is properly written in it. Parsing JSON is
not that exception: `jq` is pre-installed on both runner images this repo
uses (ubuntu-24.04 ships 1.7, macos-15 ships 1.8.2), and
`ci/check-aws-policy.sh` is the worked example.

Two things that make a bash rewrite safe rather than merely shorter:

- **A validator is rewritten against its failures, not its successes.** Both
  versions passing on the current tree says almost nothing — a script that
  silently matches nothing passes too, which is exactly what the first draft
  of `check-scaleway-scoping.sh` did. Run old and new side by side over
  deliberately broken inputs and diff the output. Doing that turned up a
  wrong sort order and a crash on `Statement` being an object, neither of
  which the happy path could show.
- **No `sed -i`.** BSD sed reads the next argument as a backup suffix and GNU
  sed does not, so a one-liner that works on the Linux runner fails on the
  macOS one — half the matrix. Write to a temporary file and `mv` it over.

If a check needs a tool beyond coreutils, test for it and say so
(`command -v jq` … `exit 2`). A missing interpreter must not produce an empty
report that reads as a pass.

### Documentation

The plan and the intermediate steps are also documented in `docs/`.

The general architecture is defined in `docs/architecture.md`; how the pieces
actually work, with diagrams, is `docs/internals.md`. A change to the engine
means checking both: the first says why, the second traces what runs.

When something does not work and should be changed, the user should be asked to change the doc and implemented then.

### Code, docs, examples and the page move together

There are now four places that describe this project, and they drift in
different directions if left alone. A change is not finished until all four
agree:

| Surface | Where | What it must not do |
|---|---|---|
| Code | `Infra/` | — |
| Design docs | `docs/*.md` | describe a mechanism that no longer exists |
| Examples | `example/`, `Infra/Demo.lean` | stop compiling, or demonstrate the old way |
| The page | `site/index.html` | claim a feature or a number the repo cannot back |

Concretely, when a change lands:

- **Grep for the thing you removed or renamed**, across `docs/`, `site/`,
  `README.md` and `AGENTS.md` — not just `Infra/`. The compiler covers the Lean
  side and covers none of the rest.
- **`docs/coverage.md` is the canonical statement of what exists.** A new
  feature adds a row; a fixed defect leaves the "known defects" list. It is
  what the README and the page summarise, so it is the one to change first.
- **The page quotes real output and real error messages.** If you change an
  error message, re-provoke it and paste what the compiler now says. The same
  rule as the examples' headers.
- **Numbers are checked, not recalled** — resource counts, kind counts, "N of
  M verified". Run the thing and read the output. Several numbers in these
  files were wrong when first written from reading the code.
- **A removed defect is deleted from the ledger, not softened.** If it is gone,
  say it is gone and say what replaced it; `docs/diff-semantics.md`'s ledger is
  only useful while it is true.
- **Build a project produced by `infra new`.** Its pinned Infra dependency
  selects Linen, which supplies the native link configuration. Keep the
  generated CI templates in sync with this checkout.
- **A release bumps the version everywhere it is written down.** Nine places:
  `lakefile.lean`'s `version`, `Infra/Cli/New.lean`'s `infraRev` (the tag a
  scaffolded project is pinned to), the `rev`/`@` in `README.md`,
  `docs/tutorial.md` and `site/index.html`, the heading in `CHANGELOG.md` and
  `docs/coverage.md`, **the page's "what's new" banner**
  (`site/index.html`'s `<strong>`), and **`README.md`'s "What X covers"
  heading**. Do not count them by hand —
  `ci/check-release-version.sh <version>` is the list, and adding a tenth
  place means adding it there in the same change.

  A consumer is pinned to a tag rather than to `main` on purpose — the front
  end's shape is part of what its `Main.lean` is written against — so a
  release that forgets `infraRev` scaffolds projects against the previous
  one. The user may push `main` and a new version tag together; the publisher
  waits for `lean_action_ci.yml` to pass on that exact release commit. A pinned
  `require` cannot resolve until the tag exists on the remote.

  Automatic CI runs on main and PRs targeting main, with manual dispatch
  retained. `release.yml` runs only for version tags (or a manual retry naming
  an existing version tag). `ci/require-main-ci.sh` requires that tag's actual
  checkout to be reachable from main and its latest exact-commit **push-to-main**
  CI run to be completed/success. Missing/pending CI is polled for up to two
  hours; failed/cancelled CI, invalid evidence, API errors, timeout, PR/manual or
  different-commit CI cannot publish. The full offline matrix is attested,
  not repeated on tags; the version and CHANGELOG checks still run. Cloud
  Plan/Apply/Destroy, live-test and cleanup workflows retain their own triggers.

  The last two were added after they had advertised **0.9.0 for two
  releases**. Neither is a `rev = ` line, so the checker did not know about
  them, and a reader's first impression of this project is the banner. The
  rule that follows: a place naming the *current* version belongs in the
  checker, and a place recording *when something was last looked at* should
  carry a date instead — `ci/README.md` does — so that it is not one more
  thing a release has to remember.
- **`docs/branding.md` governs the artwork.** Do not add a third-party logo
  without reading it first.

### The examples must work

`example/` is test surface, not decoration: several `#guard`s in there pin
facts that would otherwise only fail against a real cloud, and the headers are
the tutorial. After any change to the library, build everything and run every
executable:

    lake build --wfail
    lake exe infra              # the offline self-check suite
    lake exe scaleway-queue     # bare invocation: offline, free
    lake exe paris-instances    # bare invocation: offline, free
    lake exe cross-cloud        # bare invocation: offline, free
    lake exe multi-region       # bare invocation: offline, free
    lake exe serverless-sql-iam # bare invocation: offline, free
    lake exe postgres-migrations # bare invocation: offline, free
    lake exe kubernetes-postgres # bare invocation: offline, free
    lake exe scaleway-pull      # reads a real Scaleway account

All but the last are offline, credential-free and free of charge, so there is
no excuse for not running them. `scaleway-pull` needs Scaleway credentials and
is read-only.

Keep the headers true as well as the code: they document what each example
proves, and several quote real compiler error messages. If you change an error
message or an API, re-provoke the error and paste what the compiler actually
says rather than what it used to say.

### Provider facts go stale

Some values are typechecked against a table written down in this repo rather
than fetched: region codes and localities (`Infra/Core/Region.lean`), and any
future table of the same shape — instance types, runtimes, instance classes.
Each is a snapshot of a provider's catalogue, and providers add to theirs
without telling us.

So: **check these tables against the providers' own documentation** when
touching them, and treat a stale entry as a bug rather than a fact of life.
Concretely, when adding to or reviewing one —

- Verify every row against the provider's current docs, not against memory and
  not against what the table already says.
- Prefer deriving one table from another over writing the same fact twice
  (`knownRegions` is derived from the `Locality` table for exactly this
  reason), so there is one place to correct.
- Keep the unchecked escape hatch working and documented (`Region.raw`). A
  table going stale must never be a hard block on using a real region — it
  should cost the author a more visible spelling, nothing more.
- Say in the doc comment when the table was last checked and against what, so
  the next reader knows how much to trust it.

Sources: AWS's regions-and-endpoints and instance-type pages, Scaleway's
availability and product docs.

### Linen

If [linen](https://github.com/typednotes/linen) lacks functionalities, you can suggest additions (following instructions from the project).

**`linen` is a first-party sibling, not a third-party dependency.** Building
blocks belong there, and moving one out of `infra` into `linen` is a *move*
rather than a fork: `linen`'s copy becomes the only copy, and `infra`'s is
deleted in the same change. Two live copies of the same code is the outcome to
avoid — the dependency direction is fixed (`infra` requires `linen`, never the
reverse), so there is no ambiguity about which way things travel.

The test for "belongs in `linen`" is whether more than one sibling needs it, or
whether it is a building block rather than an infrastructure-as-code concern. A
cloud's region codes are a building block; the per-resource placement map that
reads them is not. A credential chain is a building block; the ownership
boundary that decides which resources it may touch is not.

Pending moves are listed in `CHANGELOG.md` under `[Unreleased]` rather than
left implicit, because a duplicate nobody has written down is a duplicate that
will drift.
