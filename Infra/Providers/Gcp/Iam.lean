import Infra.Providers.Gcp.Rest
import Infra.Core.Stage
import Infra.Core.Ownership
import Linen.Data.Base64

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

  ## Policies are roles, bound on the project

  An element of `policies` is a role name — `roles/storage.objectViewer`,
  `roles/cloudsql.client` — granted to this service account on the project the
  credentials name. That is GCP's column of the table in
  `Infra.Providers.Kinds.Iam`'s module note.

  ### Why this was refused for so long, and what changed

  Granting a role to a service account is not an operation on the service
  account. It is a **read-modify-write of the whole project's IAM policy**
  (`getIamPolicy`, edit, `setIamPolicy`), and a write that sends back a policy
  assembled incorrectly removes every binding it failed to include — for the
  entire project, not just for this identity. So `create` and `update` used to
  raise, printing the `gcloud` command that would do it, on the reasoning that
  a loud refusal beats code whose failure mode is silently deleting other
  people's access.

  It is implemented now, and the three things that make it safe are worth
  naming, because each one is a way the obvious implementation gets it wrong:

  1. **The policy object is edited, not rebuilt.** `setIamPolicy` takes back
     the whole object, and a reconstruction from the fields this library knows
     about would drop `auditConfigs` and anything Google adds later.
     `JsonRead.setField` replaces the `bindings` key and copies the rest
     through untouched; each binding is edited the same way, so a field on a
     binding that is not `members` survives too.
  2. **The `etag` is sent back.** It is inside the policy object and therefore
     travels for free with (1). It is what makes this optimistic-concurrency
     rather than last-writer-wins: a policy edited by somebody else between
     the read and the write makes the write *fail*, which is the outcome to
     want.
  3. **Conditional bindings are left alone entirely.** A binding with a
     `condition` is a different grant from an unconditional one of the same
     role, so matching on the role alone would merge two things that are not
     the same. This code reads and writes only unconditional bindings; a
     conditional binding mentioning this service account is reported by
     `readPolicies` (it is a real grant) and refused by `setPolicies` (it is
     not one this declaration can express), rather than silently rewritten.

  What is still true: this touches the project's IAM policy, and the identity
  running it needs `resourcemanager.projects.setIamPolicy`. A CI identity that
  has only the read half gets `readPolicies`' `unknown` and a clear failure
  from the write.

  ## The marker goes in `description`

  A GCP service account has no `labels` field — labels on this API surface
  live on the *project*, not on individual service accounts, and the only
  alternative (Resource Manager TagBindings) is a different API and permission
  model, out of scope here. But it does have a settable, patchable
  `description` (confirmed in the IAM v1 discovery document, 2026-09-19), and
  that is a place to write a marker.

  So this kind sits on the **second rung** of `Ownership`'s ladder: the
  marker is serialised with `encodeMarkerText`, read back with
  `decodeMarkerText`, and reaches `ownershipOf` as the same tag list a tagged
  resource produces. It is a real inclusion marker, not a fallback to naming,
  and `Backend.ownershipInfo` no longer answers `.unreadable` for `.iam` on
  GCP — which is what used to make a service account unadoptable and
  undeletable-as-orphan.

  `displayName` is left to the account id, as before; `description` is this
  tool's, and a declaration has no field that competes for it.
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

/-! ### The project's IAM policy

  Three functions share one shape: fetch the policy, look at its `bindings`,
  and — for the writer — hand the whole object back with only that key
  changed. See the module note for why the object is edited rather than
  rebuilt. -/

/-- Fetch the project's IAM policy as the opaque object it has to be handed
    back as. -/
private def getPolicy (creds : Credentials) (project : String) : IO Value :=
  Gcp.call creds "POST" crmHost s!"/v1/projects/{project}:getIamPolicy"
    (payload := some (.object []))

/-- Whether a binding carries an IAM condition.

    Load-bearing: a conditional binding is a *different grant* from an
    unconditional one naming the same role, so the two must never be merged.
    Everything below either skips these or refuses because of them. -/
private def isConditional (b : Value) : Bool := (field b "condition").isSome

/-- The roles bound to this service account in the project's IAM policy.

    Read-only, and reports **every** binding that names this member,
    conditional ones included: a conditional grant is a grant, and a `plan`
    that hid it would understate what the identity can do. `setPolicies`
    refuses rather than rewriting those, so the pair stays honest in both
    directions. -/
