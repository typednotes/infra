import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest
import Infra.Providers.Gcp.SecretManager
import Infra.Core.Stage
import Linen.Data.Base64
import Linen.Data.Time.Clock

/-
  Secret storage.

  Two unrelated APIs behind one kind: AWS Secrets Manager (AWS-JSON 1.1) and
  Scaleway Secret Manager (REST, with the value base64-encoded).

  ## The value never round-trips

  `SecretsSpec.valueFrom` names an environment variable. This module reads that
  variable at the moment of writing and sends it, and **never reads a value
  back** — `read` asks only for metadata. Neither cloud's `GetSecretValue` is
  called anywhere here.

  That is a deliberate asymmetry, and it has a consequence worth stating: a
  secret changed outside this tool is not detected as drift. Detecting it would
  mean pulling plaintext into the engine, the `Sighting`, and potentially the
  `.infra/` cache — a far worse trade than missing a drift.

  A missing environment variable is an error naming the variable, not an empty
  secret: silently writing `""` as a password is the kind of failure that is
  discovered much later and much more expensively.
-/

namespace Infra.Providers.Kinds.Secrets

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws
open Infra.Providers.JsonRead
open Data.Json (Value)

/-- Read the value a target points at, or fail naming the variable. -/
def valueFromEnv (varName : String) : IO String := do
  match ← IO.getEnv varName with
  | some v => return v
  | none   => throw (IO.userError
      s!"secret value not available: environment variable '{varName}' is not set")

