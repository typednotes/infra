import Infra.Providers.Http
import Linen.Data.Json.Encode
import Infra.Providers.JsonRead

/-
  Google's REST APIs, at the transport level.

  One shape covers all of them, which is the reason this is a file rather than
  a paragraph inside a kind: every Google API is `https://<product>.googleapis.com`,
  every one authenticates with `Authorization: Bearer <token>`, and every one
  reports failure as a nested `{"error": {...}}` object. So a second kind needs
  no new transport code — only its own paths.

  ## What differs from the other two clouds

  There is no request signing. AWS's SigV4 and Scaleway's `X-Auth-Token` both
  derive from a long-lived secret held by the caller; a Google call carries a
  bearer token that was minted elsewhere — by `gcloud`, by a service-account
  assertion, or by federating a CI runner's OIDC token. See
  `Infra.Core.GcpAuth`. By the time a call reaches here the question of where
  the token came from has been settled, and this file does not care.
-/

open Data.Json (Value)

namespace Infra.Providers.Gcp

open Infra.Core
open Infra.Providers
open Infra.Providers.JsonRead
open Network.HTTP.Client
open Network.HTTP.Types

/-- The project every resource path is scoped by.

    Separate from `Credentials.requireProject`, whose message names Scaleway's
    environment variable and config file — accurate there, and misdirection
    here. -/
def requireProject (creds : Credentials) : IO String := do
  match creds.projectId with
  | some p => return p
  | none   => throw (IO.userError
      "no GCP project configured; set GOOGLE_CLOUD_PROJECT, or use a \
service-account key file, which names its own project")

/-- Issue a call against a Google API and parse the JSON reply.

    `host` is passed rather than assumed: the product is part of the hostname
    (`pubsub.googleapis.com`, `storage.googleapis.com`), so there is no single
    endpoint to hard-code. -/
def call (creds : Credentials) (method host path : String)
    (query : Query := []) (payload : Option Value := none) : IO Value := do
  let token ← creds.requireToken .gcp
  let body := match payload with
    | some v => (Data.Json.Encode.encode v).toUTF8
    | none   => ByteArray.empty
  let headers :=
    ("Authorization", "Bearer " ++ token)
    :: (if body.isEmpty then [] else [("Content-Type", "application/json")])
  let resp ← Http.sendChecked (Http.request method host path query headers
    (if body.isEmpty then none else some body))
  let text := (Http.bodyText resp).trimAscii.toString
  -- A `DELETE` answers `200` with an empty body, which is not a JSON parse
  -- failure but would be reported as one.
  if text.isEmpty then return .null
  match Data.Json.Decode.decode text with
  | .ok v    => return v
  | .error m => throw (IO.userError s!"gcp {method} {path}: malformed JSON response: {m}")

/-! ## Long-running operations

  Three of Google's APIs here do not finish the work in the call that starts
  it: creating an Artifact Registry repository, a Cloud Run service or a Cloud
  SQL instance returns an *operation*, and the resource does not exist until
  that operation completes. Neither AWS nor Scaleway needed this — their
  creates either finish inline or report a resource that is visibly still
  settling — so this is the first place the engine has to wait inside a single
  backend call.

  Two shapes, because Google has two. Most APIs return
  `google.longrunning.Operation` with a `done` boolean; Cloud SQL predates it
  and returns its own with a `status` string. They are handled separately
  rather than behind one leaky abstraction.

  Both are bounded by fuel rather than `partial`, so the wait is a real
  measure, and both say what they were waiting for when they give up — an
  operation name alone is not something anyone can act on.
-/

/-- Wait for a `google.longrunning.Operation`.

    `reply` is the response that started it. An operation that is already
    `done` costs no extra call, which is the common case for a fast create. -/
def awaitLro (creds : Credentials) (host version : String) (reply : Value)
    (label : String) (attempts : Nat := 120) : IO Value := do
  let rec go (fuel : Nat) (current : Value) : IO Value := do
    -- An operation carrying an error is a failure of the *work*, not of the
    -- call that reported it, so it has to be raised here or it is lost.
    if let some err := field current "error" then
      let msg := (stringField err "message").getD (Data.Json.Encode.encode err)
      throw (IO.userError s!"gcp {label}: the operation failed: {msg}")
    if (boolField current "done").getD false then
      return (field current "response").getD current
    match fuel with
    | 0 =>
      let name := (stringField current "name").getD "(unnamed)"
      throw (IO.userError s!"gcp {label}: the operation did not finish in \
{attempts}s\n  operation: {name}\n  It may still be running — check the \
console before retrying, because a retry can collide with work that is about \
to succeed.")
    | fuel' + 1 =>
      IO.sleep 1000
      let some name := stringField current "name"
        | throw (IO.userError s!"gcp {label}: the operation has no name, so it \
cannot be polled")
      go fuel' (← call creds "GET" host s!"/{version}/{name}")
  go attempts reply

/-- Cloud SQL's control plane, named here because both the operation poller
    below and `Gcp.CloudSql` need it. -/
def sqlAdminHost : String := "sqladmin.googleapis.com"

/-- Wait for a Cloud SQL operation, which is not a `longrunning.Operation`.

    Its own shape: a bare `name` that is an operation id rather than a resource
    path, and a `status` of `PENDING`/`RUNNING`/`DONE` in place of `done`. The
    default patience is much longer because Cloud SQL instances genuinely take
    minutes, not seconds. -/
def awaitSqlOperation (creds : Credentials) (project : String) (reply : Value)
    (label : String) (attempts : Nat := 600) : IO Unit := do
  let rec go (fuel : Nat) (current : Value) : IO Unit := do
    if let some err := field current "error" then
      let errs := arrayField err "errors"
      let msg := match errs.head? with
        | some e => (stringField e "message").getD "(no message)"
        | none   => (Data.Json.Encode.encode err)
      throw (IO.userError s!"gcp {label}: the operation failed: {msg}")
    if (stringField current "status") == some "DONE" then return ()
    match fuel with
    | 0 =>
      let name := (stringField current "name").getD "(unnamed)"
      throw (IO.userError s!"gcp {label}: the operation did not finish in \
{attempts}s\n  operation: {name}\n  Cloud SQL work can outlast this; check \
the console rather than retrying blind.")
    | fuel' + 1 =>
      IO.sleep 1000
      let some name := stringField current "name"
        | throw (IO.userError s!"gcp {label}: the operation has no name, so it \
cannot be polled")
      go fuel' (← call creds "GET" sqlAdminHost
        s!"/sql/v1beta4/projects/{project}/operations/{name}")
  go attempts reply

/-- The last segment of a Google resource name.

    Every one is a path — `projects/p/topics/t`, `projects/p/buckets/b` — and
    the fleet keys on the bare name, so this is the join between the two. -/
def shortName (resourceName : String) : String :=
  (resourceName.splitOn "/").getLast?.getD resourceName

end Infra.Providers.Gcp
