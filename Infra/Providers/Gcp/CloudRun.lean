import Infra.Providers.Gcp.Rest
import Infra.Core.Stage

/-
  Serverless compute on GCP: Cloud Run services.

  The portable `compute` kind is "run this container image". Cloud Run is the
  direct match, and it is the same reading Scaleway's backend takes with
  Serverless Containers — so the portable spec needs no new fields.

  Cloud Functions was the alternative and is the worse one for this kind: it
  deploys *source*, from a bucket or a repository, which the portable spec has
  no way to name. `compute` carries an `image`.

  ## Units, which is where this kind actually differs per cloud

  Lambda takes memory as a number of megabytes and a timeout as a number of
  seconds. Cloud Run takes a Kubernetes quantity (`512Mi`) and a duration
  (`30s`), and reports them back the same way. So this file is the only place
  in the GCP clients doing real parsing, and it is deliberately conservative:
  a value it does not recognise reads as `unknown` rather than as a number it
  guessed, because a wrong number here is a divergence that would be
  "corrected" on every single apply.

  ## `executionRole` is the runtime identity, and silence about it is dangerous

  This was originally left unmapped on the grounds that `executionRole` is
  Lambda's concept and Cloud Run's service account is "a different thing with
  different semantics". That was wrong in the way that matters: both name the
  identity the code runs as, and *not sending one is not neutral.*

  A Cloud Run service with no service account runs as the project's **default
  compute service account**, which Google grants `roles/editor` on creation.
  So a declaration that says nothing about identity gets an Editor on the whole
  project — the opposite of what leaving a field unspoken is supposed to mean
  elsewhere in this library, where it means "whatever the cloud has, stays".
  On a create there is no "whatever the cloud has"; there is a default, and
  this one is enormous.

  So `executionRole` maps to the service's `serviceAccount`, and omitting it
  warns rather than passing quietly. It is a warning and not a refusal because
  the field is optional in the portable spec and a project may legitimately
  have tightened its default — but it is said out loud, because nobody would
  otherwise learn it from the declaration.

  Found by a live run: deploying without one fails with
  `iam.serviceaccounts.actAs denied on …-compute@developer.gserviceaccount.com`,
  which is Google refusing to let the deployer borrow that identity. The error
  is about permission; the problem it reveals is about which identity was being
  chosen.

  `runtime`, `namespace'` and `handler` really are not Cloud Run concepts, and
  stay `unknown` — the same fields AWS and Scaleway already leave unset.

  Endpoints and field names checked against Google's Cloud Run Admin API
  reference (`v2`, `projects.locations.services`), 2026-09.
-/

namespace Infra.Providers.Gcp.CloudRun

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)
open Network.HTTP.Types (Query)

def host : String := "run.googleapis.com"

private def parent (project location : String) : String :=
  s!"/v2/projects/{project}/locations/{location}/services"

private def servicePath (project location name : String) : String :=
  parent project location ++ "/" ++ name

/-- `512Mi` to `512`. Also accepts `M`, `Gi` and `G`.

    `none` for anything else, including a bare byte count: Cloud Run does
    accept one, but treating it as megabytes would be off by a factor of a
    million, and reporting `unknown` costs only a field in the divergence
    table. -/
def parseMemoryMi (s : String) : Option Nat :=
  let num (body : String) : Option Nat := body.toNat?
  if s.endsWith "Mi" then num (s.dropEnd 2).copy
  else if s.endsWith "M" then num (s.dropEnd 1).copy
  else if s.endsWith "Gi" then (num (s.dropEnd 2).copy).map (· * 1024)
  else if s.endsWith "G"  then (num (s.dropEnd 1).copy).map (· * 1024)
  else none

/-- `30s` to `30`. Fractional seconds round down; anything else is `none`. -/
def parseSeconds (s : String) : Option Nat :=
  if s.endsWith "s" then
    let body := (s.dropEnd 1).copy
    match body.toNat? with
    | some n => some n
    | none   => ((body.splitOn ".").head?.bind (·.toNat?))
  else none

/-- Every service in the project and location, with its status. -/
def list (creds : Credentials) (project location : String) :
    IO (List (String × String)) := do
  let rec go (fuel : Nat) (token : String) (acc : List (String × String)) :
      IO (List (String × String)) := do
    match fuel with
    | 0 =>
      IO.eprintln "warning: gcp cloud run: stopped paginating services after 50 \
pages; the list may be incomplete"
      return acc
    | fuel' + 1 =>
      let query : Query := if token.isEmpty then [] else [("pageToken", some token)]
      let reply ← Gcp.call creds "GET" host (parent project location) query
      let here := (arrayField reply "services").filterMap fun s =>
        (stringField s "name").map fun n =>
          -- `terminalCondition.type` is the closest thing to a one-word status.
          let status := (field s "terminalCondition").bind (stringField · "state")
          (Gcp.shortName n, status.getD "")
      let acc := acc ++ here
      match stringField reply "nextPageToken" with
      | some next => if next.isEmpty then return acc else go fuel' next acc
      | none      => return acc
  go 50 "" []

/-- The first container of the service's template, which is the one this kind
    manages. A service with none is malformed rather than empty. -/
