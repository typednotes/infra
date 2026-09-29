# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28), which moved
infra from linen v1.0.0 to v1.6.1. None of the linen modules infra imports
changed in that range, and `lake build` / `lake test` pass on macOS. Each item
names where it comes from; re-check before acting.

Pending moves into linen are tracked in `CHANGELOG.md` under `[Unreleased]`
(see `AGENTS.md`, "## Linen"); this file is the wider list, and items that
become moves should be recorded there too.

**Status 2026-09-29.** Done, in 0.20.0, which pins linen **v1.8.0** — tagged
locally in `../linen` and **not yet pushed**: the tag must reach the remote
before infra's commits do, or infra's CI cannot resolve its `require`. What is
still open is below, unchecked.

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
  - [ ] **Unsupported operations as values**: `Scaleway/Sqs.lean`'s
    `credentialsFor` still raises for GCP, and `Aws/Protocols.lean` still
    signs GCP queues against a `.invalid` host, where
    `Cloud.Error.Class.unsupported` would say so as a value. Behaviour is
    correct (both fail loudly); only the shape differs.
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

- [ ] **Most AWS and Scaleway listings read one page** (and GCP's Cloud SQL
  and GKE). Recorded in `docs/coverage.md`'s known defects and
  `docs/diff-semantics.md`'s soft spots. Each needs its provider's
  continuation, checked against the generated SDK rather than recalled:
  - AWS — S3 `ListBuckets` (`Kinds/ObjectStore.lean:49`, shared with
    Scaleway), SQS `ListQueues` (`Kinds/Queues.lean:45`, shared), Secrets
    Manager `ListSecrets` (`Kinds/Secrets.lean:188`), Lambda
    (`Kinds/Compute.lean:56`), EC2 `DescribeInstances` and
    `DescribeSecurityGroups` (`Kinds/Ec2.lean:328`, `:136`), IAM `ListUsers`,
    `ListAttachedUserPolicies`, `ListAccessKeys` (`Kinds/Iam.lean:80`, `:89`,
    `:261`), ECR (`Kinds/ImageRegistry.lean:50`), RDS
    (`Kinds/Postgres.lean:95`), EKS node groups (`Kinds/Kubernetes.lean:467`);
  - Scaleway — secrets (`Kinds/Secrets.lean:316`, `:157`;
    `Kinds/Postgres.lean:68`), containers and container namespaces
    (`Kinds/Compute.lean:185`, `:340`, `:209`, `:439`), functions and
    function namespaces (`:490`, `:498`, `:518`, `:726`), IAM applications,
    policies and rules (`Kinds/Iam.lean:322`, `:392`, `:401`), registry
    namespaces (`Kinds/ImageRegistry.lean:156`), RDB
    (`Kinds/Postgres.lean:213`), Serverless SQL (`:412`), Kapsule pools
    (`Kinds/Kubernetes.lean:233`), SQS credentials (`Scaleway/Sqs.lean:174`);
  - GCP — Cloud SQL (`Gcp/CloudSql.lean:70`), GKE
    (`Kinds/Kubernetes.lean:674`).
  All should go through `Http.listAll`, which already fails rather than
  truncates.
- [x] **Kapsule's delete deleted the declared Private Network**
  (`with_additional_resources=true`); now `false`, and the Scaleway
  Kubernetes leg asserts the network survives (0.20.0).

## Watch

- [ ] **JSON number precision.** linen's `Data.Json.Encode` writes non-integer
  numbers with 6 significant digits. The GCP IAM read-modify-write
  (`Gcp/Iam.lean:204`) re-encodes whole policies — safe only while every number
  in them is an integer. The Kubernetes client re-encodes manifests too
  (`Kube.Client.apply`): a raw manifest with a non-integer number would be
  rounded — noted in `docs/kubernetes.md`, "Apply semantics".

## Kubernetes

- [x] implement docs/kubernetes.md — 0.19.0, offline only.
- [x] **Run the live leg on Scaleway**: passed, all four stages
  (2026-09-29), after three fixes it found — `network` is required
  (Kapsule refuses a cluster without a Private Network), Endpoints are the
  Service's (excluded from the scan), and the delete cascade above. A current
  Kapsule kubeconfig does carry a usable token.
- [ ] **Run the live leg on GCP** — GCP_RESULT
- [ ] **Run the live leg on AWS** from the Live test workflow
  (`-f leg=kubernetes`), once the prepared grants are applied: the three
  statements in `ci/aws-permissions-policy.json` (`put-role-policy`) and
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
