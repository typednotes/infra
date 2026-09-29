# Managed Kubernetes, and workloads as declared resources

**Status: implemented in 0.19.0; run live in 0.20.0 on Scaleway and GCP
(2026-09-29), all four stages each; AWS's workflow runs created and deleted the
control plane but failed node-group IAM validation, with those grants now
fixed; the complete round trip has not passed yet.** The first runs found four
things, fixed in 0.20.0:
Kapsule requires a Private Network; its delete cascade deleted that network;
Endpoints carry a Service's marker without an owner; the metrics groups answer
503 until metrics-server is ready. This page began as the proposal the implementation was judged
against — doc first, code after, in the spirit of `AGENTS.md` — and it
remains the design doc. The body describes what now *is*; where the
implementation deviated from the proposal, "Where the implementation
differs" at the end records what changed and why. Provider facts below that
name a date were checked against that source on that date. `docs/coverage.md`
carries the kinds' rows and their exercise level.

## Problem

The fleet used to stop at the cloud's edge. `compute` deploys single
containers, `postgres` a database, and everything that runs *on a cluster* —
Deployments, Services, StatefulSets — had no declaration: it was a runbook
step (`kubectl apply`, a Helm install in CI) that the plan did not name, the
review surface did not include, and the ordering of which no declaration
stated.

Managed Kubernetes clusters are now a portable kind (`kubernetesCluster`, on
all three clouds), and the in-cluster objects are declared resources in the
same fleet syntax (`kubernetesObject`). What Helm bundles into a chart, a
fleet already bundles: **the fleet is the chart.** The declaration is the
review surface, `plan` the diff, `apply` the install, and the same marker,
scheduler and orphan machinery that governs every other resource governs a
StatefulSet.

## The two kinds

### `kubernetesCluster`

Portable, the `postgres` recipe: nothing in "a managed Kubernetes control
plane with a node pool" names a cloud. Per cloud: EKS, GKE, Kapsule.

```lean
resource scaleway kubernetesCluster "main"
  { version := "1.31",
    nodeType := "GP1-S",
    nodeCount := 3,
    autoscale := ((2, 6) : Nat × Nat),  -- (min, max); (0, 0), the default, is a fixed pool
    network := "pn-typednotes" }
```

- `version` is a plain `String`, checked by the cloud at create; unset means
  the cloud's default. No table of known versions in this repo: Kubernetes
  minor versions arrive on every cloud's own schedule, a table would go
  stale, and the `Region.raw` precedent says a stale table must never
  hard-block — so there is no table at all, just as `PostgresSpec.version`
  has none. A declared `1.31` is realised by a reported `1.31.4-eks-…`
  (`k8sVersionMatches`); a change is an in-place upgrade.
- `nodeType` likewise a `String` (`t3.large`, `e2-standard-2`, `GP1-S`): the
  typed EC2 table is EC2's, not every cloud's node catalogue. Compared
  case-insensitively with `-` and `_` the same (Kapsule spells one type both
  ways). A change **replaces the node pool** — the new pool is created and
  ready before the old one is deleted — never the cluster.
- `autoscale` needs its type written out: a pair of numerals is the shape
  `Infra.Core.Coe` documents as not coercing (`((2, 6) : Nat × Nat)`). `(n, n)`
  is refused (`Plan.kubernetesProblem`): a cloud reports a pool with equal
  bounds as fixed, so it would read back as `(0, 0)` and never converge —
  write `nodeCount := n`. While a pool autoscales, `nodeCount` is its initial
  size and is not compared.
