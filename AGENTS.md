# Infra

## Code

**Commit and tag freely; never push.** Pushing is the human's, always — not
"unless approved", not "unless it seems expected", not "unless the previous
step was approved and this is obviously the next one". Prepare the work so
that a push is the only thing left: commit it, tag it, run the checks, say
what is ready and what the push will trigger.

Written this strongly because the weaker version ("do not push without
approval") did not hold. Approval for one release was carried forward into
the next on the reasoning that a version bump implies a release — which is
plausible, and wrong, and exactly the kind of reasoning an explicit rule
exists to stop. A tag under this repository's ruleset is immutable and a push
to `main` is public; neither is the assistant's to decide the timing of.

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

## CI scripts are bash

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

## Documentation

The code should stay in sync with the documentation in `docs/`.
The plan and the intermediate steps are also documented in `docs/`.

The general architecture is defined in `docs/architecture.md`; how the pieces
actually work, with diagrams, is `docs/internals.md`. A change to the engine
means checking both: the first says why, the second traces what runs.

When something does not work and should be changed, the user should be asked to change the doc and implemented then.

## Code, docs, examples and the page move together

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
- **`Infra/Cli/New.lean` embeds a copy of the lakefile's native link-flag
  block and of the CI workflows.** Lake cannot propagate `moreLinkArgs` from a
  dependency, so every consumer needs that block; if this repo's own
  `lakefile.lean` link flags or workflows change, the scaffolder's copies have
  to change with them. `lake exe infra new /tmp/x` and building the result is
  the check.
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
  one. Tag the commit, and push the tag: a pinned `require` cannot resolve
  until the tag exists on the remote.

  The last two were added after they had advertised **0.9.0 for two
  releases**. Neither is a `rev = ` line, so the checker did not know about
  them, and a reader's first impression of this project is the banner. The
  rule that follows: a place naming the *current* version belongs in the
  checker, and a place recording *when something was last looked at* should
  carry a date instead — `ci/README.md` does — so that it is not one more
  thing a release has to remember.
- **`docs/branding.md` governs the artwork.** Do not add a third-party logo
  without reading it first.

## The examples must work

`example/` is test surface, not decoration: several `#guard`s in there pin
facts that would otherwise only fail against a real cloud, and the headers are
the tutorial. After any change to the library, build everything and run every
executable:

    lake build
    lake exe infra              # the offline self-check suite
    lake exe scaleway-queue     # bare invocation: offline, free
    lake exe paris-instances    # bare invocation: offline, free
    lake exe cross-cloud        # bare invocation: offline, free
    lake exe multi-region       # bare invocation: offline, free
    lake exe serverless-sql-iam # bare invocation: offline, free
    lake exe postgres-migrations # bare invocation: offline, free
    lake exe scaleway-pull      # reads a real Scaleway account

All but the last are offline, credential-free and free of charge, so there is
no excuse for not running them. `scaleway-pull` needs Scaleway credentials and
is read-only.

Keep the headers true as well as the code: they document what each example
proves, and several quote real compiler error messages. If you change an error
message or an API, re-provoke the error and paste what the compiler actually
says rather than what it used to say.

## Provider facts go stale

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

## Linen

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
