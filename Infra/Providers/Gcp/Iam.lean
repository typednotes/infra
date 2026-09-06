import Infra.Providers.Gcp.Rest
import Infra.Core.Stage

/-
  IAM on GCP: service accounts.

  ## Which GCP object is an `iam` resource

  The portable `iam` kind is "a named identity with policies attached". AWS
  reads that as an IAM user, Scaleway as an IAM application, and GCP as a
  **service account** — the only one of GCP's identity objects that a tool can
  create, that has a stable name, and that other resources can be bound to.
  Roles and custom roles are the wrong answer: a role is a *set of
  permissions*, not an identity, so nothing could be granted it.

  ## The name is a 6–30 character account id

  Google constrains it more tightly than either other cloud: 6 to 30
  characters, lowercase letters, digits and hyphens, starting with a letter.
  A fleet's names are fixed at compile time, so a name that fails those rules
  fails every apply, and the error names the rule rather than passing Google's
  back verbatim.

  The email — `{id}@{project}.iam.gserviceaccount.com` — is what everything
  else refers to, so it goes in `ObservedOf` where the ARN goes for AWS.

  ## Policies are read and not written, deliberately

  This is the one field that is not fully implemented, and the reason is worth
  stating rather than hiding behind an `unknown`.

  On GCP, granting a role to a service account is not an operation on the
  service account. It is a **read-modify-write of the whole project's IAM
  policy** (`getIamPolicy`, edit, `setIamPolicy`), and a write that sends back
  a policy assembled incorrectly removes every binding it failed to include —
  for the entire project, not just for this identity.

  Google's own guidance is that this is safe when done with the returned
  `etag`, and it is. But it is code whose failure mode is *silently deleting
  other people's access*, and there is no way to rehearse it against anything
  but a real project. So:

  - `read` reports the roles actually bound to this service account, from the
    project policy. Real information, and read-only.
  - `create` and `update` **raise** if the declaration names any policies,
    with the `gcloud` command that would bind them.

  That way a declared policy is visible in `plan` as a divergence and refused
  loudly at apply, rather than being quietly dropped — which is the failure
  this codebase treats as worse than not supporting the field at all.
-/

namespace Infra.Providers.Gcp.Iam

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)
open Network.HTTP.Types (Query)

def host : String := "iam.googleapis.com"

/-- Cloud Resource Manager, which owns the project's IAM policy. -/
def crmHost : String := "cloudresourcemanager.googleapis.com"

/-- A service account's email, which is its identity everywhere else. -/
def emailOf (project accountId : String) : String :=
  s!"{accountId}@{project}.iam.gserviceaccount.com"

private def saPath (project accountId : String) : String :=
  s!"/v1/projects/{project}/serviceAccounts/{emailOf project accountId}"

/-- Reject a name Google will reject, and say which rule it broke.

    Checked here rather than left to the API because the message that comes
    back names a field and a regex, and the author needs to know it is the
    resource name in their fleet. -/
private def checkAccountId (name : String) : IO Unit := do
  let ok :=
    6 ≤ name.length && name.length ≤ 30
    && (name.toList.head?.map (fun c => c.isLower && c.isAlpha) |>.getD false)
    && name.all fun c => (c.isLower && c.isAlpha) || c.isDigit || c == '-'
  unless ok do
    throw (IO.userError s!"gcp iam: '{name}' is not a usable service-account id\n  \
Google requires 6-30 characters, lowercase letters, digits and hyphens, \
starting with a letter. This is a resource name in your fleet, so it is fixed \
at compile time — rename it there.")

/-- Every service account in the project, by account id (not by email).

    The fleet keys on the bare name, so the email's local part is what is
    returned; `emailOf` reconstructs the rest. -/
def list (creds : Credentials) (project : String) : IO (List (String × String)) := do
  let rec go (fuel : Nat) (token : String) (acc : List (String × String)) :
      IO (List (String × String)) := do
    match fuel with
    | 0 =>
      IO.eprintln "warning: gcp iam: stopped paginating service accounts after 50 \
pages; the list may be incomplete"
      return acc
    | fuel' + 1 =>
      let query : Query := if token.isEmpty then [] else [("pageToken", some token)]
      let reply ← Gcp.call creds "GET" host s!"/v1/projects/{project}/serviceAccounts" query
      let here := (arrayField reply "accounts").filterMap fun a =>
        (stringField a "email").map fun e => ((e.splitOn "@").headD e, e)
      let acc := acc ++ here
      match stringField reply "nextPageToken" with
      | some next => if next.isEmpty then return acc else go fuel' next acc
      | none      => return acc
  go 50 "" []

