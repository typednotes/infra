import Infra.Providers.Http
import Infra.Providers.JsonRead
import Infra.Specs.Kubernetes
import Linen.Data.Streaming.Network
import Linen.Network.TLS.Context
import Linen.Network.HTTP.Client.Response
import Linen.Data.Base64

/-
  The Kubernetes API, one client for three clouds.

  EKS, GKE and Kapsule serve the same REST+JSON API; only the bearer
  credential differs, and minting it is the cloud's business
  (`Kinds.Kubernetes`). This module takes an `Access` — where the API server
  is, the CA that signs its certificate, and a bearer token — and does the
  rest: get, list with a label selector, server-side apply, delete, and the
  discovery calls that turn a kind into a REST path.

  ## Why its own transport

  A managed cluster's API server presents a certificate signed by the
  cluster's own CA, not a public one, and `Infra.Providers.Http` — through
  linen's HTTP client — only trusts the system store. linen's TLS layer does
  offer a context that trusts a given CA file
  (`Network.TLS.createClientContextWithCA`), so the connection is assembled
  here from linen's pieces: a TCP socket, that context, and linen's
  `performRequest` over the session. The CA is written to a temporary file
  for the handshake and removed after it. Hostname verification is linen's
  (`SSL_set1_host`), which for GKE's IP endpoint relies on OpenSSL 3 treating
  an IP literal as an IP — recorded as a live-test item in
  `docs/kubernetes.md`.

  ## Unreachable is an error

  A failure to reach the API server raises — after the same retry policy as
  every other provider call — and is never read as "absent". Whether a
  cluster that cannot be reached still exists is the *cloud's* question, and
  `Kinds.Kubernetes` asks it before calling here (hard edge 2).
-/

namespace Infra.Providers.Kube

open Infra.Core
open Infra.Providers
open Infra.Providers.JsonRead
open Network.HTTP.Client
open Network.HTTP.Types
open Data.Json (Value)

/-- How to reach one cluster's API server. Built per operation and never
    stored: `token` is a bearer credential minted for this run
    (`Kinds.Kubernetes.access`). The `Repr` redacts it. -/
structure Access where
  /-- The cluster's fleet slot, for messages. -/
  label : String
  host  : String
  port  : UInt16
  /-- The cluster CA, PEM. -/
  caPem : String
  token : String

instance : Repr Access where
  reprPrec a _ := s!"Access({a.label} at {a.host}:{a.port}, token <redacted>)"

/-- Host and port of an API server URL: `https://1.2.3.4`,
    `https://x.api.k8s.fr-par.scw.cloud:6443`, `https://ABC.gr7.eu-west-1.eks.amazonaws.com`. -/
def parseServer (url : String) : Option (String × UInt16) :=
  let rest := if url.startsWith "https://" then (url.drop 8).toString else url
  let hostPort := (rest.splitOn "/").headD ""
  match hostPort.splitOn ":" with
  | [h]    => if h.isEmpty then none else some (h, 443)
  | [h, p] => p.toNat?.bind fun n => if h.isEmpty || n > 65535 then none else some (h, n.toUInt16)
  | _      => none

#guard parseServer "https://1.2.3.4" = some ("1.2.3.4", 443)
#guard parseServer "https://abc.api.k8s.fr-par.scw.cloud:6443" = some ("abc.api.k8s.fr-par.scw.cloud", 6443)
#guard parseServer "https://x.eks.amazonaws.com/" = some ("x.eks.amazonaws.com", 443)
#guard parseServer "https://" = none

