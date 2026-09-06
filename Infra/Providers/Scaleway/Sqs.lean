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

  every run has to mint again. The secret is shown once, so an existing
  credential cannot be recovered and reused — minting really is the only
  option once the cache is cold.

  That alone would leave a growing pile of credentials in the console, and
  worse: the mint call rejects a **duplicate name**, so the very first
  uncaptured mint takes the name `infra` and every later attempt dies on
  `409 already_exists` — permanently, in that project, with no way out from
  inside the tool. Which is exactly what a CI run did.

  So the name is treated as an identity that can be reclaimed: on `409`, the
  credential holding it is deleted and a fresh one minted. This is safe
  because an uncaptured secret is unrecoverable, so the credential being
  deleted cannot authenticate anything and has no value to lose. It also
  bounds the count — exactly one credential named `infra` exists, however many
  times CI runs.

  The cost is a rule: **`infra` is this library's name.** A hand-made
  credential called `infra` will be deleted out from under whatever uses it.
-/

namespace Infra.Providers.Scaleway.Sqs

open Infra.Core
open Infra.Providers
open Infra.Providers.JsonRead
open Data.Json (Value)

private def prefix' (region : String) : String := Scaleway.regionalPrefix "mnq" "v1beta1" region

/-! ## Why there is an in-process cache as well as a keychain one

  `credentialsFor` is called by every queues operation — five call sites in
  `Infra.Providers.Live` — and `pull` runs one of them per listing. The live
  test polls `pull` once a second for up to three minutes, so a single run
  reaches this function a few hundred times.

  With a working keychain that is free: the first call mints, the rest read the
  cache. Without one — a CI runner has no keychain daemon — every call missed,
  and once `reclaim` made a duplicate-name mint *succeed* instead of failing at
  `409`, each miss deleted the previous credential and minted another. One run
  churned two dozen before anyone looked.

  That is worse than the deadlock it replaced. It hammers Scaleway's IAM, it
  will eventually be rate-limited, and it leaves the account's credential list
  thrashing.

  So the memo below is not an optimisation, it is the fix: mint at most once
  per process, whatever the keychain does. The keychain cache stays because it
  makes the *next run* free too, on a machine that has one.
-/

/-- Credentials minted in this process, keyed by project and region.

    Not a `Credentials` on its own: a fleet can name resources in more than one
    region, and Scaleway's SQS credentials are regional. -/
initialize mintedThisRun : IO.Ref (List ((String × String) × Credentials)) ← IO.mkRef []

/-- The keychain account the dedicated SQS credential is cached under. Distinct
    from the main `scaleway` account `Infra.Core.Credentials` uses. -/
private def keychainAccount : String := "scaleway-sqs"

/-- The name this library gives the credential it manages.

    It is an **identity, not a label**: the mint call rejects a duplicate name,
    so exactly one credential may carry this one, and `reclaim` will delete
    whatever holds it. Do not name a hand-made credential `infra`. -/
private def credentialName : String := "infra"

/-- Does this error mean "it is already there"? -/
private def alreadyExists (msg : String) : Bool :=
  (msg.splitOn "already_exists").length > 1 || (msg.splitOn "HTTP 409").length > 1

/-- Best-effort: a project that is already active answers activation the same
    as one just activated in every observed case, so a failure here is not
    treated as fatal — only a failed mint afterwards is.

    It does **return** the failure rather than discard it, though. Swallowing
    it entirely was a mistake: when activation fails for a real reason the
    mint that follows fails too, and its error is the only one anyone sees.
    Two calls fail, one message survives, and it describes the second.

    The failures worth recognising, each measured against the live API rather
    than read off a page:

    | Cause | Status |
    |---|---|
    | Route does not exist | `404` with **no** `type` field, so `HTTP 404 : Not Found` |
    | Region outside `fr-par`/`nl-ams` | `501 unknown service` |
    | Project has never been activated | `412 precondition_failed` — "SQS must be enabled" |
    | Key cannot see the project | `403 permissions_denied`, on resource `namespace` |
    | Missing or malformed `project_id` | `400 invalid_arguments` |

    Note what is *not* in that table: none of those is a `404 not_found`. That
    body shape needs `"type":"not_found"`, which only the by-id routes
    (`GET`/`PATCH`/`DELETE .../sqs-credentials/{id}`) produce. So a
    `not_found` seen during a create is not this call and not the mint — look
    for a stale credential id instead. -/
