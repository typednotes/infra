import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Core.Stage
import Infra.Core.Ownership

/-
  Machine identities, their permissions, and their keys.

  `IamSpec` is `name` plus `policies`, which the three clouds realise very
  differently:

    * AWS — an IAM **user** with managed policies attached by ARN, over the
      Query protocol (form-encoded POST, XML reply), always signed
      `us-east-1` because IAM is global.
    * Scaleway — an IAM **application**, over the REST API, organization-scoped
      rather than regional, with permissions expressed as a *policy* carrying
      rules (this file) rather than as attachable objects.
    * GCP — a service account. `Infra.Providers.Gcp.Iam`, not this file.

  ## What `policies` means on each cloud

  A list of **the cloud's own name for a set of permissions**, granted at that
  cloud's natural scope for an identity. Concretely:

    | cloud    | an element is           | scope                        |
    |----------|-------------------------|------------------------------|
    | AWS      | a managed-policy ARN    | the account                  |
    | Scaleway | a permission-set name   | the credentials' **project** |
    | GCP      | a role name             | the project                  |

  That is a real portable reading, not a coincidence: all three clouds name
  bundles of permissions and grant them to a principal. What is *not* portable
  is the spelling, and the spelling is the cloud's, so a fleet that names
  `AmazonS3ReadOnlyAccess` on AWS names `ObjectStorageReadOnly` on Scaleway and
  `roles/storage.objectViewer` on GCP. Nothing here translates between them,
  because a translation that looked right and granted the wrong thing is worse
  than three explicit lists.

  This is a change of meaning on Scaleway. `policies` used to be documented as
  "AWS managed-policy ARNs", reported `unknown`, and left unenforced — the
  application's existence was managed and its permissions were not. It is now
  a permission-set list, read back and reconciled; see `Scw.setPolicies` for
  what the reconciliation is authoritative over and what it refuses to touch.

  ## Scope on Scaleway is the project, not the organization

  A Scaleway rule must name **precisely one** of `project_ids` and
  `organization_id`. This file always writes `project_ids := [the credentials'
  project]`, which is the narrower of the two and the one a per-project fleet
  wants; an organization-wide grant is deliberately not expressible here,
  since the portable `policies` field carries no scope and silently choosing
  the wider one is the direction that over-grants.
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

def create (creds : Credentials) (name markerValue : String) (policies : List String) :
    IO String := do
  let root ← Query.call creds Query.iamEndpoint "CreateUser" version
    [ ("UserName", name)
    , ("Tags.member.1.Key", markerKey), ("Tags.member.1.Value", markerValue) ]
  for arn in policies do
    attach creds name arn
  let arn := match root.child "CreateUserResult" with
    | some r => match r.child "User" with
      | some u => (u.childText "Arn").getD ""
      | none   => ""
    | none => ""
  return arn

/-- The tag pairs in a `ListUserTags` reply, as a pure function of the parsed
    XML.

    Extracted from `readOwnership` so that it can be checked against a real
    reply body offline, which is the whole reason it exists as a name. The
    version this replaces double-unwrapped the response: it took
    `root.child "ListUserTagsResult"` and *then* called `members … "Tags"
    "member"`, which unwraps again — so it looked for a `<member>` inside a
    `<member>` and always found nothing.

    Every AWS IAM user this tool created therefore read back as carrying no
    tags at all, which `ownershipOf` correctly calls `foreign`. It survived
    because nothing exercised it: the live sequence put a resource in the
    (then) ledger as it created it, so the (then) adoption loop never
    asked; the trimmed stage does not drop the user, so the orphan recheck
    never asks either;
    and no offline test could reach an XML body. The live ownership check
    added in 0.11.0 asks directly, and found it on its first real run.

    The shape, which is what the guard below pins:

        <ListUserTagsResponse><ListUserTagsResult>
          <Tags><member><Key>k</Key><Value>v</Value></member></Tags>
        </ListUserTagsResult></ListUserTagsResponse> -/
def tagsOfListUserTags (root : Text.XML.Element) : List (String × String) :=
  (members root "ListUserTagsResult" "Tags").filterMap fun t =>
    match t.childText "Key", t.childText "Value" with
    | some k, some v => some (k, v)
    | _,      _      => none

/- A real `ListUserTags` reply, parsed. This is the assertion that the fix
   above is a fix, and it is the one that could have been written at any point
   in the last two weeks: the body is a wire format, not an account, so there
   was never anything stopping it being checked offline.

   The failing version returned `[]` here. `ownershipOf` then reads `[]` as
   `foreign`, so every IAM user this tool created on AWS was unadoptable and
   undeletable-as-orphan while `create` was writing the tag perfectly well. -/
