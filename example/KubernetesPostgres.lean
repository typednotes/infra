import Infra

/-!
  # Example: a managed cluster, and Postgres running in it

  A Kapsule cluster, and a Postgres StatefulSet behind a Service, declared in
  the same syntax as every other resource — **the fleet is the chart**. The
  plan is the diff, `apply` is the install, and the marker, the scheduler and
  the orphan scan that govern a bucket govern the StatefulSet too.

      secrets db-password ──────────────┐
      kubernetes-cluster main ──┬───────┴──▶ statefulset.apps/postgres ──▶ service/postgres
                                └──────────────────────────────────────────▶ (same cluster)

  Four resources, one apply. Every edge is **name-borne**:

  * an in-cluster object's fleet name is its *address*,
    `<cluster>/<namespace>/<kind>/<name>` — so `main/default/…` is in cluster
    `main`, on this line's own cloud, and cannot point at another cloud's;
  * the StatefulSet's `POSTGRES_PASSWORD` names the secret `db-password`,
    read once at apply and written into the object, never reported back;
  * the Service, with no explicit selector, selects `app = postgres` — the
    label every workload infra creates carries — so it fronts the StatefulSet
    of the same name, and is scheduled after it.

  ## Run

      lake exe kubernetes-postgres            -- offline: the plan, from placeholders
      lake exe kubernetes-postgres render     -- offline: the objects, as YAML
      lake exe kubernetes-postgres plan       -- reads the Scaleway account
      lake exe kubernetes-postgres apply      -- creates a billable cluster

  `destroy --keep-data` keeps the cluster (it holds the volumes) and removes
  the objects; the StatefulSet's PersistentVolumeClaim outlives it either
  way — Kubernetes keeps claims, and infra never deletes one.

  **Run live on Scaleway and GCP** (2026-09-29, the Kubernetes leg of
  `test/Live.lean`, four stages each); AWS's leg runs from the Live test
  workflow. Every backend call is written against the providers' generated
  SDKs and discovery documents (dates in `Infra/Providers/Kinds/Kubernetes.lean`);
  see `docs/coverage.md`.
-/
open Infra.Core
open Infra.Specs

fleet kubernetesPostgres in paris where
  provider scaleway where
    resource secrets "db-password"
      { valueFrom := fromEnv "DB_PASSWORD" }

    resource kubernetesCluster "main"
      { version := "1.31",
        nodeType := "GP1-S",
        nodeCount := 3,
        autoscale := ((2, 6) : Nat × Nat),
        network := "pn-typednotes" }

    resource kubernetesObject "main/default/statefulset.apps/postgres"
      { shape := statefulSet (image := "postgres:17") (replicas := 1) (ports := [5432])
          (env := [.lit "POSTGRES_USER" "dbadmin", .lit "PGDATA" "/var/lib/postgresql/data/pg",
                   .secret "POSTGRES_PASSWORD" "db-password"])
          (storage := some { sizeGb := 20, storageClass := "scw-bssd",
                             mountPath := "/var/lib/postgresql/data" }) }

    resource kubernetesObject "main/default/service/postgres"
      { shape := service 5432 }

/- Nothing here holds a value: the password comes from the environment at
   apply time and goes straight into the StatefulSet. -/
#guard kubernetesPostgres.plan.secretsAreSound

/- Every address parses, agrees with its shape, and names a cluster this
   fleet declares on the same cloud. -/
#guard kubernetesPostgres.plan.kubernetesIsSound

#guard kubernetesPostgres.keys.count .scaleway .kubernetesCluster = 1
#guard kubernetesPostgres.keys.count .scaleway .kubernetesObject = 2

/- The ordering, pinned offline: the scheduled order, not the declaration
   order, and a missing slot answers false so a rename fails the guard
   instead of quietly satisfying it. -/
private def order : List String :=
  match orderActions kubernetesPostgres.plan (actions kubernetesPostgres.plan (worldOf [])) with
  | .ok ordered => ordered.map Action.slot
  | .error _    => []

private def runsBefore (a b : String) : Bool :=
  match order.idxOf? a, order.idxOf? b with
  | some i, some j => i < j
  | _,      _      => false

#guard runsBefore "scaleway/kubernetes-cluster/main"
  "scaleway/kubernetes-object/main/default/statefulset.apps/postgres"
#guard runsBefore "scaleway/secrets/db-password"
  "scaleway/kubernetes-object/main/default/statefulset.apps/postgres"
#guard runsBefore "scaleway/kubernetes-object/main/default/statefulset.apps/postgres"
  "scaleway/kubernetes-object/main/default/service/postgres"

/- The teardown is the transpose: objects before their cluster. -/
private def teardown : List String :=
  let T := kubernetesPostgres.plan
  -- Every slot seen, so every one is a DELETE.
  let W : World kubernetesPostgres.keys :=
    { sighting := fun _ k _ => some { observed := Infra.Providers.placeholderObserved k "x"
                                      reported := Infra.Providers.placeholderReported k ⟨"x"⟩ } }
  match orderActions (Plan.absent kubernetesPostgres.keys) (actions (Plan.absent _) W) T with
  | .ok ordered => ordered.map Action.slot
  | .error _    => []

#guard match teardown.idxOf? "scaleway/kubernetes-object/main/default/service/postgres",
             teardown.idxOf? "scaleway/kubernetes-object/main/default/statefulset.apps/postgres",
             teardown.idxOf? "scaleway/kubernetes-cluster/main" with
  | some svc, some sts, some cluster => svc < sts && sts < cluster
  | _, _, _ => false

