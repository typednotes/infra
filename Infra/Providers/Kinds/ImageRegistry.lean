import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage

/-
  Container image registries.

  Unlike object storage and queues, the two clouds share no API here, so this
  is genuinely two implementations behind one kind — which is the case the
  portable-spec design has to handle to be worth anything.

    * AWS ECR speaks AWS-JSON 1.1.
    * Scaleway Container Registry speaks its own REST API, where a registry is
      a "namespace".

  ## What is portable, and what is not

  `ImageRegistrySpec` is `name` plus `immutableTags`. Only ECR has tag
  immutability; Scaleway has no equivalent, so it reports `unknown` there —
  "could not see", which by design never counts as drift. A target asking for
  immutable tags on Scaleway is therefore accepted and quietly unenforced,
  which is worth knowing: the alternative would be failing every apply.

  ## Identity

  ECR addresses a repository by name. Scaleway addresses a namespace by UUID,
  so every operation resolves name → id first. That costs an extra call, but it
  keeps the fleet key a readable name instead of a UUID.
-/

namespace Infra.Providers.Kinds.ImageRegistry

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws
open Infra.Providers.JsonRead
open Data.Json (Value)

-- ══════════════════════════════════════════════════════════════
-- AWS ECR
-- ══════════════════════════════════════════════════════════════

namespace Ecr

private def target (op : String) : String := s!"AmazonEC2ContainerRegistry_V20150921.{op}"

/-- Every repository, as `(name, uri)`. -/
def list (creds : Credentials) (ep : Endpoint) : IO (List (String × String)) := do
  let reply ← Json.call creds ep (target "DescribeRepositories") (.object [])
  return (arrayField reply "repositories").filterMap fun r =>
    match stringField r "repositoryName", stringField r "repositoryUri" with
    | some n, some u => some (n, u)
    | some n, none   => some (n, "")
    | _,      _      => none

/-- Tag immutability for one repository. -/
def readImmutable (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Partial Bool) := do
  let reply ← Json.call creds ep (target "DescribeRepositories")
    (.object [("repositoryNames", .array #[.string name])])
  match (arrayField reply "repositories").head? with
  | none   => return .unknown
  | some r =>
    match stringField r "imageTagMutability" with
    | some "IMMUTABLE" => return .known true
    | some _           => return .known false
    | none             => return .unknown

private def mutabilityValue (immutable : Bool) : Value :=
  .string (if immutable then "IMMUTABLE" else "MUTABLE")

/-- Create a repository, returning its URI. -/
def create (creds : Credentials) (ep : Endpoint) (name : String) (immutable : Bool) :
    IO String := do
  let reply ← Json.call creds ep (target "CreateRepository")
    (.object [("repositoryName", .string name),
              ("imageTagMutability", mutabilityValue immutable)])
  match field reply "repository" with
  | some r => return (stringField r "repositoryUri").getD ""
  | none   => return ""

def setImmutable (creds : Credentials) (ep : Endpoint) (name : String) (immutable : Bool) :
    IO Unit := do
  discard <| Json.call creds ep (target "PutImageTagMutability")
    (.object [("repositoryName", .string name),
              ("imageTagMutability", mutabilityValue immutable)])

/-- Delete a repository. `force` is required for one that still holds images;
    without it the call fails and the plan stalls on a resource the target says
    should be gone. -/
def delete (creds : Credentials) (ep : Endpoint) (name : String) : IO Unit := do
  discard <| Json.call creds ep (target "DeleteRepository")
    (.object [("repositoryName", .string name), ("force", .bool true)])

end Ecr

-- ══════════════════════════════════════════════════════════════
-- Scaleway Container Registry
-- ══════════════════════════════════════════════════════════════

namespace Scw

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "registry" "v1" region

/-- Every namespace, as `(name, id, endpoint)`. -/
def listRaw (creds : Credentials) : IO (List (String × String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/namespaces")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "namespaces").filterMap fun n =>
    match stringField n "name", stringField n "id" with
    | some nm, some id => some (nm, id, (stringField n "endpoint").getD "")
    | _,       _       => none

def list (creds : Credentials) : IO (List (String × String)) := do
  return (← listRaw creds).map fun (nm, _, ep) => (nm, ep)

/-- Resolve a name to the UUID every other call needs. -/
def idOf (creds : Credentials) (name : String) : IO (Option String) := do
  return ((← listRaw creds).find? (·.1 == name)).map (·.2.1)

private def requireId (creds : Credentials) (name : String) : IO String := do
  match ← idOf creds name with
  | some id => return id
  | none    => throw (IO.userError s!"scaleway registry: no namespace named '{name}'")

/-- Scaleway has no tag-immutability setting, so it is never reported. -/
def readImmutable : IO (Partial Bool) := pure .unknown

def create (creds : Credentials) (name : String) : IO String := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/namespaces")
    (payload := some (.object [("name", .string name), ("project_id", .string project)]))
  return (stringField reply "endpoint").getD ""

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/namespaces/{id}")

end Scw

end Infra.Providers.Kinds.ImageRegistry