private def listUserTagsReply : String :=
  "<ListUserTagsResponse xmlns=\"https://iam.amazonaws.com/doc/2010-05-08/\">\
<ListUserTagsResult><Tags>\
<member><Key>managed-by-infra</Key><Value>true</Value></member>\
<member><Key>team</Key><Value>infra</Value></member>\
</Tags><IsTruncated>false</IsTruncated></ListUserTagsResult>\
</ListUserTagsResponse>"

#guard (match Text.XML.parse listUserTagsReply with
        | .ok root => tagsOfListUserTags root
        | .error _ => []) = [("managed-by-infra", "true"), ("team", "infra")]

/- And the marker is then found in it, which is the question the engine
   actually asks. Pinning the parse alone would not catch a future change that
   parsed the tags and lost the key. -/
#guard (match Text.XML.parse listUserTagsReply with
        | .ok root => markedBy none (tagsOfListUserTags root)
        | .error _ => false)

/- A user with no tags parses to no tags, rather than to an error — which is a
   real reply (`<Tags/>`) and must read as "not ours", not as "unreadable". -/
#guard (match Text.XML.parse
          "<ListUserTagsResponse><ListUserTagsResult><Tags/>\
</ListUserTagsResult></ListUserTagsResponse>" with
        | .ok root => tagsOfListUserTags root
        | .error _ => [("parse", "failed")]) = []

/-- Tags, for `Ownership.ownershipOf`. `ListUsers` does not report them
    (same gap as EC2/RDS), so this is a second call keyed by name. `createdAt`
    is left `none`, matching every other kind's first tranche, though
    `ListUsers`'s own `CreateDate` is available if a later pass wants it. -/
def readOwnership (creds : Credentials) (name : String) : IO Evidence := do
  let attempt ← (Query.call creds Query.iamEndpoint "ListUserTags" version
    [("UserName", name)]).toBaseIO
  match attempt with
  | .error _ => return .unreadable
  | .ok root => return .tags (tagsOfListUserTags root) none

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

/-! ### Access keys

  An AWS access key is the pair `(AccessKeyId, SecretAccessKey)`, and the
  secret half is returned **only** by `CreateAccessKey` — `ListAccessKeys`
  reports metadata and never the secret. That is the same one-shot shape
  Scaleway and GCP have, and the reason `SecretSource.apiKeyFor` exists: a
  value nobody can read back a second time cannot travel through observed
  state, so it has to go straight into a secret at the moment it is minted. -/

/-- Mint an access key for a user. Returns `(accessKeyId, secretAccessKey)`.

    The caller is `Live.lean`'s `.secrets` create, which writes the second
    component into a secret and never lets it out again. -/
def createAccessKey (creds : Credentials) (userName : String) : IO (String × String) := do
  -- `docs/aws-operator-policy.json` **denies** this action, deliberately:
  -- create a user, attach `AdministratorAccess`, mint its key is a three-step
  -- path to full admin, and the name prefix does not help because the new
  -- user is inside it. So a fleet using `apiKeyFor` on AWS under the
  -- recommended policy gets a 403 here, and that 403 is the policy working.
  -- The error says so, because otherwise it reads as a misconfiguration.
  let root ← match ← (Query.call creds Query.iamEndpoint "CreateAccessKey" version
      [("UserName", userName)]).toBaseIO with
    | .ok r => pure r
    | .error e =>
      if ((toString e).splitOn "AccessDenied").length > 1
         || ((toString e).splitOn "explicit deny").length > 1 then
        throw (IO.userError s!"aws iam: refused permission to mint an access key \
for '{userName}'.\n  If you are using this repo's recommended operator policy, this \
is its `NeverMintUsableCredentials` statement doing its job rather than a \
misconfiguration: creating a user, attaching a powerful policy and minting its key \
is a path to full admin, so the action is denied outright.\n  \
`docs/permissions.md`, \"SecretSource.apiKeyFor on AWS needs the denied action\", \
has the narrow way to allow it and what allowing it costs.\n  {e}")
      else throw e
  match (root.child "CreateAccessKeyResult").bind (·.child "AccessKey") with
  | none => throw (IO.userError
      s!"aws iam: CreateAccessKey for '{userName}' returned no access key")
  | some k =>
    match k.childText "AccessKeyId", k.childText "SecretAccessKey" with
    | some id, some secret => return (id, secret)
    | _, _ => throw (IO.userError
        s!"aws iam: CreateAccessKey for '{userName}' returned an incomplete access key")

