import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage
import Infra.Core.Ownership

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

def list (creds : Credentials) (ep : Endpoint) : IO (List String) := do
  let reply ← RestJson.call creds ep "GET" base
  return (arrayField reply "Functions").filterMap (stringField · "FunctionName")

/-- Configuration and image, which live behind different calls. -/
def read (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Partial String × Partial Nat × Partial Nat × Partial (List (String × String))
        × String) := do
  let whole ← RestJson.call creds ep "GET" s!"{base}/{name}"
  let cfg := (field whole "Configuration").getD whole
  let image := match field whole "Code" with
    | some c => (stringField c "ImageUri").getD ""
    | none   => ""
  let role := match stringField cfg "Role" with
    | some r => Partial.known r
    | none   => .unknown
  let memory := match natField cfg "MemorySize" with
    | some m => Partial.known m
    | none   => .unknown
  let timeout := match natField cfg "Timeout" with
    | some t => Partial.known t
    | none   => .unknown
  let env := match field cfg "Environment" with
    | some e => match field e "Variables" with
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
    IO (Option (List (String × String) × Option String)) := do
  let whole ← RestJson.call creds ep "GET" s!"{base}/{name}"
  let tags := match field whole "Tags" with
    | some (.object fields) => fields.filterMap fun (k, v) =>
        match v with
        | .string s => some (k, s)
        | _         => none
    | _ => []
  return some (tags, none)

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
  Scaleway.regionalPrefix "containers" "v1beta1" region

