import Infra.Providers.Kinds.Secrets
import Infra.Core.Stage

/-
  Managed PostgreSQL.

    * AWS RDS, over the Query protocol.
    * Scaleway Managed Database (RDB), over the REST API.

  ## The one place a secret value is read

  Both services demand a master password at creation, and `PostgresSpec` holds
  only `masterPasswordSecret` — the *name* of a secret, never the password. So
  creating a database means fetching that secret's value once, at apply time.

  That is the single exception to the rule in `Kinds.Secrets` that values only
  ever travel outward, and it is deliberately confined to `fetchMasterPassword`
  below. The value is passed straight to the create call and never returned,
  never stored in a `Sighting`, and never written to the `.infra/` cache. The
  `.secrets` kind's own `read` still never fetches a value; drift detection
  there remains metadata-only.

  ## Password changes are not reconciled

  Neither service reports the master password, so a rotation in the secret is
  invisible here. Rotating it means acting on the database directly. Detecting
  it would require storing or comparing the plaintext, which is precisely what
  this design refuses to do.
-/

namespace Infra.Providers.Kinds.Postgres

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws
open Infra.Providers.JsonRead
open Data.Json (Value)

/-- Fetch a master password from the cloud's secret manager, by secret name.

    The only value-reading path in the provider layer. Everything it returns
    flows into one create call and nowhere else. -/
def fetchMasterPassword (provider : ProviderId) (creds : Credentials) (secretName : String) :
    IO String := do
  if secretName.isEmpty then
    throw (IO.userError
      "postgres needs masterPasswordSecret: the name of a secret holding the master password")
  match provider with
  | .aws =>
    let ep := Json.secretsEndpoint creds.region
    let reply ← Json.call creds ep "secretsmanager.GetSecretValue"
      (.object [("SecretId", .string secretName)])
    match stringField reply "SecretString" with
    | some v => return v
    | none   => throw (IO.userError s!"secret '{secretName}' holds no string value")
  | .scaleway =>
    -- Scaleway returns the value base64-encoded from a versioned endpoint.
    let pfx := Scaleway.regionalPrefix "secret-manager" "v1beta1" creds.region
    let listing ← Scaleway.call creds "GET" (pfx ++ "/secrets")
    match (arrayField listing "secrets").find? (fun s => stringField s "name" == some secretName) with
    | none => throw (IO.userError s!"scaleway secrets: no secret named '{secretName}'")
    | some s =>
      let id := (stringField s "id").getD ""
      let reply ← Scaleway.call creds "GET" (pfx ++ s!"/secrets/{id}/versions/latest/access")
      match stringField reply "data" with
      | some encoded =>
        match Data.Base64.decode encoded with
        | some bytes => return String.fromUTF8! bytes
        | none       => throw (IO.userError s!"secret '{secretName}': value is not valid base64")
      | none => throw (IO.userError s!"secret '{secretName}' holds no data")

-- ══════════════════════════════════════════════════════════════
-- AWS RDS
-- ══════════════════════════════════════════════════════════════

namespace Rds

private def version : String := "2014-10-31"

private def instances (root : Text.XML.Element) (result : String) : List Text.XML.Element :=
  match root.child result with
  | none   => []
  | some r => Query.listItems r "DBInstances" "DBInstance"

def list (creds : Credentials) (ep : Endpoint) : IO (List (String × String)) := do
  let root ← Query.call creds ep "DescribeDBInstances" version
  return (instances root "DescribeDBInstancesResult").filterMap fun i =>
    match i.childText "DBInstanceIdentifier" with
    | some n =>
      let host := match i.child "Endpoint" with
        | some e => (e.childText "Address").getD ""
        | none   => ""
      some (n, host)
    | none => none