/-- A CA the clouds hand out base64-encoded (EKS `certificateAuthority.data`,
    GKE `clusterCaCertificate`, a kubeconfig's `certificate-authority-data`),
    decoded to PEM text. -/
def pemOfBase64 (b64 : String) : Option String :=
  (Data.Base64.decode b64.trimAscii.toString).bind String.fromUTF8?

-- ────────────────────────────────────────────────────────────────────
-- Transport
-- ────────────────────────────────────────────────────────────────────

/-- One request over TLS trusting only the cluster's CA. -/
private def sendOnce (a : Access) (caPath : String) (req : Request) : IO Response := do
  let (sock, _) ← Data.Streaming.Network.getSocketTCP a.host a.port
  Network.Socket.setRecvTimeout sock Http.timeoutMillis
  Network.Socket.setSendTimeout sock Http.timeoutMillis
  let ctx ← Network.TLS.createClientContextWithCA caPath
  let session ← Network.TLS.connectSocket ctx sock.raw a.host
  let conn : Connection :=
    { connRead := fun n => Network.TLS.read session n.toUSize
      connWrite := fun data => Network.TLS.write session data
      connClose := do
        Network.TLS.close session
        let _ ← Network.Socket.close sock
        pure ()
      connIsSecure := true }
  try performRequest conn req finally conn.connClose

/-- Send a request to the API server, retrying transient failures, and return
    the response whatever its status — `call` and `get?` decide. -/
def send (a : Access) (method path : String) (query : Query := [])
    (contentType : String := "application/json") (body : Option Value := none) :
    IO Response := do
  let bytes := body.map fun v => (Data.Json.Encode.encode v).toUTF8
  let rendered := canonicalQuery query
  let req : Request :=
    { method := parseMethod method
      host := a.host, port := a.port, path
      queryString := if rendered.isEmpty then "" else "?" ++ rendered
      headers := ([("Authorization", "Bearer " ++ a.token), ("Accept", "application/json"),
                   ("Connection", "close")]
                  ++ (if bytes.isSome then [("Content-Type", contentType)] else [])).map
        fun (n, v) => (Data.CI.mk' n, v)
      body := bytes
      isSecure := true
      timeoutMillis := Http.timeoutMillis }
  IO.FS.withTempFile fun h caPath => do
    h.putStr a.caPem
    h.flush
    withRetry Http.policy (sendOnce a caPath.toString req)

private def label (a : Access) (method path : String) : String :=
  s!"kubernetes {a.label} {method} {path}"

private def parseBody (what : String) (resp : Response) : IO Value := do
  let text := (Http.bodyText resp).trimAscii.toString
  if text.isEmpty then return .null
  match Data.Json.Decode.decode text with
  | .ok v    => return v
  | .error m => throw (IO.userError s!"{what}: malformed JSON response: {m}")

/-- Call and require a 2xx; the API server's `Status` body is read for the
    error (`{"reason":…,"message":…}`) through `Http.describeError`, which
    already reads a flat `code`/`message`. -/
def call (a : Access) (method path : String) (query : Query := [])
    (contentType : String := "application/json") (body : Option Value := none) : IO Value := do
  let resp ← send a method path query contentType body
  let status := resp.statusCode.statusCode
  unless 200 ≤ status && status ≤ 299 do
    let text := Http.bodyText resp
    -- Kubernetes names the failure in `reason` (`NotFound`, `Forbidden`,
    -- `Conflict`, `Invalid`), which is the code worth keeping.
    let described := Http.describeError status text
    let reason := match Data.Json.Decode.decode text with
      | .ok v => (stringField v "reason").getD described.code
      | .error _ => described.code
    throw (IO.userError s!"{label a method path}: {toString { described with code := reason }}")
  parseBody (label a method path) resp

/-- A GET that reads a 404 as `none`. -/
def get? (a : Access) (path : String) (query : Query := []) : IO (Option Value) := do
  let resp ← send a "GET" path query
  if resp.statusCode.statusCode == 404 then return none
  let status := resp.statusCode.statusCode
  unless 200 ≤ status && status ≤ 299 do
    throw (IO.userError s!"{label a "GET" path}: \
{toString (Http.describeError status (Http.bodyText resp))}")
  some <$> parseBody (label a "GET" path) resp

-- ────────────────────────────────────────────────────────────────────
-- Discovery: from a kind to a REST path
-- ────────────────────────────────────────────────────────────────────

/-- Where a kind is served: the group-version root (`/api/v1`,
    `/apis/apps/v1`), the plural resource name, whether it is namespaced,
    and its `apiVersion`/`kind`. -/
structure Resource where
  root       : String
  plural     : String
  namespaced : Bool
  apiVersion : String
  kind       : String
  deriving Repr, BEq

/-- The `<kind>[.<group>]` segment of an object's address for this resource. -/
def Resource.kindSegment (r : Resource) : String :=
  let g := Infra.Specs.apiGroupOf r.apiVersion
  if g.isEmpty then r.kind.toLower else s!"{r.kind.toLower}.{g}"

/-- The prefix a group-version is served under. -/
def prefixOf (apiVersion : String) : String :=
  if (apiVersion.splitOn "/").length == 2 then s!"/apis/{apiVersion}" else s!"/api/{apiVersion}"

/-- The three typed shapes' resources, which need no discovery call. -/
def typed : List Resource :=
  [ { root := "/apis/apps/v1", plural := "deployments", namespaced := true
      apiVersion := "apps/v1", kind := "Deployment" }
  , { root := "/apis/apps/v1", plural := "statefulsets", namespaced := true
      apiVersion := "apps/v1", kind := "StatefulSet" }
  , { root := "/api/v1", plural := "services", namespaced := true
      apiVersion := "v1", kind := "Service" } ]

/-- The resources of one group-version, from its discovery document: every
    top-level (not a subresource) resource that can be listed and deleted. -/
def resourcesOf (a : Access) (apiVersion : String) : IO (List Resource) := do
  let doc ← call a "GET" (prefixOf apiVersion)
  return (arrayField doc "resources").filterMap fun r =>
    let verbs := stringArrayField r "verbs"
    match stringField r "name", stringField r "kind" with
    | some plural, some kind =>
      if (plural.splitOn "/").length == 1 && verbs.contains "list" && verbs.contains "delete" then
        some { root := prefixOf apiVersion, plural
               namespaced := (boolField r "namespaced").getD true, apiVersion, kind }
      else none
    | _, _ => none

/-- The resource serving `apiVersion`/`kind`. -/
def resourceFor (a : Access) (apiVersion kind : String) : IO Resource := do
  if let some r := typed.find? fun r => r.apiVersion == apiVersion && r.kind == kind then
    return r
  match (← resourcesOf a apiVersion).find? (·.kind == kind) with
  | some r => return r
  | none   => throw (IO.userError s!"kubernetes {a.label}: the API server serves no \
{kind} in {apiVersion}")

/-- The resource an address's `<kind>[.<group>]` segment names, at the
    group's preferred version — for a delete or a read addressed by name
    alone, which has no `apiVersion` to go on. -/
def resourceOfSegment (a : Access) (kindSeg : String) : IO Resource := do
  if let some r := typed.find? (·.kindSegment == kindSeg) then return r
  let (kindLower, group) := match kindSeg.splitOn "." with
    | k :: g@(_ :: _) => (k, ".".intercalate g)
    | _               => (kindSeg, "")
  let version ← if group.isEmpty then pure "v1" else do
    let doc ← call a "GET" s!"/apis/{group}"
    match (doc.lookup "preferredVersion").bind (stringField · "groupVersion") with
    | some gv => pure gv
    | none    => throw (IO.userError s!"kubernetes {a.label}: API group {group} has no \
preferred version")
  match (← resourcesOf a version).find? (·.kind.toLower == kindLower) with
  | some r => return r
  | none   => throw (IO.userError s!"kubernetes {a.label}: no resource of kind \
'{kindSeg}' is served")

/-- Every group-version the server offers, core first, at each group's
    preferred version. -/
def groupVersions (a : Access) : IO (List String) := do
  let core := stringArrayField (← call a "GET" "/api") "versions"
  let groups := arrayField (← call a "GET" "/apis") "groups"
  let named := groups.filterMap fun g =>
    (g.lookup "preferredVersion").bind (stringField · "groupVersion")
  return core ++ named

/-- The path of one object. -/
def objectPath (r : Resource) (ns name : String) : String :=
  if r.namespaced then s!"{r.root}/namespaces/{ns}/{r.plural}/{name}"
  else s!"{r.root}/{r.plural}/{name}"

-- ────────────────────────────────────────────────────────────────────
-- Objects
-- ────────────────────────────────────────────────────────────────────

/-- An object found by a scan: its address and its labels. -/
structure Found where
  name   : Infra.Specs.ObjectName
  uid    : String
  labels : List (String × String)

/-- Every object carrying the label `key` (any value), across every
    namespace and every listable, deletable resource — except those this
    fleet must never claim as undeclared:

    * **objects with an owner** (`ownerReferences`): a controller's child —
      a ReplicaSet, a pod, an EndpointSlice — is its parent's, whatever its
      labels say;
    * **PersistentVolumeClaims**: a StatefulSet's claim carries the marker
      from its template (so it says whose it is), and infra never deletes
      one (`docs/kubernetes.md`, hard edge 5);
    * **Events**, which are the server's.

    A group-version whose discovery answers `503` — an aggregated API whose
    backing service is down — is skipped with a note on stderr rather than
    failing every plan; any other failure raises. -/
def listLabelled (a : Access) (cluster key : String) : IO (List Found) := do
  let mut out : List Found := []
  for gv in ← groupVersions a do
    let resources ← match ← (resourcesOf a gv).toBaseIO with
      | .ok rs => pure rs
      | .error e =>
        if ((toString e).splitOn "HTTP 503").length > 1 then
          IO.eprintln s!"note: kubernetes {a.label}: {gv} is unavailable (503), so it is not \
scanned for objects carrying this fleet's marker"
          pure []
        else throw e
    for r in resources do
      if r.apiVersion == "v1" && (r.plural == "persistentvolumeclaims" || r.plural == "events") then
        continue
      if r.plural == "events" then continue
      let mut token : Option String := none
      for _ in [0:1000] do
        let page ← call a "GET" s!"{r.root}/{r.plural}"
          ([("labelSelector", some key), ("limit", some "500")]
            ++ (token.map fun t => [("continue", some t)]).getD [])
        for item in arrayField page "items" do
          let md := (item.lookup "metadata").getD .null
          if !(arrayField md "ownerReferences").isEmpty then continue
          match stringField md "name" with
          | none => pure ()
          | some nm =>
            let labels := match md.lookup "labels" with
              | some (.object fs) => fs.filterMap fun (k, v) => v.asString.map (k, ·)
              | _ => []
            out := out ++ [{ name := { cluster, kind := r.kindSegment, name := nm
                                       ns := if r.namespaced then (stringField md "namespace").getD "default"
                                             else "_" }
                             uid := (stringField md "uid").getD "", labels }]
        token := (page.lookup "metadata").bind (stringField · "continue") |>.filter (!·.isEmpty)
        if token.isNone then break
  return out

/-- Server-side apply: create the object if absent, and otherwise make this
    field manager's fields exactly the manifest's — removing a field infra set
    before and no longer declares, which a merge patch would leave behind.
    `force` takes over fields another manager holds; the object is this
    fleet's (its marker was checked before anything reaches here). -/
def apply (a : Access) (r : Resource) (ns name : String) (manifest : Value) : IO Value :=
  call a "PATCH" (objectPath r ns name)
    [("fieldManager", some "infra"), ("force", some "true")]
    "application/apply-patch+yaml" (some manifest)

/-- Delete, letting the garbage collector remove the object's children in the
    background. Already gone is success. -/
def delete (a : Access) (r : Resource) (ns name : String) : IO Unit := do
  let resp ← send a "DELETE" (objectPath r ns name) []
    "application/json" (some (.object [("propagationPolicy", .string "Background")]))
  let status := resp.statusCode.statusCode
  unless (200 ≤ status && status ≤ 299) || status == 404 do
    throw (IO.userError s!"{label a "DELETE" (objectPath r ns name)}: \
{toString (Http.describeError status (Http.bodyText resp))}")

/-- A JSON merge patch — for removing one label, and nothing else. -/
def mergePatch (a : Access) (r : Resource) (ns name : String) (patch : Value) : IO Unit := do
  discard <| call a "PATCH" (objectPath r ns name) [] "application/merge-patch+json" (some patch)

end Infra.Providers.Kube
