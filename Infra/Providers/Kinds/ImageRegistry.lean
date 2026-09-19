import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage
import Infra.Core.Ownership

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

/-- Create a repository, returning its URI.

    `markerValue` is the ownership marker's value — see `Infra.Core.Ownership`.
    Written as a real ECR tag at creation, the same way every other AWS kind
    here does it. It was missing, and so was the read: this kind could neither
    be adopted nor deleted as an orphan, for no reason other than that nobody
    had wired it up. -/
def create (creds : Credentials) (ep : Endpoint) (name markerValue : String)
    (immutable : Bool) : IO String := do
  let reply ← Json.call creds ep (target "CreateRepository")
    (.object [("repositoryName", .string name),
              ("imageTagMutability", mutabilityValue immutable),
              ("tags", .array #[.object
                [("Key", .string markerKey), ("Value", .string markerValue)]])])
  match field reply "repository" with
  | some r => return (stringField r "repositoryUri").getD ""
  | none   => return ""

/-- Tags, for `Ownership.ownershipOf`.

    Two calls, because ECR's tags hang off an ARN and `DescribeRepositories`
    is what knows the ARN — the same describe-then-fetch shape as RDS. -/
def readOwnership (creds : Credentials) (ep : Endpoint) (name : String) : IO Evidence := do
  match ← (Json.call creds ep (target "DescribeRepositories")
      (.object [("repositoryNames", .array #[.string name])])).toBaseIO with
  | .error _ => return .unreadable
  | .ok reply =>
    match (arrayField reply "repositories").head?.bind (stringField · "repositoryArn") with
    | none     => return .unreadable
    | some arn =>
      let tagged ← Json.call creds ep (target "ListTagsForResource")
        (.object [("resourceArn", .string arn)])
      return .tags ((arrayField tagged "tags").filterMap fun t =>
        match stringField t "Key", stringField t "Value" with
        | some k, some v => some (k, v)
        | _,      _      => none) none

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

/-- The marker goes in `description`: a registry namespace has no `tags`
    field — checked against Scaleway's own SDK (`api/registry/v1`, 2026-09-19),
    where `Namespace` is id/name/description/organization_id/project_id/
    status/endpoint/is_public/size and `CreateNamespaceRequest` adds nothing —
    but `description` is settable on create and on update.

    So this kind is on the **second rung** of `Ownership`'s ladder. Nothing in
    `ImageRegistrySpec` competes for the field, so the marker has it to
    itself. -/
def create (creds : Credentials) (name markerValue : String) : IO String := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/namespaces")
    (payload := some (.object
      [ ("name", .string name), ("project_id", .string project)
      , ("description", .string (encodeMarkerText markerValue)) ]))
  return (stringField reply "endpoint").getD ""

/-- The marker, decoded back out of the description. See `create`. -/
def readOwnership (creds : Credentials) (name : String) : IO Evidence := do
  match ← idOf creds name with
  | none    => return .unreadable
  | some id =>
    match ← (Scaleway.call creds "GET" (prefix' creds.region ++ s!"/namespaces/{id}")).toBaseIO with
    | .error _ => return .unreadable
    | .ok n    => return .tags (decodeMarkerText ((stringField n "description").getD "")) none

/-- Re-assert the marker, for the same reason S3's tag write is repeated on
    update: a description cleared by hand would otherwise leave the namespace
    unmarked for ever. -/
def putMarker (creds : Credentials) (name markerValue : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/namespaces/{id}")
    (payload := some (.object [("description", .string (encodeMarkerText markerValue))]))

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/namespaces/{id}")

end Scw

end Infra.Providers.Kinds.ImageRegistry