/-- Read a secret's value directly, for binding it into another resource's environment (see
    `Kinds.Compute`'s `.scalewayContainer` support). Narrowly scoped exactly like
    `Kinds.Postgres.fetchMasterPassword`: read once, hand straight to the create/update call
    that needs it, never stored or returned any further than that — the module note above
    about values only ever travelling outward does not apply to this one function.

    **Unconfirmed against the real API**: whether Scaleway's actual secret-binding mechanism
    for containers wants the plaintext value at all, or a native reference that never leaves
    Secret Manager. This assumes the former — see `docs/providers.md`. -/
def fetchValue (provider : ProviderId) (creds : Credentials) (secretName : String) :
    IO String := do
  if secretName.isEmpty then
    throw (IO.userError "a secretEnv reference points at an unnamed secret")
  match provider with
  -- Google's `:access` sub-resource on a version, which is the only call in
  -- this file that returns plaintext by design. `latest` is an alias the API
  -- accepts in place of a version number, so this is one call rather than a
  -- list-and-sort.
  --
  -- This branch was missing while `Gcp.SecretManager` had list, create, put
  -- and delete — everything except *reading a value*, which nothing else
  -- needs. Composed secrets do, and the gap surfaced the first time a live
  -- GCP fleet declared one: `derived-a` could not be built because the base
  -- secret's value could not be fetched. A kind can be "implemented" and
  -- still be missing the one path a dependency between resources requires.
  | .gcp =>
    let project ← Gcp.requireProject creds
    let reply ← Gcp.call creds "GET" Gcp.SecretManager.host
      s!"/v1/projects/{project}/secrets/{secretName}/versions/latest:access"
    match (field reply "payload").bind (stringField · "data") with
    | some encoded =>
      -- Base64 in the wire format: the API's encoding of a byte string, not
      -- an attempt to obscure anything.
      match Data.Base64.decode encoded with
      | some bytes => return String.fromUTF8! bytes
      | none       => throw (IO.userError
          s!"gcp secret '{secretName}': value is not valid base64")
    | none => throw (IO.userError
        s!"gcp secret '{secretName}': the access response carried no payload")
  | .aws =>
    let ep := Json.secretsEndpoint creds.region
    let reply ← Json.call creds ep "secretsmanager.GetSecretValue"
      (.object [("SecretId", .string secretName)])
    match stringField reply "SecretString" with
    | some v => return v
    | none   => throw (IO.userError s!"secret '{secretName}' holds no string value")
  | .scaleway =>
    -- Scaleway returns the value base64-encoded from a versioned endpoint.
    let pfx := Scaleway.regionalPrefix "secret-manager" "v1beta1" creds.region
    let listing ← Scaleway.call creds "GET" (pfx ++ "/secrets")
        (query := [("project_id", ← creds.requireProject)])
    match (arrayField listing "secrets").find? (fun s => stringField s "name" == some secretName) with
    | none => throw (IO.userError s!"scaleway secrets: no secret named '{secretName}'")
    | some s =>
      let id := (stringField s "id").getD ""
      let reply ← Scaleway.call creds "GET" (pfx ++ s!"/secrets/{id}/versions/latest/access")
      match stringField reply "data" with
      | some encoded =>
        match Data.Base64.decode encoded with
        | some bytes => return String.fromUTF8! bytes
        | none       => throw (IO.userError s!"secret '{secretName}': value is not valid base64")
      | none => throw (IO.userError s!"secret '{secretName}' holds no data")

-- ══════════════════════════════════════════════════════════════
-- AWS Secrets Manager
-- ══════════════════════════════════════════════════════════════

namespace Asm

private def target (op : String) : String := s!"secretsmanager.{op}"

/-- Every secret's name. -/
def list (creds : Credentials) (ep : Endpoint) : IO (List String) := do
  let reply ← Json.call creds ep (target "ListSecrets") (.object [])
  return (arrayField reply "SecretList").filterMap (stringField · "Name")

/-- Metadata only. `DescribeSecret` deliberately, not `GetSecretValue`: this
    must not pull plaintext into the engine. -/
def describeVersion (creds : Credentials) (ep : Endpoint) (name : String) : IO String := do
  let reply ← Json.call creds ep (target "DescribeSecret")
    (.object [("SecretId", .string name)])
  -- `VersionIdsToStages` is keyed by version id; any one identifies the
  -- current contents well enough to show a human.
  match field reply "VersionIdsToStages" with
  | some (.object ((v, _) :: _)) => return v
  | _                            => return ""

/-- A fresh idempotency token for Secrets Manager.

    `CreateSecret` and `PutSecretValue` both take a `ClientRequestToken`, and
    the API reference calls it optional — which it is *through an SDK*, because
    every SDK generates one when the caller omits it. Calling the API directly
    without one is rejected outright:

        HTTP 400 InvalidRequestException: You must provide a
        ClientRequestToken value. We recommend a UUID-type value.

    So it is not optional here, and this is the kind of gap that only a real
    account finds: nothing offline distinguishes a field an SDK fills in from
    one the service defaults.

    32 hex characters, which satisfies the documented 32–64 length. Time gives
    monotonicity and `IO.rand` guards against two calls inside the same
    nanosecond tick. It must be *fresh per call* rather than derived from the
    secret's contents: the token is an idempotency key, so reusing one with
    different contents is itself an error, and a fleet that writes two versions
    of a secret in one apply would collide with itself. -/
private def requestToken : IO String := do
  let now ← Data.Time.getCurrentTime
  let hi ← IO.rand 0 (2 ^ 32 - 1)
  let hex (n : Nat) (width : Nat) : String :=
    let digits := String.ofList (Nat.toDigits 16 n)
    -- Left-pad, so the token is a fixed width whatever the value.
    (String.ofList (List.replicate (width - min width digits.length) '0')) ++ digits
  return hex now.nanosSinceEpoch 24 ++ hex hi 8

def create (creds : Credentials) (ep : Endpoint) (name value : String) : IO String := do
  let reply ← Json.call creds ep (target "CreateSecret")
    (.object [ ("Name", .string name), ("SecretString", .string value)
             , ("ClientRequestToken", .string (← requestToken)) ])
  return (stringField reply "VersionId").getD ""

def putValue (creds : Credentials) (ep : Endpoint) (name value : String) : IO String := do
  let reply ← Json.call creds ep (target "PutSecretValue")
    (.object [ ("SecretId", .string name), ("SecretString", .string value)
             , ("ClientRequestToken", .string (← requestToken)) ])
  return (stringField reply "VersionId").getD ""

/-- Delete immediately rather than entering the recovery window.

    Without `ForceDeleteWithoutRecovery` the secret lingers for days and the
    name stays taken, so a plan that deletes and recreates would fail on the
    recreate — the target would never converge. -/
def delete (creds : Credentials) (ep : Endpoint) (name : String) : IO Unit := do
  discard <| Json.call creds ep (target "DeleteSecret")
    (.object [("SecretId", .string name), ("ForceDeleteWithoutRecovery", .bool true)])


/-- Exposed only so the self-check suite can verify the token's shape without
    an AWS account: length, alphabet and freshness are checkable offline, and
    the bug this fixes was invisible offline precisely because nothing checked
    them. -/
def requestTokenForCheck : IO String := requestToken

end Asm

-- ══════════════════════════════════════════════════════════════
-- Scaleway Secret Manager
-- ══════════════════════════════════════════════════════════════

namespace Scw

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "secret-manager" "v1beta1" region

private def listRaw (creds : Credentials) : IO (List (String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/secrets")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "secrets").filterMap fun s =>
    match stringField s "name", stringField s "id" with
    | some n, some i => some (n, i)
    | _,      _      => none

def list (creds : Credentials) : IO (List String) := do
  return (← listRaw creds).map (·.1)

/-- Scaleway addresses secrets by UUID, so every operation resolves the name
    first. The extra call keeps fleet keys readable. -/
private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id) => return id
  | none         => throw (IO.userError s!"scaleway secrets: no secret named '{name}'")

/-- The number of versions, as a stand-in for "which contents". Metadata only:
    the value itself is never fetched. -/
def describeVersion (creds : Credentials) (name : String) : IO String := do
  let id ← requireId creds name
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/secrets/{id}")
  return (stringField reply "version_count").getD ""

/-- Scaleway takes the value base64-encoded. -/
private def addVersion (creds : Credentials) (id value : String) : IO String := do
  let reply ← Scaleway.call creds "POST"
    (prefix' creds.region ++ s!"/secrets/{id}/versions")
    (payload := some (.object [("data", .string (Data.Base64.encode value.toUTF8))]))
  return (stringField reply "revision").getD ""

def create (creds : Credentials) (name value : String) : IO String := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/secrets")
    (payload := some (.object [("name", .string name), ("project_id", .string project)]))
  match stringField reply "id" with
  | some id => addVersion creds id value
  | none    => throw (IO.userError s!"scaleway secrets: create returned no id for '{name}'")

def putValue (creds : Credentials) (name value : String) : IO String := do
  addVersion creds (← requireId creds name) value

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/secrets/{id}")

end Scw

end Infra.Providers.Kinds.Secrets
