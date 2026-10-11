import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage
import Infra.Core.Ownership
import Infra.Providers.Marker

/-
  Serverless compute, from a container image.

  Two unrelated APIs, and the container-image decision picks which service on
  each side:

    * AWS Lambda with `PackageType=Image`, over REST-JSON.
    * Scaleway Serverless **Containers** — not Functions. Functions takes a
      runtime plus a code archive; Containers takes a registry image, which is
      what makes the two clouds comparable at all.

  ## Consequences of the image model

  Neither service reports a `runtime` — it is baked into the image — so the
  spec's `runtime` is advisory and never compared. Each cloud needs one thing
  the other has no concept of: Lambda an execution role, Containers a
  namespace. Both are optional in the spec and raise a named error here when
  the cloud that needs one does not get it.
-/

namespace Infra.Providers.Kinds.Compute

open Infra.Core
open Infra.Specs
open Infra.Providers
open Infra.Providers.Aws
open Infra.Providers.JsonRead
open Data.Json (Value)

/-- Render environment variables as a JSON object. -/
private def envObject (env : List (String × String)) : Value :=
  .object (env.map fun (k, v) => (k, .string v))

/-- Read an environment map back. -/
private def envOf (v : Value) : List (String × String) :=
  match v with
  | .object fields => fields.filterMap fun (k, x) =>
      match x with
      | .string s => some (k, s)
      | _         => none
  | _ => []

-- ══════════════════════════════════════════════════════════════
-- AWS Lambda
-- ══════════════════════════════════════════════════════════════

namespace Lambda

private def base : String := "/2015-03-31/functions"

/-- Every function's name, every page: `Marker` in, `NextMarker` out, at
    most 50 a page whatever `MaxItems` says (botocore, `lambda/2015-03-31`,
    read 2026-09-29). -/
def list (creds : Credentials) (ep : Endpoint) : IO (List String) := do
  let fns ← Http.listAll "lambda functions" fun token => do
    let reply ← RestJson.call creds ep "GET" base
      ((token.map fun t => [("Marker", some t)]).getD [])
    return (arrayField reply "Functions", reply.lookupText "NextMarker")
  return fns.filterMap (Data.Json.Value.lookupText "FunctionName")

/-- Configuration and image, which live behind different calls. -/
def read (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Partial String × Partial Nat × Partial Nat × Partial (List (String × String))
        × String) := do
  let whole ← RestJson.call creds ep "GET" s!"{base}/{name}"
  let cfg := (whole.lookup "Configuration").getD whole
  let image := match whole.lookup "Code" with
    | some c => (c.lookupText "ResolvedImageUri").getD ((c.lookupText "ImageUri").getD "")
    | none   => ""
  let role := match cfg.lookupText "Role" with
    | some r => Partial.known r
    | none   => .unknown
  let memory := match cfg.lookupNat "MemorySize" with
    | some m => Partial.known m
    | none   => .unknown
  let timeout := match cfg.lookupNat "Timeout" with
    | some t => Partial.known t
    | none   => .unknown
  let env := match cfg.lookup "Environment" with
    | some e => match e.lookup "Variables" with
      | some vars => Partial.known (envOf vars)
      | none      => .known []
    | none => .unknown
  return (role, memory, timeout, env, image)

/-- Lambda cannot create a function without an execution role, and the API's
    own error for a missing one is unhelpful. -/
private def requireRole (name role : String) : IO String := do
  if role.isEmpty then
    throw (IO.userError
      s!"compute '{name}' on aws needs executionRole: Lambda requires an execution role ARN")
  return role

/-- A `GetFunction` reply's top-level `Tags` map, as pairs. -/
private def tagsOf (whole : Value) : List (String × String) :=
  match whole.lookup "Tags" with
  | some (.object fields) => fields.filterMap fun (k, v) =>
      match v with
      | .string s => some (k, s)
      | _         => none
  | _ => []

/-- `markerValue` is the ownership marker's value, written as a Lambda tag at
    create — `Tags` here is a `{key: value}` map, unlike every other kind's
    list-of-pairs, because that is the shape `CreateFunction` actually takes.
    See the 2026-09-10 incident in `AGENTS.md` for why this cannot be left
    unset. -/
