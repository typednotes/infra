import Infra.Providers.Aws.Sign
import Linen.Data.Json.Encode
import Linen.Data.Base64
import Linen.Crypto.MD5

/-
  The four wire dialects AWS actually speaks.

  Every service below is signed identically (`Infra.Providers.Aws.Sign`); they
  differ only in how the request is shaped and how the reply is read. Factoring
  them here means each per-kind module is request construction and response
  mapping, nothing else.

  | dialect     | shape                                        | used by             |
  |-------------|----------------------------------------------|---------------------|
  | `S3`        | REST, bucket in the path, XML reply           | object storage      |
  | `Query`     | `POST /` form body, XML reply                 | IAM, RDS            |
  | `Json`      | `POST /` + `X-Amz-Target`, JSON reply         | Secrets, ECR, SQS   |
  | `RestJson`  | method + path, JSON body and reply            | Lambda              |

  Scaleway's own API is not here: it is not AWS-shaped and not SigV4-signed —
  see `Infra.Providers.Scaleway.Rest`. Its *object storage* and *queues*,
  however, are S3- and SQS-compatible, so they use `S3` and `Json` below with a
  different endpoint. That reuse is the point.
-/

namespace Infra.Providers.Aws

open Infra.Core
open Infra.Providers
open Network.HTTP.Client
open Network.HTTP.Types
open Data.Json (Value)

/-- Parse an XML reply, or say which call produced unreadable output. -/
private def parseXml (what : String) (resp : Response) : IO Text.XML.Element := do
  match Text.XML.parse (Http.bodyText resp) with
  | .ok e    => return e
  | .error m => throw (IO.userError s!"{what}: malformed XML response: {m}")

/-- Parse a JSON reply. An empty body becomes `null`: several AWS operations
    answer 200 with nothing at all. -/
private def parseJson (what : String) (resp : Response) : IO Value := do
  let text := (Http.bodyText resp).trimAscii.toString
  if text.isEmpty then return .null
  match Data.Json.Decode.decode text with
  | .ok v    => return v
  | .error m => throw (IO.userError s!"{what}: malformed JSON response: {m}")

-- ══════════════════════════════════════════════════════════════
-- S3: REST with the bucket in the path, XML replies
-- ══════════════════════════════════════════════════════════════

namespace S3

/-- The S3 endpoint for a cloud and region.

    Scaleway Object Storage speaks the S3 API, so it differs only here — which
    is what lets one client serve both. -/
def endpoint (provider : ProviderId) (region : String) : Endpoint :=
  match provider with
  | .aws      => { host := s!"s3.{region}.amazonaws.com", service := "s3", region }
  | .scaleway => { host := s!"s3.{region}.scw.cloud",     service := "s3", region }
  -- Cloud Storage does expose an S3-compatible XML API on one global host,
  -- but it authenticates with HMAC interoperability keys rather than the
  -- bearer token this library holds for GCP. Written down because it is where
  -- a live `objectStore` backend for GCP would start, and unused until then —
  -- `Providers.Gcp.backend` is a placeholder.
  | .gcp      => { host := "storage.googleapis.com", service := "s3", region }

/-- Path-style addressing: `/` for service-level calls, `/bucket` otherwise.

    Path-style rather than virtual-host style (`bucket.s3.…`) because it needs
    no per-bucket DNS or wildcard certificate, and because it is what
    S3-compatible clouds implement most consistently. -/
def bucketPath (bucket : Option String) : String :=
  match bucket with
  | some b => "/" ++ b
  | none   => "/"

/-- `Content-MD5` for a request body: base64 of its MD5 digest.

    S3 requires an integrity header — `Content-MD5` or one of the
    `x-amz-checksum-*` family — on the bucket-configuration writes
    (`PutBucketVersioning`, `PutBucketTagging`, and their relatives). Without
    one they are refused outright:

        HTTP 400 InvalidRequest: Missing required header for this request:
        Content-MD5 OR x-amz-checksum-*

    It is not the same thing as SigV4's `x-amz-content-sha256`, which is a
    signing input rather than an integrity declaration, so having one does not
    satisfy the other. -/
def contentMd5 (body : ByteArray) : String :=
  Data.Base64.encode (Crypto.MD5.hash body)

/-- Issue an S3 call. `path` is signed exactly as sent — S3 does not
    double-encode. -/
def call (creds : Credentials) (ep : Endpoint) (method : String)
    (bucket : Option String := none) (query : Query := [])
    (body : ByteArray := ByteArray.empty)
    (headers : List (String × String) := []) : IO Response :=
  Aws.call creds ep method (bucketPath bucket) query
    (if body.isEmpty then headers
     else ("Content-Type", "application/xml") :: ("Content-MD5", contentMd5 body) :: headers)
    body (doubleEncodePath := false)

/-- Issue an S3 call and parse its XML reply. -/
def callXml (creds : Credentials) (ep : Endpoint) (method : String)
    (bucket : Option String := none) (query : Query := [])
    (body : ByteArray := ByteArray.empty) : IO Text.XML.Element := do
  parseXml s!"s3 {method} {bucketPath bucket}" (← call creds ep method bucket query body)

end S3

-- ══════════════════════════════════════════════════════════════
-- Query: `POST /` with a form body, XML replies
-- ══════════════════════════════════════════════════════════════

namespace Query

/-- IAM is global: one endpoint, always signed `us-east-1`, whatever region the
    credentials name. Signing it regionally is a common and confusing mistake,
    so the region is fixed here rather than passed in. -/
