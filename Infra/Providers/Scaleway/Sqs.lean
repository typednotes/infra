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

  ## Where there is no keychain

  That cache is what makes minting a one-off, and a CI runner does not have
  one — no keychain daemon, so the lookup misses and the store fails. The
  store failing is handled (it warns rather than throwing, since caching must
  not be able to fail the thing it optimises), but the consequence is not
  handled and should be understood before pointing CI at a real project:

  **every run mints another credential, and nothing deletes it.** The secret
  is shown once, so an existing credential cannot be recovered and reused —
  minting really is the only option once the cache is cold. A CI job that runs
  daily therefore leaves a growing pile of credentials named `infra` in the
  Scaleway console.

  The fix is for the live test to delete the credential it minted, which needs
  the id from the mint response and a `DELETE .../sqs-credentials/{id}`.
  Not done; recorded in `docs/coverage.md`.
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
    treated as fatal — only a failed mint afterwards is.

    It does **return** the failure rather than discard it, though. Swallowing
    it entirely was a mistake: when activation fails for a real reason — a
    wrong path, an unsupported region, a project without the product — the
    mint that follows fails too, and its error is the only one anyone sees.
    Two calls fail, one message survives, and it describes the second. -/
private def activate (creds : Credentials) (region project : String) :
    IO (Option String) := do
  match ← (Scaleway.call creds "POST" (prefix' region ++ "/activate-sqs")
      (payload := some (.object [("project_id", .string project)]))).toBaseIO with
  | .ok _    => return none
  | .error e => return some (toString e)

/-- Mint a fresh dedicated credential, named so it is recognisable among any
    others in the Scaleway console. Full permissions: this credential is used
    for every SQS operation `infra` performs, not just publishing. -/
private def mint (creds : Credentials) (region project : String) : IO Credentials := do
  let path := prefix' region ++ "/sqs-credentials"
  let reply ← Scaleway.call creds "POST" path
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
      let activationError ← activate creds creds.region project
      -- Name the call, the path and the region. `HTTP 404 not_found` on its
      -- own does not say which of the three requests in this flow produced
      -- it, and they are provisioning, minting and the queue operation
      -- itself — three different problems with three different fixes.
      let c ← match ← (mint creds creds.region project).toBaseIO with
        | .ok c => pure c
        | .error e =>
          let also := match activationError with
            | some a => s!"\n  activation had already failed with: {a}"
            | none   => ""
          throw (IO.userError s!"scaleway queues: could not mint a dedicated SQS \
credential for project {project} in {creds.region}\n  POST {Scaleway.host}{prefix' creds.region}/sqs-credentials\n  {e}{also}")
      -- Caching is an optimisation, not a requirement, and it must not be
      -- able to fail the operation it is optimising. A CI runner has no
      -- keychain daemon, so this throws there — after a successful mint,
      -- which would waste the credential and report a confusing error.
      match ← (storeInKeychainAccount keychainAccount c).toBaseIO with
      | .ok _ => pure ()
      | .error e =>
        -- Said out loud, because the consequence is not free: see the module
        -- note. Without a cache every run mints another credential.
        IO.eprintln s!"warning: minted a Scaleway SQS credential but could not \
cache it ({e}); it will be minted again next run — see docs/providers.md"
      return c

end Infra.Providers.Scaleway.Sqs
