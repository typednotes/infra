# Infra

## Code

Please commit code but do not push without approval.

## Documentation

The code should stay in sync with the documentation in `docs/`.
The plan and the intermediate steps are also documented in `docs/`.

The general architecture is defined in `docs/architecture.md`.

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