# Infra

## Code

Please commit code but do not push without approval.

## Documentation

The code should stay in sync with the documentation in `docs/`.
The plan and the intermediate steps are also documented in `docs/`.

The general architecture is defined in `docs/architecture.md`.

When something does not work and should be changed, the user should be asked to change the doc and implemented then.

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