private def listRaw (creds : Credentials) : IO (List (String × String × List String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/containers")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "containers").filterMap fun c =>
    match stringField c "name", stringField c "id" with
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
    IO (Option (List (String × String) × Option String)) := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return some (tags.map Scaleway.decodeTag, none)
  | none               => return none

private def listNamespacesRaw (creds : Credentials) :
    IO (List (String × String × List String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "namespaces").filterMap fun n =>
    match stringField n "name", stringField n "id" with
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
    IO (Option (List (String × String) × Option String)) := do
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return some (tags.map Scaleway.decodeTag, none)
  | none               => return none

/-- Public alias of `namespaceId`, for the namespace kind's own operations. -/
def namespaceIdOfName (creds : Credentials) (name : String) : IO String :=
  namespaceId creds name

def read (creds : Credentials) (name : String) :
    IO (Partial Nat × Partial Nat × Partial (List (String × String)) × String) := do
  let id ← requireId creds name
  let c ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/containers/{id}")
  let memory := match natField c "memory_limit" with
    | some m => Partial.known m
    | none   => .unknown
  let timeout := match natField c "max_concurrency" with
    | some _ => match natField c "timeout" with
      | some t => Partial.known t
      | none   => .unknown
    | none => .unknown
  let env := match field c "environment_variables" with
    | some e => Partial.known (envOf e)
    | none   => .unknown
  return (memory, timeout, env, (stringField c "registry_image").getD "")

/-- `markerValue` is written as a flat tag (`Scaleway.encodeTag`) at create —
    see the 2026-09-10 incident in `AGENTS.md`. -/
def create (creds : Credentials) (name image ns markerValue : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  let nsId ← namespaceId creds ns
  discard <| Scaleway.call creds "POST" (prefix' creds.region ++ "/containers")
    (payload := some (.object
      [ ("namespace_id", .string nsId)
      , ("name", .string name)
      , ("registry_image", .string image)
      , ("memory_limit", .number (Float.ofNat memoryMb))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))

def update (creds : Credentials) (name image : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/containers/{id}")
    (payload := some (.object
      [ ("registry_image", .string image)
      , ("memory_limit", .number (Float.ofNat memoryMb))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env) ]))

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/containers/{id}")

/-! ### The richer surface `.scalewayContainer` needs

  Everything below is additional to what the portable `.compute` kind's `list`/`read`/
  `create`/`update` above already use — it reuses their private helpers (`prefix'`,
  `listRaw`, `requireId`, `namespaceId`, `envObject`, `envOf`) rather than re-resolving
  names to ids a second way. `delete` above is already enough; there is nothing kind-specific
  to add to it.

  **Unconfirmed against the real API**: `port`/`min_scale`/`max_scale`/`cpu_limit` follow the
  naming convention `memory_limit`/`timeout`/`environment_variables`/`registry_image` above
  already assume, but none of this has been checked against a real deployment — see
  `docs/providers.md`. Secret-bound environment variables are even less certain: this assumes
  Scaleway wants the plaintext value at `secret_environment_variables`, following the
  plaintext-at-set-time assumption `Kinds.Secrets.fetchValue` documents. -/

/-- Render secret-backed environment variables as a JSON array. Each value has already been
    read once by `Kinds.Secrets.fetchValue` and is passed straight through. -/
private def secretEnvArray (secretEnv : List (String × String)) : Value :=
  .array (secretEnv.map fun (k, v) => .object [("key", .string k), ("value", .string v)]).toArray

/-- The domain alongside the name, which `list` above does not need. -/
def listFull (creds : Credentials) : IO (List (String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/containers")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "containers").filterMap fun c =>
    match stringField c "name" with
    | some n => some (n, (stringField c "domain_name").getD "")
    | none   => none

/-- Every namespace, as `(name, id)`. -/
def listNamespaces (creds : Credentials) : IO (List (String × String)) := do
  return (← listNamespacesRaw creds).map fun (n, i, _) => (n, i)

/-- Every field `.scalewayContainer` can report, beyond what `read` above needs for the
    portable `.compute` kind. -/
def readFull (creds : Credentials) (name : String) :
    IO (Partial Nat × Partial Nat × Partial Nat × Partial Nat × Partial Nat × Partial Nat ×
        Partial (List (String × String)) × String × String) := do
  let id ← requireId creds name
  let c ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/containers/{id}")
  let optNat (field : String) : Partial Nat :=
    match natField c field with
    | some n => .known n
    | none   => .unknown
  let env := match field c "environment_variables" with
    | some e => Partial.known (envOf e)
    | none   => .unknown
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
  let nsName ← match stringField c "namespace_id" with
    | none    => pure ""
    | some id => do
      match (← listNamespaces creds).find? (·.2 == id) with
      | some (n, _) => pure n
      -- A namespace the credential cannot list is not the same as no
      -- namespace, but there is nothing truer to say from here.
      | none        => pure ""
  return (optNat "port", optNat "min_scale", optNat "max_scale", optNat "memory_limit",
          optNat "cpu_limit", optNat "timeout", env,
          (stringField c "registry_image").getD "", nsName)

/-- `markerValue` is written as a flat tag (`Scaleway.encodeTag`) at create —
    see the 2026-09-10 incident in `AGENTS.md`. This is the exact create path
    `.scalewayContainer` uses, i.e. the resource kind involved in that
    incident. -/
def createFull (creds : Credentials) (name image ns markerValue : String)
    (port minScale maxScale memoryMb cpuLimit timeoutSec : Nat)
    (env secretEnv : List (String × String)) : IO String := do
  let nsId ← namespaceId creds ns
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/containers")
    (payload := some (.object
      [ ("namespace_id", .string nsId)
      , ("name", .string name)
      , ("registry_image", .string image)
      , ("port", .number (Float.ofNat port))
      , ("min_scale", .number (Float.ofNat minScale))
      , ("max_scale", .number (Float.ofNat maxScale))
      , ("memory_limit", .number (Float.ofNat memoryMb))
      , ("cpu_limit", .number (Float.ofNat cpuLimit))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env)
      , ("secret_environment_variables", secretEnvArray secretEnv)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))
  return (stringField reply "domain_name").getD ""

def updateFull (creds : Credentials) (name image : String)
    (port minScale maxScale memoryMb cpuLimit timeoutSec : Nat)
    (env secretEnv : List (String × String)) : IO String := do
  let id ← requireId creds name
  let reply ← Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/containers/{id}")
    (payload := some (.object
      [ ("registry_image", .string image)
      , ("port", .number (Float.ofNat port))
      , ("min_scale", .number (Float.ofNat minScale))
      , ("max_scale", .number (Float.ofNat maxScale))
      , ("memory_limit", .number (Float.ofNat memoryMb))
      , ("cpu_limit", .number (Float.ofNat cpuLimit))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env)
      , ("secret_environment_variables", secretEnvArray secretEnv) ]))
  return (stringField reply "domain_name").getD ""

/-! ### Namespace CRUD

  Functions and Containers each have their own namespace product at their own
  prefix, so these are written once per product rather than shared. What
  differs is only the prefix and what the response carries. -/

/-- One namespace's description, by name. -/
def readNamespace (creds : Credentials) (name : String) : IO (Partial String) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
      (query := [("project_id", ← creds.requireProject)])
  match (arrayField reply "namespaces").find? (fun n => stringField n "name" == some name) with
  | none   => return .unknown
  | some n => return match stringField n "description" with
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
  return ((stringField reply "id").getD "",
          (stringField reply "registry_endpoint").getD "")

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
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/functions")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "functions").filterMap fun f =>
    match stringField f "name", stringField f "id" with
    | some n, some i => some (n, i, stringArrayField f "tags")
    | _,      _      => none

def list (creds : Credentials) : IO (List (String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/functions")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "functions").filterMap fun f =>
    match stringField f "name" with
    | some n => some (n, (stringField f "domain_name").getD "")
    | none   => none

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway functions: no function named '{name}'")

/-- Tags, for `Ownership.ownershipOf`. -/
def readOwnership (creds : Credentials) (name : String) :
    IO (Option (List (String × String) × Option String)) := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return some (tags.map Scaleway.decodeTag, none)
  | none               => return none

private def listNamespacesRaw (creds : Credentials) :
    IO (List (String × String × List String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "namespaces").filterMap fun n =>
    match stringField n "name", stringField n "id" with
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
    IO (Option (List (String × String) × Option String)) := do
  match (← listNamespacesRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return some (tags.map Scaleway.decodeTag, none)
  | none               => return none

def read (creds : Credentials) (name : String) :
    IO (String × Partial (Option String) × String) := do
  let id ← requireId creds name
  let f ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/functions/{id}")
  let runtime := (stringField f "runtime").getD ""
  -- The bucket comes back as the environment variable it was written into.
  let bucket := match field f "environment_variables" with
    | some e => Partial.known (stringField e "SOURCE_BUCKET")
    | none   => .unknown
  -- The namespace, resolved from its id. Reported for the same reason
  -- `Containers.readFull` reports it: `Divergent .scalewayFunction` compares
  -- `namespace` with `forcesReplace`, which has no `unknown` escape, so
  -- blanking it makes every pull propose a replace and the fleet never
  -- converges. The container had exactly that bug and it cost a
  -- twelve-minute CI timeout to see.
  let nsName ← match stringField f "namespace_id" with
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
  return (arrayField reply "runtimes").filterMap fun r => stringField r "name"

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
  | .ok reply => return (stringField reply "domain_name").getD ""
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
  let some url := stringField reply "url"
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

/-! ### Namespace CRUD

  Functions and Containers each have their own namespace product at their own
  prefix, so these are written once per product rather than shared. What
  differs is only the prefix and what the response carries. -/

/-- One namespace's description, by name. -/
def readNamespace (creds : Credentials) (name : String) : IO (Partial String) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
      (query := [("project_id", ← creds.requireProject)])
  match (arrayField reply "namespaces").find? (fun n => stringField n "name" == some name) with
  | none   => return .unknown
  | some n => return match stringField n "description" with
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
  return ((stringField reply "id").getD "",
          (stringField reply "registry_endpoint").getD "")

def updateNamespace (creds : Credentials) (name description : String) : IO Unit := do
  let id ← namespaceIdOfName creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/namespaces/{id}")
    (payload := some (.object [("description", .string description)]))

def deleteNamespace (creds : Credentials) (name : String) : IO Unit := do
  let id ← namespaceIdOfName creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/namespaces/{id}")

end Functions

end Infra.Providers.Kinds.Compute
