# Changelog

Notable changes to `infra`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are
[semantic](https://semver.org/), with the 0.x caveat that a minor bump may
break the Lean API — and before a first tagged release, several will.

`docs/coverage.md` is the standing statement of what exists and how far it has
been exercised; this file is what changed and when.

## [0.3.0] — 2026-09-05

### Added

- **GCP as a third cloud**, at the type level. Resources can be declared,
  placed, referenced, scheduled, diffed and exported to HCL for GCP today.
  There is **no live client**: every backend branch raises rather than
  returning an empty list, because an empty list would claim nothing exists
  there and the engine would propose creating a fleet it cannot create.
  `grep noGcp` is the to-do list.
- **A GCP credential source.** GCP is the first cloud here that does not sign
  its requests, so `Credentials` gains an `accessToken`, and the chain gains a
  row that shells out to `gcloud auth print-access-token`, then the keychain,
  then `GOOGLE_OAUTH_ACCESS_TOKEN`. The token expires within the hour and a
  long apply can outlive one; that is written down rather than discovered.
- **20 GCP regions**, checked against Google's own location lists. Four
  apparent matches are deliberately absent because they are traps:
  `europe-west1` is Belgium not Ireland, `europe-west4` is Eemshaven not
  Amsterdam, `europe-southwest1` is Madrid where AWS's Spain is Aragón, and
  `northamerica-northeast1` is Montréal where AWS names only "Canada
  (Central)".
- **Terraform / OpenTofu interoperability, both directions**
  (`Infra/Interop/Terraform.lean`). `toHcl` writes `.tf` from a fleet, with
  real HCL references where the fleet has references and a per-resource
  `region` from the placement; `fleetOfState` reads `terraform show -json`
  back into a fleet declaration. Neither is a round trip and both say so.
- **A test driver** (`lake test`), offline by default. `lake test -- aws`
  (or `scaleway`, `gcp`) creates one real queue, checks the fleet converged,
  and deletes it again — with teardown guaranteed even when the assertions
  fail, and a teardown failure reported *alongside* the original rather than
  replacing it. Everything it creates is named `ci-tests-infra-…`.
- **A manually-triggered live workflow**, one cloud at a time
  (`.github/workflows/live-test.yml`), plus a backstop teardown if the driver
  dies between create and delete.
- **A landing page** (`site/`, deployed to GitHub Pages), a logo, and
  `docs/branding.md` recording the trademark constraints behind both.
- **`docs/tutorial.md`** — a path from an empty directory to a two-cloud
  fleet. Every snippet in it is compiled.
- **`docs/coverage.md`** — the canonical statement of what this version does
  and how far each part has been run.

### Changed

- **Deletions are now topologically sorted**, not merely reversed. Teardown
  is the reverse of a topological sort of the same graph, so it no longer
  depends on `Kind` enum order or declaration order happening to agree with
  the dependency direction. `orderActions` takes the plan to read deletion
  edges from as a third argument, because `Plan.absent` carries no specs.
- **`instanceType` is a family and a size**, not a string. The pair is checked
  at elaboration: `t3` has no `32xlarge`, and gen-7 Intel skips `32xlarge`
  entirely.
- Package metadata (`description`, `keywords`, `homepage`, `license`) is now
  declared, so Reservoir has something to show.

### Removed

- **`S3BucketSpec.region`.** It did not place the bucket — the placement did —
  so it was only ever compared, on a `forcesReplace` row, and a bucket
  declared without it filled to `eu-west-1` and proposed a replacement that
  recreated it exactly where it already was. It never converged. Placement is
  now the single mechanism and the disagreement is unrepresentable.
  `S3BucketObserved.region` survives, which is Terraform's `bucket_region`.

### Fixed

- **A nested-block scoping bug**: region blocks had a greedy item list, so
  `in oregon where` silently swallowed the `provider` group that followed it.
  Indentation is now load-bearing (`withPosition`/`colGt`).
- **`Regions.set` discarded per-resource placements** made before it.
- **A false claim in the documentation.** The README, the page and
  `coverage.md` said no AWS call had ever been made against a real account.
  That was inferred from `providers.md` listing only Scaleway as verified, and
  it was wrong — the `.infra/` cache held real S3 URLs, a real security group
  and two running EC2 instances. EC2's parameter names, described here as
  unverified guesses, in fact work.

## [0.2.0] — 2026-09-05

### Added

- **A fleet can say where it is.** `fleet myFleet in paris where …` places
  every cloud the fleet uses; `in aws "eu-west-1", scaleway "fr-par"` places
  them individually. A `Locality` is a place named before any cloud names it,
  so one word resolves per cloud.
- **Per-resource placement**, with `provider` and `in` blocks that nest and
  scope like a `with` in Python. Precedence is innermost-first, and the set of
  regions a pull must list is derived from the declaration rather than
  configured.
- Typed region codes (`Region.of`), checked against a per-cloud table, with
  `Region.raw` as the deliberately more visible escape hatch.
- `provider` blocks, so a fleet mostly in one cloud names it once.

### Changed

- `Infra.Cli.run` takes a `regions` argument; a placed cloud no longer needs a
  region in its credentials.

## [0.1.0]

The engine: `Kind`/`SpecOf`/`Plan`/`push`, the `fleet` command, portable and
provider-local kinds across AWS and Scaleway, composed secrets, the credential
chain, the account guard, and the observed-state cache.
