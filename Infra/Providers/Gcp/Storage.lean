import Infra.Providers.Gcp.Rest
import Infra.Core.Stage

/-
  Object storage on GCP, over the Cloud Storage JSON API.

  ## Why not the S3-compatible one

  GCS does expose an S3-compatible XML API, and `objectStore` already has an
  S3 client serving both AWS and Scaleway — so routing GCP there too looks
  free. It is not. That API authenticates with HMAC keys, which are a separate
  credential a user has to create by hand in the console; every GCP credential
  this library can obtain is a bearer token. Signing a SigV4 request with a
  bearer token produces a 403, not a fallback.

  This was in fact what happened, silently: `objectStore` had no GCP branch at
  all and routed unconditionally to the S3 client, so a declared GCP bucket
  reached an `storage.googleapis.com` endpoint with a signature it could not
  accept. Like `.queues` before it, the kind was unimplemented *without*
  appearing in `grep noGcp`.

  ## Names are global

  A bucket name is unique across all of Google Cloud, not per project — the
  same as S3 and unlike most GCP resources. So `create` can fail with `409`
  because *somebody else* owns the name, which is worth distinguishing from
  the project already owning it; the error says so.

  Endpoints and field names checked against Google's Cloud Storage JSON API
  reference (`storage/v1`, `buckets` resource), 2026-09.
-/

namespace Infra.Providers.Gcp.Storage

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)
open Network.HTTP.Types (Query)

def host : String := "storage.googleapis.com"

private def bucketPath (bucket : String) : String := s!"/storage/v1/b/{bucket}"

/-- Every bucket in the project.

    Paginated with a fuel bound rather than `partial`, and it says so when it
    stops: a truncated list read as complete would make the planner propose
    creating buckets that already exist. -/
def listBuckets (creds : Credentials) (project : String) : IO (List String) := do
  let rec go (fuel : Nat) (token : String) (acc : List String) : IO (List String) := do
    match fuel with
    | 0 =>
      IO.eprintln "warning: gcp storage: stopped paginating buckets after 50 pages; \
the list may be incomplete"
      return acc
    | fuel' + 1 =>
      let query : Query :=
        ("project", some project) :: (if token.isEmpty then [] else [("pageToken", some token)])
      let reply ← Gcp.call creds "GET" host "/storage/v1/b" query
      let here := (arrayField reply "items").filterMap (stringField · "name")
      let acc := acc ++ here
      match stringField reply "nextPageToken" with
      | some next => if next.isEmpty then return acc else go fuel' next acc
      | none      => return acc
  go 50 "" []

/-- Whether versioning is on.

    `unknown` when the bucket does not report the field at all, which is not
    the same as reporting it off — the distinction `Partial` exists for, and
    what keeps an unspoken field from being diffed. -/
def readVersioning (creds : Credentials) (bucket : String) : IO (Partial Bool) := do
  let reply ← Gcp.call creds "GET" host (bucketPath bucket)
  match field reply "versioning" with
  | none => return .unknown
  | some v =>
    match boolField v "enabled" with
    | some b => return .known b
    | none   => return .unknown

/-- The bucket's labels, which are what GCP calls tags.

    An absent `labels` object means genuinely none, so it is `known []` rather
    than `unknown`: the planner should be able to remove the last label and see
    it converge. -/
def readLabels (creds : Credentials) (bucket : String) :
    IO (Partial (List (String × String))) := do
  let reply ← Gcp.call creds "GET" host (bucketPath bucket)
  match field reply "labels" with
  | some (.object fields) =>
    return .known (fields.filterMap fun (k, v) =>
      match v with | .string s => some (k, s) | _ => none)
  | _ => return .known []

private def versioningObject (enabled : Bool) : String × Value :=
  ("versioning", .object [("enabled", .bool enabled)])

private def labelsObject (labels : List (String × String)) : String × Value :=
  ("labels", .object (labels.map fun (k, v) => (k, .string v)))

/-- Create a bucket. The project is a query parameter, not a body field. -/
def createBucket (creds : Credentials) (project bucket : String)
    (versioning : Bool) (labels : List (String × String)) : IO Unit := do
  let payload : Value := .object
    [ ("name", .string bucket), versioningObject versioning, labelsObject labels ]
  match ← (Gcp.call creds "POST" host "/storage/v1/b" [("project", some project)]
      (payload := some payload)).toBaseIO with
  | .ok _ => pure ()
  | .error e =>
    let msg := toString e
    -- Bucket names are global. `409` here means the name is taken, and by
    -- whom changes what the reader should do about it.
    if (msg.splitOn "HTTP 409").length > 1 then
      throw (IO.userError s!"gcp storage: the bucket name '{bucket}' is already taken\n  \
Bucket names are global across all of Google Cloud, not per project, so this \
may be someone else's. If it is yours, it is in another project.\n  {msg}")
    else throw e

/-- Update the mutable fields. `PATCH`, so unmentioned fields are untouched. -/
def patchBucket (creds : Credentials) (bucket : String)
    (versioning : Bool) (labels : List (String × String)) : IO Unit := do
  discard <| Gcp.call creds "PATCH" host (bucketPath bucket)
    (payload := some (.object [versioningObject versioning, labelsObject labels]))

/-- Delete a bucket. Already gone is not an error; **not empty** is.

    Google refuses to delete a bucket with objects in it, and that refusal is
    deliberately not swallowed: silently leaving a bucket behind after
    reporting a successful destroy is how data is presumed deleted when it is
    not. -/
def deleteBucket (creds : Credentials) (bucket : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (bucketPath bucket)).toBaseIO with
  | .ok _ => pure ()
  | .error e =>
    let msg := toString e
    if (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 then
      pure ()
    else if (msg.splitOn "HTTP 409").length > 1 then
      throw (IO.userError s!"gcp storage: bucket '{bucket}' is not empty, so it was not \
deleted\n  Google refuses to delete a bucket with objects in it. Empty it \
first; `infra` will not delete objects it does not manage.\n  {msg}")
    else throw e

/-- The bucket's public URL, for `ObservedOf`. -/
def bucketUrl (bucket : String) : String := s!"https://storage.googleapis.com/{bucket}"

#guard bucketUrl "assets" = "https://storage.googleapis.com/assets"

end Infra.Providers.Gcp.Storage
