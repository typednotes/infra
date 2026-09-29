import Infra.Core.Credentials
import Linen.Cloud.Transport
import Linen.Cloud.Error
import Linen.Cloud.Page
import Linen.Network.HTTP.Client.Retry
import Linen.Network.HTTP.Simple
import Linen.Network.HTTP.Types.URI
import Linen.Data.CaseInsensitive

/-
  The one place provider calls go out — on linen's transport.

  Sending, retrying and reading a failure are `Linen.Cloud`'s
  (`Cloud.Transport.network`, `Cloud.retryPolicy`, `Cloud.describeError`, and
  the four error dialects it reads: S3/AWS XML, AWS-JSON, Scaleway JSON and
  Google's nested JSON). They lived here until infra moved onto `Linen.Cloud`
  (0.20.0). What stays is infra's side of the seam:

  * **The rendering.** A failure becomes an `IO.userError` reading
    `HTTP <status> <code>: <message> (request <id>)` — the provider's own code
    and message, not a bare status, since "403" is not a diagnosis and
    "SignatureDoesNotMatch" is. `Backend.readsAsAbsent` and `readsAsRefused`
    read the status and code back out of exactly this form, and classify them
    with linen's taxonomy.
  * **The request builders**, `request` and `requestPresigned`, which the
    protocol dialects above (`Aws.Protocols`, `Scaleway.Rest`, `Gcp.Rest`)
    still use.
-/

namespace Infra.Providers.Http

open Network.HTTP.Client
open Network.HTTP.Types

/-- How any single read or write may block. linen's value. -/
def timeoutMillis : Nat := Cloud.timeoutMillis

/-- A failure as infra renders it: `HTTP <status> <code>: <message> (request <id>)`.
    The form `readsAsAbsent`/`readsAsRefused` parse. -/
def render (e : Cloud.Error) : String :=
  let rid := match e.requestId with | some r => s!" (request {r})" | none => ""
  let code := if e.code.isEmpty then "" else s!" {e.code}"
  s!"HTTP {e.status}{code}: {e.message}{rid}"

/-- A non-2xx response, described by linen (`Cloud.describeError`, which keeps
    the raw body, truncated, when no dialect parses) and rendered by infra. -/
def describe (status : Nat) (body : String) : String :=
  render (Cloud.describeError status body)

/-- Build a request. `path` must already be canonical; `query` is passed
    separately so the signer and the wire agree on its rendering. -/
def request (method : String) (host path : String) (query : Query := [])
    (headers : List (String × String) := []) (body : Option ByteArray := none) : Request :=
  let rendered := Network.HTTP.Types.canonicalQuery query
  { method := parseMethod method
    host, path
    port := 443
    queryString := if rendered.isEmpty then "" else "?" ++ rendered
    headers := headers.map fun (n, v) => (Data.CI.mk' n, v)
    body
    isSecure := true
    timeoutMillis := timeoutMillis }

/-- Build a request whose query string is used exactly as given.

    For a *presigned* URL, and only for that. `request` above renders the query
    through `canonicalQuery`, which percent-encodes each component and sorts the
    parameters — correct when this library is the signer, and fatal when
    somebody else already signed. A presigned URL's signature covers the exact
    encoded string in the exact order it arrived, so re-encoding or reordering
    it produces a request the issuer refuses, with an error about the signature
    that says nothing about why.

    `queryString` is passed without the leading `?`, which this adds. -/
def requestPresigned (method : String) (host path queryString : String)
    (headers : List (String × String) := []) (body : Option ByteArray := none) :
    Request :=
  { method := parseMethod method
    host, path
    port := 443
    queryString := if queryString.isEmpty then "" else "?" ++ queryString
    headers := headers.map fun (n, v) => (Data.CI.mk' n, v)
    body
    isSecure := true
    timeoutMillis := timeoutMillis }

/-- Send a request through linen's transport, retrying transient failures
    (`Cloud.retryPolicy`). Does not inspect the status: see `sendChecked`. -/
def send (req : Request) : IO Response :=
  Cloud.Transport.network.send req

/-- A response body for an *error* message: lossy, since refusing to decode
    would discard the only diagnostic there is. -/
def errorText (resp : Response) : String := Cloud.bodyTextLossy resp

/-- Send a request and require a 2xx, raising the provider's own error
    otherwise. -/
def sendChecked (req : Request) : IO Response := do
  let resp ← send req
  if Cloud.isSuccess resp then return resp
  throw (IO.userError (describe (Cloud.statusOf resp) (errorText resp)))

/-- The response body as text, or a failure if it is not UTF-8 — a result is
    never read from a body decoded with replacement characters. -/
def bodyText (resp : Response) : IO String :=
  Infra.Core.orThrow (Cloud.bodyText resp)

/-- Decoded bytes as text — a secret's value, a key file — or a failure naming
    `what` if they are not UTF-8. Replaces `String.fromUTF8!`, which panicked:
    a secret holding binary would have crashed the run rather than said so. -/
def utf8Text (what : String) (bytes : ByteArray) : IO String :=
  match String.fromUTF8? bytes with
  | some s => pure s
  | none   => throw (IO.userError s!"{what}: the value is not UTF-8 text")

/-- Every item of a listing the provider hands back in pages, read with
    linen's `Cloud.paginate` — which records whether the page budget ran out
    before the provider said it was done.

    `fetch` gets the previous page's continuation (`none` for the first) and
    answers the page's items and the next continuation (`none`, or empty, when
    it is the last). A listing still going after `maxPages` pages **fails**,
    naming `what`: a truncated listing read as complete makes the planner
    propose creating resources that exist, and the orphan scan miss the ones
    it should destroy. (The GCP listings used to stop at 50 pages with a
    warning and return what they had, indistinguishable from complete.) -/
def listAll {α : Type} (what : String)
    (fetch : Option String → IO (List α × Option String))
    (maxPages : Nat := Cloud.defaultMaxPages) : IO (List α) := do
  let page (c : Option Cloud.Cursor) : IO (Except Cloud.Error (Cloud.Page α)) := do
    let (items, next) ← fetch (c.map (·.token))
    return .ok { items, next := (next.filter (!·.isEmpty)).map Cloud.Cursor.mk }
  let listing ← Infra.Core.orThrow (← Cloud.paginate maxPages page)
  if listing.truncated then
    throw (IO.userError s!"{what}: the listing was still going after {listing.pagesRead} pages, \
so it is incomplete — and a listing read as complete when it is not would plan creating what \
exists and miss orphans. Nothing was changed")
  return listing.items

end Infra.Providers.Http
