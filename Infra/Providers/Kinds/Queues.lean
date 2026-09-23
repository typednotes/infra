import Infra.Providers.Aws.Protocols
import Infra.Core.Stage
import Infra.Providers.JsonRead
import Infra.Core.Ownership
import Infra.Providers.Marker

/-
  Queues, over the SQS API.

  The second place one implementation serves both clouds: Scaleway's Messaging
  and Queuing exposes an SQS-compatible endpoint, so `.queues` needs no
  Scaleway-specific code, exactly as `.objectStore` needs none.

  SQS's modern wire form is AWS-JSON 1.0 — `POST /` with an `X-Amz-Target`
  header — rather than the older query protocol.

  ## Identity

  SQS identifies a queue by URL, but `Infra.Core.pullEntries` matches a listed
  resource to a fleet key by comparing the handle against `Keys.name`. So the
  handle here is the queue *name*, and the URL travels in `ObservedOf`, where
  operations that need it can find it. Using the URL as the handle would make
  every fleet key have to spell out a full URL.
-/

namespace Infra.Providers.Kinds.Queues

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws
open Data.Json (Value)
open Infra.Providers.JsonRead

/-- The JSON protocol version SQS speaks, which is not the 1.1 most other
    AWS-JSON services use. -/
private def protocolVersion : String := "1.0"

private def target (op : String) : String := s!"AmazonSQS.{op}"

/-- The name at the end of a queue URL. -/
def nameOfUrl (url : String) : String :=
  (url.splitOn "/").getLast?.getD url

/-- Every queue the credentials can see, as `(name, url)`. -/
def listQueues (creds : Credentials) (ep : Endpoint) : IO (List (String × String)) := do
  let reply ← Json.call creds ep (target "ListQueues") (.object []) protocolVersion
  let urls := stringArrayField reply "QueueUrls"
  return urls.map fun u => (nameOfUrl u, u)

/-- A queue's URL, which most operations need in place of its name. -/
def queueUrl (creds : Credentials) (ep : Endpoint) (name : String) : IO String := do
  let reply ← Json.call creds ep (target "GetQueueUrl")
    (.object [("QueueName", .string name)]) protocolVersion
  match stringField reply "QueueUrl" with
  | some u => return u
  | none   => throw (IO.userError s!"GetQueueUrl: no URL for queue '{name}'")

/-- The visibility timeout, in seconds.

    `unknown` when the service does not report the attribute, which must not be
    confused with it being zero. -/
