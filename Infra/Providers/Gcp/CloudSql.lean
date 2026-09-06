import Infra.Providers.Gcp.Rest
import Infra.Core.Stage

/-
  Managed Postgres on GCP: Cloud SQL.

  ## There is no serverless tier, and that is a refusal rather than a guess

  The portable `postgres` kind has two shapes. `PostgresSpec.serverless` names
  a capacity range and no instance class — Aurora Serverless v2 on AWS — and
  the classic shape names an instance class instead.

  Cloud SQL has no equivalent of the first. Its nearest relatives are
  autoscaling *storage* and per-instance CPU settings, neither of which is a
  capacity range that scales to a floor. So a serverless declaration on GCP
  **raises**, naming the tier to set instead. The alternative was to pick a
  tier silently from `minCapacity`, which would invent a bill the author never
  wrote down.

  ## Everything here is slow, and one thing is not waited for

  Creating an instance takes minutes. `awaitSqlOperation` allows ten of them,
  and `create` uses it — a create that returned before the instance existed
  would make the very next `read` fail, and the engine would report a resource
  that vanished.

  What is *not* waited for is the address: the create operation carries no IP,
  and fetching one afterwards would double an already long wait. So `create`
  reports an empty endpoint and the next `pull` observes the real one. That is
  the same trade `securityGroup` makes on AWS, where the VPC is blank until
  observed.

  ## Cloud SQL's operations are its own

  Not `google.longrunning.Operation`: a bare id for a name, and a `status`
  string in place of `done`. Hence the second poller in `Gcp.Rest`.

  Endpoints and field names checked against Google's Cloud SQL Admin API
  reference (`v1beta4`, `instances`), 2026-09.
-/

namespace Infra.Providers.Gcp.CloudSql

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)

/-- Cloud SQL's control plane. Shared with the operation poller. -/
def host : String := Gcp.sqlAdminHost

private def instances (project : String) : String :=
  s!"/sql/v1beta4/projects/{project}/instances"

private def instancePath (project name : String) : String :=
  instances project ++ "/" ++ name

/-- The user Cloud SQL creates for a Postgres instance. Unlike RDS, it is not
    chosen: `postgres` is the built-in superuser, and `rootPassword` sets its
    password. A declaration naming a different `masterUsername` is honoured by
    creating that user is *not* something the create call can do, so the
    declared name is reported back rather than the built-in one being
    asserted — see `read`. -/
def builtinUser : String := "postgres"

/-- Every instance in the project, with its primary address. -/
def list (creds : Credentials) (project : String) : IO (List (String × String)) := do
  let reply ← Gcp.call creds "GET" host (instances project)
  return (arrayField reply "items").filterMap fun i =>
    (stringField i "name").map fun n =>
      let ip := (arrayField i "ipAddresses").findSome? fun a =>
        if stringField a "type" == some "PRIMARY" then stringField a "ipAddress" else none
      (n, ip.getD "")

/-- Instance class, master user, version and storage size.

    `masterUsername` reports Cloud SQL's built-in superuser, because that is
    the only user the instance is created with. If a declaration names another
    one this shows as a divergence, which is correct: it is not there. -/
def read (creds : Credentials) (project name : String) :
    IO (String × String × Partial String × Partial Nat) := do
  let i ← Gcp.call creds "GET" host (instancePath project name)
  let tier := ((field i "settings").bind (stringField · "tier")).getD ""
  let version : Partial String :=
    match stringField i "databaseVersion" with
    | some v => .known v
    | none   => .unknown
  let storage : Partial Nat :=
    match (field i "settings").bind (stringField · "dataDiskSizeGb") with
    -- Cloud SQL reports it as a *string* holding an integer, which is why this
    -- goes through `toNat?` rather than `natField`.
    | some g => match g.toNat? with
                | some n => .known n
                | none   => .unknown
    | none   => .unknown
  return (tier, builtinUser, version, storage)

/-- Create an instance and wait for it. Returns an empty address; see the
    module note. -/
def create (creds : Credentials) (project region name instanceClass password : String)
    (version : String) (storageGb : Nat) : IO String := do
  let mut settings : List (String × Value) := [("tier", .string instanceClass)]
  if storageGb != 0 then
    settings := settings ++ [("dataDiskSizeGb", .string (toString storageGb))]
  let payload : Value := .object
    [ ("name", .string name)
    , ("region", .string region)
    , ("databaseVersion", .string (if version.isEmpty then "POSTGRES_16" else version))
    , ("rootPassword", .string password)
    , ("settings", .object settings) ]
  let started ← Gcp.call creds "POST" host (instances project) (payload := some payload)
  Gcp.awaitSqlOperation creds project started s!"cloud sql: create {name}"
  return ""

/-- Refuse a serverless declaration, and say what to write instead. -/
def createServerless (name : String) : IO String := do
  throw (IO.userError s!"gcp postgres: '{name}' is declared serverless \
(minCapacity/maxCapacity), and Cloud SQL has no serverless tier — no \
capacity range that scales to a floor.\n  Set an instance class instead, for \
example `instanceClass := \"db-custom-1-3840\"`, and Cloud SQL will size the \
instance from it. Choosing a tier here from the capacity range would invent a \
bill you did not write down.")

/-- Change the mutable settings and wait. `PATCH`, so unmentioned settings
    stay. -/
def update (creds : Credentials) (project name instanceClass : String)
    (storageGb : Nat) : IO Unit := do
  let mut settings : List (String × Value) := []
  unless instanceClass.isEmpty do
    settings := settings ++ [("tier", .string instanceClass)]
  if storageGb != 0 then
    settings := settings ++ [("dataDiskSizeGb", .string (toString storageGb))]
  if settings.isEmpty then return ()
  let started ← Gcp.call creds "PATCH" host (instancePath project name)
    (payload := some (.object [("settings", .object settings)]))
  Gcp.awaitSqlOperation creds project started s!"cloud sql: update {name}"

/-- Delete the instance and wait. Already gone is not an error.

    No skipping of the wait here: a `destroy` that returned while the instance
    was still being torn down would let the absence check pass against a
    listing that had not caught up, and the instance would keep billing. -/
def delete (creds : Credentials) (project name : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (instancePath project name)).toBaseIO with
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e
  | .ok started =>
    Gcp.awaitSqlOperation creds project started s!"cloud sql: delete {name}"

end Infra.Providers.Gcp.CloudSql
