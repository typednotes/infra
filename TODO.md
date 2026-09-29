# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28), which moved
infra from linen v1.0.0 to v1.6.1. None of the linen modules infra imports
changed in that range, and `lake build` / `lake test` pass on macOS. Each item
names where it comes from; re-check before acting.

Pending moves into linen are tracked in `CHANGELOG.md` under `[Unreleased]`
(see `AGENTS.md`, "## Linen"); this file is the wider list, and items that
become moves should be recorded there too.

**Status 2026-09-29.** The infra-only items are done (0.19.0). The linen
halves are prepared as local commits in `../linen` on top of v1.7.0 —
`9dca31c`, `352ff11`, `868512f`, `9f5fc3f`, `4149d18` — **not pushed or
tagged**; each infra half below waits for a linen release that carries it.

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
- [ ] **`JsonRead.setField`** (and `stringField`/`natField`/`boolField`):
  linen side prepared (`Data.Json.Value.setField`, `lookupText`/`lookupNat`/
  `lookupBool`, commit `9dca31c`). Waits for a linen release; then delete
  infra's and liaison's copies (`liaison/Liaison/Egress/Credential.lean:214`).
- [ ] **The `Linen.Cloud` migration.** The blocker — splitting
  `Cloud.Error.Class.denied` — is prepared in linen (`352ff11`:
  `unauthenticated`, `serviceDisabled`, `isAuthFailure`, `classifyMessage`),
  and waits for a release. The migration steps themselves are unchanged:
  - `Core/Credentials.lean`, `Core/GcpAuth.lean` → `Cloud.Credentials(.Gcp)`.
    linen's is stricter: it refuses an `http://` `token_uri` (infra rewrites it
    to https, `GcpAuth.lean:167`) and one with a query string.
  - `Providers/Http.lean:110-161`, `Aws/Sign.lean` → `Cloud.Transport`/`Cloud.Auth`.
  - `Gcp/Storage.lean:56`, `Gcp/PubSub.lean:68` stop at 50 pages with a warning;
    `Cloud.Page` records whether a listing was truncated. (L overall)
- [ ] **Terminal colour.** linen side prepared (`868512f`: `style`, `dim`,
  `wanted`, `shouldColor`). Waits for a release; then delete
  `Infra/Core/Ansi.lean` (keeping its colour-per-verb constants as linen
  `Color.fgCode`s).

## Workarounds that linen could remove

- [ ] **The native link-flag block.** linen side prepared (`9f5fc3f`): a
  versioned canonical block, `ci/consumer/link-helpers.lean`, and
  `ci/consumer/check-link-helpers.sh`, which linen's own consumer CI job now
  splices in and checks. Once released, infra's block takes linen's markers
  for its helper half and `ci/check-lakefile-sync.sh` also runs linen's
  checker against the pinned tag. The Lake change (a dependency's
  `moreLinkArgs` reaching a dependent's executable) is not proposed.
- [ ] **CA bundles in scaffolds.** linen side prepared (`9f5fc3f`): a
  fallback bundle in `createClientContext`, `fallbackCaBundle`. Once
  released, the scaffolded "point OpenSSL at the runner's CA bundle" steps
  can go.

## Watch

- [ ] **JSON number precision.** linen's `Data.Json.Encode` writes non-integer
  numbers with 6 significant digits. The GCP IAM read-modify-write
  (`Gcp/Iam.lean:204`) re-encodes whole policies — safe only while every number
  in them is an integer. The Kubernetes client re-encodes manifests too
  (`Kube.Client.apply`): a raw manifest with a non-integer number would be
  rounded — noted in `docs/kubernetes.md`, "Apply semantics".

## Kubernetes

- [x] implement docs/kubernetes.md — 0.19.0, offline only.
- [ ] **Run the live leg** on each cloud, `lake test -- <cloud> kubernetes`,
  and move `docs/coverage.md`'s rows. Two facts only it can settle: OpenSSL 3
  verifying GKE's IP endpoint through `SSL_set1_host`, and a current Kapsule
  cluster's kubeconfig still carrying a usable token.
- [x] **Grant the CI identities the scan's new read access** (2026-09-29):
  `KubernetesReadOnly` on the Scaleway CI project, `ci/aws-permissions-policy.json`
  re-applied (`eks:ListClusters`/`DescribeCluster`), and on GCP the Kubernetes
  Engine API enabled with `roles/container.clusterViewer`.
- [ ] **Consumers need the same before upgrading** (`typednotes-infra`): on
  GCP its service account holds `roles/editor` in the same project, which
  already covers the cluster listing now the API is enabled; its AWS and
  Scaleway credentials need the read grants in `docs/permissions.md`.
