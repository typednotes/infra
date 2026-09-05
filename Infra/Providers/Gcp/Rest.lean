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

/-- The last segment of a Google resource name.

    Every one is a path — `projects/p/topics/t`, `projects/p/buckets/b` — and
    the fleet keys on the bare name, so this is the join between the two. -/
def shortName (resourceName : String) : String :=
  (resourceName.splitOn "/").getLast?.getD resourceName

end Infra.Providers.Gcp