/-- Every access key id a user has. Metadata only — never the secret half. -/
def listAccessKeys (creds : Credentials) (userName : String) : IO (List String) := do
  let root ← Query.call creds Query.iamEndpoint "ListAccessKeys" version
    [("UserName", userName)]
  return (members root "ListAccessKeysResult" "AccessKeyMetadata").filterMap
    (·.childText "AccessKeyId")

def deleteAccessKey (creds : Credentials) (userName accessKeyId : String) : IO Unit := do
  discard <| Query.call creds Query.iamEndpoint "DeleteAccessKey" version
    [("UserName", userName), ("AccessKeyId", accessKeyId)]

/-- A user with policies or access keys still attached cannot be deleted, so
    both come off first.

    The access-key half was missing and is not cosmetic: `DeleteUser` answers
    `DeleteConflict` for a user holding a key, so a fleet that had ever minted
    one could not be torn down at all. -/
def delete (creds : Credentials) (name : String) : IO Unit := do
  match ← readPolicies creds name with
  | .known arns => for arn in arns do detach creds name arn
  | .unknown    => pure ()
  for id in ← listAccessKeys creds name do
    deleteAccessKey creds name id
  discard <| Query.call creds Query.iamEndpoint "DeleteUser" version [("UserName", name)]

end Aws'

-- ══════════════════════════════════════════════════════════════
-- Scaleway IAM
-- ══════════════════════════════════════════════════════════════

/- ## These resources *can* be tagged, and this file used to say they could not

   The note that stood here declared Scaleway IAM applications a permanent
   tag-capability exception, on the strength of a reading of the API
   reference. That was wrong: `CreateApplicationRequest` and `Application`
   both carry `tags []string`, as do `CreatePolicyRequest` and `Policy`
   — checked against Scaleway's own SDK
   (`scaleway-sdk-go/api/iam/v1alpha1/iam_sdk.go`) on 2026-09-19, which is
   generated from the API definition rather than transcribed from prose.

   So this kind is on the *tag* rung of `Ownership`'s ladder like most
   others, and the fail-safe that used to refuse to adopt or delete-as-orphan
   a Scaleway application no longer applies to it. The lesson worth keeping is
   the one in `AGENTS.md` about provider facts going stale: the exception was
   documented confidently, in three files, and was never true.

   API **keys** are the genuine exception on this cloud. They have no `tags`
   field — only a `description`, which is where their marker goes. See the
   second rung of the ladder. -/
namespace Scw

private def prefix' : String := Scaleway.globalPrefix "iam" "v1alpha1"

/-- Scaleway's list endpoints default to 20 results a page. Every listing here
    asks for the documented maximum instead, because a fleet's applications,
    its policies and its keys are all things there can easily be more than
    twenty of, and a truncated listing reads as "not there" — which for an
    application means a create that fails on a name already taken, and for a
    policy means a permission silently re-granted on every apply. -/
private def pageSize : String := "100"

private def listRaw (creds : Credentials) :
    IO (List (String × String × List String)) := do
  let org ← creds.requireOrganization
  let reply ← Scaleway.call creds "GET" (prefix' ++ "/applications")
    [("organization_id", some org), ("page_size", some pageSize)]
  return (arrayField reply "applications").filterMap fun a =>
    match stringField a "name", stringField a "id" with
    | some n, some i => some (n, i, stringArrayField a "tags")
    | _,      _      => none

def list (creds : Credentials) : IO (List String) := do
  return (← listRaw creds).map (·.1)

/-- Every application as `(name, id)`, for the listing that has to report the
    id as observed state. One call, not one per application: `listRaw` already
    has both. -/
def listWithIds (creds : Credentials) : IO (List (String × String)) := do
  return (← listRaw creds).map fun (n, id, _) => (n, id)

/-- The application's UUID, which is its identity to every other API.

    Public, unlike every other `requireId` in this codebase, because it is the
    part of an application that other resources need: a Serverless SQL
    Database authenticates an application by its **id** as the PostgreSQL user
    name (the access key is not the user name — a trap worth naming, since the
    access key looks far more like a username than a UUID does). `Live.lean`
    puts it in `IamObserved.arn`, which is where a cloud-assigned identifier
    for this kind belongs. -/
def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway iam: no application named '{name}'")

/-- Tags, for `Ownership.ownershipOf`. The application listing already returns
    each one's flat `tags: []string`, so this is the same call as `list`,
    decoded rather than an extra round trip — see `Scaleway.decodeTag`. -/
def readOwnership (creds : Credentials) (name : String) : IO Evidence := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, tags) => return .tags (tags.map Scaleway.decodeTag) none
  | none              => return .unreadable

