import Infra.Providers.Gcp.Rest
import Infra.Core.Stage

/-
  Queues on GCP, over Pub/Sub topics.

  The third cloud for `.queues`, and the first that is not SQS. AWS and
  Scaleway share one client because Scaleway's endpoint is SQS-compatible;
  Pub/Sub is a different API with a different model, so it gets its own.

  ## A topic is not a queue, and the mapping is deliberate

  SQS has one object that both holds messages and is read from. Pub/Sub splits
  that in two: a **topic** messages are published to, and a **subscription**
  they are read from. A queue is therefore not one Pub/Sub object but a pair,
  and something has to be chosen as the thing a fleet key names.

  The topic is chosen. It is the durable, named, addressable half — the one a
  publisher needs to know about, the one that exists before any reader does,
  and the one whose name a person would put in a declaration. Subscriptions
  are created against it and are plural: a fleet that needs them is declaring
  a fan-out topology, which the portable `.queues` spec has no vocabulary for
  and should not pretend to.

  The visible consequence is `visibilityTimeoutSec`. On SQS that is a queue
  attribute; on Pub/Sub the nearest thing is a *subscription's* ack deadline,
  and there is no subscription here. So it is reported `.unknown` rather than
  guessed at, and `Infra.Core.Diverge.diverges` treats an unknown field as no
  divergence — which is what keeps a declared timeout from being read as a
  change to apply on every single run.

  Endpoints, names and semantics checked against Google's Pub/Sub REST
  reference (`pubsub.googleapis.com/v1`, `projects.topics` collection), 2026-09.
-/

namespace Infra.Providers.Gcp.PubSub

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)
open Network.HTTP.Types (Query)

/-- Every Pub/Sub call goes here. -/
def host : String := "pubsub.googleapis.com"

/-- A topic's full resource name, which is also its URL path. -/
def topicName (project name : String) : String := s!"projects/{project}/topics/{name}"

private def topicPath (project name : String) : String :=
  "/v1/" ++ topicName project name

/-- Every topic in the project, as short names paired with resource names.

    Paginated with a fuel bound rather than `partial`: the API returns a
    `nextPageToken` and a malfunctioning or hostile one could otherwise loop
    forever. Fifty pages is far past any real project, and stopping short is
    reported rather than silently truncating a list the planner will treat as
    complete. -/
def listTopics (creds : Credentials) (project : String) : IO (List (String × String)) := do
  let rec go (fuel : Nat) (token : String) (acc : List (String × String)) :
      IO (List (String × String)) := do
    match fuel with
    | 0 =>
      IO.eprintln "warning: gcp pubsub: stopped paginating topics after 50 pages; \
the list may be incomplete"
      return acc
    | fuel' + 1 =>
      let query : Query := if token.isEmpty then [] else [("pageToken", some token)]
      let reply ← Gcp.call creds "GET" host s!"/v1/projects/{project}/topics" query
      let here := (arrayField reply "topics").filterMap fun t =>
        (stringField t "name").map fun n => (Gcp.shortName n, n)
      let acc := acc ++ here
      match stringField reply "nextPageToken" with
      | some next => if next.isEmpty then return acc else go fuel' next acc
      | none      => return acc
  go 50 "" []

/-- Create a topic. Returns its resource name.

    `PUT` rather than `POST`: the name is chosen by the caller and is part of
    the URL, so creation is idempotent in shape though not in effect — a second
    call answers `409 ALREADY_EXISTS`. -/
def createTopic (creds : Credentials) (project name : String) : IO String := do
  let reply ← Gcp.call creds "PUT" host (topicPath project name)
    (payload := some (.object []))
  return (stringField reply "name").getD (topicName project name)

/-- A topic's resource name, or a failure if it is not there.

    The engine treats a `404` here as the resource being absent — see
    `readsAsAbsent` in `Infra.Core.Engine` — so a topic deleted between the
    list and the read does not fail a pull. -/
def readTopic (creds : Credentials) (project name : String) : IO String := do
  let reply ← Gcp.call creds "GET" host (topicPath project name)
  return (stringField reply "name").getD (topicName project name)

/-- Delete a topic. Already gone is not an error.

    `delete` is reached from a plan, and a plan can be a little out of date —
    the same tolerance `Ec2.Instance'.delete` has for an instance that is
    already terminating. -/
def deleteTopic (creds : Credentials) (project name : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (topicPath project name)).toBaseIO with
  | .ok _ => pure ()
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e

/-! ## Self-checks

  Path construction, which is where a wrong resource name would come from and
  which needs no network to check. -/

#guard topicName "typednotes" "ci-tests-infra-queue"
  = "projects/typednotes/topics/ci-tests-infra-queue"
#guard Gcp.shortName "projects/typednotes/topics/ci-tests-infra-queue"
  = "ci-tests-infra-queue"
-- A bare name survives being shortened, so a reply that omits the prefix does
-- not turn into an empty handle.
#guard Gcp.shortName "ci-tests-infra-queue" = "ci-tests-infra-queue"

end Infra.Providers.Gcp.PubSub
