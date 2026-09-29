# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28), which moved
infra from linen v1.0.0 to v1.6.1. None of the linen modules infra imports
changed in that range, and `lake build` / `lake test` pass on macOS. Each item
names where it comes from; re-check before acting.

Pending moves into linen are tracked in `CHANGELOG.md` under `[Unreleased]`
(see `AGENTS.md`, "## Linen"); this file is the wider list, and items that
become moves should be recorded there too.

**Status 2026-09-29.** 0.20.0 pins linen **v1.8.0** (on the remote). 0.20.1
closes the rest that is infra's own: every listing pages, unsupported SQS
operations are values, and lossy JSON numbers are refused. What is still open
is below, unchecked — each waits on another repository or on a change to a
cloud account.

## After the bump

- [x] **Pin Linux CI runners to `ubuntu-24.04`.** This repository's workflows,
  the scaffolded ones (`Infra/Cli/New.lean`), and the "Protect main" ruleset
  (`docs/github/main-branch-ruleset.json`, applied on GitHub 2026-09-29). The
  ruleset now requires only the two checks infra's CI produces,
  `build (ubuntu-24.04)` and `build (macos-latest)`: it had been copied from
  linen's and also required five linen-only jobs (arm64, consumer, unsealable
  host) that never report here.
- [x] **Fix the stale `[Unreleased]` notes.** Six `fromUTF8!` uses, and the
  `Sqs.lean` reference now points at `credentialsFor`.

## Duplicates of linen

- [x] **`JsonRead.field`** replaced by `Data.Json.Value.lookup`.
- [x] **`JsonRead.setField`** and `stringField`/`natField`/`boolField`: gone,
  for linen's `Value.setField` and `lookupText`/`lookupNat`/`lookupBool`
  (0.20.0). `JsonRead` keeps `arrayField` and `stringArrayField`.
  - [ ] liaison's copy (`liaison/Liaison/Egress/Credential.lean:214`) —
    liaison's to delete when it pins v1.8.0.
- [x] **The `Linen.Cloud` migration** (0.20.0): `Core/Credentials.lean` is
  linen's chain (`Cloud.Credentials.Chain.loadFrom`, keychain service
  `infra`); `Core/GcpAuth.lean` is deleted; `Providers/Http.lean` sends
  through `Cloud.Transport` and describes errors with `Cloud.describeError`;
  SigV4 is `Cloud.Auth`; `readsAsAbsent`/`readsAsRefused` classify with
  `Cloud.classify`; the GCP listings page through `Cloud.paginate` and fail
  instead of truncating; no `String.fromUTF8!` is left in library code.
  - [x] **Unsupported operations as values** (0.20.1): `sqsEndpoint` and
    `credentialsFor` take an `SqsCloud` (`aws | scaleway`), so GCP cannot
    be asked; `SqsCloud.of` answers it with `Cloud.Error.unsupported`.
- [x] **Terminal colour**: `Infra/Core/Ansi.lean` deleted for linen's
  `System.Console.Ansi` (0.20.0).

## Workarounds that linen could remove

- [x] **The native link-flag block**: `lakefile.lean` and
  `Infra/Cli/New.lean` embed linen's canonical block, and
  `ci/check-lakefile-sync.sh` runs linen's `check-link-helpers.sh` on both
  (0.20.0). The Lake change (a dependency's `moreLinkArgs` reaching a
  dependent's executable) is not proposed.
- [x] **CA bundles in scaffolds**: the "point OpenSSL at the runner's CA
  bundle" steps are gone from this repository's workflows and the scaffolded
  ones, for linen's `fallbackCaBundle` (0.20.0).

## Found on the way

- [x] **Every listing reads every page** (0.20.1). All of the call sites
  listed here, and seven more the list had missed, go through `Http.listAll`
  — `Scaleway.listAll`, `Query.callAll`, or the service's own continuation,
  each checked against the generated SDK or discovery document. GKE's
  cluster listing has no pages; `missingZones` fails it. `docs/coverage.md`,
  "Known defects", records the closure.
- [x] **Kapsule's delete deleted the declared Private Network**
  (`with_additional_resources=true`); now `false`, and the Scaleway
  Kubernetes leg asserts the network survives (0.20.0).

- [x] **The 0.20.0 CI failures** (0.20.1): a scaffolded project did not
  build (its catalogue's Kapsule cluster had no `network`), and
  `live-test.yml` held a duplicate `env:` key, which made it invalid.
  `ci/check-workflows.sh` (actionlint) now runs in CI.

## Watch

- [x] **JSON number precision** (0.20.1). Worse than rounding: linen writes a
  non-integer with six digits after the point, so `1e-7` was sent as
  `0.000000`. Every request body and the Terraform export now go through
  `Infra.Core.JsonExact`, which refuses such a number and names it; a raw
  manifest holding one fails `kubernetesIsSound` at compile time.
  - [ ] **linen's renderer** should write the shortest representation that
    reads back as the same `Float` (`CHANGELOG.md`, `[Unreleased]`). Not
    changed from here: a linen session was active.

## Kubernetes

- [x] implement docs/kubernetes.md — 0.19.0, offline only.
- [x] **Run the live leg on Scaleway**: passed, all four stages
  (2026-09-29), after three fixes it found — `network` is required
  (Kapsule refuses a cluster without a Private Network), Endpoints are the
  Service's (excluded from the scan), and the delete cascade above. A current
  Kapsule kubeconfig does carry a usable token.
- [x] **Run the live leg on GCP**: passed, all four stages (2026-09-29), in
  Frankfurt — Paris's `europe-west9-a` was out of `e2-medium` for forty
  minutes, and a GKE create cannot be cancelled, only waited out. OpenSSL 3
  does verify GKE's IP endpoint.
- [ ] **Run the live leg on AWS** from the Live test workflow
  (`-f leg=kubernetes`), once the prepared grants are applied: the four
  `Kubernetes…` statements in `ci/aws-permissions-policy.json` (`put-role-policy`) and
  `aws iam update-role --role-name infra-ci --max-session-duration 7200`
  (`ci/README.md`, "The Kubernetes leg"). The IAM roles exist.
- [x] **Grant the CI identities the scan's new read access** (2026-09-29):
  `KubernetesReadOnly` on the Scaleway CI project, `ci/aws-permissions-policy.json`
  re-applied (`eks:ListClusters`/`DescribeCluster`), and on GCP the Kubernetes
  Engine API enabled with `roles/container.clusterViewer`.
- [ ] **Consumers need the same before upgrading** (`typednotes-infra`): on
  GCP its service account holds `roles/editor` in the same project, which
  already covers the cluster listing now the API is enabled; its AWS and
  Scaleway credentials need the read grants in `docs/permissions.md`.