def readPolicies (creds : Credentials) (project accountId : String) :
    IO (Partial (List String)) := do
  let member := s!"serviceAccount:{emailOf project accountId}"
  match ← (getPolicy creds project).toBaseIO with
  | .error _ =>
    -- Reading the project policy needs `resourcemanager.projects.getIamPolicy`,
    -- which a narrowly-scoped CI identity may well not have. That is not a
    -- reason to fail the whole pull, so it reports unknown — which diverges
    -- from nothing.
    return .unknown
  | .ok policy =>
    let roles := (arrayField policy "bindings").filterMap fun b =>
      if (stringArrayField b "members").contains member then stringField b "role" else none
    return .known roles.eraseDups

/-- Make this service account's project-level roles be exactly `wanted`.

    The read-modify-write the module note describes, and the three safety
    properties it names are each one line of this:

    * the policy object arrives from `getPolicy` and leaves through
      `setField "bindings"`, so `etag`, `version`, `auditConfigs` and anything
      unknown pass through untouched;
    * each surviving binding is likewise edited with `setField "members"`
      rather than rebuilt;
    * `isConditional` bindings are skipped by the editor and refused up front,
      so no conditional grant is ever silently rewritten.

    A binding this identity is removed from and which then has no members left
    is dropped: an empty `members` is rejected by `setIamPolicy`. A binding
    that still holds other members keeps them, which is the whole point.

    Writes nothing when nothing changes. That is not only an optimisation:
    `setIamPolicy` on an unchanged policy still bumps the etag and shows up in
    the project's audit log, and a fleet whose every apply rewrote the
    project's IAM policy would be indistinguishable, in that log, from one
    that was actually changing it. -/
