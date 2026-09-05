# Changelog

Notable changes to `infra`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are
[semantic](https://semver.org/), with the 0.x caveat that a minor bump may
break the Lean API — and before a first tagged release, several will.

`docs/coverage.md` is the standing statement of what exists and how far it has
been exercised; this file is what changed and when.

## [0.3.4] — 2026-09-05

### Added

- **`infra gcp-check <key.json>`** — verifies a service-account key by
  actually using it: parse, sign, exchange. Prints neither the key nor the
  token. The GCP key path is now confirmed working end to end against a real
  service account, including the credential chain reading
  `GOOGLE_APPLICATION_CREDENTIALS`.
- **ASCII diagrams of both federation flows** in `docs/ci-auth.md`, because
  the difference between them is where the checks live and that does not
  survive prose: AWS puts both narrowings on the role's trust policy in one
  hop; GCP splits them across a provider condition and a service account's own
  IAM policy, in two.
- **`docs/ci-auth.md` and `ci/`** — the AWS OIDC role, its trust policy and its
  permissions policy, as runnable documents rather than prose, alongside the
  GCP commands. Both clouds now federate; neither stores a key.

- **GCP Workload Identity Federation** is set up and wired into the live
  workflow: `google-github-actions/auth@v2` exchanges GitHub's OIDC token for
  a short-lived one, so neither AWS nor GCP has a stored credential any more.

### Fixed

- **The live test read a cloud's listing once, immediately after writing.**
  Every list API here is eventually consistent — SQS's `ListQueues`
  explicitly so — so the first real AWS run reported "did not converge" for a
  queue that had almost certainly been created and was simply not visible yet.
  Worse, the teardown that followed found nothing to delete and reported
  success, so a real resource could have been left behind while the job
  claimed to be clean. Both directions now poll for up to 60 seconds.
  Confirmed after the fact: the queue was still in `eu-west-1`.
- **Documented AWS's sixty-second window.** SQS refuses to recreate a queue
  deleted less than a minute earlier, and a fleet's names are fixed at compile
  time, so the live test cannot dodge it with a unique name. Back-to-back AWS
  runs inside that window fail on create; the workflow's `concurrency` group
  prevents overlap but not proximity.

## [0.3.3] — 2026-09-05

### Added

- **GCP service-account key files.** `GOOGLE_APPLICATION_CREDENTIALS` is now
  the first GCP credential source: `Infra.Core.GcpAuth` reads the key, builds
  an RFC 7523 assertion, signs it RS256 and exchanges it for an access token,
  with no `gcloud` in the picture. **Requires linen ≥ 0.13.0**, which is where
  the RSA signing came from — this is what that addition was for.
- **AWS OIDC in CI.** The live-test workflow federates a role instead of
  storing a key, so there is no long-lived AWS secret in the repository at
  all. Needs a repository *variable* `AWS_ROLE_ARN` — not a secret.
- `docs/authentication.md` now has a table of which method belongs where, and
  says plainly why browser login is not implemented for any of the three.

## [0.3.2] — 2026-09-05

### Added

- **`infra new <dir>`** scaffolds a declaration repository: the canonical
  structure, a commented example fleet that compiles, a `.gitignore` that
  excludes the state cache, a README, and CI for **both GitHub and GitLab**
  with the plan/apply split already wired. It wraps `lake init` rather than
  reimplementing toolchain pinning, and it emits the platform link-flag block
  every consumer needs — which Lake cannot propagate from a dependency and
  which is the most annoying part of starting one of these by hand.

### Fixed

- **`certificate verify failed` on every live CI call.** Lean's toolchain
  bundles a static OpenSSL whose compile-time trust-store path does not exist
  on a runner. `SSL_CERT_FILE`/`SSL_CERT_DIR` are now set in the live-test
  workflow *and* in every workflow `infra new` generates. Found by the AWS
  live test on its first real run.

## [0.3.1] — 2026-09-05

### Fixed

- **The observed-state cache was never cleaned.** `Persistence.save` wrote
  only the `(provider, kind)` pairs that had rows and never removed the file
  of a pair that had become empty, so after a `destroy` the cache went on
  listing every resource that had just been deleted — indefinitely, since
  nothing ever wrote that path again. No plan was affected: `load` has no
  callers and the engine plans from a fresh `pull`. What it damaged was the
  cache's value as a record, and it was believed. `Main.lean` now checks that
  saving nothing loads back nothing, and the live test asserts the same after
  a real teardown.

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