def iamEndpoint : Endpoint :=
  { host := "iam.amazonaws.com", service := "iam", region := "us-east-1" }

def rdsEndpoint (region : String) : Endpoint :=
  { host := s!"rds.{region}.amazonaws.com", service := "rds", region }

def ec2Endpoint (region : String) : Endpoint :=
  { host := s!"ec2.{region}.amazonaws.com", service := "ec2", region }

/-- STS is global and always signs `us-east-1`, the same rule as `iamEndpoint`
    and for the same reason: signing it regionally is a common mistake, so the
    region is fixed here rather than passed in. -/
def stsEndpoint : Endpoint :=
  { host := "sts.amazonaws.com", service := "sts", region := "us-east-1" }

/-- The elements of a nested list in a Query response.

    Every Query-protocol service wraps collections the same way — a container
    element holding repeated children — and only the two tag names differ.
    `Iam`, `Postgres` and `Ec2` each had their own copy of this before it was
    hoisted here; the leaf tag varies (`member`, `DBInstance`, `item`), the
    walk does not. -/
def listItems (parent : Text.XML.Element) (container leaf : String) :
    List Text.XML.Element :=
  match parent.child container with
  | none   => []
  | some c => c.named leaf

/-- Render a form body. Uses the same strict encoder as the signer, so the
    body that is hashed is byte-for-byte the body that is sent. -/
def formBody (params : List (String × String)) : ByteArray :=
  ("&".intercalate (params.map fun (k, v) =>
      Network.HTTP.Types.encodeQueryComponent k ++ "=" ++
      Network.HTTP.Types.encodeQueryComponent v)).toUTF8

/-- Invoke a Query-protocol action. Parameters go in the body, never the query
    string, so a long parameter list cannot overflow a URL length limit. -/
def call (creds : Credentials) (ep : Endpoint) (action version : String)
    (params : List (String × String) := []) : IO Text.XML.Element := do
  let body := formBody ([("Action", action), ("Version", version)] ++ params)
  let resp ← Aws.call creds ep "POST" "/" []
    [("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")]
    body (doubleEncodePath := true)
  parseXml s!"{ep.service} {action}" resp

end Query

-- ══════════════════════════════════════════════════════════════
-- AWS-JSON: `POST /` with `X-Amz-Target`
-- ══════════════════════════════════════════════════════════════

namespace Json

def secretsEndpoint (region : String) : Endpoint :=
  { host := s!"secretsmanager.{region}.amazonaws.com", service := "secretsmanager", region }

def ecrEndpoint (region : String) : Endpoint :=
  { host := s!"api.ecr.{region}.amazonaws.com", service := "ecr", region }

/-- SQS. Scaleway's queues are SQS-compatible, so the same client serves both —
    as with S3, only the host differs.

    `scaleway.com`, not `scw.cloud`: unlike object storage, Messaging and
    Queuing was never on the `scw.cloud` domain, and the old host here did not
    resolve at all. Confirmed against Scaleway's own AWS-CLI connection guide
    (`https://sqs.mnq.{region}.scaleway.com`). -/
def sqsEndpoint (provider : ProviderId) (region : String) : Endpoint :=
  match provider with
  | .aws      => { host := s!"sqs.{region}.amazonaws.com",      service := "sqs", region }
  | .scaleway => { host := s!"sqs.mnq.{region}.scaleway.com", service := "sqs", region }
  -- GCP has no SQS-compatible API at all: its queues are Pub/Sub, a different
  -- protocol that this client cannot speak. A `.invalid` host is a reserved
  -- TLD that never resolves, so reaching here fails immediately and says why,
  -- rather than signing a request against something plausible.
  | .gcp      => { host := "gcp-queues-are-pubsub-not-sqs.invalid", service := "sqs", region }

/-- Invoke an operation. `target` is the wire name, e.g.
    `secretsmanager.CreateSecret`; `version` selects the JSON protocol flavour
    (`1.1` for most services, `1.0` for SQS). -/
def call (creds : Credentials) (ep : Endpoint) (target : String)
    (payload : Value) (version : String := "1.1") : IO Value := do
  let body := (Data.Json.Encode.encode payload).toUTF8
  let resp ← Aws.call creds ep "POST" "/" []
    [ ("Content-Type", s!"application/x-amz-json-{version}")
    , ("X-Amz-Target", target) ]
    body (doubleEncodePath := true)
  parseJson target resp

end Json

-- ══════════════════════════════════════════════════════════════
-- REST-JSON: method and path carry the meaning
-- ══════════════════════════════════════════════════════════════

namespace RestJson

def lambdaEndpoint (region : String) : Endpoint :=
  { host := s!"lambda.{region}.amazonaws.com", service := "lambda", region }

/-- Invoke a REST-JSON operation. `path` includes the API version prefix, e.g.
    `/2015-03-31/functions`. -/
def call (creds : Credentials) (ep : Endpoint) (method path : String)
    (query : Query := []) (payload : Option Value := none) : IO Value := do
  let body := match payload with
    | some v => (Data.Json.Encode.encode v).toUTF8
    | none   => ByteArray.empty
  let headers := if body.isEmpty then [] else [("Content-Type", "application/json")]
  let resp ← Aws.call creds ep method path query headers body (doubleEncodePath := true)
  parseJson s!"{method} {path}" resp

end RestJson

end Infra.Providers.Aws