def create (creds : Credentials) (ep : Endpoint) (name image role markerValue : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  discard <| RestJson.call creds ep "POST" base (payload := some (.object
    [ ("FunctionName", .string name)
    , ("PackageType", .string "Image")
    , ("Code", .object [("ImageUri", .string image)])
    , ("Role", .string (← requireRole name role))
    , ("MemorySize", .number (Float.ofNat memoryMb))
    , ("Timeout", .number (Float.ofNat timeoutSec))
    , ("Environment", .object [("Variables", envObject env)])
    , ("Tags", .object [(markerKey, .string markerValue)]) ]))

/-- Tags, for `Ownership.ownershipOf`. `ListFunctions` does not report them
    (see the module note on `.compute`'s coverage), but `GetFunction` — the
    same call `read` above already makes — does, as a top-level `Tags` map
    rather than a list of pairs. `createdAt` is left `none`, matching every
    other kind's first tranche. -/
def readOwnership (creds : Credentials) (ep : Endpoint) (name : String) :
    IO Evidence := do
  let whole ← RestJson.call creds ep "GET" s!"{base}/{name}"
  return .tags (tagsOf whole) none

/-- Take this fleet's ownership marker off the function, leaving its other
    tags.

    `UntagResource` is `DELETE /2017-03-31/tags/{ARN}?tagKeys=…` (Lambda API
    reference, `UntagResource`) and removes by key alone, so the value is
    checked first against a fresh `GetFunction` — which is also where the ARN
    comes from.

    The one call in this library whose path carries characters outside the
    unreserved set: an ARN's `:`s. SigV4 for every service but S3 signs each
    path segment URI-encoded *twice*, the wire carrying it encoded once —
    which is what an SDK sends (`arn%3Aaws%3Alambda…`). So the request is
    signed over the raw path (`Crypto.SigV4.canonicalUri` double-encodes it)
    and sent with the ARN segment encoded once. Every other call here has an
    all-unreserved path, where the two spellings coincide. -/
def releaseMarker (creds : Credentials) (ep : Endpoint) (name fleet : String) : IO Unit := do
  let whole ← RestJson.call creds ep "GET" s!"{base}/{name}"
  if (Marker.releaseTags fleet (tagsOf whole)).isSome then
    let cfg := (whole.lookup "Configuration").getD whole
    let some arn := cfg.lookupText "FunctionArn"
      | throw (IO.userError s!"lambda '{name}': GetFunction reported no FunctionArn")
    let signedPath := s!"/2017-03-31/tags/{arn}"
    let req ← Aws.signedRequest creds ep "DELETE" signedPath [("tagKeys", some markerKey)]
      (doubleEncodePath := true)
    let wirePath :=
      s!"/2017-03-31/tags/{Network.URI.escapeURIString Network.URI.isUnreserved arn}"
    match ← (Http.sendChecked { req with path := wirePath }).toBaseIO with
    | .ok _    => pure ()
    | .error e => throw (IO.userError s!"lambda DELETE {signedPath}: {e}")

/-- Configuration and code are separate endpoints, so an update is two calls. -/
def update (creds : Credentials) (ep : Endpoint) (name image role : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  discard <| RestJson.call creds ep "PUT" s!"{base}/{name}/configuration"
    (payload := some (.object
      [ ("Role", .string (← requireRole name role))
      , ("MemorySize", .number (Float.ofNat memoryMb))
      , ("Timeout", .number (Float.ofNat timeoutSec))
      , ("Environment", .object [("Variables", envObject env)]) ]))
  discard <| RestJson.call creds ep "PUT" s!"{base}/{name}/code"
    (payload := some (.object [("ImageUri", .string image)]))

def delete (creds : Credentials) (ep : Endpoint) (name : String) : IO Unit := do
  discard <| RestJson.call creds ep "DELETE" s!"{base}/{name}"

end Lambda

-- ══════════════════════════════════════════════════════════════
-- Scaleway Serverless Containers
-- ══════════════════════════════════════════════════════════════

namespace Containers

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "containers" "v1" region

private def listRaw (creds : Credentials) : IO (List (String × String × List String)) := do
  let containers ← Scaleway.listAll creds "scaleway containers"
      (prefix' creds.region ++ "/containers") "containers"
      (query := [("project_id", ← creds.requireProject)])
  return containers.filterMap fun c =>
    match c.lookupText "name", c.lookupText "id" with
    | some n, some i => some (n, i, stringArrayField c "tags")
    | _,      _      => none

def list (creds : Credentials) : IO (List String) := do
  return (← listRaw creds).map (·.1)

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway containers: no container named '{name}'")

/-- Tags, for `Ownership.ownershipOf`. `list`'s reply already carries each
    container's flat `tags: []string` — see `Scaleway.decodeTag`. -/
def readOwnership (creds : Credentials) (name : String) :
    IO Evidence := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return .tags (tags.map Scaleway.decodeTag) none
  | none              => return .unreadable

private def listNamespacesRaw (creds : Credentials) :
    IO (List (String × String × List String)) := do
  let namespaces ← Scaleway.listAll creds "scaleway namespaces"
      (prefix' creds.region ++ "/namespaces") "namespaces"
      (query := [("project_id", ← creds.requireProject)])
  return namespaces.filterMap fun n =>
    match n.lookupText "name", n.lookupText "id" with
    | some nm, some i => some (nm, i, stringArrayField n "tags")
    | _,       _      => none

/-- Resolve a namespace name to its id, which every container operation needs. -/
private def namespaceId (creds : Credentials) (name : String) : IO String := do
  if name.isEmpty then
    throw (IO.userError
      "compute on scaleway needs a namespace: Serverless Containers groups containers into one")
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway containers: no namespace named '{name}'")

/-- Tags, for `Ownership.ownershipOf`, on the namespace rather than a
    container in it. This is the kind directly implicated in the 2026-09-10
    incident: `deleteNamespace` cascades Scaleway-side to every container the
    namespace holds, so a namespace claimed by name alone can take an
    unmanaged sibling container down with it. -/
def readNamespaceOwnership (creds : Credentials) (name : String) :
    IO Evidence := do
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return .tags (tags.map Scaleway.decodeTag) none
  | none              => return .unreadable

/-- Public alias of `namespaceId`, for the namespace kind's own operations. -/
def namespaceIdOfName (creds : Credentials) (name : String) : IO String :=
  namespaceId creds name

def read (creds : Credentials) (name : String) :
    IO (Partial Nat × Partial Nat × Partial (List (String × String)) × String) := do
  let id ← requireId creds name
  let c ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/containers/{id}")
  let memory := match c.lookupNat "memory_limit_bytes" with
    | some m => Partial.known (m / 1000000)
    | none   => .unknown
  let timeout := match c.lookupText "timeout" with
    | some duration => match (duration.dropEnd 1).toString.toNat? with
      | some seconds => Partial.known seconds
      | none => .unknown
    | none => .unknown
  let env := match c.lookup "environment_variables" with
    | some e => Partial.known (envOf e)
    | none   => .unknown
  return (memory, timeout, env, (c.lookupText "image").getD "")

/-- `markerValue` is written as a flat tag (`Scaleway.encodeTag`) at create —
    see the 2026-09-10 incident in `AGENTS.md`. -/
def create (creds : Credentials) (name image ns markerValue : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  let nsId ← namespaceId creds ns
  discard <| Scaleway.call creds "POST" (prefix' creds.region ++ "/containers")
    (payload := some (.object
      [ ("namespace_id", .string nsId)
      , ("name", .string name)
      , ("image", .string image)
      , ("memory_limit_bytes", .number (Float.ofNat (memoryMb * 1000000)))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))

def update (creds : Credentials) (name image : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/containers/{id}")
    (payload := some (.object
      [ ("image", .string image)
      , ("memory_limit_bytes", .number (Float.ofNat (memoryMb * 1000000)))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env) ]))

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/containers/{id}")

/-- Take this fleet's ownership marker off a container (both `.compute` and
    `.scalewayContainer` on Scaleway), leaving every other tag byte-for-byte.

    `PATCH /containers/{id}` with the full new `tags` list — the endpoint
    `update` already uses; `UpdateContainerRequest` carries `Tags *[]string`
    (Scaleway SDK, `api/container/v1beta1`) and a list replaces the old one.
    Only `tags` is sent, and `redeploy` is not, so nothing is rolled out. -/
def releaseMarker (creds : Credentials) (name fleet : String) : IO Unit := do
  match (← listRaw creds).find? (·.1 == name) with
  | none               => pure ()
  | some (_, id, tags) =>
    match Scaleway.dropTag (markerKey, fleet) tags with
    | none      => pure ()
    | some rest =>
      discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/containers/{id}")
        (payload := some (.object [("tags", .array (rest.map Value.string).toArray)]))

/-- The same for a containers namespace: `PATCH /namespaces/{id}` — the
    endpoint `updateNamespace` uses — with the full new `tags` list
    (`UpdateNamespaceRequest.Tags *[]string`, same SDK package). The
    description is not sent, so it stays. -/
def releaseNamespaceMarker (creds : Credentials) (name fleet : String) : IO Unit := do
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | none               => pure ()
  | some (_, id, tags) =>
    match Scaleway.dropTag (markerKey, fleet) tags with
    | none      => pure ()
    | some rest =>
      discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/namespaces/{id}")
        (payload := some (.object [("tags", .array (rest.map Value.string).toArray)]))

/-! ### The richer surface `.scalewayContainer` needs

  Everything below is additional to what the portable `.compute` kind's `list`/`read`/
  `create`/`update` above already use — it reuses their private helpers (`prefix'`,
  `listRaw`, `requireId`, `namespaceId`, `envObject`, `envOf`) rather than re-resolving
  names to ids a second way. `delete` above is already enough; there is nothing kind-specific
  to add to it.

  The v1 generated SDK (checked 2026-10-11) uses `image`, byte-valued memory,
  `mvcpu_limit`, duration strings and maps for both environment collections. -/

/-- Render secret-backed environment variables as a JSON map. Each value has already been
    read once by `Kinds.Secrets.fetchValue` and is passed straight through. -/
private def secretEnvObject (secretEnv : List (String × String)) : Value := envObject secretEnv

private def addFields (body : Value) (extra : List (String × Value)) : Value :=
  match body with
  | .object fields => .object (fields ++ extra)
  | _ => .object extra

def get (creds : Credentials) (name : String) : IO Value := do
  Scaleway.call creds "GET" (prefix' creds.region ++ s!"/containers/{← requireId creds name}")

def observedFromJson (c : Value) : ScalewayContainerObserved :=
  { handle := ⟨(c.lookupText "name").getD ""⟩
    url := ((c.lookupText "public_endpoint").getD "").replace "https://" ""
    containerId := (c.lookupText "id").getD ""
    privateUrl := (c.lookupText "private_endpoint").getD "" }

def accessFromJson (c : Value) : Option ScalewayAccess := do
  let publicEndpoint ← c.lookupBool "default_public_endpoint_enabled"
  -- Optional v1 fields are omitted, not necessarily emitted as JSON null.
  let privateValue := (c.lookup "private_endpoint").getD .null
  let networkValue := (c.lookup "private_network_id").getD .null
  let network ← match networkValue with
    | .null => some none
    | .string id => some (some id)
    | _ => none
  let privateEndpoint ← match privateValue with
    | .null => some false
    | .string url => some (!url.isEmpty)
    | _ => none
  return { privateNetworkId := network, publicEndpoint, privateEndpoint }

private def hasIngressBypass (creds : Credentials) (id : String) : IO Bool := do
  let domains ← Scaleway.listAll creds "container domains" (prefix' creds.region ++ "/domains") "domains"
    (query := [("project_id", ← creds.requireProject), ("container_id", some id)])
  let triggers ← Scaleway.listAll creds "container triggers" (prefix' creds.region ++ "/triggers") "triggers"
    (query := [("project_id", ← creds.requireProject), ("container_id", some id)])
  return (domains ++ triggers).any fun item => item.lookupText "container_id" == some id

private def requireNoIngressBypass (creds : Credentials) (id name : String) : IO Unit := do
  if ← hasIngressBypass creds id then
    throw (IO.userError s!"scaleway container '{name}': a custom domain or trigger bypasses private-only access; remove it before applying")

private def checkNetwork (creds : Credentials) (id : String) : IO Unit := do
  Scaleway.requirePrivateNetwork creds id

private def privateHost (url : String) : Option String := do
  if !url.startsWith "http://" then none else
  let host := (url.drop 7).toString
  if host.isEmpty || !host.endsWith ".internal" ||
      !host.toList.all (fun c => c.isAlphanum || c == '-' || c == '.') then none
  else some host

private def proxyHost (creds : Credentials) (proxy : ScalewayContainerProxy Resolved)
    (network : Option String) : IO String := do
  let upstream ← get creds proxy.backend.raw
  let some access := accessFromJson upstream
    | throw (IO.userError "proxy backend endpoint policy could not be read")
  unless access.privateEndpoint && !access.publicEndpoint &&
      access.privateNetworkId == network && network.isSome do
    throw (IO.userError "proxy backend must be private-only on the same Private Network")
  unless upstream.lookupText "privacy" == some "public" do
    throw (IO.userError "proxy backend requires Scaleway IAM credentials, which this proxy does not inject")
  requireNoIngressBypass creds (upstream.lookupText "id" |>.getD "") proxy.backend.raw
  let some host := privateHost ((upstream.lookupText "private_endpoint").getD "")
    | throw (IO.userError "proxy backend has no usable native private HTTP endpoint")
  return host

def proxyMetadata (proxy : ScalewayContainerProxy Resolved) : String :=
  Data.Json.Encode.encode (.object
    [("backend", .string proxy.backend.raw),
     ("allowedCidrs", .array (proxy.allowedCidrs.map Value.string).toArray),
     ("pathPrefix", .string proxy.pathPrefix)])

private def parseProxy (text : String) : Option (ScalewayContainerProxy Resolved) := do
  let json ← (Data.Json.Decode.decode text).toOption
  let backend ← json.lookupText "backend"
  let pathPrefix ← json.lookupText "pathPrefix"
  let proxy : ScalewayContainerProxy Resolved :=
    { backend := ⟨backend⟩, allowedCidrs := stringArrayField json "allowedCidrs", pathPrefix }
  if backend.isEmpty || proxy.problem.isSome then none else some proxy

/-- Metadata never substitutes for actual enforcement: config, command, image,
    privacy and HTTPS readback must agree, and current upstream DNS is checked.
    Malformed/stale policy reads as no enforced proxy, so the plan repairs it. -/
def proxyFromRuntime (c : Value) (host : String) : Option (ScalewayContainerProxy Resolved) := do
  let environment := (c.lookup "environment_variables").getD (.object [])
  let text ← environment.lookupText "INFRA_PROXY_POLICY"
  let proxy ← parseProxy text
  if !isNginxImage ((c.lookupText "image").getD "") ||
      stringArrayField c "command" != nginxProxyCommand || stringArrayField c "args" != nginxProxyArgs ||
      c.lookupText "privacy" != some "public" || c.lookupBool "https_connections_only" != some true then
    none
  else
    let expected := nginxProxyConfig ((c.lookupNat "port").getD 8080) proxy.allowedCidrs proxy.pathPrefix host
    if environment.lookupText "NGINX_CONFIG" == some expected then some proxy else none

private def readProxy (creds : Credentials) (c : Value) : IO (Option (ScalewayContainerProxy Resolved)) := do
  let environment := (c.lookup "environment_variables").getD (.object [])
  let some text := environment.lookupText "INFRA_PROXY_POLICY" | return none
  let some proxy := parseProxy text | return none
  if !((← listRaw creds).any fun entry => entry.1 == proxy.backend.raw) then return none
  let upstream ← get creds proxy.backend.raw
  let some upstreamAccess := accessFromJson upstream | return none
  if upstreamAccess.publicEndpoint || !upstreamAccess.privateEndpoint ||
      upstreamAccess.privateNetworkId != (accessFromJson c |>.bind (·.privateNetworkId)) ||
      upstream.lookupText "privacy" != some "public" ||
      (← hasIngressBypass creds ((upstream.lookupText "id").getD "")) then return none
  let some host := privateHost ((upstream.lookupText "private_endpoint").getD "") | return none
  return proxyFromRuntime c host

private def waitReady (creds : Credentials) (id : String) : IO Value := do
  let start ← IO.monoMsNow
  repeat
    let current ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/containers/{id}")
    match current.lookupText "status" with
    | some "ready" => return current
    | some "error" => throw (IO.userError s!"container deployment failed: {(current.lookupText "error_message").getD "unknown error"}")
    | _ => pure ()
    if (← IO.monoMsNow) - start > 900000 then throw (IO.userError "container did not become ready within 15 minutes")
    IO.sleep 2000

/-- Pure native fields shared by create/update; none omits rather than resets.
    The POST request includes visibility immediately, before any secrets serve. -/
def nativeFields (access : Option ScalewayAccess) (privacy : Option ScalewayContainerPrivacy)
    (httpsOnly : Option Bool) (command args : Option (List String)) (creating : Bool := false) : List (String × Value) :=
  (access.map (fun policy =>
    [("private_network_id", .string (policy.privateNetworkId.getD "")),
     ("enable_default_public_endpoint", .bool policy.publicEndpoint),
     ("enable_private_endpoint", .bool policy.privateEndpoint)])).getD [] ++
  (privacy.map fun p => [("privacy", .string p.apiValue)]).getD [] ++
  (httpsOnly.map fun only => [(if creating then "https_connections_only" else "https_connection_only", .bool only)]).getD [] ++
  (command.map fun values => [("command", .array (values.map Value.string).toArray)]).getD [] ++
  (args.map fun values => [("args", .array (values.map Value.string).toArray)]).getD []

private def payload (creds : Credentials) (spec : ProviderSpec .scalewayContainer)
    (secretEnv : List (String × String)) (clearingProxy : Bool := false) (creating : Bool := false) : IO Value := do
  if let some access := spec.access then
    if let some problem := access.problem then throw (IO.userError problem)
    if let some network := access.privateNetworkId then checkNetwork creds network
  let mut environment := spec.env
  let mut command := spec.command
  let mut args := spec.args
  let mut privacy := spec.privacy
  let mut httpsOnly := spec.httpsOnly
  match spec.proxy with
  | none =>
    if clearingProxy then
      command := command.orElse (fun _ => some [])
      args := args.orElse (fun _ => some [])
  | some proxy =>
    if let some problem := proxy.problem then throw (IO.userError problem)
    unless isNginxImage spec.image && spec.port > 0 && spec.port < 65536 do
      throw (IO.userError "managed proxy requires official NGINX and a bounded port")
    unless command.isNone && args.isNone && privacy != some .authenticated && httpsOnly != some false do
      throw (IO.userError "managed proxy owns command/args and requires public privacy and HTTPS")
    let some access := spec.access | throw (IO.userError "managed proxy requires explicit access")
    unless access.publicEndpoint && access.privateNetworkId.isSome do
      throw (IO.userError "managed proxy requires a public endpoint and Private Network")
    if environment.any (fun pair => ["NGINX_CONFIG", "INFRA_PROXY_POLICY"].contains pair.1) then
      throw (IO.userError "managed proxy reserves NGINX_CONFIG and INFRA_PROXY_POLICY")
    let host ← proxyHost creds proxy access.privateNetworkId
    environment := environment ++
      [("INFRA_PROXY_POLICY", proxyMetadata proxy),
       ("NGINX_CONFIG", nginxProxyConfig spec.port proxy.allowedCidrs proxy.pathPrefix host)]
    command := some nginxProxyCommand
    args := some nginxProxyArgs
    privacy := some .openAccess
    httpsOnly := some true
  return .object
    ([("image", .string spec.image), ("port", .number (Float.ofNat spec.port)),
      ("min_scale", .number (Float.ofNat spec.minScale)), ("max_scale", .number (Float.ofNat spec.maxScale)),
      ("memory_limit_bytes", .number (Float.ofNat (spec.memoryMb * 1000000))),
      ("mvcpu_limit", .number (Float.ofNat spec.cpuLimit)), ("timeout", .string s!"{spec.timeoutSec}s"),
      ("environment_variables", envObject environment), ("secret_environment_variables", secretEnvObject secretEnv)] ++
     nativeFields spec.access privacy httpsOnly command args creating)

/-- The domain alongside the name, which `list` above does not need. -/
def listFull (creds : Credentials) : IO (List ScalewayContainerObserved) := do
  let containers ← Scaleway.listAll creds "scaleway containers"
      (prefix' creds.region ++ "/containers") "containers"
      (query := [("project_id", ← creds.requireProject)])
  return containers.filterMap fun c =>
    if (c.lookupText "name").isSome then some (observedFromJson c) else none

/-- Every namespace, as `(name, id)`. -/
def listNamespaces (creds : Credentials) : IO (List (String × String)) := do
  return (← listNamespacesRaw creds).map fun (n, i, _) => (n, i)

/-- Every field `.scalewayContainer` can report, beyond what `read` above needs for the
    portable `.compute` kind. -/
def readFull (creds : Credentials) (name : String) : IO (Reported .scalewayContainer) := do
  let id ← requireId creds name
  let c ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/containers/{id}")
  let optNat (field : String) : Partial Nat :=
    match c.lookupNat field with
    | some n => .known n
    | none   => .unknown
  let proxy ← readProxy creds c
  let proxy := if ((c.lookup "environment_variables").bind (·.lookup "INFRA_PROXY_POLICY")).isSome then
      proxy.orElse (fun _ => some { backend := ⟨""⟩, allowedCidrs := [], pathPrefix := "" })
    else none
  let env := match c.lookup "environment_variables" with
    | some e => Partial.known ((envOf e).filter fun pair =>
        !(e.lookup "INFRA_PROXY_POLICY").isSome || !["NGINX_CONFIG", "INFRA_PROXY_POLICY"].contains pair.1)
    | none => .unknown
  -- The namespace, resolved from its id back to the name a fleet keys on.
  --
  -- This used to be reported as `""` by the caller, and the consequence was
  -- not a missing field but a **perpetual replace**: `Divergent
  -- .scalewayContainer` compares `namespace` with `divergesReq … .forcesReplace`,
  -- which has no `unknown` escape, so a declared namespace against an empty
  -- one diverged on every single pull. The live test never converged and
  -- reported `REPLACE … ci-tests-infra-ctr` for as long as it was allowed to
  -- poll. Same trap as `S3BucketSpec.region` before it.
  --
  -- Reporting it truthfully is the fix rather than excluding it from the
  -- table: a container genuinely cannot move namespace, so a *changed*
  -- declaration really does need a replace, and that is worth detecting.
  let nsName ← match c.lookupText "namespace_id" with
    | none    => pure ""
    | some id => do
      match (← listNamespaces creds).find? (·.2 == id) with
      | some (n, _) => pure n
      -- A namespace the credential cannot list is not the same as no
      -- namespace, but there is nothing truer to say from here.
      | none        => pure ""
  let some access := accessFromJson c | throw (IO.userError "container API did not report endpoint visibility")
  let access ← if !access.publicEndpoint && (← hasIngressBypass creds id) then
      pure { access with publicEndpoint := true }
    else pure access
  let privacy := match c.lookupText "privacy" with
    | some "public" => Partial.known (some ScalewayContainerPrivacy.openAccess)
    | some "private" => Partial.known (some ScalewayContainerPrivacy.authenticated)
    | _ => .unknown
  let timeout := match (c.lookupText "timeout").bind (fun duration => (duration.dropEnd 1).toString.toNat?) with
    | some seconds => Partial.known seconds
    | none => .unknown
  return { name, namespace' := ⟨nsName⟩, image := (c.lookupText "image").getD ""
           port := optNat "port", minScale := optNat "min_scale", maxScale := optNat "max_scale"
           memoryMb := (optNat "memory_limit_bytes").map (· / 1000000)
           cpuLimit := optNat "mvcpu_limit", timeoutSec := timeout, env
           secretEnv := .unknown, migrations := .unknown, access := .known (some access), privacy
           httpsOnly := (c.lookupBool "https_connections_only").map (fun b => Partial.known (some b)) |>.getD .unknown
           command := .known (some (stringArrayField c "command")), args := .known (some (stringArrayField c "args"))
           proxy := .known proxy }

/-- `markerValue` is written as a flat tag (`Scaleway.encodeTag`) at create —
    see the 2026-09-10 incident in `AGENTS.md`. This is the exact create path
    `.scalewayContainer` uses, i.e. the resource kind involved in that
    incident. -/
def createFull (creds : Credentials) (spec : ProviderSpec .scalewayContainer) (markerValue : String)
    (secretEnv : List (String × String)) : IO ScalewayContainerObserved := do
  let nsHandle : Handle .scalewayContainerNamespace := spec.namespace'
  let nsId ← namespaceId creds nsHandle.raw
  let body ← payload creds spec secretEnv (creating := true)
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/containers")
    (payload := some (addFields body [("namespace_id", .string nsId), ("name", .string spec.name),
      ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))
  let some id := reply.lookupText "id" | throw (IO.userError "container create reply has no id")
  return observedFromJson (← waitReady creds id)

def updateFull (creds : Credentials) (spec : ProviderSpec .scalewayContainer)
    (secretEnv : List (String × String)) : IO ScalewayContainerObserved := do
  let id ← requireId creds spec.name
  if spec.access.any (fun policy => !policy.publicEndpoint) then requireNoIngressBypass creds id spec.name
  let current ← get creds spec.name
  let clearing := ((current.lookup "environment_variables").bind (·.lookup "INFRA_PROXY_POLICY")).isSome
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/containers/{id}")
    (payload := some (← payload creds spec secretEnv clearing))
  return observedFromJson (← waitReady creds id)

/-! ### Namespace CRUD

  Functions and Containers each have their own namespace product at their own
  prefix, so these are written once per product rather than shared. What
  differs is only the prefix and what the response carries. -/

/-- One namespace's description, by name. -/
def readNamespace (creds : Credentials) (name : String) : IO (Partial String) := do
  let namespaces ← Scaleway.listAll creds "scaleway namespaces"
      (prefix' creds.region ++ "/namespaces") "namespaces"
      (query := [("project_id", ← creds.requireProject)])
  match namespaces.find? (fun n => n.lookupText "name" == some name) with
  | none   => return .unknown
  | some n => return match n.lookupText "description" with
                     | some d => .known d
                     | none   => .known ""

/-- Create a namespace. Needs the project id, like every Scaleway create.
    `markerValue` is written as a flat tag (`Scaleway.encodeTag`) — this is
    the resource whose unconditional `deleteNamespace` cascade caused the
    2026-09-10 incident in `AGENTS.md`; the marker here is what lets a future
    `push` refuse to claim a pre-existing namespace by name alone. -/
def createNamespace (creds : Credentials) (name description markerValue : String) :
    IO (String × String) := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/namespaces")
    (payload := some (.object
      [ ("name", .string name), ("description", .string description)
      , ("project_id", .string project)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))
  return ((reply.lookupText "id").getD "",
          (reply.lookupText "registry_endpoint").getD "")

def updateNamespace (creds : Credentials) (name description : String) : IO Unit := do
  let id ← namespaceIdOfName creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/namespaces/{id}")
    (payload := some (.object [("description", .string description)]))

def deleteNamespace (creds : Credentials) (name : String) : IO Unit := do
  let id ← namespaceIdOfName creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/namespaces/{id}")

end Containers

-- ══════════════════════════════════════════════════════════════
-- Scaleway Serverless Functions (the provider-local kind)
-- ══════════════════════════════════════════════════════════════

/-
  `.scalewayFunction` is Serverless **Functions**, not Containers: it carries a
  runtime and deploys code, which is the distinction that makes it a separate,
  provider-local kind rather than a second way to spell `.compute`.
-/

namespace Functions

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "functions" "v1beta1" region

private def listRaw (creds : Credentials) : IO (List (String × String × List String)) := do
  let functions ← Scaleway.listAll creds "scaleway functions"
      (prefix' creds.region ++ "/functions") "functions"
      (query := [("project_id", ← creds.requireProject)])
  return functions.filterMap fun f =>
    match f.lookupText "name", f.lookupText "id" with
    | some n, some i => some (n, i, stringArrayField f "tags")
    | _,      _      => none

def list (creds : Credentials) : IO (List (String × String)) := do
  let functions ← Scaleway.listAll creds "scaleway functions"
      (prefix' creds.region ++ "/functions") "functions"
      (query := [("project_id", ← creds.requireProject)])
  return functions.filterMap fun f =>
    match f.lookupText "name" with
    | some n => some (n, (f.lookupText "domain_name").getD "")
    | none   => none

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway functions: no function named '{name}'")

/-- Tags, for `Ownership.ownershipOf`. -/
def readOwnership (creds : Credentials) (name : String) :
    IO Evidence := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return .tags (tags.map Scaleway.decodeTag) none
  | none              => return .unreadable

private def listNamespacesRaw (creds : Credentials) :
    IO (List (String × String × List String)) := do
  let namespaces ← Scaleway.listAll creds "scaleway namespaces"
      (prefix' creds.region ++ "/namespaces") "namespaces"
      (query := [("project_id", ← creds.requireProject)])
  return namespaces.filterMap fun n =>
    match n.lookupText "name", n.lookupText "id" with
    | some nm, some i => some (nm, i, stringArrayField n "tags")
    | _,       _      => none

/-- The namespace a function belongs to, resolved from its name. -/
private def namespaceIdOf (creds : Credentials) (name : String) : IO String := do
  if name.isEmpty then
    throw (IO.userError "scalewayFunction needs a namespace")
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway functions: no namespace named '{name}'")

/-- Public alias of `namespaceIdOf`, for the namespace kind's own operations. -/
def namespaceIdOfName (creds : Credentials) (name : String) : IO String :=
  namespaceIdOf creds name

/-- Every namespace, as `(name, id)`. -/
def listNamespaces (creds : Credentials) : IO (List (String × String)) := do
  return (← listNamespacesRaw creds).map fun (n, i, _) => (n, i)

/-- Tags, for `Ownership.ownershipOf`, on the namespace. -/
def readNamespaceOwnership (creds : Credentials) (name : String) :
    IO Evidence := do
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return .tags (tags.map Scaleway.decodeTag) none
  | none              => return .unreadable

def read (creds : Credentials) (name : String) :
    IO (String × Partial (Option String) × String) := do
  let id ← requireId creds name
  let f ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/functions/{id}")
  let runtime := (f.lookupText "runtime").getD ""
  -- The bucket comes back as the environment variable it was written into.
  let bucket := match f.lookup "environment_variables" with
    | some e => Partial.known (e.lookupText "SOURCE_BUCKET")
    | none   => .unknown
  -- The namespace, resolved from its id. Reported for the same reason
  -- `Containers.readFull` reports it: `Divergent .scalewayFunction` compares
  -- `namespace` with `forcesReplace`, which has no `unknown` escape, so
  -- blanking it makes every pull propose a replace and the fleet never
  -- converges. The container had exactly that bug and it cost a
  -- twelve-minute CI timeout to see.
  let nsName ← match f.lookupText "namespace_id" with
    | none    => pure ""
    | some nsId => do
      match (← listNamespaces creds).find? (·.2 == nsId) with
      | some (n, _) => pure n
      | none        => pure ""
  return (runtime, bucket, nsName)

/-- The referenced bucket is passed as an environment variable, which is what
    makes the cross-cloud dependency edge do real work. -/
private def envFor (bucket : Option (Handle .s3Bucket)) : Value :=
  match bucket with
  | some h => .object [("SOURCE_BUCKET", .string h.raw)]
  | none   => .object []

/-- The runtime names this region will accept.

    Scaleway spells them without punctuation — `python311`, `node22`, `go123` —
    so `python3.12` is rejected as `invalid runtime`, an error that says
    nothing about what *would* work. The set changes as versions come and go,
    which is why it is fetched rather than hardcoded. -/
def listRuntimes (creds : Credentials) : IO (List String) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/runtimes")
  return (arrayField reply "runtimes").filterMap fun r => r.lookupText "name"

def create (creds : Credentials) (name runtime ns handler markerValue : String)
    (bucket : Option (Handle .s3Bucket)) : IO String := do
  let nsId ← namespaceIdOf creds ns
  let attempt ← (Scaleway.call creds "POST" (prefix' creds.region ++ "/functions")
    (payload := some (.object
      [ ("namespace_id", .string nsId)
      , ("name", .string name)
      , ("runtime", .string runtime)
      -- Scaleway names the entry point `<file>.<function>` and requires it at
      -- create; the archive `deployCode` uploads has to contain that file.
      , ("handler", .string handler)
      , ("environment_variables", envFor bucket)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))).toBaseIO
  match attempt with
  | .ok reply => return (reply.lookupText "domain_name").getD ""
  | .error e =>
    -- "invalid runtime" is the one refusal here with a knowable answer, so
    -- ask for it rather than making the operator go and look.
    if ((toString e).splitOn "runtime").length > 1 then
      let available ← (listRuntimes creds).toBaseIO
      let hint := match available with
        | .ok (_ :: _) =>
          s!"; {creds.region} accepts: {String.intercalate ", " (available.toOption.getD [])}"
        | _ => ""
      throw (IO.userError s!"{e}: runtime '{runtime}' is not one this region offers{hint}")
    else
      throw e

/-- Split an absolute `https://` URL into host, path and query.

    Needed because the upload target is *presigned*: Scaleway hands back a
    complete URL with its signature in the query string, and it must be used
    exactly as given. `Scaleway.call` cannot serve it — that helper pins the
    host and attaches the auth token, and adding either to a presigned URL
    invalidates the signature it already carries.

    Deliberately not a general URL parser. It handles what this one call
    produces and refuses anything else, which is the safe direction: a URL
    shape this does not understand raises rather than being half-parsed into a
    request that goes somewhere unintended. -/
private def splitUrl (url : String) : IO (String × String × String) := do
  let rest ← match url.dropPrefix? "https://" with
    | some r => pure r.toString
    | none   => throw (IO.userError
        s!"function upload: expected an https:// URL, got '{url}'")
  let (hostPart, afterHost) := match rest.splitOn "/" with
    | h :: tl => (h, "/" ++ String.intercalate "/" tl)
    | []      => (rest, "/")
  match afterHost.splitOn "?" with
  | [path]     => return (hostPart, path, "")
  -- The query is carried as one opaque string, never parsed into parameters:
  -- the signature covers the exact encoded bytes in the exact order, so
  -- splitting and re-rendering it would break it. That is what
  -- `Http.requestPresigned` exists for.
  | path :: qs => return (hostPart, path, String.intercalate "?" qs)
  | []         => return (hostPart, afterHost, "")

/-- Deploy source code to a function: ask for a presigned URL, PUT the archive
    at it, then tell Scaleway to deploy what was uploaded.

    Three calls, and they have to be in this order. The function must already
    exist (`create` above), because the upload URL is issued for its id.

    `content_length` is required on the first call and must match the archive
    exactly. Scaleway signs the URL for that length, so a mismatch is refused
    at the PUT with a signature error that says nothing about length. -/
def deployCode (creds : Credentials) (name : String) (zip : ByteArray) :
    IO Unit := do
  let id ← requireId creds name
  let reply ← Scaleway.call creds "GET"
    (prefix' creds.region ++ s!"/functions/{id}/upload-url")
    (query := [("content_length", some (toString zip.size))])
  let some url := reply.lookupText "url"
    | throw (IO.userError
        s!"function '{name}': upload-url reply carried no 'url'")
  let (host, path, queryString) ← splitUrl url
  -- The presigned PUT. No auth header: the signature in the query string *is*
  -- the authorisation, and `X-Auth-Token` alongside it is what Scaleway
  -- rejects.
  discard <| match ← (Http.sendChecked (Http.requestPresigned "PUT" host path
      queryString [("Content-Type", "application/octet-stream")]
      (some zip))).toBaseIO with
    | .ok r    => pure r
    | .error e => throw (IO.userError s!"function '{name}': uploading \
{zip.size} bytes to the presigned URL failed: {e}")
  discard <| Scaleway.call creds "POST"
    (prefix' creds.region ++ s!"/functions/{id}/deploy")

def update (creds : Credentials) (name : String)
    (bucket : Option (Handle .s3Bucket)) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/functions/{id}")
    (payload := some (.object [("environment_variables", envFor bucket)]))

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/functions/{id}")

/-- Take this fleet's ownership marker off a function, leaving every other tag
    byte-for-byte.

    `PATCH /functions/{id}` with the full new `tags` list — the endpoint
    `update` already uses; `UpdateFunctionRequest` carries `Tags *[]string`
    (Scaleway SDK, `api/function/v1beta1`) and a list replaces the old one.
    Only `tags` is sent, and `redeploy` is not. -/
def releaseMarker (creds : Credentials) (name fleet : String) : IO Unit := do
  match (← listRaw creds).find? (·.1 == name) with
  | none               => pure ()
  | some (_, id, tags) =>
    match Scaleway.dropTag (markerKey, fleet) tags with
    | none      => pure ()
    | some rest =>
      discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/functions/{id}")
        (payload := some (.object [("tags", .array (rest.map Value.string).toArray)]))

/-- The same for a functions namespace: `PATCH /namespaces/{id}` — the
    endpoint `updateNamespace` uses — with the full new `tags` list
    (`UpdateNamespaceRequest.Tags *[]string`, same SDK package). The
    description is not sent, so it stays. -/
def releaseNamespaceMarker (creds : Credentials) (name fleet : String) : IO Unit := do
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | none               => pure ()
  | some (_, id, tags) =>
    match Scaleway.dropTag (markerKey, fleet) tags with
    | none      => pure ()
    | some rest =>
      discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/namespaces/{id}")
        (payload := some (.object [("tags", .array (rest.map Value.string).toArray)]))

/-! ### Namespace CRUD

  Functions and Containers each have their own namespace product at their own
  prefix, so these are written once per product rather than shared. What
  differs is only the prefix and what the response carries. -/

/-- One namespace's description, by name. -/
def readNamespace (creds : Credentials) (name : String) : IO (Partial String) := do
  let namespaces ← Scaleway.listAll creds "scaleway namespaces"
      (prefix' creds.region ++ "/namespaces") "namespaces"
      (query := [("project_id", ← creds.requireProject)])
  match namespaces.find? (fun n => n.lookupText "name" == some name) with
  | none   => return .unknown
  | some n => return match n.lookupText "description" with
                     | some d => .known d
                     | none   => .known ""

/-- Create a namespace. Needs the project id, like every Scaleway create.
    `markerValue` is written as a flat tag (`Scaleway.encodeTag`) — this
    namespace's own `deleteNamespace` cascades to every function inside it the
    same way `Containers.deleteNamespace` does, so it needs the same marker to
    let a future `push` refuse to claim a pre-existing namespace by name
    alone. -/
def createNamespace (creds : Credentials) (name description markerValue : String) :
    IO (String × String) := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/namespaces")
    (payload := some (.object
      [ ("name", .string name), ("description", .string description)
      , ("project_id", .string project)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))
  return ((reply.lookupText "id").getD "",
          (reply.lookupText "registry_endpoint").getD "")

def updateNamespace (creds : Credentials) (name description : String) : IO Unit := do
  let id ← namespaceIdOfName creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/namespaces/{id}")
    (payload := some (.object [("description", .string description)]))

def deleteNamespace (creds : Credentials) (name : String) : IO Unit := do
  let id ← namespaceIdOfName creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/namespaces/{id}")

end Functions

end Infra.Providers.Kinds.Compute