private def firstContainer (svc : Value) : Option Value :=
  (field svc "template").bind fun t => (arrayField t "containers").head?

/-- What `read` needs: image, memory, timeout, environment. -/
def read (creds : Credentials) (project location name : String) :
    IO (String × Partial Nat × Partial Nat × Partial (List (String × String))
        × Partial String) := do
  let svc ← Gcp.call creds "GET" host (servicePath project location name)
  let container := firstContainer svc
  let image := (container.bind (stringField · "image")).getD ""
  let memory : Partial Nat :=
    match container.bind (fun c => (field c "resources").bind (fun r =>
        (field r "limits").bind (stringField · "memory"))) with
    | some m => match parseMemoryMi m with
                | some n => .known n
                | none   => .unknown
    | none   => .unknown
  let timeout : Partial Nat :=
    match (field svc "template").bind (stringField · "timeout") with
    | some t => match parseSeconds t with
                | some n => .known n
                | none   => .unknown
    | none   => .unknown
  let env : Partial (List (String × String)) :=
    match container with
    | none => .unknown
    | some c =>
      .known ((arrayField c "env").filterMap fun e =>
        match stringField e "name", stringField e "value" with
        | some k, some v => some (k, v)
        -- An env var backed by a secret reports `valueSource`, not `value`.
        -- It cannot be compared against a literal, so it is dropped rather
        -- than reported as empty — the same choice `securityGroup` makes for
        -- a rule it cannot represent.
        | _,      _      => none)
  let serviceAccount : Partial String :=
    match (field svc "template").bind (stringField · "serviceAccount") with
    | some sa => if sa.isEmpty then .unknown else .known sa
    | none    => .unknown
  return (image, memory, timeout, env, serviceAccount)

private def bodyOf (image : String) (memoryMb timeoutSec : Nat)
    (env : List (String × String)) (serviceAccount : String) : Value :=
  .object
    [ ("template", .object
        ([ ("timeout", .string s!"{timeoutSec}s") ]
         -- Only when named. An empty string is not a service account, and
         -- sending one would be rejected rather than defaulted.
         ++ (if serviceAccount.isEmpty then []
             else [("serviceAccount", .string serviceAccount)])
         ++
        [ ("containers", .array
            #[ .object
                 [ ("image", .string image)
                 , ("resources", .object
                     [("limits", .object [("memory", .string s!"{memoryMb}Mi")])])
                 , ("env", .array ((env.map fun (k, v) =>
                     Value.object [("name", .string k), ("value", .string v)]).toArray)) ] ]) ])) ]

/-- Say so when no runtime identity was named. See the module note: the
    default is an Editor on the project, so this is not a detail. -/
private def warnIfNoIdentity (name serviceAccount : String) : IO Unit := do
  if serviceAccount.isEmpty then
    IO.eprintln s!"warning: cloud run '{name}' declares no executionRole, so it \
will run as the project's default compute service account — which Google grants \
roles/editor. Name one to avoid that."

/-- Create the service and wait for it. -/
def create (creds : Credentials) (project location name image : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String))
    (serviceAccount : String) : IO Unit := do
  warnIfNoIdentity name serviceAccount
  let started ← Gcp.call creds "POST" host (parent project location)
    [("serviceId", some name)]
    (payload := some (bodyOf image memoryMb timeoutSec env serviceAccount))
  discard <| Gcp.awaitLro creds host "v2" started s!"cloud run: create {name}"

/-- Update the service and wait for it.

    A `PATCH` on a Cloud Run service replaces the template wholesale, so every
    managed field is sent every time — sending only the changed one would drop
    the others. That is the opposite of the Artifact Registry call above, and
    the difference is the API's, not a choice made here. -/
def update (creds : Credentials) (project location name image : String)
    (memoryMb timeoutSec : Nat) (env : List (String × String))
    (serviceAccount : String) : IO Unit := do
  warnIfNoIdentity name serviceAccount
  let started ← Gcp.call creds "PATCH" host (servicePath project location name)
    (payload := some (bodyOf image memoryMb timeoutSec env serviceAccount))
  discard <| Gcp.awaitLro creds host "v2" started s!"cloud run: update {name}"

/-- Delete the service and wait for it. Already gone is not an error. -/
def delete (creds : Credentials) (project location name : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (servicePath project location name)).toBaseIO with
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e
  | .ok started =>
    discard <| Gcp.awaitLro creds host "v2" started s!"cloud run: delete {name}"

/-! ## Self-checks — the unit parsing, which is the only guessing this file does -/

#guard parseMemoryMi "512Mi" = some 512
#guard parseMemoryMi "512M"  = some 512
#guard parseMemoryMi "1Gi"   = some 1024
#guard parseMemoryMi "2G"    = some 2048
-- A bare byte count is *not* read as megabytes: being wrong by a million is
-- worse than reporting nothing.
#guard parseMemoryMi "536870912" = none
#guard parseMemoryMi "" = none

#guard parseSeconds "30s"   = some 30
#guard parseSeconds "3.5s"  = some 3
#guard parseSeconds "30"    = none
#guard parseSeconds "s"     = none

end Infra.Providers.Gcp.CloudRun