def setPolicies (creds : Credentials) (project accountId : String)
    (wanted : List String) : IO Unit := do
  let member := s!"serviceAccount:{emailOf project accountId}"
  -- Named, because this is the one call here that needs a project-level
  -- permission rather than a service-account-level one, and a CI identity
  -- holding `roles/iam.serviceAccountAdmin` and nothing else does not have
  -- it. `readPolicies` answers `unknown` in that case and diverges from
  -- nothing, so a fleet that declares no policies never reaches this; one
  -- that does should be told which grant is missing rather than shown
  -- Google's own message about a resource it did not know it was touching.
  let policy ← match ← (getPolicy creds project).toBaseIO with
    | .ok v    => pure v
    | .error e => throw (IO.userError s!"gcp iam: cannot read project \
'{project}''s IAM policy, which is where a role is bound — so the roles \
declared for '{accountId}' cannot be reconciled.\n  This needs \
`resourcemanager.projects.getIamPolicy` (and `setIamPolicy` to write), which \
`roles/iam.serviceAccountAdmin` does not include.\n  {e}")
  let bindings := arrayField policy "bindings"
  let conditional := bindings.filter fun b =>
    isConditional b && (stringArrayField b "members").contains member
  unless conditional.isEmpty do
    throw (IO.userError s!"gcp iam: '{accountId}' appears in {conditional.length} conditional role binding(s) on project '{project}' — {String.intercalate ", " (conditional.filterMap (stringField · "role"))}. A conditional binding is a different grant from an unconditional one of the same role, and `policies` cannot express the condition, so rewriting it here would change what it means. Remove the condition, or take this identity out of those bindings, and `plan` will converge.")
  -- Edit in place: each binding keeps every field it had, minus this member
  -- where it is no longer wanted and plus it where it now is.
  let edited := bindings.filterMap fun b =>
    if isConditional b then some b else
    match stringField b "role" with
    | none      => some b
    | some role =>
      let ms := stringArrayField b "members"
      let ms' :=
        if wanted.contains role then (if ms.contains member then ms else ms ++ [member])
        else ms.filter (· != member)
      if ms'.isEmpty then none
      else some (setField b "members" (.array (ms'.map Value.string).toArray))
  -- Roles asked for that no unconditional binding covers yet.
  let covered := bindings.filterMap fun b =>
    if isConditional b then none else stringField b "role"
  let added := (wanted.filter (!covered.contains ·)).eraseDups.map fun role =>
    Value.object [("role", .string role), ("members", .array #[.string member])]
  let bindings' := edited ++ added
  if bindings' == bindings then
    return ()
  let policy' := setField policy "bindings" (.array bindings'.toArray)
  discard <| Gcp.call creds "POST" crmHost s!"/v1/projects/{project}:setIamPolicy"
    (payload := some (.object [("policy", policy')]))

/-- Create the service account, with the ownership marker in its description.
    Returns its email.

    Policies are bound afterwards rather than in the create call: there is no
    way to ask for them here, because a role binding is an edit to the
    *project*, not a field of the account. -/
def create (creds : Credentials) (project accountId markerValue : String)
    (policies : List String) : IO String := do
  checkAccountId accountId
  let payload : Value := .object
    [ ("accountId", .string accountId)
    , ("serviceAccount", .object
        [ ("displayName", .string accountId)
        , ("description", .string (encodeMarkerText markerValue)) ]) ]
  let reply ← Gcp.call creds "POST" host s!"/v1/projects/{project}/serviceAccounts"
    (payload := some payload)
  let email := (stringField reply "email").getD (emailOf project accountId)
  unless policies.isEmpty do
    setPolicies creds project accountId policies
  return email

/-- The marker, for `Ownership.ownershipOf`, out of the account's description.

    The second rung of the ladder: no tags on this object, one writable string,
    and `decodeMarkerText` turns it back into the tag list the rule speaks in.
    A description a human wrote decodes to a tag whose key is that text, which
    correctly reads as "not ours" without being mistaken for "never touched".

    `createdAt` is `none`: a service account has no creation timestamp on this
    API surface at all, so there is nothing to age out against
    `Boundary.since`. -/
def readOwnership (creds : Credentials) (project accountId : String) : IO Evidence := do
  match ← (Gcp.call creds "GET" host (saPath project accountId)).toBaseIO with
  | .error _ => return .unreadable
  | .ok sa   => return .tags (decodeMarkerText ((stringField sa "description").getD "")) none

/-- Re-assert the marker on an existing account.

    `update` has to write it as well as `create`, for the reason S3's tag
    handling does: an account whose description was cleared by hand would
    otherwise stay unmarked for ever, and a marker that only creation writes
    is a marker that decays. -/
def putMarker (creds : Credentials) (project accountId markerValue : String) : IO Unit := do
  discard <| Gcp.call creds "PATCH" host (saPath project accountId)
    (query := [])
    (payload := some (.object
      [ ("serviceAccount", .object
          [("description", .string (encodeMarkerText markerValue))])
      , ("updateMask", .string "description") ]))

/-! ### Service-account keys

  A key's private half is returned by `create` and by nothing else — the
  discovery document says so in as many words of `privateKeyData`: "Only
  provided in `CreateServiceAccountKey` responses." Same one-shot shape as
  AWS's and Scaleway's, and the same reason `SecretSource.apiKeyFor` has to
  mint straight into a secret. -/

/-- Mint a key for a service account. Returns `(keyId, the key file's JSON)`.

    The "secret" for GCP is a whole credentials **file**, not a password: what
    comes back is base64 of the JSON that `GOOGLE_APPLICATION_CREDENTIALS`
    would point at, so it is decoded here and stored as the file's own text.
    Anything else would make the secret unusable without a decoding step
    nobody would guess at.

    The key id is the last segment of the resource name, and is the only part
    safe to record: `Live.lean` puts it in `SecretsObserved.accessKey`, which
    is cached and printed. -/
def createKey (creds : Credentials) (project accountId : String) :
    IO (String × String) := do
  let reply ← Gcp.call creds "POST" host (saPath project accountId ++ "/keys")
    (payload := some (.object
      [ ("privateKeyType", .string "TYPE_GOOGLE_CREDENTIALS_FILE")
      , ("keyAlgorithm", .string "KEY_ALG_RSA_2048") ]))
  let keyId := ((stringField reply "name").getD "").splitOn "/" |>.getLast!
  match stringField reply "privateKeyData" with
  | none => throw (IO.userError s!"gcp iam: the key for '{accountId}' was created but carried no privateKeyData, and Google will not return it again. Delete the key and retry.")
  | some encoded =>
    match Data.Base64.decode encoded with
    | some bytes => return (keyId, String.fromUTF8! bytes)
    | none       => throw (IO.userError
        s!"gcp iam: the key for '{accountId}' is not valid base64")

/-- The **user-managed** keys of a service account, by key id.

    Filtered on both sides — the `keyTypes` query parameter and the returned
    `keyType` — because every service account also carries Google-managed
    keys it rotates itself, which are not ours, cannot be deleted, and would
    make "this account has no keys" impossible to assert.

    Its only caller is the live test, which uses it to prove that deleting a
    minted-key secret really deletes the key. -/
def listUserKeys (creds : Credentials) (project accountId : String) :
    IO (List String) := do
  let reply ← Gcp.call creds "GET" host (saPath project accountId ++ "/keys")
    [("keyTypes", some "USER_MANAGED")]
  return (arrayField reply "keys").filterMap fun k =>
    if stringField k "keyType" == some "SYSTEM_MANAGED" then none
    else (stringField k "name").map fun n => (n.splitOn "/").getLast!

/-- Delete one key. Already gone is not an error, and neither is a
    Google-managed key refusing to be deleted — those are not ours to remove
    and exist on every service account. -/
def deleteKey (creds : Credentials) (project accountId keyId : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (saPath project accountId ++ s!"/keys/{keyId}")).toBaseIO with
  | .ok _ => pure ()
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e

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