def read (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (String × String × Partial String × Partial Nat) := do
  let root ← Query.call creds ep "DescribeDBInstances" version
    [("DBInstanceIdentifier", name)]
  match (instances root "DescribeDBInstancesResult").head? with
  | none => return ("", "", .unknown, .unknown)
  | some i =>
    let cls := (i.childText "DBInstanceClass").getD ""
    let user := (i.childText "MasterUsername").getD ""
    let ver := match i.childText "EngineVersion" with
      | some v => Partial.known v
      | none   => .unknown
    let storage := match (i.childText "AllocatedStorage").bind String.toNat? with
      | some s => Partial.known s
      | none   => .unknown
    return (cls, user, ver, storage)

def create (creds : Credentials) (ep : Endpoint) (name instanceClass masterUsername
    password engineVersion : String) (storageGb : Nat) : IO String := do
  let root ← Query.call creds ep "CreateDBInstance" version
    [ ("DBInstanceIdentifier", name)
    , ("DBInstanceClass", instanceClass)
    , ("Engine", "postgres")
    , ("EngineVersion", engineVersion)
    , ("AllocatedStorage", toString storageGb)
    , ("MasterUsername", masterUsername)
    , ("MasterUserPassword", password) ]
  return match root.child "CreateDBInstanceResult" with
    | some r => match r.child "DBInstance" with
      | some i => match i.child "Endpoint" with
        | some e => (e.childText "Address").getD ""
        | none   => ""
      | none => ""
    | none => ""

/-- Only the settings RDS can change in place. Storage can grow but not shrink;
    `ApplyImmediately` avoids the change sitting in a maintenance window where
    a later plan would keep proposing it. -/
def modify (creds : Credentials) (ep : Endpoint) (name instanceClass : String)
    (storageGb : Nat) : IO Unit := do
  discard <| Query.call creds ep "ModifyDBInstance" version
    [ ("DBInstanceIdentifier", name)
    , ("DBInstanceClass", instanceClass)
    , ("AllocatedStorage", toString storageGb)
    , ("ApplyImmediately", "true") ]

/-- `SkipFinalSnapshot` because a target that says the database should be gone
    means gone; leaving a snapshot behind keeps the identifier reserved and the
    plan would never converge. -/
def delete (creds : Credentials) (ep : Endpoint) (name : String) : IO Unit := do
  discard <| Query.call creds ep "DeleteDBInstance" version
    [("DBInstanceIdentifier", name), ("SkipFinalSnapshot", "true")]

end Rds

-- ══════════════════════════════════════════════════════════════
-- Scaleway Managed Database
-- ══════════════════════════════════════════════════════════════

namespace Rdb

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "rdb" "v1" region

private def listRaw (creds : Credentials) : IO (List (String × String × String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/instances")
  return (arrayField reply "instances").filterMap fun i =>
    match stringField i "name", stringField i "id" with
    | some n, some id =>
      let host := match field i "endpoint" with
        | some e => (stringField e "ip").getD ""
        | none   => ""
      some (n, id, host)
    | _, _ => none

def list (creds : Credentials) : IO (List (String × String)) := do
  return (← listRaw creds).map fun (n, _, h) => (n, h)

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError s!"scaleway rdb: no instance named '{name}'")

def read (creds : Credentials) (name : String) :
    IO (String × String × Partial String × Partial Nat) := do
  let id ← requireId creds name
  let i ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/instances/{id}")
  let cls := (stringField i "node_type").getD ""
  -- Scaleway reports the engine as e.g. `PostgreSQL-16`; only the version part
  -- is comparable with what a target writes.
  let ver := match stringField i "engine" with
    | some e => match (e.splitOn "-").getLast? with
      | some v => Partial.known v
      | none   => .unknown
    | none => .unknown
  let storage := match field i "volume" with
    | some v => match natField v "size" with
      -- Reported in bytes; targets are written in gigabytes.
      | some bytes => Partial.known (bytes / 1000000000)
      | none       => .unknown
    | none => .unknown
  return (cls, "", ver, storage)

def create (creds : Credentials) (name nodeType masterUsername password engineVersion : String)
    (storageGb : Nat) : IO String := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/instances")
    (payload := some (.object
      [ ("name", .string name)
      , ("engine", .string s!"PostgreSQL-{engineVersion}")
      , ("node_type", .string nodeType)
      , ("user_name", .string masterUsername)
      , ("password", .string password)
      , ("volume_size", .number (Float.ofNat (storageGb * 1000000000)))
      , ("volume_type", .string "bssd")
      , ("project_id", .string project) ]))
  return match field reply "endpoint" with
    | some e => (stringField e "ip").getD ""
    | none   => ""

def modify (creds : Credentials) (name nodeType : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/instances/{id}")
    (payload := some (.object [("node_type", .string nodeType)]))

def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/instances/{id}")

end Rdb

-- ══════════════════════════════════════════════════════════════
-- Scaleway Serverless SQL Database
-- ══════════════════════════════════════════════════════════════

/- Routed to when a `PostgresSpec`'s `instanceClass` is unset (see `PostgresSpec.serverless` and
   `Infra.Providers.Live`'s `.postgres` branch).

   **Genuinely unimplemented.** Scaleway Serverless SQL Database's real endpoint paths, payload
   field names, and capacity units are not verified against any account — see
   `docs/providers.md`. `list`/`read` report honestly (nothing known, matching `unknown`'s
   meaning throughout this codebase); mutations raise a named "not yet implemented" error rather
   than guess at a shape that only looks like it works, because a create that silently does
   nothing would make the engine believe a database exists when it does not.

   AWS's serverless counterpart, Aurora Serverless v2, has no analogous namespace here at all:
   `Live.lean` raises directly rather than routing through a stub, since there is no partial
   RDS-based path to reuse the way there is for `list`/`read` on Scaleway's classic RDB. -/
namespace ServerlessSql

def list (_creds : Credentials) : IO (List (String × String)) := pure []

def read (_creds : Credentials) (_name : String) :
    IO (String × String × Partial String × Partial Nat) :=
  pure ("", "", .unknown, .unknown)

private def unimplemented {α : Type} (op : String) : IO α :=
  throw (IO.userError s!"scaleway serverless sql database: {op} is not yet implemented")

def create (_creds : Credentials) (_name _masterUsername _password _engineVersion : String)
    (_minCapacity _maxCapacity : Nat) : IO String :=
  unimplemented "create"

def modify (_creds : Credentials) (_name : String) (_minCapacity _maxCapacity : Nat) : IO Unit :=
  unimplemented "modify"

def delete (_creds : Credentials) (_name : String) : IO Unit :=
  unimplemented "delete"

end ServerlessSql

end Infra.Providers.Kinds.Postgres