def readVisibilityTimeout (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Partial Nat) := do
  let url ← queueUrl creds ep name
  let reply ← Json.call creds ep (target "GetQueueAttributes")
    (.object [("QueueUrl", .string url),
              ("AttributeNames", .array #[.string "VisibilityTimeout"])])
    protocolVersion
  match field reply "Attributes" with
  | none => return .unknown
  | some attrs =>
    match natField attrs "VisibilityTimeout" with
    | some n => return .known n
    | none   => return .unknown

/-- Create a queue, returning its URL.

    `tags` is a top-level `CreateQueue` field (distinct from `Attributes`),
    which real SQS accepts and Scaleway's mnq — SQS-*compatible*, not a full
    reimplementation — does not: see `readOwnershipByName` below.
    `Live.lean` passes the ownership marker here for AWS and an empty list
    for Scaleway, so this stays one shared function rather than forking on
    provider inside it. -/
def createQueue (creds : Credentials) (ep : Endpoint) (name : String)
    (visibilityTimeoutSec : Nat) (tags : List (String × String) := []) : IO String := do
  let reply ← Json.call creds ep (target "CreateQueue")
    (.object
      ([ ("QueueName", .string name)
       , ("Attributes", .object [("VisibilityTimeout", .string (toString visibilityTimeoutSec))]) ]
       ++ (if tags.isEmpty then [] else
            [("tags", .object (tags.map fun (k, v) => (k, .string v)))])))
    protocolVersion
  match stringField reply "QueueUrl" with
  | some u => return u
  | none   => throw (IO.userError s!"CreateQueue: no URL returned for '{name}'")

/-- A queue's tags, from `ListQueueTags`. -/
private def queueTags (creds : Credentials) (ep : Endpoint) (url : String) :
    IO (List (String × String)) := do
  let reply ← Json.call creds ep (target "ListQueueTags")
    (.object [("QueueUrl", .string url)]) protocolVersion
  return match field reply "Tags" with
    | some (.object fields) => fields.filterMap fun (k, v) =>
        match v with
        | .string s => some (k, s)
        | _         => none
    | _ => []

/-- Tags, for `Ownership.ownershipOf` — AWS SQS only. `ListQueueTags` is a
    separate call keyed by `QueueUrl`, same gap as EC2/RDS/IAM.
    `createdAt` is left `none`, matching every other kind's first tranche.

    Scaleway's queues go to `readOwnershipByName` below instead. -/
def readOwnership (creds : Credentials) (ep : Endpoint) (name : String) :
    IO Evidence := do
  let attempt ← (queueUrl creds ep name).toBaseIO
  match attempt with
  | .error _ => return .unreadable
  | .ok url  => return .tags (← queueTags creds ep url) none

/-- Take this fleet's ownership marker off a queue, leaving its other tags —
    **AWS SQS only**: a Scaleway queue carries no marker to remove (see
    `readOwnershipByName`).

    `UntagQueue` removes by key alone (SQS API reference, `UntagQueue`:
    `QueueUrl`, `TagKeys`), so the value is checked first against a fresh
    `ListQueueTags`. -/
def releaseMarker (creds : Credentials) (ep : Endpoint) (name fleet : String) : IO Unit := do
  let url ← queueUrl creds ep name
  if (Marker.releaseTags fleet (← queueTags creds ep url)).isSome then
    discard <| Json.call creds ep (target "UntagQueue")
      (.object [("QueueUrl", .string url), ("TagKeys", .array #[.string markerKey])])
      protocolVersion

/-- Ownership for a **Scaleway** queue, which has no marker to carry.

    ## Permanent exception: Scaleway mnq queues cannot be tagged

    Scaleway's SQS-compatible endpoint does not implement `TagQueue`/
    `ListQueueTags`/the `tags` field on `CreateQueue` — it is a compatibility
    shim over a different underlying product, not a full SQS reimplementation.
    There is nothing writable on a queue but the name it was created with, so
    this is the **third rung** of `Ownership`'s ladder: `Evidence.named`, and
    `Boundary.namePrefix` decides.

    That is a real improvement on what was here before, which was `none` —
    "this backend cannot tell you", which made a Scaleway queue permanently
    unadoptable and undeletable-as-orphan however the fleet was configured. A
    fleet that sets `namePrefix` and names its queues with it now manages them
    like anything else; a fleet that does not is exactly where it was.

    The `queueUrl` call is what establishes the queue is really there: without
    it this would happily report a name for a queue that does not exist, and
    the scan would claim — and `push` try to destroy — nothing. -/
def readOwnershipByName (creds : Credentials) (ep : Endpoint) (name : String) :
    IO Evidence := do
  match ← (queueUrl creds ep name).toBaseIO with
  | .error _ => return .unreadable
  | .ok _    => return .named name none

def setVisibilityTimeout (creds : Credentials) (ep : Endpoint) (name : String)
    (visibilityTimeoutSec : Nat) : IO Unit := do
  let url ← queueUrl creds ep name
  discard <| Json.call creds ep (target "SetQueueAttributes")
    (.object [("QueueUrl", .string url),
              ("Attributes", .object [("VisibilityTimeout", .string (toString visibilityTimeoutSec))])])
    protocolVersion

def deleteQueue (creds : Credentials) (ep : Endpoint) (name : String) : IO Unit := do
  let url ← queueUrl creds ep name
  discard <| Json.call creds ep (target "DeleteQueue")
    (.object [("QueueUrl", .string url)]) protocolVersion

end Infra.Providers.Kinds.Queues
