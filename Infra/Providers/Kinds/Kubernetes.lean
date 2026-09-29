import Infra.Providers.Kube.Client
import Infra.Providers.Kinds.Secrets
import Infra.Providers.Kinds.Identity
import Infra.Providers.Scaleway.Rest
import Infra.Providers.Gcp.Rest
import Infra.Providers.Aws.Protocols
import Infra.Providers.Aws.Sign
import Infra.Core.Backend
import Infra.Core.Stage

/-
  The two Kubernetes kinds' backends: managed clusters on three clouds, and
  the objects inside them.

  ## Clusters

  One `kubernetesCluster` is a control plane and **one** node pool. Per cloud:

  | | control plane | pool | marker |
  |---|---|---|---|
  | AWS | EKS `CreateCluster` | a managed node group | cluster tags |
  | GCP | GKE, regional, nodes in one zone | a node pool | `resourceLabels` |
  | Scaleway | Kapsule, Cilium CNI | a pool | cluster tags (`key=value`) |

  Every create waits until the cluster answers `ACTIVE` / `RUNNING` /
  `ready`, because the objects the same apply creates next need its API
  server. A node type or node role change replaces the *pool* — the new one
  is created and ready before the old is deleted — never the cluster.

  Provider facts, checked against the generated SDKs and discovery documents
  on 2026-09-29, not against prose:

  * **EKS** (botocore `eks/2017-11-01/service-2.json`): `CreateCluster`
    requires `name`, `roleArn` and `resourcesVpcConfig` (the subnets); a node
    group requires `subnets` and `nodeRole`; both take `tags`. The kube API
    token is a presigned STS `GetCallerIdentity` URL with the signed header
    `x-k8s-aws-id: <cluster>`, prefixed `k8s-aws-v1.` and base64url-encoded
    without padding — the format `aws eks get-token` emits; botocore presigns
    with `UNSIGNED-PAYLOAD`, which linen's `presignedUrl` does too.
    `accessConfig.bootstrapClusterCreatorAdminPermissions` (default true)
    makes the identity that created the cluster its admin.
  * **GKE** (`container.googleapis.com` v1 discovery, revision 20260915):
    `clusters.create` takes `network`, `locations`, `resourceLabels` and
    `nodePools` (`config.machineType`, `initialNodeCount`, `autoscaling`);
    labels change through `:setResourceLabels` with the `labelFingerprint`.
    A regional cluster's pool size is *per zone*, so the cluster's
    `locations` is pinned to one zone of the region (the first
    `compute.regions.get` lists) and `nodeCount` means the total, as on the
    other two clouds.
  * **Kapsule** (scaleway-sdk-go `api/k8s/v1/k8s_sdk.go`): `CreateClusterRequest`
    takes `type`, `version` (required), `cni`, `tags`, `pools`
    (`node_type`, `size`, `autoscaling`, `min_size`, `max_size`, `zone`) and
    `private_network_id` — optional in the SDK, but **mandatory** for a
    `kapsule` cluster, as the API answers (`invalid_arguments`, "a Private
    Network is mandatory for this cluster type", 2026-09-29, the first live
    call); the kubeconfig
    (`GET …/clusters/{id}/kubeconfig`, base64 in a `scw.File`) carries a
    **token** user (`Kubeconfig.GetToken`, and a `redacted` parameter that
    hides "the legacy token") — so no TLS client certificate is needed, and
    the linen addition `docs/kubernetes.md` had pencilled in for mutual TLS
    is not.

  ## Objects

  An object is reached through its cluster: the address's first segment is
  the cluster's fleet name, the cloud's API says where the cluster's API
  server is and which CA signs it, and a bearer token is minted for the
  call (`access`). **The cloud decides whether a cluster is gone**: `access`
  answers `none` only when the cloud no longer lists the cluster — then its
  objects are gone with it — and anything else (an API server that does not
  answer) is an error, never "absent" (hard edge 2).

  `list` answers two questions at once: the declared objects, fetched by
  name (a declared name held by an unmarked object must be seen, so that
  `foreignDeclared` can refuse it), and every object anywhere in the cluster
  carrying the marker label (`Kube.listLabelled`), which is what the scan for
  undeclared objects reads. The clusters it looks in are the declaration's —
  declared, or named in a `forget` (`routes`); see `Engine.scannableUndeclared`.
-/

namespace Infra.Providers.Kinds.Kubernetes

open Infra.Core
open Infra.Providers
open Infra.Providers.JsonRead
open Infra.Providers.Aws
open Infra.Specs (ObjectName ObjectShape)
open Data.Json (Value)

/-- A cluster the declaration names on one cloud, as the object backend needs
    it: where it is, and which objects the declaration puts in it. Derived by
    `Infra.Cli.run` (`kubernetesRoutesOf`), like the migrations routes: an
    object's handle is only its address, and the declaration is the only
    place that says which clusters to look in. -/
structure ClusterRoute where
  /-- The cluster's fleet name. -/
  name    : String
  /-- The region it is placed in; `""` when the declaration does not say
      (a `forget`), which a backend reads as "look in my own". -/
  region  : String
  /-- The fleet names of the objects declared in it. -/
  objects : List String := []
  deriving Repr, Inhabited

/-- One cluster as a cloud reports it, whatever the cloud. -/
structure ClusterInfo where
  name     : String
  id       : String
  endpoint : String
  status   : String
  /-- The cluster CA, base64 as the cloud hands it out; `""` on Kapsule,
      whose CA comes with the kubeconfig. -/
  caB64    : String := ""
  version  : String := ""
  tags     : List (String × String) := []
  network  : Partial String := .unknown
  clusterRole : Partial String := .unknown
  deriving Repr, Inhabited

/-- The cluster's one node pool. -/
structure PoolInfo where
  name      : String
  id        : String := ""
  nodeType  : String
  count     : Nat
  autoscale : Nat × Nat
  nodeRole  : Partial String := .unknown
  deriving Repr, Inhabited

/-- `(min, max, desired)` for a pool: fixed at `nodeCount`, or autoscaling
    between the bounds from `nodeCount` clamped into them. -/
def scaling (s : ProviderSpec .kubernetesCluster) : Nat × Nat × Nat :=
  let asc : Nat × Nat := s.autoscale
  let count : Nat := s.nodeCount
  if asc.2 == 0 then (count, count, count)
  else (asc.1, asc.2, min asc.2 (max asc.1 count))

#guard scaling ({ name := "c", version := "", nodeType := "t", nodeCount := 3, autoscale := (0, 0)
                  network := "", clusterRole := "", nodeRole := "" } : ProviderSpec .kubernetesCluster)
  = (3, 3, 3)
#guard scaling ({ name := "c", version := "", nodeType := "t", nodeCount := 1, autoscale := (2, 6)
                  network := "", clusterRole := "", nodeRole := "" } : ProviderSpec .kubernetesCluster)
  = (2, 6, 2)

/-- The name of the pool after `pool`: `infra-pool-1` → `infra-pool-2`. A pool
    replacement creates the next one before deleting the current. -/
def nextPoolName (current : String) : String :=
  match (current.splitOn "-").getLast? >>= String.toNat? with
  | some n => s!"infra-pool-{n + 1}"
  | none   => "infra-pool-1"