-- ── Policies ──

/-- The policies whose principal is this application.

    Returned as `(id, name, tags, permissionSetNames)`. A policy names exactly
    one principal, so every policy here exists solely to grant permissions to
    this application — which is what makes reconciling them coherent. -/
private def policiesOf (creds : Credentials) (appId : String) :
    IO (List (String × String × List String × List String)) := do
  let org ← creds.requireOrganization
  let reply ← Scaleway.call creds "GET" (prefix' ++ "/policies")
    [ ("organization_id", some org), ("application_ids", some appId)
    , ("page_size", some pageSize) ]
  (arrayField reply "policies").filterMapM fun p => do
    match stringField p "id", stringField p "name" with
    | some id, some nm =>
      let rules ← Scaleway.call creds "GET" (prefix' ++ "/rules")
        [("policy_id", some id), ("page_size", some pageSize)]
      let sets := (arrayField rules "rules").flatMap (stringArrayField · "permission_set_names")
      return some (id, nm, stringArrayField p "tags", sets)
    | _, _ => return none

/-- The policy this tool owns, if it has made one: the one carrying the
    ownership marker in its tags. Anything else attached to the application was
    put there by somebody else. -/
private def ours (markerValue : String)
    (ps : List (String × String × List String × List String)) :
    Option (String × String × List String × List String) :=
  ps.find? fun (_, _, tags, _) => markedBy (some markerValue) (tags.map Scaleway.decodeTag)

/-- Every permission set granted to this application, across every policy
    attached to it.

    All of them, not only this tool's own, and that is the point: a permission
    granted by a policy somebody added by hand is a permission the application
    really has, so reporting only what we wrote would make `plan` claim the
    identity is narrower than it is. `setPolicies` then refuses to reconcile
    rather than quietly deleting the other policy — see there. -/
def readPolicies (creds : Credentials) (name : String) : IO (Partial (List String)) := do
  match ← (requireId creds name).toBaseIO with
  | .error _  => return .unknown
  | .ok appId =>
    let ps ← policiesOf creds appId
    -- Deduplicated: two policies may name the same set, and the declared list
    -- is a set in spirit, so reporting a duplicate would be drift that no edit
    -- to the declaration could ever resolve.
    return .known (ps.flatMap (·.2.2.2)).eraseDups

/-- One rule granting `sets` over this fleet's project. -/
private def ruleFor (project : String) (sets : List String) : Value :=
  .object
    [ ("permission_set_names", .array (sets.map Value.string).toArray)
    , ("project_ids", .array #[.string project]) ]

/-- Make the application's permissions be exactly `wanted`.

    **Authoritative over the policy it created, and refuses to touch any
    other.** A policy attached to this application that does not carry the
    ownership marker was put there by a human or another tool; deleting it
    would be this tool destroying something it never created, and silently
    leaving it would mean a fleet that reports drift it can never resolve. So
    the third option: raise, name the policy, and say what to do. That is the
    same choice `Gcp.Iam` makes about a `policies` list it cannot bind safely.

    An empty `wanted` removes this tool's policy entirely rather than leaving
    an empty one behind, because a policy with no rules and a policy that does
    not exist grant the same thing, and the second is the one that does not
    show up in a console listing as a puzzle. -/
def setPolicies (creds : Credentials) (name markerValue : String)
    (wanted : List String) : IO Unit := do
  let appId ← requireId creds name
  let project ← creds.requireProject
  let org ← creds.requireOrganization
  let ps ← policiesOf creds appId
  let mine := ours markerValue ps
  let foreign := ps.filter fun p => match mine with
    | some m => m.1 != p.1
    | none   => true
  unless foreign.isEmpty do
    throw (IO.userError s!"scaleway iam: application '{name}' has \
{foreign.length} polic(y/ies) this fleet did not create — \
{String.intercalate ", " (foreign.map (·.2.1))}. Its permissions are therefore \
not this declaration's to reconcile, and deleting somebody else's policy is \
not something this tool will do on its own. Detach or delete them in the \
console (or `scw iam policy delete`), or exclude this identity from the \
fleet's boundary, and `plan` will converge.")
  match mine, wanted.isEmpty with
  | none,   true  => pure ()
  | some m, true  =>
    discard <| Scaleway.call creds "DELETE" (prefix' ++ s!"/policies/{m.1}")
  | none,   false =>
    discard <| Scaleway.call creds "POST" (prefix' ++ "/policies")
      (payload := some (.object
        [ ("name", .string name), ("organization_id", .string org)
        , ("application_id", .string appId)
        , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))])
        , ("rules", .array #[ruleFor project wanted]) ]))
  | some m, false =>
    -- `PUT /rules` overwrites the policy's whole rule set, which is exactly
    -- the semantics wanted: the declaration is the complete list.
    discard <| Scaleway.call creds "PUT" (prefix' ++ "/rules")
      (payload := some (.object
        [ ("policy_id", .string m.1)
        , ("rules", .array #[ruleFor project wanted]) ]))

-- ── API keys ──

/-- Mint an API key for an application. Returns `(accessKey, secretKey)`.

    `description` carries the ownership marker: an API key is the one IAM
    object on this cloud with no `tags` field, so this is the second rung of
    `Ownership`'s ladder — see `encodeMarkerText`.

    The secret half is returned here and **never again**: `GET /api-keys`
    reports `secret_key` as null for every key that already exists. Which is
    why this is called from a secret's `create` and nowhere else. -/
def createApiKey (creds : Credentials) (appId description : String) :
    IO (String × String) := do
  let reply ← Scaleway.call creds "POST" (prefix' ++ "/api-keys")
    (payload := some (.object
      [ ("application_id", .string appId)
      , ("description", .string description) ]))
  match stringField reply "access_key", stringField reply "secret_key" with
  | some access, some secret => return (access, secret)
  | some _, none => throw (IO.userError
      "scaleway iam: the API key was created but its secret key was not \
returned, and Scaleway will not show it again. Delete the key and retry.")
  | _, _ => throw (IO.userError "scaleway iam: create api-key returned no access key")

/-- Every API key in the organization, as `(accessKey, applicationId,
    description)`. Metadata only: `secret_key` is null here by design. -/
def listApiKeys (creds : Credentials) : IO (List (String × String × String)) := do
  let org ← creds.requireOrganization
  let reply ← Scaleway.call creds "GET" (prefix' ++ "/api-keys")
    [("organization_id", some org), ("page_size", some pageSize)]
  return (arrayField reply "api_keys").filterMap fun k =>
    (stringField k "access_key").map fun access =>
      (access, (stringField k "application_id").getD "", (stringField k "description").getD "")

/-- Delete one API key. Already gone is not an error: this is reached from a
    secret's teardown, which may run twice if an apply failed part way. -/
def deleteApiKey (creds : Credentials) (accessKey : String) : IO Unit := do
  match ← (Scaleway.call creds "DELETE" (prefix' ++ s!"/api-keys/{accessKey}")).toBaseIO with
  | .ok _    => pure ()
  | .error e => unless ((toString e).splitOn "HTTP 404").length > 1 do throw e

/-- Delete the application, and the policy this tool attached to it.

    Scaleway deletes an application's **API keys** along with it, so those need
    no separate pass — unlike AWS, where `DeleteUser` refuses while a key
    exists. A policy is *not* cascaded, though, and one left behind names a
    principal that no longer exists: harmless, invisible, and exactly the kind
    of litter a teardown is supposed to leave none of. -/
def delete (creds : Credentials) (name markerValue : String) : IO Unit := do
  let id ← requireId creds name
  for (pid, _, tags, _) in ← policiesOf creds id do
    if markedBy (some markerValue) (tags.map Scaleway.decodeTag) then
      discard <| Scaleway.call creds "DELETE" (prefix' ++ s!"/policies/{pid}")
  discard <| Scaleway.call creds "DELETE" (prefix' ++ s!"/applications/{id}")

/-- Create the application. Returns its id.

    `markerValue` is written as a flat tag (`Scaleway.encodeTag`), like every
    other tag-capable Scaleway kind — see the note above this namespace for
    why this file used to claim it could not be. -/
def create (creds : Credentials) (name markerValue : String)
    (policies : List String) : IO String := do
  let org ← creds.requireOrganization
  let reply ← Scaleway.call creds "POST" (prefix' ++ "/applications")
    (payload := some (.object
      [ ("name", .string name), ("organization_id", .string org)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))
  let id := (stringField reply "id").getD ""
  unless policies.isEmpty do
    setPolicies creds name markerValue policies
  return id

end Scw

end Infra.Providers.Kinds.Iam
