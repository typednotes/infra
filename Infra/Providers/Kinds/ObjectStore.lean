import Infra.Providers.Aws.Protocols
import Infra.Core.Stage
import Linen.Text.Pandoc.XML

/-
  Object storage, over the S3 API.

  Serves three of the sixteen `(provider, kind)` pairs from one implementation:

    * `.objectStore` on AWS
    * `.objectStore` on Scaleway — Object Storage is S3-compatible
    * `.s3Bucket` on AWS — the provider-local kind, with storage class and
      region on top

  That the portable kind needs no Scaleway-specific code is the whole point of
  indexing `SpecOf` by `Kind` alone. Only `S3.endpoint` differs.

  Bucket-level operations only: no object CRUD.
-/

namespace Infra.Providers.Kinds.ObjectStore

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws
open Network.HTTP.Types

/-- Issue an S3 call, treating "not found" as absence rather than failure.

    `GET ?tagging` answers `404 NoSuchTagSet` for a bucket with no tags, and
    `?versioning` answers 200 with an empty document when versioning was never
    enabled. Neither is an error, and raising on them would make `read` fail
    for perfectly ordinary buckets. -/
private def readSubresource (creds : Credentials) (ep : Endpoint)
    (bucket subresource : String) : IO (Option Text.XML.Element) := do
  let req ← Aws.signedRequest creds ep "GET" s!"/{bucket}" [(subresource, none)]
  let resp ← Http.send req
  let status := resp.statusCode.statusCode
  if status == 404 then return none
  if !(200 ≤ status && status ≤ 299) then
    throw (IO.userError
      (toString (Http.describeError status (Http.bodyText resp))))
  match Text.XML.parse (Http.bodyText resp) with
  | .ok e    => return some e
  | .error _ => return none      -- an empty body is a legitimate "unset"

/-- Bucket names, from `ListAllMyBucketsResult`. -/
def listBuckets (creds : Credentials) (ep : Endpoint) : IO (List String) := do
  let root ← S3.callXml creds ep "GET"
  match root.child "Buckets" with
  | none    => return []
  | some bs => return (bs.named "Bucket").filterMap (·.childText "Name")

/-- Whether versioning is enabled. `unknown` when the bucket reports no
    versioning document at all, which is distinct from reporting `Suspended`. -/
def readVersioning (creds : Credentials) (ep : Endpoint) (bucket : String) :
    IO (Partial Bool) := do
  match ← readSubresource creds ep bucket "versioning" with
  | none => return .unknown
  | some root =>
    match root.childText "Status" with
    | some "Enabled" => return .known true
    | some _         => return .known false
    | none           => return .unknown      -- never configured

/-- The bucket's tags. -/
def readTags (creds : Credentials) (ep : Endpoint) (bucket : String) :
    IO (Partial (List (String × String))) := do
  match ← readSubresource creds ep bucket "tagging" with
  | none => return .known []                 -- 404 NoSuchTagSet: genuinely none
  | some root =>
    match root.child "TagSet" with
    | none => return .known []
    | some ts =>
      return .known ((ts.named "Tag").filterMap fun t =>
        match t.childText "Key", t.childText "Value" with
        | some k, some v => some (k, v)
        | _,      _      => none)

/-- Whether Object Lock is enabled — an AWS-only, creation-time setting.

    A bucket without it answers 404, which is "off", not "unknown". -/
def readObjectLock (creds : Credentials) (ep : Endpoint) (bucket : String) :
    IO (Partial Bool) := do
  match ← readSubresource creds ep bucket "object-lock" with
  | none => return .known false
  | some root =>
    match root.childText "ObjectLockEnabled" with
    | some "Enabled" => return .known true
    | some _         => return .known false
    | none           => return .known false

/-- `PUT /bucket`, with the location constraint non-default regions require.

    `us-east-1` must *not* carry one: S3 rejects the request if it does.

    `objectLock` is a creation-time header because that is the only time S3
    accepts it — the setting cannot be turned on afterwards. -/
def createBucket (creds : Credentials) (ep : Endpoint) (bucket : String)
    (objectLock : Bool := false) : IO Unit := do
  let body :=
    if ep.region == "us-east-1" then ByteArray.empty
    else ("<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
          s!"<LocationConstraint>{ep.region}</LocationConstraint>" ++
          "</CreateBucketConfiguration>").toUTF8
  let headers := if objectLock then [("x-amz-bucket-object-lock-enabled", "true")] else []
  discard <| S3.call creds ep "PUT" (some bucket) [] body headers

def putVersioning (creds : Credentials) (ep : Endpoint) (bucket : String) (enabled : Bool) :
    IO Unit := do
  let status := if enabled then "Enabled" else "Suspended"
  let body := ("<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" ++
               s!"<Status>{status}</Status></VersioningConfiguration>").toUTF8
  discard <| S3.call creds ep "PUT" (some bucket) [("versioning", none)] body

def putTags (creds : Credentials) (ep : Endpoint) (bucket : String)
    (tags : List (String × String)) : IO Unit := do
  if tags.isEmpty then
    -- No tags means *remove* the tag set, not write an empty one: S3 rejects
    -- an empty `TagSet`.
    discard <| S3.call creds ep "DELETE" (some bucket) [("tagging", none)]
  else
    let entries := String.join (tags.map fun (k, v) =>
      s!"<Tag><Key>{Linen.Text.Pandoc.XML.escapeStringForXML k}</Key>" ++
      s!"<Value>{Linen.Text.Pandoc.XML.escapeStringForXML v}</Value></Tag>")
    let body := ("<Tagging xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><TagSet>" ++
                 entries ++ "</TagSet></Tagging>").toUTF8
    discard <| S3.call creds ep "PUT" (some bucket) [("tagging", none)] body

def deleteBucket (creds : Credentials) (ep : Endpoint) (bucket : String) : IO Unit := do
  discard <| S3.call creds ep "DELETE" (some bucket)

/-- The bucket's public URL, for `ObservedOf`. -/
def bucketUrl (ep : Endpoint) (bucket : String) : String :=
  s!"https://{ep.host}/{bucket}"

end Infra.Providers.Kinds.ObjectStore