#guard nextPoolName "infra-pool-1" = "infra-pool-2"
#guard nextPoolName "default" = "infra-pool-1"

/-- Poll `step` until it says done, a second apart per `every`, for at most
    `attempts` rounds; say what was awaited when giving up. -/
def await (what : String) (step : IO Bool) (attempts : Nat := 900) (every : UInt32 := 2000) :
    IO Unit := do
  for _ in [0:attempts] do
    if ← step then return
    IO.sleep every
  throw (IO.userError s!"{what}: still not done after {attempts * every.toNat / 1000}s. It \
may still be in progress — check the console before retrying.")

/-- Base64url without padding, as the EKS token format wants. -/
def base64Url (bytes : ByteArray) : String :=
  let std := Data.Base64.encode bytes
  String.ofList (std.toList.filterMap fun c =>
    if c == '=' then none else some (if c == '+' then '-' else if c == '/' then '_' else c))

#guard base64Url "https://sts".toUTF8 = "aHR0cHM6Ly9zdHM"

-- ══════════════════════════════════════════════════════════════
-- Scaleway Kapsule
-- ══════════════════════════════════════════════════════════════

namespace Kapsule

private def pfx (creds : Credentials) : String :=
  Scaleway.regionalPrefix "k8s" "v1" creds.region

private def vpc (creds : Credentials) : String :=
  Scaleway.regionalPrefix "vpc" "v2" creds.region

private def infoOf (c : Value) : ClusterInfo :=
  { name := (c.lookupText "name").getD ""
    id := (c.lookupText "id").getD ""
    endpoint := (c.lookupText "cluster_url").getD ""
    status := (c.lookupText "status").getD ""
    version := (c.lookupText "version").getD ""
    tags := (stringArrayField c "tags").map Scaleway.decodeTag }

/-- Every cluster in the fleet's project, all pages. -/
def listRaw (creds : Credentials) : IO (List Value) := do
  let project ← creds.requireProject
  Scaleway.listAll creds "scaleway kubernetes clusters" (pfx creds ++ "/clusters") "clusters"
    (query := [("project_id", project)])

def list (creds : Credentials) : IO (List ClusterInfo) :=
  return (← listRaw creds).map infoOf

/-- The cluster named `name`, or `none` if the cloud does not list it — the
    one answer that means "gone" (a cluster being deleted is still listed).

    `withNetwork` also reads its private network's name (a VPC API call, and
    so a VPC read permission) — for `read`, which compares it; the scan's
    ownership read and the existence checks pass `false` and need only
    Kubernetes read access. -/
def describe (creds : Credentials) (name : String) (withNetwork : Bool := true) :
    IO (Option ClusterInfo) := do
  let found := (← list creds).find? (·.name == name)
  match found with
  | none => return none
  | some c =>
    if c.status == "deleted" then return none
    if !withNetwork then return some c
    -- The private network, by name, which is how a declaration names it.
    let raw ← Scaleway.call creds "GET" (pfx creds ++ s!"/clusters/{c.id}")
    let network ← match raw.lookupText "private_network_id" with
      | some pn =>
        match ← (Scaleway.call creds "GET" (vpc creds ++ s!"/private-networks/{pn}")).toBaseIO with
        | .ok v    => pure (Partial.known ((v.lookupText "name").getD pn))
        | .error _ => pure .unknown
      | none => pure .unknown
    return some { c with network }

def pools (creds : Credentials) (clusterId : String) : IO (List PoolInfo) := do
  let pools ← Scaleway.listAll creds "scaleway kubernetes pools"
    (pfx creds ++ s!"/clusters/{clusterId}/pools") "pools"
  return pools.map fun p =>
    let auto := (p.lookupBool "autoscaling").getD false
    { name := (p.lookupText "name").getD "", id := (p.lookupText "id").getD ""
      nodeType := (p.lookupText "node_type").getD ""
      count := (p.lookupNat "size").getD 0
      autoscale := if auto then ((p.lookupNat "min_size").getD 0, (p.lookupNat "max_size").getD 0)
                   else (0, 0) }

/-- The API server's CA and the kubeconfig's token.

    The token is the cluster's admin token — a secret, read on every call
    that reaches the API server (the observation path included, since reading
    an object needs it) and handed straight to the request, never stored. -/
def credentialsOf (creds : Credentials) (clusterId : String) : IO (String × String) := do
  let file ← Scaleway.call creds "GET" (pfx creds ++ s!"/clusters/{clusterId}/kubeconfig")
  let yaml ← match (file.lookupText "content").bind Data.Base64.decode |>.bind String.fromUTF8? with
    | some y => pure y
    | none   => throw (IO.userError s!"kapsule cluster {clusterId}: the kubeconfig could not \
be decoded")
  -- A kubeconfig is YAML, and the two values needed are single-line scalars
  -- under fixed keys; reading them by key is enough, and a missing one is an
  -- error rather than a guess.
  let valueOf (key : String) : Option String :=
    (yaml.splitOn "\n").findSome? fun line =>
      let t := line.trimAscii.toString
      if t.startsWith (key ++ ":") then
        some ((t.drop (key.length + 1)).trimAscii.toString.replace "\"" "")
      else none
  match valueOf "certificate-authority-data", valueOf "token" with
  | some ca, some tok =>
    if tok.isEmpty then
      throw (IO.userError s!"kapsule cluster {clusterId}: the kubeconfig carries no token")
    return (ca, tok)
  | _, _ => throw (IO.userError s!"kapsule cluster {clusterId}: the kubeconfig has no \
certificate-authority-data or token")

/-- The highest version Kapsule offers that realises `declared` (`""`: the
    highest of all). `CreateClusterRequest.version` is required, so the
    cloud's default has to be looked up. -/
private def resolveVersion (creds : Credentials) (declared : String) : IO String := do
  let reply ← Scaleway.call creds "GET" (pfx creds ++ "/versions")
  let names := (arrayField reply "versions").filterMap (Data.Json.Value.lookupText "name")
  let ok := names.filter fun v => declared.isEmpty || k8sVersionMatches declared v
  let key (v : String) : List Nat := (v.splitOn ".").map fun p => p.toNat?.getD 0
  match ok.mergeSort (fun a b => key a ≥ key b) with
  | v :: _ => return v
  | []     => throw (IO.userError s!"kapsule: no Kubernetes version matching \
'{declared}' is offered in {creds.region} (offered: {", ".intercalate names})")

private def networkId (creds : Credentials) (name : String) : IO (Option String) := do
  if name.isEmpty then
    throw (IO.userError "a Kapsule cluster needs `network`: the Private Network it is \
attached to, by name — the API refuses a cluster without one, and infra references networks \
and never creates one")
  -- Every page: the `name` filter matches names *containing* it, so the
  -- exact match need not be on the first.
  let networks ← Scaleway.listAll creds "scaleway private networks"
      (vpc creds ++ "/private-networks") "private_networks"
      (query := [("project_id", ← creds.requireProject), ("name", name)])
  match networks.find? (·.lookupText "name" == some name) with
  | some pn => return pn.lookupText "id"
  | none    => throw (IO.userError s!"kapsule: no private network named '{name}' in \
{creds.region} — infra references networks by name and never creates one")