- `network` is the prerequisite reference — **by name, never managed**: the
  `masterPasswordSecret` pattern. Infra does not create, claim, or delete
  network resources. What it names is the cloud's own unit: on AWS a VPC (its
  `Name` tag, a `vpc-…` id, or `default` for the region's default VPC), whose
  subnets the cluster uses — EKS requires them in at least two availability
  zones, so `network` is required there; on GCP a VPC network (the project's
  `default` when unset); on Scaleway a Private Network by name, which
  Kapsule requires ("a Private Network is mandatory for this cluster type",
  the API's answer to the first live create, 2026-09-29) — so `network` is
  required there too, and `infra check` says so before any call. No cloud can move a live cluster to
  another network, so a change is a `REPLACE`.
- `clusterRole` and `nodeRole` are AWS's: EKS requires an IAM role for the
  control plane and one for the nodes, as an ARN or a role name in the
  fleet's own account and partition. GCP and Scaleway have no counterpart and
  ignore both; the AWS backend refuses a create without them, naming the field
  (the `ComputeSpec.executionRole` convention). A new `nodeRole` replaces the
  pool; a new `clusterRole` is a `REPLACE` (EKS cannot change it).
- `holdsData`: deleting a cluster deletes everything in it — namespaces,
  volumes, every workload. `destroy --keep-data` keeps clusters standing for
  the same reason it keeps databases.

### Provisioning waits and CI budgets

A cluster create waits for its control plane and node pool before returning;
the objects scheduled after it need that API server. On AWS those are two
serial operations: EKS must be `ACTIVE` before a managed node group can be
created. Teardown reverses them: delete the node group, wait for not-found,
then delete the control plane and wait again. The live test's four stages
reuse one cluster; they do not provision four clusters.

The shared `awaitStatus` loop (0.21.1) reports its operation immediately,
then elapsed seconds and the provider's status on the first poll, on a status
change, and roughly every fifteen seconds, with a completion line. It writes
flushed stderr so progress remains visible during a create without becoming
part of a CLI's JSON/YAML output. The default thirty-minute budget includes
HTTP time, measured with a monotonic clock; an already-running HTTP call is
bounded by the transport, not interrupted by the waiter.

EKS's four wait targets follow botocore's
`eks/2017-11-01/waiters-2.json` (checked 2026-09-29): cluster activation fails
on `FAILED` or `DELETING`, node-group activation on `CREATE_FAILED`, node-group
deletion on `DELETE_FAILED`, and cluster deletion on `ACTIVE`, `CREATING` or
`PENDING`. Errors include `health.issues` codes, messages and resource IDs.
A failed-create node group can still be deleted; `CREATE_FAILED` is not a
deletion failure. Only not-found completes deletion, and missing status in
a successful response is an error. GKE keeps reporting operation errors
immediately; Kapsule reports its cluster/pool status through the same loop.

The Live test workflow gives its Kubernetes job **100 minutes**: a sixty-minute
live step, a thirty-minute backstop, and ten minutes for setup/build. The
ordinary fleet gets thirty minutes: sixteen for the live step, six for the
backstop, and eight for setup/build. Both jobs must outlast their live step
**and** cleanup; the previous twenty-minute job cap overrode Kubernetes's
sixty-minute step allowance. AWS's two-hour credentials cover the larger job.
Changing the workflow affects subsequent runs, not a job already running.

Verification: `checkKubernetesWaiters` replays a stable status, a changing one,
slow HTTP calls, all four EKS targets, failed-create cleanup and a failure with
health issues, without sleeping or touching a cloud. `ci/check-workflows.sh`
validates the workflow with actionlint.

### `kubernetesObject`

Portable, one kind with typed shapes — the `PostgresSpec.classic` /
`.serverless` two-shape precedent, generalised. A resource is one in-cluster
object; its **fleet name is its address**, and its shape says what it is.

```lean
resource scaleway kubernetesObject "main/default/statefulset.apps/postgres"
  { shape := statefulSet (image := "postgres:17") (replicas := 1) (ports := [5432])
      (env := [.lit "POSTGRES_USER" "dbadmin", .secret "POSTGRES_PASSWORD" "db-password"])
      (storage := some { sizeGb := 20, storageClass := "scw-bssd",
                         mountPath := "/var/lib/postgresql/data" }) }

resource scaleway kubernetesObject "main/default/service/postgres"
  { shape := service 5432 }
```

- **The address**, `<cluster>/<namespace>/<kind>[.<group>]/<name>`
  (`Infra.Specs.ObjectName`), is the fleet name because a fleet name must be
  the cloud-side identifier (`Keys.name`), and an object is identified by all
  four together. `<cluster>` is the fleet name of a `kubernetesCluster` **on
  the object's own cloud** — the name has no cloud in it, so a workload
  cannot point at another cloud's cluster at all, and the scheduler's edge to
  the cluster comes from the name (`Engine.impliedByName`), the way a
  migration history's edge to its database does. `<namespace>` is a DNS-1123
  label, or `_` for a cluster-scoped object (only a `raw` shape can be one).
  `<kind>` is the lowercased Kubernetes kind with its API group, the way
  `kubectl` spells a resource type (`deployment.apps`; the core group has
  none, `service`). Two objects of different kinds can share a name, which is
  exactly the StatefulSet and the Service above.
- The four shapes, built with helpers (`deployment`, `statefulSet`,
  `service`, `rawObject`), since dot-notation does not see through the `Expr`
  wrapper. A new shape (ConfigMap, Ingress, Job, HPA) is an additive change to
  one inductive, not a new `Kind` constructor and its checklist; the `raw`
  shape — `(apiVersion, kind, manifest)`, the body as a JSON object carried
  verbatim — is the `Region.raw` escape hatch for objects without a typed
  shape yet.
- A `service` with no explicit `selector` selects pods labelled
  `app = <the service's own name>`, the label infra itself writes on every
  workload's pods. So `service 5432` at `…/service/postgres` fronts the
  StatefulSet at `…/statefulset.apps/postgres` without either naming the
  other a second time, and the scheduler draws the name-borne edge from the
  service to the workloads of that name.
- `statefulSet`'s `storage` is the volume claim template: size, storage
  class (referenced by name — it is the cluster's, not infra's) and mount
  path. The claim template carries the marker label, so its PVCs say whose
  they are (hard edge 5 says what infra does with that — nothing).
- `env` values are literals or the fleet name of a `secrets` resource (hard
  edge 3).
- `Plan.kubernetesProblem` refuses, before any action and at compile time for
  a `#guard`: an address that does not parse, whose kind disagrees with its
  shape, whose names are not valid (DNS-1123; a Service's must start with a
  letter; a StatefulSet's must be a label, since its pods' hostnames are); a
  cluster the fleet does not declare on the same cloud; a shape that is
  unsound (a port outside 1-65535, a raw manifest that is not a JSON object).
- **Namespaces are not a managed object**: infra never creates or deletes
  one, and a namespace other than `default` must exist already —
  `docs/coverage.md` says so. Declare one through `rawObject "v1" "Namespace"`
  at `<cluster>/_/namespace/<name>` if the fleet should own it: the objects in
  that namespace are then scheduled after it (a name-borne edge, like the
  service's).
- A workload's region is its cluster's: the object's backend reaches the API
  server through the cluster, so an object placed anywhere but its cluster's
  region is refused (`Infra.Cli.kubernetesRoutesOf`) rather than silently
  routed through the wrong regional endpoint.

## Ownership

The ladder, applied honestly, and for once with no climbing:

- **Cluster: rung 1 on all three clouds** — EKS tags, GKE
  `resourceLabels`, Kapsule tags (`key=value` strings). The first kind whose
  rung-table row reads `tags | tags | labels` with no exception. Release:
  EKS `UntagResource`, GKE `:setResourceLabels` under the label fingerprint,
  Kapsule `PATCH` of the remaining tags.
- **Object: rung 1 everywhere, by construction.** Kubernetes objects carry
  labels natively; infra writes `managed-by-infra=<fleet>` in the object's own
  `metadata.labels` at create, reads it back in `ownershipInfo`, and `release`
  removes it with a JSON merge patch that touches nothing else. The marker is
  **never** put on a pod template: a ReplicaSet or a pod carrying it would be
  found by the scan as an undeclared object of this fleet's and deleted from
  under its controller.

Inheritance from the cluster was considered and rejected: an object inside
this fleet's cluster that carries no marker of its own would be managed on
the parent's say-so, which is exactly the "declared name is not evidence"
trap in reverse — someone else's Deployment in a namespace infra uses,
deleted because its *cluster* is ours. Only objects carrying the marker are
touched; the label is the whole of it, same as a tag on a bucket.
`Main.lean`'s `checkKubernetes` pins it against a snapshot: an unmarked
object holding a declared address is refused and never updated, another
fleet's object is left alone, and an undeclared marked one is destroyed.

## The hard edges

### 1. A cluster's deletion deletes everything in it

`holdsData := true` keeps a cluster out of `destroy --keep-data`. The rest is
ordering: the name-borne edge gives the scheduler its dependency, so a
teardown deletes a workload before its cluster, and an apply that removes a
cluster and its objects destroys the objects first — no special case, just
the DAG (`example/KubernetesPostgres.lean` pins both directions). When the
cluster line alone is removed, the cluster is an orphan whose cloud-side
deletion takes everything in it (EKS after its node groups, which it
requires). Kapsule's delete passes `with_additional_resources=false`: `true`
also deletes the declared Private Network once empty — it did, on the first
live run — and every attached volume, so the load balancers and volumes a
Kapsule cluster made for itself are left standing (`docs/coverage.md`).

The subtle case is the *scan*: an orphaned workload is found by listing
marked objects inside the clusters the declaration names — declared, or named
in a `forget` — so a workload whose line was removed is found and deleted from
a cluster that stays. A cluster the declaration no longer names at all is not
reached for an in-cluster scan, and does not need to be: its own orphan
deletion destroys everything in it. `scannableUndeclared` is `true` for
`.kubernetesObject` — the scan runs, over the declaration's clusters — and
that boundary is written down here and in `docs/coverage.md`.

What the scan lists, and does not: every top-level resource the API server
serves that can be listed and deleted, across all namespaces, with a label
selector on the marker key — except **objects with an owner**
(`ownerReferences`: a controller's child is its parent's), **PersistentVolume
Claims** (hard edge 5), core **Endpoints** — the endpoints controller copies a
Service's labels, the marker included, onto its Endpoints and sets no owner
reference, so the first live run read one as an orphan (2026-09-29) — and
**Events** (`Kube.excludedFromScan`). The metrics groups
(`metrics.k8s.io` and its custom/external siblings) are not asked: they serve
only computed, undeletable resources, and `metrics.k8s.io` answers `503` until
metrics-server is ready. Any other group-version whose discovery
answers `503` — an aggregated API whose backing service is down — is skipped
with a note on stderr rather than failing every plan.

### 2. Unreachable is split by asking the cloud, not the connection

A workload's `read`/`list` reaches through the cluster's endpoint, which can
be down three ways, and they must not blur (`Kinds.Kubernetes.reachability`):

- the cloud's control plane still lists the cluster, the API server is
  unreachable → **error**. The object's state is unknown and the run must not
  guess; a transient API-server outage read as "absent" would plan a
  re-create of a StatefulSet that is running.
- the cloud says the cluster is gone (deleted by hand, or as an orphan in this
  very apply) → the objects are gone with it: **absent**.
- a cluster the cloud lists but that reports no endpoint yet (still
  provisioning) is the first case, not the second.

"Unreachable" never means "does not exist" without the cloud's own word for
it. Both halves are pinned offline: `reachability`'s `#guard`s, and
`checkKubernetes` asking a closed port on `127.0.0.1` and requiring an error.

### 3. Secrets into the cluster: one read, at apply

A Postgres container needs its password as an env value, and the kube API has
no secret-by-reference the way Scaleway's container platform does — the
manifest carries the value, or a Kubernetes Secret object does, and infra
manages no Secret objects of its own. So the value crosses, and the crossing
is the `fetchMasterPassword` discipline: the apply path reads each `secrets`
value the environment names, once, through `Kinds.Secrets.fetchValue`, hands
it straight to the server-side apply, never stores, never prints.

The price, said out loud, and in `docs/diff-semantics.md`'s ledger: the kube
API returns whole objects, so **reading** a workload (the observation path —
`plan`, `dump`) receives the value over the wire. It is dropped where the
response is parsed (`Infra.Specs.shapeOfLive`, which maps the variable back to
`EnvVar.secret <name> <secret>` through an annotation infra wrote), before
anything reaches `Reported`, a plan line or a snapshot — but it has crossed
into this process. The value is not compared: a changed secret is not drift,
and `--refresh-secrets` is what rewrites it (an object's update re-reads
every secret it names, `resendsSecretsOnUpdate`).

What it costs beyond that: the value lands in the cluster's etcd, and is only
as protected as the cluster's encryption at rest. Per the providers' own
documentation (prose, 2026-09-29 — not an SDK fact): GKE encrypts etcd at the
storage layer by default, with application-layer secrets encryption optional;
EKS enables envelope encryption of all Kubernetes API data by default on
current versions; **for Kapsule it is not established** — `docs/providers.md`
says so. A fleet that wants the value never to cross can declare a Secret
through `rawObject` and reference it from a `raw` workload.

### 4. Three authentications, one API

The kube API is the same REST+JSON on every cloud — get, list with a label
selector, server-side apply, delete, and discovery — so **one client**
(`Infra.Providers.Kube.Client`) serves all three, and only the bearer
credential differs (`Kinds.Kubernetes.access`):

- **EKS**: the token is `k8s-aws-v1.` and the base64url (unpadded) of a
  presigned STS `GetCallerIdentity` URL signed with the header
  `x-k8s-aws-id: <cluster>` — the format `aws eks get-token` emits, signed over
  the empty body's SHA-256 as botocore's generic `SigV4QueryAuth` does.
  `UNSIGNED-PAYLOAD` is only its S3 presigner's rule, and a token signed that
  way — as linen's `presign` always signs, and as infra did until 0.20.2 — is
  refused by STS (`SignatureDoesNotMatch`) and by the cluster (a bare 401). The
  identity that created the cluster is its admin
  (`bootstrapClusterCreatorAdminPermissions`); any other needs an EKS access
  entry.
- **GKE**: the OAuth bearer the other GCP clients already hold.
- **Kapsule**: the kubeconfig's **token** user. The proposal expected a
  client certificate and pencilled in a linen addition for mutual TLS; the
  generated SDK decided otherwise (`api/k8s/v1/kubeconfig.go`:
  `KubeconfigUser.Token`, `Kubeconfig.GetToken`, and a `redacted` parameter
  that hides "the legacy token"), so no linen addition is needed. The token is
  read from the kubeconfig on every call that reaches the API server — the
  observation path included — and handed straight to the request.

Tokens are minted per call, never stored.

A managed cluster's API server presents a certificate signed by the
cluster's own CA, which the cloud hands out with the cluster (EKS
`certificateAuthority.data`, GKE `masterAuth.clusterCaCertificate`, the
kubeconfig's `certificate-authority-data`). linen's HTTP client only trusts
the system store, so the client assembles the connection from linen's own
pieces — a TCP socket, `Network.TLS.createClientContextWithCA` over the CA
written to a temporary file, and `performRequest` — with linen's hostname
verification. For GKE's IP endpoint that relies on OpenSSL 3 treating an IP
literal passed to `SSL_set1_host` as an IP; recorded as a live-test item.

### 5. PVCs outlive their workloads

Deleting a StatefulSet does not delete its PVCs — Kubernetes semantics, not
infra's, and not something a wrapper should paper over. The claim template
carries the marker label so a PVC says whose it is, but infra **does not
list or delete PVCs**: no shape, excluded from the scan by name, and their
data outliving the workload is what `--keep-data` wants anyway. A fleet that
wants a PVC gone deletes it by hand, or deletes the cluster (hard edge 1).
Enumerated in `docs/coverage.md`'s limits, not left silent.

## Rendering: `helm template` for a fleet

`infra render` prints every in-cluster object the fleet declares as the YAML
`apply` would send, offline — no cloud, cluster or credential is asked:

    lake exe kubernetes-postgres render                  # every object
    lake exe kubernetes-postgres render scaleway          # one cloud
    lake exe kubernetes-postgres render scaleway/main \
      | kubectl apply --dry-run=server -f -              # one cluster

It is the same `Specs.renderManifest` the live backend applies, not a second
rendering: the fleet's label is on every object (and on a StatefulSet's claim
template, never on a pod template), the annotations infra reads back are
there, and documents come in declaration order, each after `---` and headed
`# Source: <plan-line id>`. Two things differ from what reaches a cluster,
both said in the output: **a secret-sourced value is a placeholder**,
`<secret NAME>`, because a plaintext value never leaves `apply` (the
Terraform export's rule too); and nothing the cluster adds — defaults,
status — is there, since this is the declaration, not a read. A declaration
`kubernetesIsSound` refuses renders nothing, and its problem is the error.

The YAML is written for Kubernetes' reader, which is go-yaml's **YAML 1.1**:
a string is plain only if it is a string under 1.1 and 1.2 alike, so `on`,
`yes`, `y`, `80`, `1.27` and `2026-09-29` are quoted (`Infra.Interop.Yaml`;
checked by round trip through linen's parser, and against PyYAML — a 1.1
reader — on 57 such strings, 2026-09-29). A number the JSON encoder would
change is refused, as it is on the apply path.

Applying the output with `kubectl` works — the objects carry this fleet's
label, so the next `apply` finds them already there, as declared — but it is
not the intended use: `render` is for reading, reviewing and diffing what a
declaration means, as `helm template` is.

## Apply semantics

- **Create and update are one call: server-side apply**
  (`PATCH …?fieldManager=infra&force=true`, `application/apply-patch+yaml`).
  It creates an absent object and, for an existing one, makes infra's fields
  exactly the manifest's — removing a field infra set before and no longer
  declares, which a merge patch would leave behind. `force` takes over fields
  another manager holds; the object's marker was checked before anything
  reaches the backend (`Engine.foreignDeclared`).
- **Immutability** (`Divergent .kubernetesObject`): a StatefulSet's
  `storage` is a `REPLACE` (Kubernetes refuses any change to
  `volumeClaimTemplates`); image, replicas, ports, environment, a service's
  ports and selector, and a raw manifest are updated in place. A raw manifest
  is compared with the declaration through an annotation infra writes
  (`infra.typednotes.org/manifest`), as JSON — whitespace is not drift, and a
  change made inside the object by someone else is not noticed (the
  `kubectl apply` last-applied reading). Defaults compare in their wire form
  (a `targetPort` of `0` is the port; an empty selector is `app = <name>`), so
  a declaration that spells a default out converges with one that does not.
- **Numbers are re-encoded, and never changed.** A manifest goes to the API
  server through linen's JSON encoder, which writes a non-integer number with
  six digits after the point — `1e-7` as `0.000000`. Every number a typed
  shape writes is an integer; a raw manifest holding a number the encoder
  would change is refused by `kubernetesIsSound` at compile time, and any
  request body holding one is refused before it is sent
  (`Infra.Core.JsonExact`, 0.20.1). One the encoder keeps — `0.5` — passes.
  Write the others as a string where Kubernetes accepts one (a quantity,
  `"1e-7"`), or as an integer in smaller units.
- **Delete** is `propagationPolicy: Background`: the garbage collector takes
  the object's children. An object whose cluster the cloud no longer lists is
  gone with it, which is success.
- **Clusters wait**: a create returns once the cluster answers `ACTIVE` /
  `RUNNING` / `ready` (and, on EKS, once its node group does), because the
  objects the same apply creates next need its API server.
- **EKS does not autoscale on its own**: `autoscale` sets the managed node
  group's bounds, and scaling within them needs the Cluster Autoscaler (or
  Karpenter) running in the cluster. GKE and Kapsule autoscale natively.
- **GKE's pool is per zone**, so the cluster is regional with its nodes
  pinned to one zone (the first `compute.regions.get` lists), and `nodeCount`
  means the total, as on the other two clouds.

## Provider facts, verified

Checked against generated SDKs and discovery documents — not prose docs, the
2026-09-19 rule — on 2026-09-29, and recorded in
`Infra/Providers/Kinds/Kubernetes.lean`:

- **EKS** (botocore `eks/2017-11-01/service-2.json`): `CreateCluster`
  requires `name`, `roleArn` and `resourcesVpcConfig` (`subnetIds`), and takes
  `tags` and `accessConfig`; `CreateNodegroup` requires `subnets` and
  `nodeRole` and takes `instanceTypes`, `scalingConfig` and `tags`. The token
  format above; its fifteen-minute validity is the authenticator's, and a
  token is minted per call.
- **GKE** (`container.googleapis.com` v1 discovery, revision 20260915):
  `clusters.create` takes `network`, `locations`, `resourceLabels`,
  `initialClusterVersion` and `nodePools` (`config.machineType`,
  `initialNodeCount`, `autoscaling`); `setResourceLabels` takes the
  `labelFingerprint`; cluster statuses `PROVISIONING` … `RUNNING`.
- **Kapsule** (scaleway-sdk-go `api/k8s/v1/k8s_sdk.go`): `CreateClusterRequest`
  takes `type`, `version` (required — so an unset version is resolved to the
  highest `GET …/versions` offers), `cni`, `tags`, `pools` (`node_type`,
  `size`, `autoscaling`, `min_size`, `max_size`, `zone`) and
  `private_network_id` (optional in the SDK, mandatory for `kapsule` per the
  API, 2026-09-29); `DeleteClusterRequest.with_additional_resources`, which
  deletes volumes, load balancers and *empty Private Networks* — sent `false`;
  the token-bearing kubeconfig above.
- **DNS-1123** as the object-name rule, as enforced by the API server's own
  validation (labels for namespaces and a StatefulSet's name, subdomains for
  most objects, DNS-1035 labels for a Service).
- **Not verified by an SDK, and said so**: etcd encryption at rest per cloud
  (hard edge 3), and OpenSSL 3's IP handling in `SSL_set1_host` (hard edge 4).

## What it cost

- Two `Kind` constructors — `#guard card Kind = 17` — and with them every
  total match the design guarantees: `Kind.lean`, `Specs/`, `Settle`,
  `Action`, `Diverge`, `Engine` (`scannableUndeclared`, `holdsData`,
  `impliedByName`, `resendsSecretsOnUpdate`), `Placeholder`, `Live.lean`,
  `Terraform.lean`.
- The **route derivation** in `Infra/Cli.lean` (`kubernetesRoutesOf`, the
  `migrationRoutesOf` precedent): the object backend's listing learns which
  clusters to look in, and which objects the declaration puts in each, from
  the declaration — including clusters named only in `forget`s.
- A transport of its own for the cluster CA (hard edge 4) — built from
  linen's pieces, not a linen change.
- **Terraform interop**: clusters export as `aws_eks_cluster`,
  `google_container_cluster` and `scaleway_k8s_cluster` — the control plane
  only, with a `# TODO` naming the node-pool resource each provider keeps
  separate. Objects export as the kubernetes provider's `kubernetes_manifest`,
  whose `manifest` is the object exactly as the live backend renders it, a
  secret-sourced value left as a placeholder naming its secret.
  `kubernetes_manifest` names no cloud or cluster, so the importer skips it
  rather than guess (`Terraform.cloudlessTypes`).
- Tests, offline: `Main.lean`'s `checkKubernetes` (a snapshot with a cluster,
  a marked in-cluster orphan, an unmarked object holding a declared address,
  another fleet's object; the service-after-workload edge; `--keep-data`
  keeping the cluster; an unreachable API server as an error);
  `reachability`'s and the manifest round trip's `#guard`s
  (`Infra/Specs/Kubernetes.lean`: a rendered object reads back as the shape it
  came from, a secret's value dropped); and `example/KubernetesPostgres.lean`,
  whose guards pin the ordering, the teardown order, `--keep-data`, and three
  refused siblings. Live: an opt-in leg on each cloud, `lake test -- <cloud>
  kubernetes` — four stages, the trimmed one dropping objects inside a cluster
  that stays — **passed on Scaleway and GCP** (2026-09-29) and not yet run
  on AWS. Settled by those runs: OpenSSL 3 verifies GKE's IP endpoint
  through `SSL_set1_host`, and a current Kapsule kubeconfig carries a usable
  token.

## Alternatives considered

- **Helm itself.** A package manager with a template language, rendering to
  the same objects. The plan would show an opaque `helm upgrade` step; the
  review surface is a values file, not the objects; and the ordering, marker
  and orphan machinery this repo already is would be bypassed for the one
  resource type that most needs it. `helm install` remains usable *alongside*
  (a consumer can point `rawObject` at rendered output), but this replaces it
  as the deploy path, and says so — the two-step skew of a CI step outside the
  declaration is what the migrations kind already abolished once.
- **One `Kind` per object type.** Per-object `Diverge` tables for free, at the
  price of an enum that grows with every object type ("etc." is open-ended)
  and a checklist per addition. The shape sum keeps the totality guarantee —
  one constructor, one checklist — and `#guard`s pin per-shape facts just as
  tightly.
- **A chart-bundle kind.** One resource holding a list of objects: closest to
  Helm, and it makes per-object drift invisible — the engine would diff a set,
  and the set-compare machinery would paper over a changed image inside an
  unchanged list length. Rejected: the fleet is the bundle.
- **CI steps running `kubectl`.** The status quo; what this replaces.

## What this buys

One `apply` still deploys the whole fleet — now including the cluster and what
runs on it. The Postgres StatefulSet behind its Service, declared in the same
syntax as the database it may replace, its drift diffed per field, its rollout
ordered, its orphans found by label, its deletion gated by `--keep-data` like
every other thing that holds data. The plan names what a `helm install` would
have hidden, and nothing in the cluster is touched that does not carry the
fleet's name.

## Where the implementation differs

What changed from the proposal, and why — the body above already describes
the result.

- **The fleet name is the address; there is no `cluster` or `namespace`
  field.** The proposal had `cluster := k8s` as a typed reference and a
  `namespace` field, with the object's plain name as its fleet name. That
  cannot work: a fleet name must be the cloud-side identifier and unique per
  `(cloud, kind)`, and the proposal's own example declares a StatefulSet and a
  Service both named `postgres`. The name therefore has to carry the kind, and
  to be unique across clusters and namespaces it has to carry both — at which
  point a separate reference would only be something to disagree with. The
  proposal's reason for the typed reference ("a workload cannot point at a
  cluster on another cloud") holds more strongly for a name with no cloud in
  it than for a sigma type the macro would have had to check.
- **Shapes are built with helpers** (`statefulSet (…)`), not `.statefulSet
  (…)`: dot-notation resolves against `Expr`, the field's wrapper, not
  `ObjectShape` (`Infra.Core.Coe`'s module note). **`autoscale` needs its
  type**, `((2, 6) : Nat × Nat)`, for the numeral reason in the same note.
- **No linen addition.** Kapsule's kubeconfig carries a token user (hard edge
  4), so the pending "TLS client certificates" entry is withdrawn.
- **A StatefulSet's `storage` has a `mountPath`.** A claim template needs a
  volume mount to be of any use; the proposal left it out.
- **PVCs are excluded from the scan, not warned about at `dump` time.** The
  proposal asked for a warning per marked PVC; the scan now simply never
  lists them (with owned objects and Events), and `docs/coverage.md` states
  the exclusion. A per-backend warning channel into `dump` did not exist and
  was not worth building for one kind.
- **The observation path receives secret values** (hard edge 3): the
  proposal said a dry run "never has the value". It does not *hold* one — the
  value is dropped at parse — but the kube API cannot be asked for an object
  without its environment, so the value crosses the wire. Recorded in the
  ledger, like the migrations observer secret.
- **The scan covers every listable resource type**, not just the typed
  shapes' kinds, so a raw object whose kind the declaration no longer names
  is still found; with the three exclusions above and the `503` skip.
- **A few decisions the proposal left open**: EKS's `network` resolves to a
  VPC's subnets; GKE's cluster is regional with one node zone; a node-type
  change replaces the pool rather than the cluster; an EKS `autoscale` needs
  the Cluster Autoscaler to act.
