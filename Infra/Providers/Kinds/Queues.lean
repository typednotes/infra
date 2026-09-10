import Infra.Providers.Aws.Protocols
import Infra.Core.Stage
import Infra.Providers.JsonRead
import Infra.Core.Ownership

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
    reimplementation — does not: see the permanent exception below.
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

/-- Tags, for `Ownership.ownershipOf` — AWS SQS only. `ListQueueTags` is a
    separate call keyed by `QueueUrl`, same gap as EC2/RDS/IAM.
    `createdAt` is left `none`, matching every other kind's first tranche.

    ## Permanent exception: Scaleway mnq queues cannot be tagged

    Scaleway's SQS-compatible endpoint does not implement `TagQueue`/
    `ListQueueTags`/the `tags` field on `CreateQueue` — it is a compatibility
    shim over a different underlying product, not a full SQS reimplementation.
    There is no marker to write and none to read back on that cloud, so
    `Backend.ownershipInfo` returns `none` for `.queues` there unconditionally
    (see `Live.lean`), and the engine's fail-safe (`Engine.lean`, the
    2026-09-10 incident) refuses to adopt or delete-as-orphan a Scaleway queue
    on the ledger's say-so alone. This is a permanent, intentional gap, not a
    half-implemented feature: see `AGENTS.md`'s "no half-implemented
    features" rule. -/
def readOwnership (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Option (List (String × String) × Option String)) := do
  let attempt ← (queueUrl creds ep name).toBaseIO
  match attempt with
  | .error _ => return none
  | .ok url =>
    let reply ← Json.call creds ep (target "ListQueueTags")
      (.object [("QueueUrl", .string url)]) protocolVersion
    let tags := match field reply "Tags" with
      | some (.object fields) => fields.filterMap fun (k, v) =>
          match v with
          | .string s => some (k, s)
          | _         => none
      | _ => []
    return some (tags, none)

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