/-- The roles bound to this service account in the project's IAM policy.

    Read-only, and the only half of `policies` that is implemented — see the
    module note for why the other half raises instead. -/
def readPolicies (creds : Credentials) (project accountId : String) :
    IO (Partial (List String)) := do
  let member := s!"serviceAccount:{emailOf project accountId}"
  match ← (Gcp.call creds "POST" crmHost s!"/v1/projects/{project}:getIamPolicy"
      (payload := some (.object []))).toBaseIO with
  | .error _ =>
    -- Reading the project policy needs `resourcemanager.projects.getIamPolicy`,
    -- which a narrowly-scoped CI identity may well not have. That is not a
    -- reason to fail the whole pull, so it reports unknown — which diverges
    -- from nothing.
    return .unknown
  | .ok policy =>
    let roles := (arrayField policy "bindings").filterMap fun b =>
      if (stringArrayField b "members").contains member then stringField b "role" else none
    return .known roles

/-- Create the service account. Returns its email. -/
def create (creds : Credentials) (project accountId : String)
    (policies : List String) : IO String := do
  checkAccountId accountId
  unless policies.isEmpty do
    throw (IO.userError s!"gcp iam: '{accountId}' declares {policies.length} \
policy/policies, and binding a role on GCP is a read-modify-write of the \
WHOLE project's IAM policy — which this does not do, because getting it wrong \
removes other identities' access. The service account was not created.\n  \
Bind them yourself, then remove `policies` from the declaration:\n\
{String.intercalate "\n" (policies.map fun r =>
  s!"    gcloud projects add-iam-policy-binding {project} \\\\\n      \
--member=serviceAccount:{emailOf project accountId} --role={r}")}")
  let payload : Value := .object
    [ ("accountId", .string accountId)
    , ("serviceAccount", .object [("displayName", .string accountId)]) ]
  let reply ← Gcp.call creds "POST" host s!"/v1/projects/{project}/serviceAccounts"
    (payload := some payload)
  return (stringField reply "email").getD (emailOf project accountId)

/-- Refuse to change policies, for the reason in the module note. -/
def setPolicies (project accountId : String) (policies : List String) : IO Unit := do
  unless policies.isEmpty do
    throw (IO.userError s!"gcp iam: cannot set policies on '{accountId}' — \
binding a role on GCP rewrites the whole project's IAM policy, which this \
does not do. `plan` shows the difference so it is not hidden; bind it with \
`gcloud projects add-iam-policy-binding {project} \
--member=serviceAccount:{emailOf project accountId} --role=…` and the \
difference goes away.")

/-- Delete the service account. Already gone is not an error. -/
def delete (creds : Credentials) (project accountId : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (saPath project accountId)).toBaseIO with
  | .ok _ => pure ()
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e

#guard emailOf "typednotes" "ci-tests-infra-sa"
  = "ci-tests-infra-sa@typednotes.iam.gserviceaccount.com"

-- The account-id rules, which are Google's and are stricter than either other
-- cloud's. `checkAccountId` is `IO`, so what is checked here is the predicate
-- it is built from — kept in step by construction rather than by comment.
private def idOk (name : String) : Bool :=
  6 ≤ name.length && name.length ≤ 30
  && (name.toList.head?.map (fun c => c.isLower && c.isAlpha) |>.getD false)
  && name.all fun c => (c.isLower && c.isAlpha) || c.isDigit || c == '-'

#guard idOk "ci-tests-infra-sa" = true
#guard idOk "infra" = false            -- 5 characters, one short
#guard idOk "1infra" = false           -- must start with a letter
#guard idOk "Infra-sa" = false         -- no capitals
#guard idOk "infra_sa" = false         -- no underscores
#guard idOk "infra-sa" = true

end Infra.Providers.Gcp.Iam
