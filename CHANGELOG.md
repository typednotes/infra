# Changelog

Notable changes to `infra`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are
[semantic](https://semver.org/), with the 0.x caveat that a minor bump may
break the Lean API — and before a first tagged release, several will.

`docs/coverage.md` is the standing statement of what exists and how far it has
been exercised; this file is what changed and when.

## [0.4.3] — 2026-09-06

### Fixed

- **A Cloud Run service could silently run as project Editor.**
  `ComputeSpec.executionRole` was left unmapped on GCP, on the reasoning that
  it is Lambda's concept and Cloud Run's service account is a different one.
  Both name the identity the code runs as, and not sending one is *not*
  neutral: Cloud Run then uses the project's default compute service account,
  which Google grants `roles/editor`. So a declaration that said nothing about
  identity got an Editor on the whole project — the opposite of what leaving a
  field unspoken means everywhere else here, where it means "whatever the
  cloud has, stays". On a create there is no such thing; there is a default,
  and this one is enormous.

  `executionRole` now maps to the service's `serviceAccount`, `read` reports it
  so a declared identity is diffable, and omitting it warns. Found by a live
  run failing with `iam.serviceaccounts.actAs denied` — an error about
  permission that revealed a problem about which identity was being chosen.

### Documentation

- **`iam.serviceAccounts.actAs` is a grant, not a role**, and is not implied by
  `roles/run.admin`. `ci/README.md` has it, along with why the live fleet names
  a runtime identity rather than accepting the default.

## [0.4.2] — 2026-09-06

### Verified

- **AWS's full live leg passes.** Nine resources across seven kinds —
  `queues`, three `secrets`, `imageRegistry`, `objectStore`, `s3Bucket`,
  `securityGroup`, `iam` — created, converged, deleted, with the state cache
  checked empty afterwards. Two of the three dependency patterns were
  exercised for real: the chain and the fan-out.

  `docs/coverage.md`'s "never run" ledger is rewritten rather than amended.
  It listed ECR, Secrets Manager and IAM as never called; all three now create,
  read and delete on every AWS run. What remains on AWS is Lambda and RDS —
  the two kinds the live fleet cannot include.

  The significant remaining hole is now **`update`**, on all three clouds, and
  the live test cannot close it by design: it creates and deletes, so it never
  diffs a *changed* target against an existing resource. That needs a second
  apply with a modified fleet, which is a different test shape.

  Scaleway and GCP still pass for `queues` only; their legs are blocked on
  grants, not code.

## [0.4.1] — 2026-09-06

Everything the first extended live runs found after 0.4.0 was tagged. All of
it is prerequisites and diagnostics rather than the engine — which is the
useful signal: the parts that had never met a real account were the edges, not
the core.

### Fixed

- **An EC2 security group description could not contain an apostrophe**, and
  saying so was left to raw XML. EC2 allows only
  `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*`, so "created and destroyed by infra's live
  test" was refused. A fleet's descriptions are compile-time constants, so this
  would have failed every apply rather than intermittently. The client
  validates the set and names the offending characters, and the live fleet's
  descriptions are pinned by a guard.

- **The live workflow's backstop re-created what it was meant to remove.**
  `lake test -- <provider>` is a create *and* a destroy, and the comment
  justifying the backstop said "destroy against the same fleet is idempotent"
  — true of destroy, and this was not destroy. A failed leg was followed by a
  second create that failed identically, so the cleanup could leave more behind
  than it removed. The driver takes a `destroy` argument now, sharing one code
  path with the round trip's own teardown rather than being a second
  implementation of the operation where being wrong costs money.

### Documentation

- **Google Cloud needs its APIs enabled**, which is a separate act from
  granting a role to call them — the permission list was complete and the
  calls still failed with `Secret Manager API has not been used in project …
  before or it is disabled`. `ci/README.md` now has the
  `gcloud services enable` line for the seven APIs the live fleet touches, and
  says why `sqladmin` is deliberately absent.

## [0.4.0] — 2026-09-06

A minor bump rather than a patch: GCP stopped being a type-level cloud, and
the way a project is started changed shape.

### Added

- **All seven portable kinds now work on all three clouds.** GCP gained
  `objectStore` (Cloud Storage), `secrets` (Secret Manager), `queues`
  (Pub/Sub topics), `imageRegistry` (Artifact Registry), `compute` (Cloud
  Run), `iam` (service accounts) and `postgres` (Cloud SQL). `grep noGcp` was
  the to-do list; it is empty and the helper is deleted.

  Three of those APIs do not finish the work in the call that starts it, which
  is new here, so `Gcp.Rest` gained two operation pollers — Google has two
  shapes, `longrunning.Operation` with a `done` boolean and Cloud SQL's own
  with a `status` string. Both bounded by fuel rather than `partial`.

  Two limits stated rather than hidden. A serverless `postgres` declaration
  **raises** on GCP: Cloud SQL has no capacity range that scales to a floor,
  and choosing a tier from `minCapacity` would invent a bill nobody wrote
  down. And `iam` **reads** the roles bound to a service account but refuses
  to write them, because granting a role on GCP is a read-modify-write of the
  whole project's IAM policy and getting it wrong removes other identities'
  access — so a declared policy shows in `plan` and is refused at apply with
  the `gcloud` command that would bind it, rather than being silently dropped.

- **`infra init`** turns the directory you are already in into a declaration
  project, so the ordinary flow works: `lake init`, add the dependency,
  `lake exe infra init`. It **converts `lakefile.toml` to `lakefile.lean`**,
  preserving the package name, version, libraries, executables and requires,
  and keeping the original as `lakefile.toml.replaced-by-infra` — the
  conversion is not cosmetic, because the native link flags are computed by
  running `pkg-config` on the build machine and TOML cannot express that.
  A TOML file it does not fully recognise is refused rather than rewritten on
  a guess. `infra new` remains the shortcut that does the `lake init` too.

- **`Catalogue.lean`** in every scaffolded project: all fourteen kinds across
  all three clouds, **compiled and never applied**. Commented-out examples
  rot; these are type-checked by the user's own build against the version of
  `infra` they depend on.

- **CI for five systems** in a scaffolded project — GitHub Actions, GitLab CI,
  CircleCI, Azure Pipelines and Jenkins — each using the approval mechanism
  its host actually gates on, because an approval that does not gate is
  decorative.

- **The live round trip now declares eleven of the fourteen kinds** — 22
  (cloud, kind) pairs, eight to ten resources per leg — each created from
  nothing, checked, and deleted.

  It also has **shape**, not just size: a chain (a secret composed from
  another's value), a fan-out (two secrets from one base), and a fan-in
  (Scaleway's container depending on its namespace by key reference *and* on a
  secret through `secretEnv`). Ordering is the part of the engine most likely
  to be wrong in a way only a real cloud reveals, and each pattern fails
  differently when the schedule is wrong. All three are pinned offline by
  guards on the create order, negative ones included.

  What has actually *run* is still `queues` on all three clouds. The
  seven-kind legs are blocked on permissions neither CI identity holds, and
  `docs/coverage.md` keeps those two facts apart rather than counting code
  that has not executed.

  Three kinds remain excluded, listed in `docs/coverage.md`:
  `scalewayFunction` needs deployable code rather than an image;
  `awsInstance` needs a stale-prone AMI id and bills by the second;
  `postgres` takes longer to create than the workflow's step timeout.
  `compute` and `scalewayContainer` came *in* once a public image was allowed
  — Cloud Run and Serverless Containers both pull one, so nothing has to be
  built first. Lambda still cannot, needing an ECR image in-account.

  Buckets are included for the first time. Their names are unique across a
  whole cloud and a fleet's names are compile-time constants, which is why they
  were excluded before; a fixed random suffix resolves it, at the stated cost
  that a fork must change it to avoid colliding.

  This needs permissions neither CI identity had — AWS's role was scoped to
  SQS alone, GCP's service account holds only `roles/pubsub.editor`.
  `ci/README.md` now gives the CLI commands per cloud, and
  `ci/aws-permissions-policy.json` is the extended policy.

- **Scaleway Serverless SQL Database** is implemented, where it used to be a
  stub that raised. `postgres` with capacity bounds and no instance class now
  works on Scaleway — endpoint family confirmed against the live API, field
  names from Scaleway's own CLI reference. A Serverless SQL Database has no
  root user, so `masterUsername` and `masterPasswordSecret` have no
  counterpart and are ignored rather than sent.

- **Discovery metadata**: repository topics, canonical URL, Open Graph, a
  Twitter card, JSON-LD, and a real 1200x630 social card rendered from the
  project's own mark.

- **The vendors' real AWS, Google Cloud and Scaleway marks** on the page,
  installed unmodified, with provenance and trademark status recorded in
  `assets/providers/SOURCES.md`.

### Fixed

- **AWS Secrets Manager rejected every `create`.** `CreateSecret` and
  `PutSecretValue` require a `ClientRequestToken`; the API reference calls it
  optional, which it is through an SDK, because every SDK generates one when
  the caller omits it. This library does not use an SDK. Found by the first
  live AWS secret — nothing offline distinguishes a field an SDK supplies from
  one the service defaults — and now covered by an offline check on the
  token's shape and freshness.

- **Scaleway failures did not say which call failed.** Its error bodies are
  the terse ones of the three clouds: a refused request reports
  `403 permissions_denied: insufficient permissions` and nothing else, no
  product, operation or resource, which across a ten-resource fleet is a
  needle in a haystack. Its calls now name the method and path.

- **A scaffolded project could not link on Linux.** `Infra/Cli/New.lean`
  embeds a copy of this repo's native link-flag block, and it had drifted: it
  had lost `pkgAbsoluteLibs` and gained OpenSSL flags, which are the two
  things the canonical block's comments exist to prevent. Every project the
  scaffolder ever produced failed to link on the platform its own generated CI
  runs on. Now a verbatim copy between markers, with
  `ci/check-lakefile-sync.sh` failing the build on any divergence and a CI step
  that scaffolds a project and builds it.

- **`objectStore` on GCP was signed with SigV4** and sent to
  `storage.googleapis.com`. It had no GCP branch at all and borrowed the S3
  client; GCS's S3-compatible API needs HMAC keys, which this library never
  holds, so it could only ever have returned 403. The same defect `queues` had.

- **Google's errors rendered with an empty message.** Its error body nests one
  level deeper than either other cloud (`{"error":{"message":…}}`), so every
  GCP failure read as `HTTP 404 :` with the only useful part dropped.

- **A federated credentials file was read as a service-account key.**
  `google-github-actions/auth` points `GOOGLE_APPLICATION_CREDENTIALS` at the
  `external_account` file that Workload Identity Federation writes, so the key
  path fired, threw on the type, and never reached the access token sitting in
  the environment. Such a file now declines rather than failing.

- **Scaleway queues could deadlock permanently.** The SQS credential's secret
  is shown once and the mint call rejects a duplicate name, so one uncaptured
  mint took the name and every later attempt failed with `409` forever. The
  name is now reclaimed. Also: caching that credential no longer fails the
  operation it optimises, and an already-activated project answers activation
  with `409`, not `200`.

- **Page legibility.** A contrast audit in both colour schemes reported 20
  failures in light and 27 in dark; all are fixed. Blue-as-text and
  blue-as-fill were one token doing two jobs and are now two.

- **The published site's assets could drift from their source**, and did — a
  `<picture>` source pointed at a file present only on the source side, and a
  matching `<source>` that 404s does not fall back to its `<img>`, so dark mode
  would have shown broken images with every local check passing.
  `ci/check-site-assets-sync.sh` now resolves every reference against the
  published tree.

- **The scaffold CI step was macOS-broken**, using GNU `sed -i`, and rebuilt
  the whole of `linen` a second time — killed by the OOM killer locally.

### Changed

- **The cloud strip shows supported clouds only.** Planned ones were listed
  greyed, which made a landing page carry a roadmap, and a roadmap reads as a
  promise.
- **Provider marks are no longer boxed.** Dark mode sets the row on one light
  band rather than recolouring artwork, which their guidelines forbid.

## [0.3.5] — 2026-09-06

### Fixed

- **A pull aborted if a resource vanished between `list` and `read`.** Every
  cloud's list API is eventually consistent, so a refresh moments after a
  delete sees the deleted resource listed and then fails to read it — which
  took down the whole pull rather than reporting the resource as gone. The
  same happens when anything is deleted out of band mid-refresh. A read that
  fails with a recognised not-found code is now treated as absence; anything
  else, notably a permission error, still fails, because mistaking *denied*
  for *absent* would have the next apply create a duplicate. Found by the
  first live AWS run that got far enough to try.

### Added

- **`AWS_ROLE_ARN` is trimmed** and read from either a variable or a secret;
  a missing one now fails with a message naming the setting.
- **The workflow prints its own OIDC claims** before assuming a role, since
  `Not authorized to perform sts:AssumeRoleWithWebIdentity` names neither the
  claim nor the condition that rejected it.
- Trust policies use **immutable subject claims** (`owner@id/repo@id`), which
  is what GitHub issues for repositories created after 15 July 2026.

## [0.3.4] — 2026-09-05

### Added

- **`infra gcp-check <key.json>`** — verifies a service-account key by
  actually using it: parse, sign, exchange. Prints neither the key nor the
  token. The GCP key path is now confirmed working end to end against a real
  service account, including the credential chain reading
  `GOOGLE_APPLICATION_CREDENTIALS`.
- **The live workflow declares `environment: production`**, which is what
  makes the AWS role's environment-pinned trust policy usable — and where
  required reviewers go, so assuming a `PowerUserAccess` role needs a human.
  Adding the reviewers is a repository setting and the one part neither the
  workflow nor the policy can do for itself.
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
