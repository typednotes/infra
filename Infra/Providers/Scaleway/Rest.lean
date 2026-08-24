import Infra.Providers.Http
import Linen.Data.Json.Encode
import Infra.Providers.JsonRead

/-
  Scaleway's own API.

  One JSON-over-HTTPS surface at `api.scaleway.com`, authenticated by a single
  `X-Auth-Token` header holding the secret key. No request signing, no
  canonical form, no clock skew to worry about — everything SigV4 exists for is
  simply absent here.

  This covers every Scaleway kind *except* two, which are deliberately not
  routed through it:

    * object storage is S3-compatible
    * queues are SQS-compatible

  Both go through the AWS clients at a Scaleway endpoint instead
  (`Infra.Providers.Aws.S3`, `Infra.Providers.Aws.Json`), which is why the
  portable `.objectStore` kind needs no Scaleway-specific code at all.
-/

namespace Infra.Providers.Scaleway

open Infra.Core
open Infra.Providers
open Network.HTTP.Client
open Network.HTTP.Types
open Data.Json (Value)

/-- The API host. A single global host; the region appears in the path, not the
    hostname, unlike AWS. -/
def host : String := "api.scaleway.com"

/-- A product's regional path prefix, e.g.
    `/functions/v1beta1/regions/fr-par`.

    Scaleway versions each product separately, so the version travels with the
    product rather than being global. -/
def regionalPrefix (product version region : String) : String :=
  s!"/{product}/{version}/regions/{region}"

/-- A product's zonal path prefix, for the products that are zone- rather than
    region-scoped. -/
def zonalPrefix (product version zone : String) : String :=
  s!"/{product}/{version}/zones/{zone}"

/-- A product's account-level path prefix, for the products that are neither —
    IAM being the notable one. -/
def globalPrefix (product version : String) : String :=
  s!"/{product}/{version}"

/-- Issue a call and parse the JSON reply.

    The secret key is the bearer token, so it goes in a header and never into a
    URL, where it could reach a proxy log. -/
def call (creds : Credentials) (method path : String)
    (query : Query := []) (payload : Option Value := none) : IO Value := do
  let body := match payload with
    | some v => (Data.Json.Encode.encode v).toUTF8
    | none   => ByteArray.empty
  let headers :=
    ("X-Auth-Token", creds.secretKey)
    :: (if body.isEmpty then [] else [("Content-Type", "application/json")])
  let resp ← Http.sendChecked (Http.request method host path query headers
    (if body.isEmpty then none else some body))
  let text := (Http.bodyText resp).trimAscii.toString
  if text.isEmpty then return .null
  match Data.Json.Decode.decode text with
  | .ok v    => return v
  | .error m => throw (IO.userError s!"scaleway {method} {path}: malformed JSON response: {m}")

-- ── Reading replies ──

-- Reply accessors (`field`, `stringField`, `natField`, `arrayField`, …) live in
-- `Infra.Providers.JsonRead`. They started here, but SQS — an AWS protocol —
-- needs the same ones, which made this the wrong home for them. Scaleway call
-- sites should `open Infra.Providers.JsonRead`.

end Infra.Providers.Scaleway
