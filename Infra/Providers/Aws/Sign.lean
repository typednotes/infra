import Infra.Providers.Http
import Linen.Crypto.SigV4
import Linen.Data.Time.Clock

/-
  Signing AWS-family requests.

  Joins `Infra.Core.Credentials` to Linen's `Crypto.SigV4` and hands back a
  ready-to-send request. Every AWS protocol below this — REST-XML, Query,
  AWS-JSON, REST-JSON — differs only in how it *builds* the request; they all
  sign it the same way, so signing lives here once.

  S3-compatible clouds (Scaleway Object Storage among them) use this too: the
  scheme is not AWS-specific, only the endpoint is.
-/

namespace Infra.Providers.Aws

open Infra.Core
open Infra.Providers
open Network.HTTP.Client
open Network.HTTP.Types

/-- Where a signed call is going, and under what scope. -/
structure Endpoint where
  /-- Wire host, e.g. `s3.eu-west-1.amazonaws.com`. -/
  host    : String
  /-- SigV4 service name, e.g. `s3`, `iam`, `lambda`. -/
  service : String
  /-- SigV4 region. Not always the caller's region: IAM is global and always
      signs `us-east-1`, whatever region the credentials name. -/
  region  : String

/-- Sign and send, returning the response or raising the provider's own error.

    `unsignedBody` is the S3 escape hatch for large payloads; everything here
    hashes its body, which is what non-S3 services require anyway.

    `doubleEncodePath` reflects a genuine split in AWS's rules: S3 signs the
    path exactly as sent, every other service expects it encoded twice.
    Getting it wrong yields `SignatureDoesNotMatch` with nothing to indicate
    why, so it is explicit at every call site rather than defaulted. -/
def signedRequestAt (creds : Credentials) (ep : Endpoint) (now : Data.Time.UTCTime)
    (method path : String) (query : Query := [])
    (headers : List (String × String) := []) (body : ByteArray := ByteArray.empty)
    (doubleEncodePath : Bool := false) : IO Request := do
  let sigHeaders ← Crypto.SigV4.sign
    { accessKeyId := creds.accessKey
      secretAccessKey := creds.secretKey
      sessionToken := creds.sessionToken }
    ep.region ep.service now
    { method, path, query
      headers := ("Host", ep.host) :: headers
      payload := body
      doubleEncodePath }
  return Http.request method ep.host path query
    (("Host", ep.host) :: headers ++ sigHeaders)
    (if body.isEmpty then none else some body)

/-- Sign against the current wall clock. The signing time is a parameter of
    `signedRequestAt` rather than read inside it, so the signature can be
    checked against AWS's published vectors without a fixed-clock hack. -/
def signedRequest (creds : Credentials) (ep : Endpoint)
    (method path : String) (query : Query := [])
    (headers : List (String × String) := []) (body : ByteArray := ByteArray.empty)
    (doubleEncodePath : Bool := false) : IO Request := do
  signedRequestAt creds ep (← Data.Time.getCurrentTime) method path query headers body
    doubleEncodePath

/-- Sign, send, and require a 2xx.

    Every signed request in this library funnels through here — S3, EC2, SQS,
    ECR, Secrets Manager, IAM, RDS, Lambda, and Scaleway's S3-compatible
    endpoints too — so it is the one place worth naming the call in a failure.

    Without it, an S3 refusal reads:

        HTTP 403 AccessDenied: Access Denied (request txgc394f…)

    and says nothing about which operation, which host or which bucket. That
    is a needle in a haystack for a fleet with nine resources, and it was
    exactly the shape of the Scaleway REST errors that this repository already
    fixed the same way. The method, host and path identify the operation; the
    query is included because for the query-protocol services it carries the
    `Action`, and nothing secret travels there — SigV4 signs in a header.

    `sendChecked` still does the deciding; this only re-labels its error. -/
def call (creds : Credentials) (ep : Endpoint)
    (method path : String) (query : Query := [])
    (headers : List (String × String) := []) (body : ByteArray := ByteArray.empty)
    (doubleEncodePath : Bool := false) : IO Response := do
  let req ← signedRequest creds ep method path query headers body doubleEncodePath
  match ← (Http.sendChecked req).toBaseIO with
  | .ok r    => pure r
  | .error e =>
    let shownPath := if path.isEmpty then "/" else path
    let shownQuery := if req.queryString.isEmpty then "" else req.queryString
    throw (IO.userError
      s!"{ep.service} {method} {ep.host}{shownPath}{shownQuery}: {e}")

end Infra.Providers.Aws
