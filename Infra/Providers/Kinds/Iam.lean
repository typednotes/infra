import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage

/-
  Machine identities.

  `IamSpec` is `name` plus `policies`, which the two clouds realise very
  differently:

    * AWS — an IAM **user** with managed policies attached by ARN, over the
      Query protocol (form-encoded POST, XML reply), always signed
      `us-east-1` because IAM is global.
    * Scaleway — an IAM **application**, over the REST API, organization-scoped
      rather than regional.

  ## What is not portable here

  `policies` is a list of AWS managed-policy ARNs. Scaleway has no ARNs: its
  policies are rule sets naming permission sets and a scope, which no list of
  opaque strings can express. So on Scaleway the policy list is reported
  `unknown` and left unenforced — the same treatment `immutableTags` gets on a
  cloud with no such concept. The application's *existence* is managed; its
  permissions are not.

  Stating that plainly is the point: the alternative would be a mapping that
  looks like it works and quietly grants the wrong thing.
-/

namespace Infra.Providers.Kinds.Iam

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws
open Infra.Providers.JsonRead
open Data.Json (Value)

-- ══════════════════════════════════════════════════════════════
-- AWS IAM
-- ══════════════════════════════════════════════════════════════

namespace Aws'

private def version : String := "2010-05-08"

/-- Members of a Query-protocol result list. IAM wraps repeated elements in
    `<member>` inside a named container. -/
private def members (root : Text.XML.Element) (result container : String) :
    List Text.XML.Element :=
  match root.child result with
  | none   => []
  | some r => Query.listItems r container "member"

def list (creds : Credentials) : IO (List (String × String)) := do
  let root ← Query.call creds Query.iamEndpoint "ListUsers" version
  return (members root "ListUsersResult" "Users").filterMap fun m =>
    match m.childText "UserName", m.childText "Arn" with
    | some n, some a => some (n, a)
    | some n, none   => some (n, "")
    | _,      _      => none

/-- The ARNs of the managed policies attached to a user. -/
def readPolicies (creds : Credentials) (name : String) : IO (Partial (List String)) := do
  let root ← Query.call creds Query.iamEndpoint "ListAttachedUserPolicies" version
    [("UserName", name)]
  return .known ((members root "ListAttachedUserPoliciesResult" "AttachedPolicies").filterMap
    (·.childText "PolicyArn"))

private def attach (creds : Credentials) (name arn : String) : IO Unit := do
  discard <| Query.call creds Query.iamEndpoint "AttachUserPolicy" version
    [("UserName", name), ("PolicyArn", arn)]

private def detach (creds : Credentials) (name arn : String) : IO Unit := do
  discard <| Query.call creds Query.iamEndpoint "DetachUserPolicy" version
    [("UserName", name), ("PolicyArn", arn)]

def create (creds : Credentials) (name : String) (policies : List String) : IO String := do
  let root ← Query.call creds Query.iamEndpoint "CreateUser" version [("UserName", name)]
  for arn in policies do
    attach creds name arn
  let arn := match root.child "CreateUserResult" with
    | some r => match r.child "User" with
      | some u => (u.childText "Arn").getD ""
      | none   => ""
    | none => ""
  return arn

/-- Reconcile the attached set: detach what is no longer wanted, attach what is
    newly wanted. Sending the whole list blindly would fail on the ones already
    attached. -/
def setPolicies (creds : Credentials) (name : String) (wanted : List String) : IO Unit := do
  let current ← match ← readPolicies creds name with
    | .known cs => pure cs
    | .unknown  => pure []
  for arn in current.filter (!wanted.contains ·) do
    detach creds name arn
  for arn in wanted.filter (!current.contains ·) do
    attach creds name arn

/-- A user with policies still attached cannot be deleted, so they come off
    first. -/
def delete (creds : Credentials) (name : String) : IO Unit := do
  match ← readPolicies creds name with
  | .known arns => for arn in arns do detach creds name arn
  | .unknown    => pure ()
  discard <| Query.call creds Query.iamEndpoint "DeleteUser" version [("UserName", name)]

end Aws'

-- ══════════════════════════════════════════════════════════════
-- Scaleway IAM
-- ══════════════════════════════════════════════════════════════

namespace Scw

private def prefix' : String := Scaleway.globalPrefix "iam" "v1alpha1"

private def listRaw (creds : Credentials) : IO (List (String × String)) := do
  let org ← creds.requireOrganization
  let reply ← Scaleway.call creds "GET" (prefix' ++ "/applications")
    [("organization_id", some org)]
  return (arrayField reply "applications").filterMap fun a =>
    match stringField a "name", stringField a "id" with
    | some n, some i => some (n, i)
    | _,      _      => none

def list (creds : Credentials) : IO (List String) := do
  return (← listRaw creds).map (·.1)

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id) => return id
  | none         => throw (IO.userError s!"scaleway iam: no application named '{name}'")

/-- Never reported: see the module note on why AWS policy ARNs have no Scaleway
    equivalent. `unknown` keeps this out of the divergence calculation rather
    than pretending the list is empty. -/
def readPolicies : IO (Partial (List String)) := pure .unknown

def create (creds : Credentials) (name : String) : IO String := do
  let org ← creds.requireOrganization
  let reply ← Scaleway.call creds "POST" (prefix' ++ "/applications")
    (payload := some (.object [("name", .string name), ("organization_id", .string org)]))
  return (stringField reply "id").getD ""

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' ++ s!"/applications/{id}")

end Scw

end Infra.Providers.Kinds.Iam
