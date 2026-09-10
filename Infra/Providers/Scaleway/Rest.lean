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
  -- Name the call in every failure. Scaleway's error bodies are the terse ones
  -- of the three clouds: a refused request says
  --
  --     HTTP 403 permissions_denied: insufficient permissions
  --
  -- and nothing else — not the product, not the operation, not the resource.
  -- AWS names the action and Google names the exact permission and resource,
  -- so only this cloud left the reader guessing which of a ten-resource
  -- fleet's calls had been refused. The method and path are enough to identify
  -- the product and operation, and cost nothing when the call succeeds.
  let resp ← match ← (Http.sendChecked (Http.request method host path query headers
      (if body.isEmpty then none else some body))).toBaseIO with
    | .ok r => pure r
    | .error e => throw (IO.userError s!"scaleway {method} {path}: {e}")
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

-- ── Tags ──

/-- Scaleway's `tags` field is a flat `[]string`, unlike AWS/GCP's key/value
    pairs — so the ownership marker (`Infra.Core.Ownership.markerKey`, a
    `(String × String)` pair everywhere else) has to be serialised into one
    plain string to travel in it. `=` is not a character either side of this
    ever produces on its own (`markerKey` is a fixed identifier; a fleet name
    is validated shorter down the same rules as any other resource name), so
    splitting on the first one is unambiguous in practice; it is still done as
    "first `=` splits key from the rest" rather than "no `=` allowed in the
    value" so a value that did contain one would not silently misparse into
    a different key. -/
def encodeTag (t : String × String) : String := t.1 ++ "=" ++ t.2

/-- The other half of `encodeTag`. A flat tag with no `=` at all (hand-written,
    or from a product that also stores non-key/value labels) decodes to itself
    as the key with an empty value, rather than being dropped — dropping it
    would mean a tag this tool did not write could vanish from what `tags`
    round-trips, which is the kind of silent loss `Divergent` must not have. -/
def decodeTag (s : String) : String × String :=
  match s.splitOn "=" with
  | k :: rest =>
    if rest.isEmpty then (k, "") else (k, String.intercalate "=" rest)
  | [] => (s, "")

#guard decodeTag (encodeTag ("managed-by-infra", "my-fleet")) = ("managed-by-infra", "my-fleet")
#guard decodeTag "team=infra" = ("team", "infra")
#guard decodeTag "just-a-label" = ("just-a-label", "")
#guard decodeTag "a=b=c" = ("a", "b=c")

end Infra.Providers.Scaleway
