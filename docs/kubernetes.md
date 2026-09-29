# Managed Kubernetes, and workloads as declared resources

**Status: proposed, not implemented.** This page begins as the proposal the
implementation will be judged against — doc first, code after, in the spirit
of `AGENTS.md`. Provider facts below that name a date were checked against
that source on that date; facts in the "to verify" list are *not* facts yet.

## Problem

The fleet today stops at the cloud's edge. `compute` deploys single
containers, `postgres` a database, and everything that runs *on a cluster* —
Deployments, Services, StatefulSets — has no declaration: it is a runbook
step (`kubectl apply`, a Helm install in CI) that the plan does not name,
the review surface does not include, and the ordering of which no
declaration states.

The proposal: managed Kubernetes clusters become a portable kind
(`kubernetesCluster`, on all three clouds), and the in-cluster objects
become declared resources in the same fleet syntax. What Helm bundles into
a chart, a fleet already bundles: **the fleet is the chart.** The
declaration is the review surface, `plan` the diff, `apply` the install,
and the same marker, scheduler and orphan machinery that governs every other
resource governs a StatefulSet.

## The two kinds

### `kubernetesCluster`

Portable, the `postgres` recipe: nothing in "a managed Kubernetes control
plane with a node pool" names a cloud. Per cloud: EKS, GKE, Kapsule.

```lean
resource scaleway kubernetesCluster "main" as k8s
  { version := "1.31"
  , nodeType := "gp1s"
  , nodeCount := 3
  , autoscale := (2, 6)        -- (min, max); present ⇒ the pool autoscales
  , network := "pn-typednotes" }
```

- `version` is a plain `String`, checked by the cloud at create. No table of
  known versions in this repo: Kubernetes minor versions arrive on every
  cloud's own schedule, a table would go stale, and the `Region.raw`
  precedent says a stale table must never hard-block — so here there is no
  table at all, just as `PostgresSpec.engineVersion` has none.
- `nodeType` likewise a `String` (`t3.large`, `e2-standard-2`, `gp1s`): the
  typed EC2 table is EC2's, not every cloud's node catalogue.
- `network` is the prerequisite reference — EKS subnets, GKE subnetwork,
  Kapsule private network — **by name, never managed**: the
  `masterPasswordSecret` pattern. Infra does not create, claim, or delete
  network resources; a cluster declaration that needs one points at one
  that already exists. What each cloud actually requires of the field
  (required subnets on EKS, optional-with-defaults on GKE, private network
  on Kapsule) is in the verify list below.
- `holdsData := true`: deleting a cluster deletes everything in it —
  namespaces, PVCs, every workload. `destroy --keep-data` keeps clusters
  standing for the same reason it keeps databases.

### `kubernetesObject`

Portable, one kind with typed shapes — the `PostgresSpec.classic` /
`.serverless` two-shape precedent, generalised. A resource is one in-cluster
object; the shape names which.

```lean
resource scaleway kubernetesObject "postgres" as pg
  { cluster := k8s
  , shape := .statefulSet
      (image := "postgres:17")
      (replicas := 1)
      (ports := [5432])
      (env := [.lit "POSTGRES_USER" "dbadmin", .secret "POSTGRES_PASSWORD" "db-password"])
      (storage := some { sizeGb := 20, storageClass := "scw-bssd" }) }

resource scaleway kubernetesObject "postgres"
  { cluster := k8s
  , shape := .service 5432 }
```

- `cluster` is a **typed reference** (`K p .kubernetesCluster`), so a
  workload cannot point at a cluster on another cloud — the type says so —
  and the scheduler gets its edge the ordinary way. (The portable kind
  still names its cloud on the resource line; the reference and the line
  must agree, which the macro can check while it has both.)
- The first four shapes: `.deployment`, `.statefulSet`, `.service`, `.raw`.
  A new shape (ConfigMap, Ingress, Job, HPA) is an additive change to one
  inductive, not a new `Kind` constructor and its twelve-file checklist;
  the `.raw` shape — `(apiVersion, kind, manifest)` carried verbatim — is
  the `Region.raw` escape hatch for objects without a typed shape yet.
