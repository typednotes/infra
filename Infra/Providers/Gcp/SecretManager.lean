import Infra.Providers.Gcp.Rest
import Infra.Core.Stage
import Linen.Data.Base64

/-
  Secrets on GCP, over Secret Manager.

  ## A secret and its value are two resources

  AWS and Scaleway both let one call create a secret and give it a value.
  Secret Manager does not: a *secret* is a container with a replication policy
  and no data, and a *version* holds the bytes. Creating a secret with a value
  is therefore two calls, and there is no way to make it one.

  That has a consequence worth stating rather than discovering. If the second
  call fails, the secret exists and is empty — and an empty secret is not the
  same as an absent one, because the next `create` will fail with
  `ALREADY_EXISTS` while the value is still missing. So the version is added
  first-thing after creation and a failure there says exactly what state was
  left behind, which is the only way the reader can tell those two situations
  apart.

  ## The value never lands anywhere it can be read back

  Same discipline as the other two clouds: the plaintext goes into the request
  body and nowhere else. It is not logged, not put in a URL, and not returned.
  `read` reports the version identifier only — `Infra.Providers.Kinds.Secrets`
  explains why fetching a secret in order to diff it would be a worse trade
  than not diffing it.

  Endpoints and field names checked against Google's Secret Manager REST
  reference (`v1`, `projects.secrets` and `projects.secrets.versions`), 2026-09.
-/

namespace Infra.Providers.Gcp.SecretManager

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)
open Network.HTTP.Types (Query)

def host : String := "secretmanager.googleapis.com"

private def secretPath (project name : String) : String :=
  s!"/v1/projects/{project}/secrets/{name}"

/-- Every secret in the project, by short name. -/
def list (creds : Credentials) (project : String) : IO (List String) := do
  let rec go (fuel : Nat) (token : String) (acc : List String) : IO (List String) := do
    match fuel with
    | 0 =>
      IO.eprintln "warning: gcp secret manager: stopped paginating secrets after 50 \
pages; the list may be incomplete"
      return acc
    | fuel' + 1 =>
      let query : Query := if token.isEmpty then [] else [("pageToken", some token)]
      let reply ← Gcp.call creds "GET" host s!"/v1/projects/{project}/secrets" query
      let here := (arrayField reply "secrets").filterMap fun s =>
        (stringField s "name").map Gcp.shortName
      let acc := acc ++ here
      match stringField reply "nextPageToken" with
      | some next => if next.isEmpty then return acc else go fuel' next acc
      | none      => return acc
  go 50 "" []

/-- The newest enabled version's identifier, as an opaque string.

    `latest` is an alias the API accepts in place of a number, so this is one
    call rather than a list-and-sort. -/
def describeVersion (creds : Credentials) (project name : String) : IO String := do
  let reply ← Gcp.call creds "GET" host (secretPath project name ++ "/versions/latest")
  return ((stringField reply "name").map Gcp.shortName).getD ""

/-- Add a version holding `value`. Returns the version identifier.

    The payload is base64 in the wire format — that is the API's encoding of a
    byte string, not an attempt to obscure anything. -/
def addVersion (creds : Credentials) (project name value : String) : IO String := do
  let payload : Value := .object
    [("payload", .object [("data", .string (Data.Base64.encode value.toUTF8))])]
  let reply ← Gcp.call creds "POST" host (secretPath project name ++ ":addVersion")
    (payload := some payload)
  return ((stringField reply "name").map Gcp.shortName).getD ""

/-- Create the secret, then give it its first value.

    Two calls, and the failure of the second is reported with what it left
    behind — see the module note. `automatic` replication is chosen because the
    alternative is naming regions, and a secret's replication policy is not
    something the portable spec has a field for; a project with an org policy
    forbidding automatic replication will get a clear error from Google here
    rather than a wrong guess from us. -/
def create (creds : Credentials) (project name value : String) : IO String := do
  discard <| Gcp.call creds "POST" host s!"/v1/projects/{project}/secrets"
    [("secretId", some name)]
    (payload := some (.object [("replication", .object [("automatic", .object [])])]))
  match ← (addVersion creds project name value).toBaseIO with
  | .ok v => return v
  | .error e =>
    throw (IO.userError s!"gcp secret manager: created the secret '{name}' but could \
not add its value\n  The secret now EXISTS AND IS EMPTY, so a retry will fail \
with ALREADY_EXISTS while the value is still missing. Either add a version by \
hand or delete the secret and re-apply.\n  {e}")

/-- Give an existing secret a new value. Returns the version identifier.

    Prior versions are left in place: Secret Manager keeps them, and destroying
    history is not this call's decision. -/
def putValue (creds : Credentials) (project name value : String) : IO String :=
  addVersion creds project name value

/-- Delete the secret and every version of it. Already gone is not an error. -/
def delete (creds : Credentials) (project name : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (secretPath project name)).toBaseIO with
  | .ok _ => pure ()
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e

end Infra.Providers.Gcp.SecretManager