private def poolBody (s : ProviderSpec .kubernetesCluster) (name zone : String) : Value :=
  let (lo, hi, desired) := scaling s
  let asc : Nat × Nat := s.autoscale
  .object
    [ ("name", .string name), ("node_type", .string s.nodeType)
    , ("autoscaling", .bool (asc.2 != 0)), ("size", .number desired.toFloat)
    , ("min_size", .number lo.toFloat), ("max_size", .number hi.toFloat)
    , ("autohealing", .bool true), ("container_runtime", .string "containerd")
    , ("zone", .string zone), ("tags", .array #[]) ]

private def awaitReady (creds : Credentials) (id what : String) : IO Unit :=
  await what do
    let c ← Scaleway.call creds "GET" (pfx creds ++ s!"/clusters/{id}")
    return c.lookupText "status" == some "ready"

private def awaitPoolReady (creds : Credentials) (poolId what : String) : IO Unit :=
  await what do
    let p ← Scaleway.call creds "GET" (pfx creds ++ s!"/pools/{poolId}")
    return p.lookupText "status" == some "ready"

def create (creds : Credentials) (s : ProviderSpec .kubernetesCluster) (fleet : String) :
    IO ClusterInfo := do
  let version ← resolveVersion creds s.version
  let pn ← networkId creds s.network
  let body : Value := .object (
    [ ("project_id", .string (← creds.requireProject)), ("type", .string "kapsule")
    , ("name", .string s.name), ("description", .string "")
    , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, fleet))])
    , ("version", .string version), ("cni", .string "cilium")
    , ("pools", .array #[poolBody s "infra-pool-1" s!"{creds.region}-1"])
    , ("feature_gates", .array #[]), ("admission_plugins", .array #[])
    , ("apiserver_cert_sans", .array #[]) ]
    ++ (pn.map fun id => [("private_network_id", .string id)]).getD [])
  let reply ← Scaleway.call creds "POST" (pfx creds ++ "/clusters") (payload := some body)
  let id := (reply.lookupText "id").getD ""
  awaitReady creds id s!"kapsule cluster {s.name}"
  match ← describe creds s.name with
  | some c => return c
  | none   => throw (IO.userError s!"kapsule cluster {s.name}: created, then not listed")

def update (creds : Credentials) (s : ProviderSpec .kubernetesCluster) : IO ClusterInfo := do
  let some c ← describe creds s.name false
    | throw (IO.userError s!"kapsule cluster {s.name}: not found")
  if !s.version.isEmpty && !k8sVersionMatches s.version c.version then
    let target ← resolveVersion creds s.version
    discard <| Scaleway.call creds "POST" (pfx creds ++ s!"/clusters/{c.id}/upgrade")
      (payload := some (.object [("version", .string target), ("upgrade_pools", .bool true)]))
    awaitReady creds c.id s!"kapsule cluster {s.name} upgrade to {target}"
  let pool ← match ← pools creds c.id with
    | p :: _ => pure p
    | []     => throw (IO.userError s!"kapsule cluster {s.name}: has no pool")
  if nodeTypeKey pool.nodeType != nodeTypeKey s.nodeType then
    -- A new pool first, ready before the old one goes: pods reschedule onto it.
    let fresh ← Scaleway.call creds "POST" (pfx creds ++ s!"/clusters/{c.id}/pools")
      (payload := some (poolBody s (nextPoolName pool.name) s!"{creds.region}-1"))
    awaitPoolReady creds ((fresh.lookupText "id").getD "") s!"kapsule pool for {s.name}"
    discard <| Scaleway.call creds "DELETE" (pfx creds ++ s!"/pools/{pool.id}")
  else
    let (lo, hi, desired) := scaling s
    let asc : Nat × Nat := s.autoscale
    discard <| Scaleway.call creds "PATCH" (pfx creds ++ s!"/pools/{pool.id}")
      (payload := some (.object (
        [ ("autoscaling", .bool (asc.2 != 0))
        , ("min_size", .number lo.toFloat), ("max_size", .number hi.toFloat) ]
        ++ (if asc.2 == 0 then [("size", .number desired.toFloat)] else []))))
    awaitPoolReady creds pool.id s!"kapsule pool for {s.name}"
  match ← describe creds s.name with
  | some c' => return c'
  | none    => throw (IO.userError s!"kapsule cluster {s.name}: not found after update")

/-- Delete the cluster, and **only** the cluster: `with_additional_resources`
    is `false`, explicitly.

    It used to be `true`, on the reading that it removed what Kapsule had made
    for the cluster. What it removes is every volume attached to it —
    `retain` ones included — its load balancers, and any Private Network left
    empty, which is the **declared** `network`: required since Kapsule made it
    mandatory, and a network infra references and never creates. The first
    live run deleted the CI project's network exactly so (2026-09-29) — the
    2026-09-10 cascade again, one kind over. Nothing Scaleway deletes on the
    cluster's behalf carries this fleet's marker, so none of it is infra's to
    delete.

    **Not covered, and said so** (`docs/coverage.md`): load balancers and
    volumes the cluster created for its own Services and claims are left
    standing — unmarked, named after the cluster id — and are billed until
    removed. Deleting the fleet's `LoadBalancer` Services and claims before
    the cluster lets the cluster clean up after itself.

    The cluster's data goes with it, which is why the kind `holdsData`. Waits
    until the cluster is no longer listed, so a replace does not collide with
    its own name. -/
def delete (creds : Credentials) (name : String) : IO Unit := do
  let some c ← describe creds name false | return
  discard <| Scaleway.call creds "DELETE" (pfx creds ++ s!"/clusters/{c.id}")
    (query := [("with_additional_resources", "false")])
  await s!"kapsule cluster {name} deletion" do return (← describe creds name false).isNone

def release (creds : Credentials) (name fleet : String) : IO Unit := do
  let some c := (← listRaw creds).find? (·.lookupText "name" == some name) | return
  match Scaleway.dropTag (markerKey, fleet) (stringArrayField c "tags") with
  | none => return
  | some rest =>
    discard <| Scaleway.call creds "PATCH" (pfx creds ++ s!"/clusters/{(c.lookupText "id").getD ""}")
      (payload := some (.object [("tags", .array (rest.map Value.string).toArray)]))

end Kapsule

-- ══════════════════════════════════════════════════════════════
-- AWS EKS
-- ══════════════════════════════════════════════════════════════

namespace Eks

def endpoint (region : String) : Endpoint :=
  { host := s!"eks.{region}.amazonaws.com", service := "eks", region }

private def ep (creds : Credentials) : Endpoint := endpoint creds.region

private def ec2 (creds : Credentials) : Endpoint := Query.ec2Endpoint creds.region

private def tagsOf (v : Value) : List (String × String) :=
  match v.lookup "tags" with
  | some (.object fs) => fs.filterMap fun (k, x) => x.asString.map (k, ·)
  | _ => []

def list (creds : Credentials) : IO (List String) :=
  Http.listAll "eks clusters" fun token => do
    let reply ← RestJson.call creds (ep creds) "GET" "/clusters"
      ([("maxResults", some "100")] ++ (token.map fun t => [("nextToken", some t)]).getD [])
    return (stringArrayField reply "clusters", reply.lookupText "nextToken")

/-- A VPC's id and, if it has one, its `Name` tag — both spellings a
    declaration may use for it, newline-separated for
    `Divergent .kubernetesCluster`. -/
private def vpcSpellings (creds : Credentials) (vpcId : String) : IO String := do
  match ← (Query.call creds (ec2 creds) "DescribeVpcs" "2016-11-15"
      [("VpcId.1", vpcId)]).toBaseIO with
  | .error _ => return vpcId
  | .ok root =>
    let name := (Query.listItems root "vpcSet" "item").head?.bind fun v =>
      (Query.listItems v "tagSet" "item").findSome? fun t =>
        if t.childText "key" == some "Name" then t.childText "value" else none
    return match name with
      | some n => s!"{vpcId}\n{n}"
      | none   => vpcId

/-- `DescribeCluster`, or `none` on a not-found. `withNetwork` also reads the
    VPC's `Name` tag (`ec2:DescribeVpcs`) — for `read`; the scan passes
    `false` and needs only `eks:ListClusters` and `eks:DescribeCluster`. -/
def describe (creds : Credentials) (name : String) (withNetwork : Bool := true) :
    IO (Option ClusterInfo) := do
  match ← (RestJson.call creds (ep creds) "GET" s!"/clusters/{name}").toBaseIO with
  | .error e => if readsAsAbsent (toString e) then return none else throw e
  | .ok reply =>
    let c := (reply.lookup "cluster").getD .null
    let vpcId := (c.lookup "resourcesVpcConfig").bind (Data.Json.Value.lookupText "vpcId")
    let network ← match vpcId, withNetwork with
      | some v, true => Partial.known <$> vpcSpellings creds v
      | some v, false => pure (Partial.known v)
      | none, _ => pure .unknown
    return some
      { name := (c.lookupText "name").getD name, id := (c.lookupText "arn").getD ""
        endpoint := (c.lookupText "endpoint").getD ""
        status := (c.lookupText "status").getD ""
        caB64 := ((c.lookup "certificateAuthority").bind (Data.Json.Value.lookupText "data")).getD ""
        version := (c.lookupText "version").getD ""
        tags := tagsOf c, network
        clusterRole := match c.lookupText "roleArn" with
          | some r => .known r | none => .unknown }

/-- Every node group, every page: `nextToken` both ways, `maxResults` 1–100
    (botocore, `eks/2017-11-01`, read 2026-09-29). -/
def pools (creds : Credentials) (cluster : String) : IO (List PoolInfo) := do
  let names ← Http.listAll s!"eks node groups of {cluster}" fun token => do
    let reply ← RestJson.call creds (ep creds) "GET" s!"/clusters/{cluster}/node-groups"
      ([("maxResults", some "100")] ++ (token.map fun t => [("nextToken", some t)]).getD [])
    return (stringArrayField reply "nodegroups", reply.lookupText "nextToken")
  let mut out : List PoolInfo := []
  for ng in names do
    let d ← RestJson.call creds (ep creds) "GET" s!"/clusters/{cluster}/node-groups/{ng}"
    let g := (d.lookup "nodegroup").getD .null
    let sc := (g.lookup "scalingConfig").getD .null
    let lo := (sc.lookupNat "minSize").getD 0
    let hi := (sc.lookupNat "maxSize").getD 0
    out := out ++ [{ name := ng, nodeType := (stringArrayField g "instanceTypes").headD ""
                     count := (sc.lookupNat "desiredSize").getD 0
                     autoscale := if lo == hi then (0, 0) else (lo, hi)
                     nodeRole := match g.lookupText "nodeRole" with
                       | some r => .known r | none => .unknown }]
  return out

/-- The subnets of the VPC `network` names — by `Name` tag, a `vpc-…` id, or
    `default` for the region's default VPC. -/
private def subnetsOf (creds : Credentials) (network : String) : IO (List String) := do
  if network.isEmpty then
    throw (IO.userError "an EKS cluster needs `network`: the VPC (its Name tag or id) whose \
subnets it uses — infra references networks and never creates one")
  let vpcId ← if network.startsWith "vpc-" then pure network else do
    -- `default` is the region's default VPC, as `default` is the project's
    -- default network on GCP; any other word is a `Name` tag.
    -- Every page, here and for the subnets: with a filter, EC2 may put the
    -- match on a later page than the first.
    let roots ← Query.callAll creds (ec2 creds) "DescribeVpcs" "2016-11-15"
      (if network == "default" then [("Filter.1.Name", "isDefault"), ("Filter.1.Value.1", "true")]
       else [("Filter.1.Name", "tag:Name"), ("Filter.1.Value.1", network)])
      "NextToken" (·.childText "nextToken")
    match (roots.flatMap (Query.listItems · "vpcSet" "item")).head?.bind (·.childText "vpcId") with
    | some v => pure v
    | none   => throw (IO.userError s!"eks: no VPC named '{network}' in {creds.region}")
  let roots ← Query.callAll creds (ec2 creds) "DescribeSubnets" "2016-11-15"
    [("Filter.1.Name", "vpc-id"), ("Filter.1.Value.1", vpcId)] "NextToken" (·.childText "nextToken")
  let subnets := (roots.flatMap (Query.listItems · "subnetSet" "item")).filterMap
    (·.childText "subnetId")
  if subnets.length < 2 then
    throw (IO.userError s!"eks: VPC {vpcId} has {subnets.length} subnet(s); EKS needs subnets \
in at least two availability zones")
  return subnets

/-- A role ARN from an ARN or a bare role name in the caller's own account and
    partition. -/
private def roleArn (creds : Credentials) (field role : String) : IO String := do
  if role.isEmpty then
    throw (IO.userError s!"an EKS cluster needs `{field}`: an IAM role (ARN or name) — EKS \
requires one for the control plane (`clusterRole`) and one for the nodes (`nodeRole`)")
  if role.startsWith "arn:" then return role
  let (account, callerArn) ← Identity.awsCaller creds
  let partition := ((callerArn.splitOn ":").drop 1).headD "aws"
  return s!"arn:{partition}:iam::{account}:role/{role}"

private def status (creds : Credentials) (path field : String) : IO (Option String) := do
  match ← (RestJson.call creds (ep creds) "GET" path).toBaseIO with
  | .ok v    => return (v.lookup field).bind (Data.Json.Value.lookupText "status")
  | .error e => if readsAsAbsent (toString e) then return none else throw e

private def createPool (creds : Credentials) (s : ProviderSpec .kubernetesCluster)
    (subnets : List String) (poolName fleet : String) : IO Unit := do
  let (lo, hi, desired) := scaling s
  discard <| RestJson.call creds (ep creds) "POST" s!"/clusters/{s.name}/node-groups" []
    (some (.object
      [ ("nodegroupName", .string poolName)
      , ("subnets", .array (subnets.map Value.string).toArray)
      , ("nodeRole", .string (← roleArn creds "nodeRole" s.nodeRole))
      , ("instanceTypes", .array #[.string s.nodeType])
      , ("scalingConfig", .object [("minSize", .number lo.toFloat),
          ("maxSize", .number hi.toFloat), ("desiredSize", .number desired.toFloat)])
      , ("tags", .object [(markerKey, .string fleet)]) ]))
  await s!"eks node group {s.name}/{poolName}" do
    return (← status creds s!"/clusters/{s.name}/node-groups/{poolName}" "nodegroup") == some "ACTIVE"

private def deletePool (creds : Credentials) (cluster poolName : String) : IO Unit := do
  discard <| RestJson.call creds (ep creds) "DELETE" s!"/clusters/{cluster}/node-groups/{poolName}"
  await s!"eks node group {cluster}/{poolName} deletion" do
    return (← status creds s!"/clusters/{cluster}/node-groups/{poolName}" "nodegroup").isNone

private def awaitActive (creds : Credentials) (name what : String) : IO Unit :=
  await what do return (← status creds s!"/clusters/{name}" "cluster") == some "ACTIVE"

def create (creds : Credentials) (s : ProviderSpec .kubernetesCluster) (fleet : String) :
    IO ClusterInfo := do
  let subnets ← subnetsOf creds s.network
  discard <| RestJson.call creds (ep creds) "POST" "/clusters" []
    (some (.object (
      [ ("name", .string s.name)
      , ("roleArn", .string (← roleArn creds "clusterRole" s.clusterRole))
      , ("resourcesVpcConfig", .object
          [ ("subnetIds", .array (subnets.map Value.string).toArray)
          , ("endpointPublicAccess", .bool true), ("endpointPrivateAccess", .bool false) ])
      , ("accessConfig", .object
          [ ("authenticationMode", .string "API_AND_CONFIG_MAP")
          , ("bootstrapClusterCreatorAdminPermissions", .bool true) ])
      , ("tags", .object [(markerKey, .string fleet)]) ]
      ++ (if s.version.isEmpty then [] else [("version", .string s.version)]))))
  awaitActive creds s.name s!"eks cluster {s.name}"
  createPool creds s subnets "infra-pool-1" fleet
  match ← describe creds s.name with
  | some c => return c
  | none   => throw (IO.userError s!"eks cluster {s.name}: created, then not found")

def update (creds : Credentials) (s : ProviderSpec .kubernetesCluster) (fleet : String) :
    IO ClusterInfo := do
  let some c ← describe creds s.name false | throw (IO.userError s!"eks cluster {s.name}: not found")
  if !s.version.isEmpty && !k8sVersionMatches s.version c.version then
    discard <| RestJson.call creds (ep creds) "POST" s!"/clusters/{s.name}/updates" []
      (some (.object [("version", .string s.version)]))
    awaitActive creds s.name s!"eks cluster {s.name} upgrade to {s.version}"
  let pool ← match ← pools creds s.name with
    | p :: _ => pure p
    | []     => throw (IO.userError s!"eks cluster {s.name}: has no node group")
  let roleChanged := match pool.nodeRole with
    | .known r => !s.nodeRole.isEmpty && !roleMatches s.nodeRole r
    | .unknown => false
  if nodeTypeKey pool.nodeType != nodeTypeKey s.nodeType || roleChanged then
    let subnets ← subnetsOf creds s.network
    createPool creds s subnets (nextPoolName pool.name) fleet
    deletePool creds s.name pool.name
  else
    if !s.version.isEmpty && !k8sVersionMatches s.version c.version then
      -- The nodes follow the control plane to its new version.
      discard <| RestJson.call creds (ep creds) "POST"
        s!"/clusters/{s.name}/node-groups/{pool.name}/update-version" [] (some (.object []))
    let (lo, hi, desired) := scaling s
    discard <| RestJson.call creds (ep creds) "POST"
      s!"/clusters/{s.name}/node-groups/{pool.name}/update-config" []
      (some (.object [("scalingConfig", .object [("minSize", .number lo.toFloat),
        ("maxSize", .number hi.toFloat), ("desiredSize", .number desired.toFloat)])]))
    await s!"eks node group {s.name}/{pool.name}" do
      return (← status creds s!"/clusters/{s.name}/node-groups/{pool.name}" "nodegroup")
        == some "ACTIVE"
  match ← describe creds s.name with
  | some c' => return c'
  | none    => throw (IO.userError s!"eks cluster {s.name}: not found after update")

/-- Node groups first — EKS refuses to delete a cluster that has any — then
    the cluster, waiting for each. -/
def delete (creds : Credentials) (name : String) : IO Unit := do
  if (← describe creds name false).isNone then return
  for p in ← pools creds name do deletePool creds name p.name
  discard <| RestJson.call creds (ep creds) "DELETE" s!"/clusters/{name}"
  await s!"eks cluster {name} deletion" do return (← describe creds name false).isNone

/-- `UntagResource` (`DELETE /tags/{resourceArn}?tagKeys=…`), only while the
    marker names this fleet. The ARN's `:`s make this a path outside the
    unreserved set, so it is signed over the raw path and sent with the ARN
    encoded once — the `Compute.Lambda.releaseMarker` precedent. -/
def release (creds : Credentials) (name fleet : String) : IO Unit := do
  let some c ← describe creds name false | return
  unless c.tags.contains (markerKey, fleet) do return
  let req ← Aws.signedRequest creds (ep creds) "DELETE" s!"/tags/{c.id}"
    [("tagKeys", some markerKey)] (doubleEncodePath := true)
  let wirePath := s!"/tags/{Network.URI.escapeURIString Network.URI.isUnreserved c.id}"
  match ← (Http.sendChecked { req with path := wirePath }).toBaseIO with
  | .ok _    => pure ()
  | .error e => throw (IO.userError s!"eks DELETE /tags/{c.id}: {e}")

/-- The kube API token: `k8s-aws-v1.` and the base64url of a presigned STS
    `GetCallerIdentity` URL carrying the signed header `x-k8s-aws-id`. Valid
    for fifteen minutes from signing, whatever the URL's own expiry says —
    minted per call, so always fresh. -/
def token (creds : Credentials) (cluster : String) : IO String := do
  let host := s!"sts.{creds.region}.amazonaws.com"
  let now ← Data.Time.getCurrentTime
  match ← Crypto.SigV4.presignedUrl
      { accessKeyId := creds.accessKey, secretAccessKey := creds.secretKey
        sessionToken := creds.sessionToken }
      creds.region "sts" now
      { method := "GET", path := "/"
        query := [("Action", some "GetCallerIdentity"), ("Version", some "2011-06-15")]
        headers := [("host", host), ("x-k8s-aws-id", cluster)] }
      60 s!"https://{host}" with
  | .ok url  => return "k8s-aws-v1." ++ base64Url url.toUTF8
  | .error e => throw (IO.userError s!"eks cluster {cluster}: could not sign a token: {e}")

end Eks

-- ══════════════════════════════════════════════════════════════
-- Google GKE
-- ══════════════════════════════════════════════════════════════

namespace Gke

def host : String := "container.googleapis.com"

private def base (project region : String) : String :=
  s!"/v1/projects/{project}/locations/{region}"

private def labelsOf (c : Value) : List (String × String) :=
  match c.lookup "resourceLabels" with
  | some (.object fs) => fs.filterMap fun (k, x) => x.asString.map (k, ·)
  | _ => []

private def infoOf (c : Value) : ClusterInfo :=
  let ep := (c.lookupText "endpoint").getD ""
  { name := (c.lookupText "name").getD "", id := (c.lookupText "selfLink").getD ""
    endpoint := if ep.isEmpty then "" else s!"https://{ep}"
    status := (c.lookupText "status").getD ""
    caB64 := ((c.lookup "masterAuth").bind (Data.Json.Value.lookupText "clusterCaCertificate")).getD ""
    version := (c.lookupText "currentMasterVersion").getD ""
    tags := labelsOf c
    network := match c.lookupText "network" with | some n => .known n | none => .unknown }

/-- Every cluster in the region.

    A project where the Kubernetes Engine API is not enabled fails this
    listing, and the run with it — **not** read as "nothing there", the rule
    `ci/README.md` states for Cloud SQL: one missing switch must not hide a
    whole kind. Enabling the API creates nothing and costs nothing. -/
def list (creds : Credentials) : IO (List ClusterInfo) := do
  let project ← Gcp.requireProject creds
  let reply ← Gcp.call creds "GET" host s!"{base project creds.region}/clusters"
  -- Not paged: `ListClustersResponse` has no page token at all, only
  -- `clusters` and `missingZones` (the `container` v1 discovery document,
  -- revision 20260915, read 2026-09-29). `missingZones` is its incompleteness
  -- signal — "the list of clusters returned may be missing those zones" — so
  -- a non-empty one fails the listing rather than being read as complete,
  -- for the same reason `Http.listAll` fails a truncated one.
  match stringArrayField reply "missingZones" with
  | [] => return (arrayField reply "clusters").map infoOf
  | zones => throw (IO.userError s!"gke clusters: the listing reports missing zones ({String.intercalate ", " zones}), so it may be incomplete — and a listing read as complete when it is not would plan creating what exists and miss orphans. Nothing was changed")


def get? (creds : Credentials) (name : String) : IO (Option Value) := do
  let project ← Gcp.requireProject creds
  match ← (Gcp.call creds "GET" host s!"{base project creds.region}/clusters/{name}").toBaseIO with
  | .ok v    => return some v
  | .error e => if readsAsAbsent (toString e) || ((toString e).splitOn "NOT_FOUND").length > 1
                then return none else throw e

def describe (creds : Credentials) (name : String) : IO (Option ClusterInfo) :=
  return (← get? creds name).map infoOf

def pools (creds : Credentials) (name : String) : IO (List PoolInfo) := do
  let some c ← get? creds name | return []
  let total := (c.lookupNat "currentNodeCount").getD 0
  return (arrayField c "nodePools").map fun p =>
    let a := (p.lookup "autoscaling").getD .null
    { name := (p.lookupText "name").getD ""
      nodeType := ((p.lookup "config").bind (Data.Json.Value.lookupText "machineType")).getD ""
      count := total
      autoscale := if (a.lookupBool "enabled").getD false
        then ((a.lookupNat "minNodeCount").getD 0, (a.lookupNat "maxNodeCount").getD 0) else (0, 0) }

/-- Wait for a Container API operation (its own shape: `status` `DONE`). -/
private def awaitOp (creds : Credentials) (op : Value) (what : String) : IO Unit := do
  let project ← Gcp.requireProject creds
  let name := (op.lookupText "name").getD ""
  await what do
    let o ← Gcp.call creds "GET" host s!"{base project creds.region}/operations/{name}"
    if let some err := o.lookup "error" then
      throw (IO.userError s!"gke {what}: {(err.lookupText "message").getD (Data.Json.Encode.encode err)}")
    return o.lookupText "status" == some "DONE"

/-- The first zone of the region, for a regional cluster whose nodes live in
    one zone (so a pool's size is its total, as on the other clouds). -/
private def firstZone (creds : Credentials) : IO String := do
  let project ← Gcp.requireProject creds
  let r ← Gcp.call creds "GET" "compute.googleapis.com"
    s!"/compute/v1/projects/{project}/regions/{creds.region}"
  match ((stringArrayField r "zones").map Gcp.shortName).mergeSort (· ≤ ·) with
  | z :: _ => return z
  | []     => throw (IO.userError s!"gke: region {creds.region} lists no zones")

private def poolBody (s : ProviderSpec .kubernetesCluster) (name : String) : Value :=
  let (lo, hi, desired) := scaling s
  let asc : Nat × Nat := s.autoscale
  .object
    [ ("name", .string name), ("initialNodeCount", .number desired.toFloat)
    , ("config", .object [("machineType", .string s.nodeType),
        ("oauthScopes", .array #[.string "https://www.googleapis.com/auth/cloud-platform"])])
    , ("autoscaling", .object ([("enabled", .bool (asc.2 != 0))]
        ++ (if asc.2 != 0 then [("minNodeCount", .number lo.toFloat),
                                ("maxNodeCount", .number hi.toFloat)] else []))) ]

def create (creds : Credentials) (s : ProviderSpec .kubernetesCluster) (fleet : String) :
    IO ClusterInfo := do
  let project ← Gcp.requireProject creds
  let zone ← firstZone creds
  let cluster : Value := .object (
    [ ("name", .string s.name), ("locations", .array #[.string zone])
    , ("resourceLabels", .object [(markerKey, .string fleet)])
    , ("nodePools", .array #[poolBody s "infra-pool-1"]) ]
    ++ (if s.version.isEmpty then [] else [("initialClusterVersion", .string s.version)])
    ++ (if s.network.isEmpty then [] else [("network", .string s.network)]))
  let op ← Gcp.call creds "POST" host s!"{base project creds.region}/clusters"
    (payload := some (.object [("cluster", cluster)]))
  awaitOp creds op s!"cluster {s.name}"
  match ← describe creds s.name with
  | some c => return c
  | none   => throw (IO.userError s!"gke cluster {s.name}: created, then not found")

def update (creds : Credentials) (s : ProviderSpec .kubernetesCluster) : IO ClusterInfo := do
  let project ← Gcp.requireProject creds
  let path := s!"{base project creds.region}/clusters/{s.name}"
  let some c ← describe creds s.name | throw (IO.userError s!"gke cluster {s.name}: not found")
  if !s.version.isEmpty && !k8sVersionMatches s.version c.version then
    let op ← Gcp.call creds "PUT" host path
      (payload := some (.object [("update", .object [("desiredMasterVersion", .string s.version)])]))
    awaitOp creds op s!"cluster {s.name} upgrade to {s.version}"
  let pool ← match ← pools creds s.name with
    | p :: _ => pure p
    | []     => throw (IO.userError s!"gke cluster {s.name}: has no node pool")
  if nodeTypeKey pool.nodeType != nodeTypeKey s.nodeType then
    let op ← Gcp.call creds "POST" host s!"{path}/nodePools"
      (payload := some (.object [("nodePool", poolBody s (nextPoolName pool.name))]))
    awaitOp creds op s!"node pool for {s.name}"
    let op ← Gcp.call creds "DELETE" host s!"{path}/nodePools/{pool.name}"
    awaitOp creds op s!"old node pool of {s.name}"
  else
    if !s.version.isEmpty && !k8sVersionMatches s.version c.version then
      -- `-` is the control plane's version.
      let op ← Gcp.call creds "PUT" host s!"{path}/nodePools/{pool.name}"
        (payload := some (.object [("nodeVersion", .string "-")]))
      awaitOp creds op s!"node pool of {s.name} upgrade"
    let (lo, hi, desired) := scaling s
    let asc : Nat × Nat := s.autoscale
    if asc != pool.autoscale then
      let op ← Gcp.call creds "POST" host s!"{path}/nodePools/{pool.name}:setAutoscaling"
        (payload := some (.object [("autoscaling", .object ([("enabled", .bool (asc.2 != 0))]
          ++ (if asc.2 != 0 then [("minNodeCount", .number lo.toFloat),
                                  ("maxNodeCount", .number hi.toFloat)] else [])))]))
      awaitOp creds op s!"node pool autoscaling of {s.name}"
    if asc.2 == 0 && desired != pool.count then
      let op ← Gcp.call creds "POST" host s!"{path}/nodePools/{pool.name}:setSize"
        (payload := some (.object [("nodeCount", .number desired.toFloat)]))
      awaitOp creds op s!"node pool size of {s.name}"
  match ← describe creds s.name with
  | some c' => return c'
  | none    => throw (IO.userError s!"gke cluster {s.name}: not found after update")

def delete (creds : Credentials) (name : String) : IO Unit := do
  let project ← Gcp.requireProject creds
  if (← describe creds name).isNone then return
  let op ← Gcp.call creds "DELETE" host s!"{base project creds.region}/clusters/{name}"
  awaitOp creds op s!"cluster {name} deletion"

/-- `:setResourceLabels` with every label but this fleet's marker, under the
    fingerprint just read, so a concurrent label change is refused rather
    than overwritten. -/
def release (creds : Credentials) (name fleet : String) : IO Unit := do
  let project ← Gcp.requireProject creds
  let some c ← get? creds name | return
  let labels := labelsOf c
  unless labels.contains (markerKey, fleet) do return
  let op ← Gcp.call creds "POST" host s!"{base project creds.region}/clusters/{name}:setResourceLabels"
    (payload := some (.object
      [ ("resourceLabels", .object ((labels.filter (·.1 != markerKey)).map fun (k, v) => (k, .string v)))
      , ("labelFingerprint", .string ((c.lookupText "labelFingerprint").getD "")) ]))
  awaitOp creds op s!"cluster {name} release"

end Gke

-- ══════════════════════════════════════════════════════════════
-- Per-cloud dispatch
-- ══════════════════════════════════════════════════════════════

def listClusters (provider : ProviderId) (creds : Credentials) : IO (List ClusterInfo) :=
  match provider with
  | .scaleway => Kapsule.list creds
  | .gcp      => Gke.list creds
  -- `ListClusters` names them and nothing else; each is described so the
  -- observed id and endpoint are real, as on the other two clouds.
  | .aws      => do
    let mut out : List ClusterInfo := []
    for n in ← Eks.list creds do
      if let some c ← Eks.describe creds n (withNetwork := false) then out := out ++ [c]
    return out

def describe (provider : ProviderId) (creds : Credentials) (name : String)
    (withNetwork : Bool := true) : IO (Option ClusterInfo) :=
  match provider with
  | .scaleway => Kapsule.describe creds name withNetwork
  | .gcp      => Gke.describe creds name
  | .aws      => Eks.describe creds name withNetwork

def pools (provider : ProviderId) (creds : Credentials) (c : ClusterInfo) : IO (List PoolInfo) :=
  match provider with
  | .scaleway => Kapsule.pools creds c.id
  | .gcp      => Gke.pools creds c.name
  | .aws      => Eks.pools creds c.name

/-- A cluster's reported configuration: the cluster and its one pool. -/
def read (provider : ProviderId) (creds : Credentials) (name : String) :
    IO (Reported .kubernetesCluster) := do
  let some c ← describe provider creds name
    | throw (IO.userError s!"{provider.name} kubernetes cluster {name}: not found (HTTP 404)")
  let pool := (← pools provider creds c).head?
  return { name, version := if c.version.isEmpty then .unknown else .known c.version
           nodeType := (pool.map (·.nodeType)).getD ""
           nodeCount := match pool with | some p => .known p.count | none => .unknown
           autoscale := match pool with | some p => .known p.autoscale | none => .unknown
           network := c.network, clusterRole := c.clusterRole
           nodeRole := (pool.map (·.nodeRole)).getD .unknown }

def observedOf (c : ClusterInfo) : KubernetesClusterObserved :=
  { handle := ⟨c.name⟩, clusterId := c.id, endpoint := c.endpoint }

def create (provider : ProviderId) (creds : Credentials) (s : ProviderSpec .kubernetesCluster)
    (fleet : String) : IO KubernetesClusterObserved := do
  let c ← match provider with
    | .scaleway => Kapsule.create creds s fleet
    | .gcp      => Gke.create creds s fleet
    | .aws      => Eks.create creds s fleet
  return observedOf c

def update (provider : ProviderId) (creds : Credentials) (s : ProviderSpec .kubernetesCluster)
    (fleet : String) : IO KubernetesClusterObserved := do
  let c ← match provider with
    | .scaleway => Kapsule.update creds s
    | .gcp      => Gke.update creds s
    | .aws      => Eks.update creds s fleet
  return observedOf c

def delete (provider : ProviderId) (creds : Credentials) (name : String) : IO Unit :=
  match provider with
  | .scaleway => Kapsule.delete creds name
  | .gcp      => Gke.delete creds name
  | .aws      => Eks.delete creds name

def ownership (provider : ProviderId) (creds : Credentials) (name : String) : IO Evidence := do
  match ← describe provider creds name (withNetwork := false) with
  | some c => return .tags c.tags none
  | none   => throw (IO.userError s!"{provider.name} kubernetes cluster {name}: not found (HTTP 404)")

def release (provider : ProviderId) (creds : Credentials) (name fleet : String) : IO Unit :=
  match provider with
  | .scaleway => Kapsule.release creds name fleet
  | .gcp      => Gke.release creds name fleet
  | .aws      => Eks.release creds name fleet

/-- The decision `access` makes about a cluster, from what the cloud said:
    `none` — gone, so its objects are gone with it — **only** when the cloud
    no longer lists it; its API server's host and port when it reports one;
    and an error when it lists the cluster but reports no endpoint yet. The
    pure half of hard edge 2, so both branches can be pinned offline. -/
def reachability (label : String) : Option ClusterInfo → Except String (Option (String × UInt16))
  | none   => .ok none
  | some c =>
    match Kube.parseServer c.endpoint with
    | some hp => .ok (some hp)
    | none    => .error s!"{label}: the cloud lists this cluster (status {c.status}) but \
reports no API server endpoint yet, so its objects cannot be read — which is not the \
same as their being absent"

private def readyInfo : ClusterInfo :=
  { name := "c", id := "1", endpoint := "https://k.example:6443", status := "ready" }
private def creatingInfo : ClusterInfo :=
  { name := "c", id := "1", endpoint := "", status := "creating" }
#guard (reachability "c" none).toOption == some none
#guard (reachability "c" (some readyInfo)).toOption == some (some ("k.example", 6443))
#guard (reachability "c" (some creatingInfo)).toOption == none

/-- How to reach a cluster's API server, or `none` when **the cloud** says the
    cluster is gone.

    A cluster the cloud still lists but whose API server is not answering yet
    (still provisioning) is an error, not `none`: its objects' state is
    unknown, and reading unknown as absent would plan re-creating a running
    StatefulSet. -/
def access (provider : ProviderId) (creds : Credentials) (name : String) :
    IO (Option Kube.Access) := do
  let label := slotId provider .kubernetesCluster name
  let info ← describe provider creds name (withNetwork := false)
  let reach ← match reachability label info with
    | .ok r    => pure r
    | .error e => throw (IO.userError e)
  let (some (host, port), some c) := (reach, info) | return none
  let (caB64, token) ← match provider with
    | .scaleway => Kapsule.credentialsOf creds c.id
    | .gcp      => pure (c.caB64, ← creds.requireToken .gcp)
    | .aws      => pure (c.caB64, ← Eks.token creds name)
  let some caPem := Kube.pemOfBase64 caB64
    | throw (IO.userError s!"{label}: the cluster CA could not be decoded")
  return some { label, host, port, caPem, token }

-- ══════════════════════════════════════════════════════════════
-- Objects
-- ══════════════════════════════════════════════════════════════

/-- The clusters a backend in `creds.region` looks in: the routes placed
    there, and the ones whose region the declaration does not say. -/
def routesHere (creds : Credentials) (routes : List ClusterRoute) : List ClusterRoute :=
  routes.filter fun r => r.region.isEmpty || r.region == creds.region

private def parseName (h : String) : IO ObjectName := do
  match ObjectName.parse? h with
  | some n => return n
  | none   => throw (IO.userError s!"kubernetes-object/{h}: not a \
<cluster>/<namespace>/<kind>/<name> address")

/-- The API server of the cluster an address names, or `none` if the cloud
    says that cluster is gone. -/
private def accessFor (provider : ProviderId) (creds : Credentials) (n : ObjectName) :
    IO (Option Kube.Access) :=
  access provider creds n.cluster

/-- The resource and path of an addressed object. -/
private def locate (a : Kube.Access) (n : ObjectName) : IO Kube.Resource :=
  Kube.resourceOfSegment a n.kind

/-- Every object this backend can name: the declared ones that exist (by
    name, marked or not) and every object carrying *a* marker label in the
    clusters of its region (`Kube.listLabelled`). A cluster the cloud no
    longer lists contributes nothing — its objects are gone with it. -/
def listObjects (provider : ProviderId) (creds : Credentials) (routes : List ClusterRoute) :
    IO (List KubernetesObjectObserved) := do
  let mut out : List KubernetesObjectObserved := []
  for route in routesHere creds routes do
    let some a ← access provider creds route.name | continue
    for found in ← Kube.listLabelled a route.name markerKey do
      out := out ++ [{ handle := ⟨found.name.render⟩, uid := found.uid }]
    for full in route.objects do
      if out.any (·.handle.raw == full) then continue
      let some n := ObjectName.parse? full | continue
      let r ← locate a n
      if let some live ← Kube.get? a (Kube.objectPath r n.ns n.name) then
        out := out ++ [{ handle := ⟨full⟩
                         uid := ((live.lookup "metadata").bind (Data.Json.Value.lookupText "uid")).getD "" }]
  return out

private def liveObject (provider : ProviderId) (creds : Credentials) (h : String) :
    IO (ObjectName × Kube.Access × Kube.Resource × Option Value) := do
  let n ← parseName h
  let some a ← accessFor provider creds n
    | throw (IO.userError s!"kubernetes-object/{h}: its cluster '{n.cluster}' does not exist \
(HTTP 404)")
  let r ← locate a n
  return (n, a, r, ← Kube.get? a (Kube.objectPath r n.ns n.name))

/-- The object's configuration, as the declaration would say it
    (`Infra.Specs.shapeOfLive`). A secret environment variable's value comes
    back in the API's response — the API returns whole objects — and is
    dropped there, before anything reaches `Reported`. An object infra did
    not create, of a kind with no typed shape, reports an empty raw shape:
    it cannot match a declaration, and `foreignDeclared` refuses to touch it
    anyway, since it carries no marker. -/
def readObject (provider : ProviderId) (creds : Credentials) (h : Handle .kubernetesObject) :
    IO (Reported .kubernetesObject) := do
  let (n, _, r, live?) ← liveObject provider creds h.raw
  let some live := live?
    | throw (IO.userError s!"kubernetes-object/{h.raw}: not found (HTTP 404)")
  let shape := (Infra.Specs.shapeOfLive n live).getD (.raw r.apiVersion r.kind "")
  return { name := h.raw, shape }

/-- Create or update: render the manifest — reading each secret the
    environment names, once, here on the apply path — and server-side apply
    it. The values go into the request and nowhere else. -/
def applyObject (provider : ProviderId) (creds : Credentials) (fleet : String)
    (s : ProviderSpec .kubernetesObject) : IO KubernetesObjectObserved := do
  let n ← parseName s.name
  let some a ← accessFor provider creds n
    | throw (IO.userError s!"kubernetes-object/{s.name}: its cluster '{n.cluster}' does not \
exist — it is created first in the same apply, so this means it was deleted")
  let shape : ObjectShape := s.shape
  let (apiVersion, kind) := shape.apiVersionKind
  let r ← Kube.resourceFor a apiVersion kind
  if n.clusterScoped == r.namespaced then
    throw (IO.userError s!"kubernetes-object/{s.name}: {kind} is \
{if r.namespaced then "namespaced" else "cluster-scoped"}, so its address's namespace must \
{if r.namespaced then "be a namespace" else "be '_'"}")
  let mut values : List (String × String) := []
  for sec in shape.secretNames do
    unless values.any (·.1 == sec) do
      values := values ++ [(sec, ← Secrets.fetchValue provider creds sec)]
  let manifest ← match Infra.Specs.renderManifest n shape (markerKey, fleet)
      (fun sec => ((values.find? (·.1 == sec)).map (·.2)).getD "") with
    | .ok v    => pure v
    | .error e => throw (IO.userError s!"kubernetes-object/{s.name}: {e}")
  let applied ← Kube.apply a r n.ns n.name manifest
  return { handle := ⟨s.name⟩
           uid := ((applied.lookup "metadata").bind (Data.Json.Value.lookupText "uid")).getD "" }

/-- Delete. An object whose cluster the cloud no longer lists is gone with
    it, which is success; an object already gone is too. -/
def deleteObject (provider : ProviderId) (creds : Credentials) (h : Handle .kubernetesObject) :
    IO Unit := do
  let n ← parseName h.raw
  let some a ← accessFor provider creds n | return
  let r ← locate a n
  Kube.delete a r n.ns n.name

/-- The object's labels: rung 1. -/
def objectOwnership (provider : ProviderId) (creds : Credentials)
    (h : Handle .kubernetesObject) : IO Evidence := do
  let (_, _, _, live?) ← liveObject provider creds h.raw
  match live? with
  | some live => return .tags (Infra.Specs.labelsOf live) none
  | none      => throw (IO.userError s!"kubernetes-object/{h.raw}: not found (HTTP 404)")

/-- Remove the marker label — only while it names this fleet — with a merge
    patch that touches nothing else. -/
def releaseObject (provider : ProviderId) (creds : Credentials) (fleet : String)
    (h : Handle .kubernetesObject) : IO Unit := do
  let (n, a, r, live?) ← liveObject provider creds h.raw
  let some live := live? | return
  unless Infra.Specs.labelOf live markerKey == some fleet do return
  Kube.mergePatch a r n.ns n.name
    (.object [("metadata", .object [("labels", .object [(markerKey, .null)])])])

end Infra.Providers.Kinds.Kubernetes