- A `.service` with no explicit `selector` selects pods labelled
  `app = <the service's own resource name>`, the convention infra itself
  writes on every workload it creates. So `service 5432` named `postgres`
  fronts the stateful set named `postgres` without either one naming the
  other a second time — and the scheduler draws the same name-borne edge
  (`Engine.impliedByName`) that orders a migration set after its database.
- `.statefulSet`'s `storage` is the volumeClaimTemplate: size and storage
  class, the storage class itself referenced by name (it is the cluster's,
  not infra's). The claim template carries the marker label, so its PVCs
  do too.
- `env` values are literals or the fleet name of a `secrets` resource
  (hard edge 3 below). Workload **names** must be DNS-1123 (lowercase
  alphanumerics, `-`, `.`) — a plan-time check with the reason, the
  `validFleetName` shape.
- Objects live in a `namespace` field, default `"default"`. **Namespaces
  themselves are not a managed object** in this proposal: infra never
  creates or deletes one, says so in `docs/coverage.md`, and a namespace
  that is not the default is referenced by name like the network above.
- A workload's region is its cluster's. The key family still carries one
  (the engine's routing needs a region per cloud), but the object's backend
  reaches the kube-apiserver through the cluster endpoint whatever the
  row says, so a workload line is placed *with* its cluster and a
  disagreeing placement is refused at plan time rather than silently
  ignored.

## Ownership

The ladder, applied honestly, and for once with no climbing:

- **Cluster: rung 1 on all three clouds** — EKS tags, GKE
  `resourceLabels`, Kapsule tags (each in the verify list). The first kind
  whose rung table row reads `tags | tags | labels` with no exception.
- **Object: rung 1 everywhere, by construction.** Kubernetes objects carry
  labels natively; infra writes `managed-by-infra=<fleet>` in
  `metadata.labels` at create, reads it back in `ownershipInfo`, and
  `release` strips it — the `Marker.releaseTags` operation, applied to a
  label set.

Inheritance from the cluster was considered and rejected as the primary
mechanism: an object inside this fleet's cluster that carries no marker of
its own would be managed on the parent's say-so, which is exactly the
"declared name is not evidence" trap in reverse — someone else's Deployment
in a namespace infra uses, deleted because its *cluster* is ours. Only
objects carrying the marker are touched; the label is the whole of it, same
as a tag on a bucket.

## The hard edges

### 1. A cluster's deletion deletes everything in it

`holdsData := true` keeps a cluster out of a bare `destroy`. The rest is
ordering: the typed `cluster` reference gives `HasDeps` its edge, the
scheduler orders a workload's delete before its cluster's, and an apply
that removes both a cluster and its objects destroys the objects first,
then the cluster — no special case, just the DAG. When the cluster line
alone is removed, the cluster is an orphan whose cloud-side deletion
cascades the namespace; the workload lines that go with it (they must, or
the next plan fails on a dead reference) die in the same wave, ordered
first.

The subtle case is the *scan*: an orphaned workload is found by listing
marked objects inside the clusters the declaration names — including ones
it names only in `forget`s — so a workload whose line was removed is
found and deleted from a cluster that stays. A cluster the declaration no
longer names at all cannot be reached for an in-cluster scan, and does not
need to be: the cluster's own orphan deletion destroys everything in it.
`scannableUndeclared` is `true` for `.kubernetesObject` — the scan runs,
over declared clusters only — and that boundary is written down here and in
`docs/coverage.md`, not left to a catch-all.

### 2. Unreachable is split by asking the cloud, not the connection

A workload's `read`/`list` reaches through the cluster's endpoint, which
can be down three ways, and they must not blur:

- the cloud's control plane still lists the cluster, the API server is
  unreachable → **error**. The object's state is unknown and the run must
  not guess; a transient API-server outage read as "absent" would plan a
  re-create of a StatefulSet that is running.
- the cloud says the cluster is gone (deleted by hand, or as an orphan in
  this very apply) → the objects are gone with it: **absent**.
- connection refused with no cluster check to break the tie is the first
  case, not the second. "Unreachable" never means "does not exist" without
  the cloud's own word for it.

### 3. Secrets into the cluster: one read, at apply

A Postgres container needs its password as an env value, and the kube API
has no secret-by-reference the way Scaleway's container platform does —
the manifest carries the value, or a Kubernetes Secret object does, and
this proposal does not manage those (below). So the value crosses, and the
crossing is the `fetchMasterPassword` discipline exactly: the apply path
reads the `secrets` value through one confined function, hands it straight
to the create/patch call, never stores, never prints, and the planning
path cannot reach it — a dry run never has the value and prints the env
*name* only. The widening — a second confined read on the apply path —
goes into `docs/diff-semantics.md`'s ledger, the way the migrations
observer secret did.

What it costs, said out loud: the value lands in the cluster's etcd, and
Kubernetes Secrets are only as protected as the cluster's encryption-at-
rest configuration. Whether all three clouds encrypt etcd by default is in
the verify list; if one does not, its `docs/providers.md` section says so,
loudly. The alternative — a managed `.secret` shape, an object synced
*from* an infra `secrets` resource so the value never crosses through infra
at all — is deferred, not rejected: it composes with this design (a later
shape reading from the `secrets` kind by name), and a fleet that wants it
sooner can declare the Secret through `.raw` today.

### 4. Three authentications, one API

The kube API is the same REST+JSON on every cloud — read/list/create/patch/
delete on `/apis/apps/v1/...`, no watch needed — so **one client module**
serves all three, and only the bearer credential differs:

- **EKS**: the token is a SigV4-presigned STS `GetCallerIdentity` URL,
  base64 of the request with the right headers — `infra` already signs
  SigV4 (`Aws.Sign`), so this is a presign, not a new dependency.
- **GKE**: the OAuth bearer the other GCP clients already hold
  (`Gcp.Auth`), with the cloud-platform scope.
- **Kapsule**: the kubeconfig's admin user is a client certificate — and
  `linen`'s TLS client cannot present one ("mutual TLS not supported yet",
  `ffi/tls.c`, checked 2026-09-29). This is a **linen addition** —
  first-party sibling, proposed there per its own contribution rules, and
  listed under `[Unreleased]` in `CHANGELOG.md` as pending. Whether
  Kapsule also offers a token-shaped kubeconfig user (which would make
  the addition unnecessary) is in the verify list; the generated SDK
  decides, not the prose docs.

Tokens are minted per run, never stored; a 15-minute EKS token's expiry
(verify) is inside any single action's lifetime.

### 5. PVCs outlive their workloads

Deleting a StatefulSet does not delete its PVCs — Kubernetes semantics,
not infra's, and not something a wrapper should paper over. The claim
template carries the marker label so a PVC says whose it is, but infra
**does not list or delete PVCs**: no shape, no scan, and their data
outliving the workload is what `--keep-data` wants anyway. A fleet that
wants a PVC gone deletes it by hand, or deletes the cluster (hard edge 1).
Enumerated in `docs/coverage.md`'s limits, not left silent — an unmanaged
marked thing is a warning at `dump` time, never a surprise delete.

## Provider facts to verify before implementation

Checked against generated SDKs and discovery documents — not prose docs,
the 2026-09-19 rule — with the date and source recorded in the code, the
way `Region.lean`'s tables carry theirs:

- **EKS**: `CreateCluster` required fields (role ARN, `vpcConfig.subnetIds`
  — required, so `network` is required on AWS in practice); tags on create;
  the token format and its expiry; that `eks` is on the region endpoints
  list for every region `Region.lean` carries.
- **GKE**: the `container.googleapis.com` cluster create shape; whether
  `subnetwork` is optional-with-defaults (the default network's, or the
  project's); `resourceLabels` as the label address; the scopes the
  existing OAuth flow grants.
- **Kapsule**: the k8s API create shape (pool `node_type`, `size`,
  `autoscaler`; whether `private_network_id` is required); tags on create;
  whether the kubeconfig offers a token user or only the client
  certificate (decides hard edge 4's linen addition).
- **etcd encryption at rest by default**, per cloud, for hard edge 3's
  honesty.
- **DNS-1123** as the object-name rule the plan-time check enforces.

## What it costs

- The **linen addition** (hard edge 4), if Kapsule offers no token user.
- Two `Kind` constructors — `#guard card Kind` goes to 17 — and with them
  every total match the design guarantees: `Kind.lean` itself, `Specs/`,
  `Settle`, `Action`, `Diverge` (per-shape field tables; which fields are
  immutable and force a replace — storage class and claim size on a
  StatefulSet are, image and replicas are not), `Engine` (`physicalClass`,
  `scannableUndeclared`, `holdsData`, `impliedByName` for the service
  edge), `Placeholder`, `Live.lean` per cloud, `Terraform.lean`.
- The **route derivation** in `Infra/Cli.lean` (`migrationRoutesOf`
  precedent): the object backend learns its endpoint and credential from
  the declaration's cluster resource, because a bare object name does not
  say which cluster it lives in — the migrations route table's reason
  exactly.
- The `Diverge` immutability decisions above, recorded in
  `docs/diff-semantics.md`.
- **Terraform interop** rows: `aws_eks_cluster`, `google_container_cluster`,
  `scaleway_k8s_cluster`; objects export as the `kubernetes` provider's
  resources, or are refused with a reason if their attributes do not fit
  `toHcl`'s shape — decided at implementation, not defaulted silently.
- Tests, offline first per the house rules: a `Main.lean` check replaying a
  `Snapshot` with a cluster, a marked in-cluster orphan, and an
  unmarked-but-declared-name object (the `checkMarkerDecides` shape,
  in-cluster); the unreachable split of hard edge 2 (both branches); the
  service-after-workload edge (`example/PostgresMigrations.lean`'s
  declared-first guard trick); `--keep-data` keeping a cluster;
  `checkDumpReplays` extended. A new `example/KubernetesPostgres.lean`
  whose header documents what it proves — the fleet above, offline under
  placeholder backends. Live-test stages for all three clouds.
- The four surfaces of `AGENTS.md` moved together, `docs/coverage.md`
  first: two portable-kind rows, two rung-table rows, the scan boundary,
  the PVC limit, and the removal of "Kubernetes" from "Not in this
  version". A release — the version is written in nine places
  (`ci/check-release-version.sh` is the list), not a patch.

## Alternatives considered

- **Helm itself.** A package manager with a template language, rendering
  to the same objects. The plan would show an opaque `helm upgrade` step;
  the review surface is a values file, not the objects; and the ordering,
  marker and orphan machinery this repo already is would be bypassed for
  the one resource type that most needs it. `helm install` remains usable
  *alongside* (a consumer can point `.raw` at rendered output), but this
  proposal replaces it as the deploy path, and says so — the two-step
  skew of a CI step outside the declaration is what the migrations kind
  already abolished once.
- **One `Kind` per object type.** Per-object `Diverge` tables for free, at
  the price of an enum that grows with every object type ("etc." is
  open-ended) and a twelve-file checklist per addition. The shape sum
  keeps the totality guarantee — one constructor, one checklist — and
  `#guard`s pin per-shape facts just as tightly.
- **A chart-bundle kind.** One resource holding a list of objects:
  closest to Helm, and it makes per-object drift invisible — the engine
  would diff a set, and the set-compare machinery (`lists compare as
  sets`) would paper over a changed image inside an unchanged list
  length. Rejected: the fleet is the bundle.
- **CI steps running `kubectl`.** The status quo; what this replaces.

## What this buys

One `apply` still deploys the whole fleet — now including the cluster and
what runs on it. The Postgres StatefulSet behind its Service, declared in
the same syntax as the database it may replace, its drift diffed per
field, its rollout ordered, its orphans found by label, its deletion
gated by `--keep-data` like every other thing that holds data. The plan
names what a `helm install` would have hidden, and nothing in the cluster
is touched that does not carry the fleet's name.