/- `destroy --keep-data` keeps the cluster — it holds the volumes — and
   takes the objects; the claims outlive them regardless. -/
#guard match kubernetesPostgres.keys.keyOfName? .scaleway .kubernetesCluster "main" with
  | some key => (kubernetesPostgres.plan.keepingData.assign .scaleway .kubernetesCluster key
      matches .unmanaged)
  | none => false
#guard match kubernetesPostgres.keys.keyOfName? .scaleway .kubernetesObject
    "main/default/service/postgres" with
  | some key => (kubernetesPostgres.plan.keepingData.assign .scaleway .kubernetesObject key
      matches .absent)
  | none => false

/- A namespace the fleet declares, as a raw object, is created before the
   objects in it — the same name-borne kind of edge. -/
fleet withNamespace in paris where
  resource scaleway kubernetesCluster "main" { nodeType := "GP1-S", network := "pn-typednotes" }
  resource scaleway kubernetesObject "main/apps/deployment.apps/web"
    { shape := deployment (image := "nginx:1.27") }
  resource scaleway kubernetesObject "main/_/namespace/apps"
    { shape := rawObject "v1" "Namespace" "{}" }

#guard withNamespace.plan.kubernetesIsSound
#guard match orderActions withNamespace.plan (actions withNamespace.plan (worldOf [])) with
  | .ok o =>
    match (o.map Action.slot).idxOf? "scaleway/kubernetes-object/main/_/namespace/apps",
          (o.map Action.slot).idxOf? "scaleway/kubernetes-object/main/apps/deployment.apps/web" with
    | some ns, some web => ns < web
    | _, _ => false
  | .error _ => false

/- What the declaration cannot say is refused before any action — here, at
   compile time. An object on a cluster declared on another cloud: its
   address has no cloud in it, so it names a Scaleway cluster, which this
   fleet does not declare. -/
fleet crossCloudObject in paris where
  resource aws kubernetesCluster "main"
    { nodeType := "t3.large", network := "vpc-main", clusterRole := "eks-cluster",
      nodeRole := "eks-nodes" }
  resource scaleway kubernetesObject "main/default/service/web"
    { shape := service 80 }

#guard !crossCloudObject.plan.kubernetesIsSound
#guard ((crossCloudObject.plan.kubernetesProblem.getD "").splitOn
  "does not declare on scaleway").length > 1

/- An address whose kind disagrees with its shape. -/
fleet wrongKind in paris where
  resource scaleway kubernetesCluster "main" { nodeType := "GP1-S", network := "pn-typednotes" }
  resource scaleway kubernetesObject "main/default/deployment.apps/web"
    { shape := service 80 }

#guard !wrongKind.plan.kubernetesIsSound

/- A fixed pool spelled as an autoscale range would never converge. -/
fleet fixedRange in paris where
  resource scaleway kubernetesCluster "main"
    { nodeType := "GP1-S", autoscale := ((3, 3) : Nat × Nat), network := "pn-typednotes" }

#guard !fixedRange.plan.kubernetesIsSound

/- A Kapsule cluster with no Private Network: the API refuses it
   (`invalid_arguments`, "a Private Network is mandatory for this cluster
   type" — the first live create, 2026-09-29), so `infra check` refuses it
   first. EKS likewise needs `network` and its two roles; GKE defaults all
   three. -/
fleet noNetwork in paris where
  resource scaleway kubernetesCluster "main" { nodeType := "GP1-S" }

#guard !noNetwork.plan.kubernetesIsSound
#guard ((noNetwork.plan.kubernetesProblem.getD "").splitOn
  "network is required on scaleway").length > 1

/-! ## Rendering: `helm template` for a fleet

   `lake exe kubernetes-postgres render` prints the two objects as the YAML
   `apply` sends — the same `renderManifest` — offline. Scoped with
   `render scaleway` or `render scaleway/main`, it is what `kubectl apply -f -`
   takes. The password is a placeholder: its value never leaves `apply`. -/

open Infra.Interop.KubernetesYaml in
def rendered (scope : Scope := .all) : String :=
  (render kubernetesPostgres.plan "kubernetes-postgres" scope).toOption.getD "(refused)"

private def mentions (s t : String) : Bool := (s.splitOn t).length > 1

-- Two documents, headed by their plan-line ids, in declaration order.
#guard (rendered.splitOn "---\n").length = 3
#guard rendered.startsWith "---\n# Source: scaleway/kubernetes-object/main/default/statefulset.apps/postgres\n"
#guard mentions rendered "---\n# Source: scaleway/kubernetes-object/main/default/service/postgres\n"
-- The fleet's label, as applied; the secret as a placeholder, and said so.
#guard mentions rendered "    managed-by-infra: kubernetes-postgres\n"
#guard mentions rendered "value: \"<secret db-password>\""
#guard mentions rendered "# Secret-sourced values are placeholders (db-password)"
-- Scopes: the cluster is all of it; another cloud or cluster is nothing.
#guard rendered (.cluster .scaleway "main") = rendered
#guard rendered (.cloud .aws) = ""
#guard rendered (.cluster .scaleway "other") = ""
-- A declaration `kubernetesIsSound` refuses renders nothing: its problem is
-- the error, word for word.
#guard (Infra.Interop.KubernetesYaml.render crossCloudObject.plan "f").toOption.isNone
#guard (match Infra.Interop.KubernetesYaml.render crossCloudObject.plan "f" with
        | .error e => some e | .ok _ => none) = crossCloudObject.plan.kubernetesProblem

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "kubernetes-postgres" kubernetesPostgres
    (accounts := ← Infra.Cli.Accounts.fromEnv) (args := args)