private def activate (creds : Credentials) (region project : String) :
    IO (Option String) := do
  match ← (Scaleway.call creds "POST" (prefix' region ++ "/activate-sqs")
      (payload := some (.object [("project_id", .string project)]))).toBaseIO with
  | .ok _    => return none
  | .error e =>
    -- An already-activated project answers `409 already_exists`, not `200`.
    -- The comment above used to claim otherwise, on no evidence; a real run
    -- said 409, and reporting that as a failure buried the actual error under
    -- a second one describing the normal state of affairs.
    if alreadyExists (toString e) then return none else return some (toString e)

/-- The id of the credential holding our name, if one does.

    Scaleway paginates list replies under a product-specific key, and the
    reply for this one is not documented alongside the create call. Both
    plausible spellings are read; the wrong one is simply an empty list, which
    is cheaper than being wrong about which is right. -/
private def existingId (creds : Credentials) (region project : String) :
    IO (Option String) := do
  let reply ← Scaleway.call creds "GET" (prefix' region ++ "/sqs-credentials")
    (query := [("project_id", project)])
  let entries := arrayField reply "sqs_credentials" ++ arrayField reply "credentials"
  return entries.findSome? fun c =>
    if stringField c "name" == some credentialName then stringField c "id" else none

/-- Delete the credential holding our name, so a fresh one can take it.

    This exists because of a genuine dead end. Scaleway shows a minted secret
    **once**; if it is not captured, the credential is unusable forever. But
    the name stays taken, and minting rejects a duplicate name — so a single
    uncaptured mint permanently breaks every future provisioning attempt in
    that project. That is what happened: a CI run minted successfully, failed
    to cache the secret (no keychain on a runner), and every run afterwards
    died on `409 already_exists`.

    Deleting is safe precisely because the secret is unrecoverable: a
    credential we cannot authenticate with has no value to anything, so
    reclaiming its name destroys nothing that worked. It also settles the
    accumulation problem — with the name reclaimed rather than sidestepped,
    exactly one credential named `infra` ever exists, however many times CI
    runs. -/
private def reclaim (creds : Credentials) (region project : String) : IO Unit := do
  let some id ← existingId creds region project
    | throw (IO.userError s!"scaleway queues: the name '{credentialName}' is taken in project {project} ({region}), but no credential with that name was listed — delete it in the Scaleway console under Queues -> Credentials")
  discard <| Scaleway.call creds "DELETE" (prefix' region ++ "/sqs-credentials/" ++ id)

/-- Mint a fresh dedicated credential, named so it is recognisable among any
    others in the Scaleway console. Full permissions: this credential is used
    for every SQS operation `infra` performs, not just publishing. -/
private def mint (creds : Credentials) (region project : String) : IO Credentials := do
  let path := prefix' region ++ "/sqs-credentials"
  let reply ← Scaleway.call creds "POST" path
    (payload := some (.object
      [ ("project_id", .string project)
      , ("name", .string credentialName)
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
    let project ← creds.requireProject
    let key := (project, creds.region)
    -- Checked before the keychain, because it is the cheaper of the two and
    -- because it is the one that holds on a runner with no keychain at all.
    if let some c := (← mintedThisRun.get).lookup key then
      return c
    match ← fromKeychainAccount keychainAccount with
    | some c =>
      mintedThisRun.modify ((key, c) :: ·)
      return c
    | none => do
      let activationError ← activate creds creds.region project
      -- Name the call, the path and the region. `HTTP 404 not_found` on its
      -- own does not say which of the three requests in this flow produced
      -- it, and they are provisioning, minting and the queue operation
      -- itself — three different problems with three different fixes.
      let fail (e : IO.Error) : IO Credentials := do
        let also := match activationError with
          | some a => s!"\n  activation also failed with: {a}"
          | none   => ""
        throw (IO.userError s!"scaleway queues: could not mint a dedicated SQS \
credential for project {project} in {creds.region}\n  POST {Scaleway.host}{prefix' creds.region}/sqs-credentials\n  {e}{also}")
      let c ← match ← (mint creds creds.region project).toBaseIO with
        | .ok c => pure c
        | .error e =>
          -- `409 already_exists` is not a real obstacle, and it is not
          -- self-healing either: the name is held by a credential whose
          -- secret can no longer be retrieved, so waiting or retrying as-is
          -- fails identically forever. Reclaim the name and mint once more.
          -- See `reclaim` for why deleting it destroys nothing.
          if alreadyExists (toString e) then
            IO.eprintln s!"note: a Scaleway SQS credential named \
'{credentialName}' already exists in project {project} and its secret cannot \
be retrieved; replacing it"
            match ← (reclaim creds creds.region project).toBaseIO with
            | .error re => throw (IO.userError s!"scaleway queues: the credential named \
'{credentialName}' holds the name and could not be removed to free it\n  {re}")
            | .ok _ =>
              match ← (mint creds creds.region project).toBaseIO with
              | .ok c  => pure c
              | .error e2 => fail e2
          else fail e
      -- The in-process memo first, and unconditionally. This is what bounds a
      -- run to one mint: without it every one of the few hundred calls that
      -- reach this function on a keychain-less runner would mint again, and
      -- since `reclaim` makes a duplicate name succeed, each would delete the
      -- last. That is not a slow path, it is a churn loop.
      mintedThisRun.modify ((key, c) :: ·)
      -- The keychain cache second, and it is the optional one: it must not be
      -- able to fail the operation it is optimising. A CI runner has no
      -- keychain daemon, so this throws there — after a successful mint, which
      -- would waste the credential and report a confusing error.
      match ← (storeInKeychainAccount keychainAccount c).toBaseIO with
      | .ok _ => pure ()
      | .error e =>
        -- Said out loud, but no longer alarming: the memo above means this
        -- costs one extra mint per *run*, not per call.
        IO.eprintln s!"warning: minted a Scaleway SQS credential but could not \
cache it beyond this process ({e}); the next run will mint again — see \
docs/providers.md"
      return c

/-! ## Self-check: the memo short-circuits

  The runaway this fixes was invisible offline — it needed a keychain-less
  machine *and* a real account. What is checkable here is the mechanism: that a
  stored credential is found on lookup, so the mint path is not re-entered. -/

/-- Exposed for the self-check suite. -/
def memoRoundTripsForCheck : IO Bool := do
  let key := ("check-project", "fr-par")
  let before := (← mintedThisRun.get).lookup key
  mintedThisRun.modify ((key, { accessKey := "a", secretKey := "b", region := "fr-par" }) :: ·)
  let after := (← mintedThisRun.get).lookup key
  -- Leave the ref as it was found: this runs in the same process as anything
  -- else that might use it.
  mintedThisRun.modify (·.filter (fun e => e.1 != key))
  return before.isNone && after.isSome

end Infra.Providers.Scaleway.Sqs
