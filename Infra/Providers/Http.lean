import Infra.Core.Credentials
import Linen.Network.HTTP.Client.Retry
import Linen.Network.HTTP.Simple
import Linen.Network.HTTP.Types.URI
import Linen.Data.CaseInsensitive
import Linen.Text.XML
import Linen.Data.Json.Decode

/-
  The one place provider calls go out.

  Wraps Linen's HTTP client with the timeout and retry policy every cloud API
  wants, and turns a non-2xx response into an error carrying *the provider's
  own* code and message rather than a bare status number — the difference
  between "403" and "SignatureDoesNotMatch", which is the whole diagnosis.

  Both wire dialects are handled: AWS and S3-compatible services answer with an
  XML `<Error>` document, Scaleway with JSON.
-/

namespace Infra.Providers.Http

open Network.HTTP.Client
open Network.HTTP.Types

/-- How provider calls behave under failure.

    Slightly more patient than Linen's default, because a cloud control plane
    throttling a burst of creates is normal rather than exceptional, and
    because `Retry-After` is honoured when the service sends one. -/
def policy : RetryPolicy :=
  { maxAttempts := 5, baseDelayMillis := 200, maxDelayMillis := 20000 }

/-- How long any single read or write may block. -/
def timeoutMillis : Nat := 30000

/-- A failed API call, as the provider described it. -/
structure ApiError where
  status    : Nat
  /-- The provider's error code, e.g. `NoSuchBucket`. Empty if it sent none. -/
  code      : String
  message   : String
  requestId : Option String := none
  deriving Repr

instance : ToString ApiError where
  toString e :=
    let rid := match e.requestId with | some r => s!" (request {r})" | none => ""
    let code := if e.code.isEmpty then "" else s!" {e.code}"
    s!"HTTP {e.status}{code}: {e.message}{rid}"

/-- Read an AWS/S3-style `<Error><Code>…</Code><Message>…</Message></Error>`. -/
def parseXmlError (body : String) : Option (String × String × Option String) :=
  match Text.XML.parse body with
  | .error _ => none
  | .ok root =>
    -- Some services wrap the error, so accept it at the root or one level in.
    let err := if root.name.local' == "Error" then some root else root.child "Error"
    err.map fun e =>
      ((e.childText "Code").getD "", (e.childText "Message").getD "",
       (e.childText "RequestId").orElse fun _ => e.childText "RequestID")

/-- Read a JSON error body. Scaleway uses `{"message":…,"type":…}`; the AWS
    JSON protocols use `{"__type":…,"message":…}`, sometimes capitalised. -/
def parseJsonError (body : String) : Option (String × String) :=
  match Data.Json.Decode.decode body with
  | .error _ => none
  | .ok v =>
    match v with
    | .object fields =>
      let get (k : String) : Option String :=
        (fields.find? (·.1 == k)).bind fun (_, x) =>
          match x with | .string s => some s | _ => none
      let code := (get "__type").orElse fun _ => (get "type" |>.orElse fun _ => get "code")
      let msg  := (get "message").orElse fun _ => get "Message"
      -- Google nests it: `{"error":{"code":404,"status":"NOT_FOUND","message":…}}`.
      -- Read through one level when the flat lookup found nothing, or every
      -- GCP failure renders as `HTTP 404 :` with the explanation — the only
      -- part worth having — discarded.
      let nested : Option (String × String) :=
        (fields.find? (·.1 == "error")).bind fun (_, e) =>
          match e with
          | .object inner =>
            let innerGet (k : String) : Option String :=
              (inner.find? (·.1 == k)).bind fun (_, x) =>
                match x with | .string v => some v | _ => none
            some ((innerGet "status").getD "", (innerGet "message").getD "")
          | _ => none
      match code, msg with
      | none, none => some (nested.getD ("", ""))
      | _, _       => some (code.getD "", msg.getD "")
    | _ => none

/-- Turn a response body into the best error description available, falling
    back to the raw body so nothing is ever silently swallowed. -/
def describeError (status : Nat) (body : String) : ApiError :=
  match parseXmlError body with
  | some (code, message, rid) => { status, code, message, requestId := rid }
  | none =>
    match parseJsonError body with
    | some (code, message) => { status, code, message }
    | none =>
      -- Neither dialect: keep the body, truncated, rather than discard it.
      let trimmed := body.trimAscii.toString
      let shown := if trimmed.length > 400 then (trimmed.take 400).toString ++ "…" else trimmed
      { status, code := "", message := if shown.isEmpty then "(empty response body)" else shown }

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

/-- Send a request, retrying transient failures. Does not inspect the status:
    see `sendChecked`. -/
def send (req : Request) : IO Response :=
  executeWithRetry policy req

/-- Send a request and require a 2xx, raising the provider's own error
    otherwise. -/
def sendChecked (req : Request) : IO Response := do
  let resp ← send req
  let status := resp.statusCode.statusCode
  if 200 ≤ status && status ≤ 299 then
    return resp
  else
    throw (IO.userError (toString (describeError status (String.fromUTF8! resp.body))))

/-- The response body as text. -/
def bodyText (resp : Response) : String := String.fromUTF8! resp.body

end Infra.Providers.Http
