import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage

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

def create (creds : Credentials) (ep : Endpoint) (name image role : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  discard <| RestJson.call creds ep "POST" base (payload := some (.object
    [ ("FunctionName", .string name)
    , ("PackageType", .string "Image")
    , ("Code", .object [("ImageUri", .string image)])
    , ("Role", .string (← requireRole name role))
    , ("MemorySize", .number (Float.ofNat memoryMb))
    , ("Timeout", .number (Float.ofNat timeoutSec))
    , ("Environment", .object [("Variables", envObject env)]) ]))

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

private def listRaw (creds : Credentials) : IO (List (String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/containers")
  return (arrayField reply "containers").filterMap fun c =>
    match stringField c "name", stringField c "id" with
    | some n, some i => some (n, i)
    | _,      _      => none

def list (creds : Credentials) : IO (List String) := do
  return (← listRaw creds).map (·.1)

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id) => return id
  | none         => throw (IO.userError s!"scaleway containers: no container named '{name}'")

/-- Resolve a namespace name to its id, which every container operation needs. -/
private def namespaceId (creds : Credentials) (name : String) : IO String := do
  if name.isEmpty then
    throw (IO.userError
      "compute on scaleway needs a namespace: Serverless Containers groups containers into one")
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
  match (arrayField reply "namespaces").find? (fun n => stringField n "name" == some name) with
  | some n =>
    match stringField n "id" with
    | some i => return i
    | none   => throw (IO.userError s!"scaleway containers: namespace '{name}' has no id")
  | none => throw (IO.userError s!"scaleway containers: no namespace named '{name}'")

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

def create (creds : Credentials) (name image ns : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String)) : IO Unit := do
  let nsId ← namespaceId creds ns
  discard <| Scaleway.call creds "POST" (prefix' creds.region ++ "/containers")
    (payload := some (.object
      [ ("namespace_id", .string nsId)
      , ("name", .string name)
      , ("registry_image", .string image)
      , ("memory_limit", .number (Float.ofNat memoryMb))
      , ("timeout", .string s!"{timeoutSec}s")
      , ("environment_variables", envObject env) ]))

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

private def listRaw (creds : Credentials) : IO (List (String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/functions")
  return (arrayField reply "functions").filterMap fun f =>
    match stringField f "name", stringField f "id" with
    | some n, some i => some (n, i)
    | _,      _      => none

def list (creds : Credentials) : IO (List (String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/functions")
  return (arrayField reply "functions").filterMap fun f =>
    match stringField f "name" with
    | some n => some (n, (stringField f "domain_name").getD "")
    | none   => none

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id) => return id
  | none         => throw (IO.userError s!"scaleway functions: no function named '{name}'")

/-- The namespace a function belongs to, resolved from its name. -/
private def namespaceIdOf (creds : Credentials) (name : String) : IO String := do
  if name.isEmpty then
    throw (IO.userError "scalewayFunction needs a namespace")
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
  match (arrayField reply "namespaces").find? (fun n => stringField n "name" == some name) with
  | some n =>
    match stringField n "id" with
    | some i => return i
    | none   => throw (IO.userError s!"scaleway functions: namespace '{name}' has no id")
  | none => throw (IO.userError s!"scaleway functions: no namespace named '{name}'")

def read (creds : Credentials) (name : String) : IO (String × Partial (Option String)) := do
  let id ← requireId creds name
  let f ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/functions/{id}")
  let runtime := (stringField f "runtime").getD ""
  -- The bucket comes back as the environment variable it was written into.
  let bucket := match field f "environment_variables" with
    | some e => Partial.known (stringField e "SOURCE_BUCKET")
    | none   => .unknown
  return (runtime, bucket)

/-- The referenced bucket is passed as an environment variable, which is what
    makes the cross-cloud dependency edge do real work. -/
private def envFor (bucket : Option (Handle .s3Bucket)) : Value :=
  match bucket with
  | some h => .object [("SOURCE_BUCKET", .string h.raw)]
  | none   => .object []

def create (creds : Credentials) (name runtime ns : String)
    (bucket : Option (Handle .s3Bucket)) : IO String := do
  let nsId ← namespaceIdOf creds ns
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/functions")
    (payload := some (.object
      [ ("namespace_id", .string nsId)
      , ("name", .string name)
      , ("runtime", .string runtime)
      , ("environment_variables", envFor bucket) ]))
  return (stringField reply "domain_name").getD ""

def update (creds : Credentials) (name : String)
    (bucket : Option (Handle .s3Bucket)) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/functions/{id}")
    (payload := some (.object [("environment_variables", envFor bucket)]))

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/functions/{id}")

end Functions

end Infra.Providers.Kinds.Compute
