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
  let body ← match payload with
    | some v => Http.jsonBody s!"scaleway {method} {path}" v
    | none   => pure ByteArray.empty
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
  let text := (← Http.bodyText resp).trimAscii.toString
  if text.isEmpty then return .null
  match Data.Json.Decode.decode text with
  | .ok v    => return v
  | .error m => throw (IO.userError s!"scaleway {method} {path}: malformed JSON response: {m}")

-- ── Listing every page ──

/-- The page size every listing asks for. Scaleway's list endpoints default to
    a smaller page (commonly 20 or 50), and the stop rule below does not depend
    on the server honouring this: it counts what actually came back. -/
def listPageSize : Nat := 100

/-- After a page: the next `(page, seen)` to fetch, or `none` if that was the
    last. `returned` is how many items the page held; `total` is the reply's
    `total_count`.

    The rule is the generated SDK's, `scw.Client.doListAll`
    (`scaleway-sdk-go`, `scw/client.go`, read 2026-09-29): pages are 1-based,
    an empty page ends the listing, and otherwise the page count comes from
    `total_count` against the items actually returned — not against the page
    size asked for, which a server may cap below the request. Without a
    `total_count` (no Scaleway listing omits it today) the listing runs until
    an empty page, which costs one call and cannot stop early. -/
def nextPage (page seen returned : Nat) (total : Option Nat) : Option (Nat × Nat) :=
  let seen' := seen + returned
  if returned == 0 then none
  else match total with
    | some t => if seen' ≥ t then none else some (page + 1, seen')
    | none   => some (page + 1, seen')

-- A full last page with a total: stop exactly at the total.
#guard nextPage 1 0 100 (some 100) = none
#guard nextPage 1 0 100 (some 101) = some (2, 100)
#guard nextPage 2 100 1 (some 101) = none
-- A server capping `page_size` at 50: the total, not the request, decides.
#guard nextPage 1 0 50 (some 120) = some (2, 50)
#guard nextPage 2 50 50 (some 120) = some (3, 100)
#guard nextPage 3 100 20 (some 120) = none
-- An empty page always ends it, total or not; no total runs to one.
#guard nextPage 4 120 0 (some 500) = none
#guard nextPage 1 0 7 none = some (2, 7)

/-- Every item of a paged Scaleway listing: `GET path` with `query`, the items
    read from `field`, through `Http.listAll` — which fails rather than
    returning a truncated listing. `what` names the listing in that failure.

    Every Scaleway listing in infra goes through here. Before 0.20.1 most read
    one page at the server's default size, so a project with more than a page
    of containers, secrets or policies was read as having only the first ones:
    the planner proposed creating what existed, and the orphan scan could not
    see what it should destroy. -/
def listAll (creds : Credentials) (what path field : String) (query : Query := []) :
    IO (List Value) :=
  Http.listAll what fun token => do
    -- The continuation carries the page to fetch and how many items have been
    -- seen so far, which the stop rule needs.
    let (page, seen) := match token.map (·.splitOn ":") with
      | some [p, s] => (p.toNat?.getD 1, s.toNat?.getD 0)
      | _           => (1, 0)
    let reply ← call creds "GET" path
      (query ++ [("page", some (toString page)), ("page_size", some (toString listPageSize))])
    let items := JsonRead.arrayField reply field
    let next := nextPage page seen items.length (reply.lookupNat "total_count")
    return (items, next.map fun (p, s) => s!"{p}:{s}")

-- ── Reading replies ──

-- Reply accessors: linen's `Data.Json.Value.lookup` / `lookupText` /
-- `lookupNat` / `lookupBool`, and `Infra.Providers.JsonRead`'s `arrayField`
-- and `stringArrayField` for the two infra-specific list reads.

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

/-- A resource's raw flat tag list with one encoded pair taken out, or `none`
    when that exact pair is not there — the Scaleway half of
    `Backend.release`, where `t` is `(markerKey, fleet)`.

    Works on the **raw** strings rather than on decoded pairs, so every other
    tag goes back byte-for-byte as it came: `encodeTag ∘ decodeTag` is not the
    identity (`"just-a-label"` would come back as `"just-a-label="`), and a
    release must not rewrite tags it was not asked about. Matching the whole
    encoded string also matches the value, so another fleet's marker —
    same key, different value — is never removed. -/
def dropTag (t : String × String) (tags : List String) : Option (List String) :=
  if tags.contains (encodeTag t) then some (tags.filter (· != encodeTag t)) else none

#guard dropTag ("managed-by-infra", "me") ["team=infra", "managed-by-infra=me", "just-a-label"]
     = some ["team=infra", "just-a-label"]
#guard dropTag ("managed-by-infra", "me") ["managed-by-infra=me"] = some []
#guard dropTag ("managed-by-infra", "me") ["managed-by-infra=other", "team=infra"] = none
#guard dropTag ("managed-by-infra", "me") [] = none

end Infra.Providers.Scaleway
