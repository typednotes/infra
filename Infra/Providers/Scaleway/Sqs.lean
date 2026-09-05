import Infra.Providers.Scaleway.Rest
import Linen.System.Keychain
import Linen.Data.Ini

/-
  Scaleway Queues' own credentials.

  The SQS-compatible endpoint (`Infra.Providers.Aws.Protocols.sqsEndpoint`)
  refuses the main Scaleway API key entirely: signing a queue request needs a
  *dedicated* access/secret key pair, minted by the native Scaleway API after
  a one-time activation call —

    POST /mnq/v1beta1/regions/{region}/activate-sqs    {project_id}
    POST /mnq/v1beta1/regions/{region}/sqs-credentials {project_id, name, permissions}

  — confirmed against Scaleway's own developer reference for the Queues SQS
  API. The mint call has no "get or create by name": calling it twice makes
  two credentials, and the secret is only ever shown once. So the first
  credential minted is cached in the OS keychain (same store as
  `Infra.Core.Credentials`, a different account) and reused from then on,
  rather than reprovisioned on every `push`.
-/

namespace Infra.Providers.Scaleway.Sqs

open Infra.Core
open Infra.Providers
open Infra.Providers.JsonRead
open Data.Json (Value)

private def prefix' (region : String) : String := Scaleway.regionalPrefix "mnq" "v1beta1" region

/-- The keychain account the dedicated SQS credential is cached under. Distinct
    from the main `scaleway` account `Infra.Core.Credentials` uses. -/
private def keychainAccount : String := "scaleway-sqs"

/-- Best-effort: a project that is already active answers activation the same
    as one just activated in every observed case, so a failure here is not
    treated as fatal — only a failed mint afterwards is. -/
private def activate (creds : Credentials) (region project : String) : IO Unit := do
  discard <| (Scaleway.call creds "POST" (prefix' region ++ "/activate-sqs")
    (payload := some (.object [("project_id", .string project)]))).toBaseIO

/-- Mint a fresh dedicated credential, named so it is recognisable among any
    others in the Scaleway console. Full permissions: this credential is used
    for every SQS operation `infra` performs, not just publishing. -/
private def mint (creds : Credentials) (region project : String) : IO Credentials := do
  let reply ← Scaleway.call creds "POST" (prefix' region ++ "/sqs-credentials")
    (payload := some (.object
      [ ("project_id", .string project)
      , ("name", .string "infra")
      , ("permissions", .object
          [ ("can_publish", .bool true)
          , ("can_receive", .bool true)
          , ("can_manage",  .bool true) ]) ]))
  match stringField reply "access_key", stringField reply "secret_key" with
  | some accessKey, some secretKey => return { accessKey, secretKey, region }
  | _, _ => throw (IO.userError
      "scaleway sqs-credentials: no access_key/secret_key in the response")

/-- The credentials to sign a Queues request with.

    AWS needs no separate step: its SQS accepts the same credentials as
    everything else. Scaleway does — see the module note — so the dedicated
    credential is fetched from the keychain, or provisioned and cached there
    on first use. -/
def credentialsFor (provider : ProviderId) (creds : Credentials) : IO Credentials := do
  match provider with
  | .aws => pure creds
  -- GCP's queues are Pub/Sub, which this SQS client cannot speak. Raising
  -- names the pairing rather than handing back a credential that would be
  -- used to sign a request to a host that does not exist.
  | .gcp => throw (IO.userError
      "queues on gcp: Pub/Sub is not SQS-compatible, and no Pub/Sub backend exists yet")
  | .scaleway =>
    match ← fromKeychainAccount keychainAccount with
    | some c => return c
    | none =>
      let project ← creds.requireProject
      activate creds creds.region project
      let c ← mint creds creds.region project
      storeInKeychainAccount keychainAccount c
      return c

end Infra.Providers.Scaleway.Sqs
