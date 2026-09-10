import Infra.Providers.Kinds.Secrets
import Infra.Core.Stage
import Infra.Core.Ownership

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
  -- Delegated rather than duplicated. This function's per-cloud bodies are
  -- near-copies of `Secrets.fetchValue`'s, which is exactly how GCP came to be
  -- implemented in one and missing from the other: the value-read path was
  -- added to Secret Manager's client and to `fetchValue`, and this copy still
  -- said "no backend yet". The other two branches below are the remaining
  -- duplication and should go the same way.
  | .gcp => Secrets.fetchValue provider creds secretName
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
      (query := [("project_id", ← creds.requireProject)])
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
    password engineVersion markerValue : String) (storageGb : Nat) : IO String := do
  let root ← Query.call creds ep "CreateDBInstance" version
    [ ("DBInstanceIdentifier", name)
    , ("DBInstanceClass", instanceClass)
    , ("Engine", "postgres")
    , ("EngineVersion", engineVersion)
    , ("AllocatedStorage", toString storageGb)
    , ("MasterUsername", masterUsername)
    , ("MasterUserPassword", password)
    , ("Tags.member.1.Key", markerKey), ("Tags.member.1.Value", markerValue) ]
  return match root.child "CreateDBInstanceResult" with
    | some r => match r.child "DBInstance" with
      | some i => match i.child "Endpoint" with
        | some e => (e.childText "Address").getD ""
        | none   => ""
      | none => ""
    | none => ""

/-- The ARN behind a name, needed for `ListTagsForResource`: unlike EC2's
    `DescribeInstances`, RDS's `DescribeDBInstances` does not embed tags in the
    listing, so a second call is required. -/
private def arnOf (creds : Credentials) (ep : Endpoint) (name : String) : IO (Option String) := do
  let root ← Query.call creds ep "DescribeDBInstances" version
    [("DBInstanceIdentifier", name)]
  return (instances root "DescribeDBInstancesResult").head?.bind (·.childText "DBInstanceArn")

/-- Tags, for `Ownership.ownershipOf`. `createdAt` is left `none`, matching
    every other kind's first tranche, though `InstanceCreateTime` is available
    on the instance if a later pass wants it. -/
def readOwnership (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Option (List (String × String) × Option String)) := do
  match ← arnOf creds ep name with
  | none => return none
  | some arn =>
    let root ← Query.call creds ep "ListTagsForResource" version [("ResourceName", arn)]
    let tags := match root.child "ListTagsForResourceResult" with
      | some r => (Query.listItems r "TagList" "Tag").filterMap fun t =>
          match t.childText "Key", t.childText "Value" with
          | some k, some v => some (k, v)
          | _, _           => none
      | none => []
    return some (tags, none)

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

private def listRaw (creds : Credentials) : IO (List (String × String × String × List String)) := do
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/instances")
      (query := [("project_id", ← creds.requireProject)])
  return (arrayField reply "instances").filterMap fun i =>
    match stringField i "name", stringField i "id" with
    | some n, some id =>
      let host := match field i "endpoint" with
        | some e => (stringField e "ip").getD ""
        | none   => ""
      some (n, id, host, stringArrayField i "tags")
    | _, _ => none

def list (creds : Credentials) : IO (List (String × String)) := do
  return (← listRaw creds).map fun (n, _, h, _) => (n, h)

private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _, _) => return id
  | none                => throw (IO.userError s!"scaleway rdb: no instance named '{name}'")

/-- Tags, for `Ownership.ownershipOf`. -/
def readOwnership (creds : Credentials) (name : String) :
    IO (Option (List (String × String) × Option String)) := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, _, tags) => return some (tags.map Scaleway.decodeTag, none)
  | none                  => return none

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

def create (creds : Credentials)
    (name nodeType masterUsername password engineVersion markerValue : String)
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
      , ("project_id", .string project)
      , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]))
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

/- Scaleway Serverless SQL Database, which is what a `PostgresSpec` with no
   `instanceClass` means on this cloud (see `PostgresSpec.serverless` and
   `Infra.Providers.Live`'s `.postgres` branch).

   ## Why this is a separate product and not a mode of `rdb`

   Managed Database sizes an instance by `node_type` and bills for it whether
   it is busy or not. Serverless SQL has no node type at all: it scales between
   `cpu_min` and `cpu_max` vCPU and bills for what it uses. Different endpoint,
   different object, different identity — hence a second namespace rather than
   a flag.

   ## What the portable spec cannot say here

   `masterUsername` and `masterPasswordSecret` have **no counterpart**. A
   Serverless SQL Database has no root user to set a password for: access is
   through IAM credentials, minted separately. So the create call below ignores
   both, and `read` reports no username rather than inventing one — which
   keeps them out of the divergence table instead of proposing a change on
   every apply.

   Worth knowing: `Live.lean` fetches the master password *before* it branches
   on `instanceClass`, so a serverless declaration still reads the secret it
   names. Harmless, and cheaper to leave than to restructure the branch, but it
   means the secret must exist even though nothing consumes it.

   `storageGb` has no counterpart — storage grows on its own. `version` does
   have one on `create` (see below), but `read` still reports none: the `GET`
   response carries no such field for this product.

   ## Verified

   The endpoint family was confirmed against the live API rather than recalled:
   `/serverless-sqldb/v1alpha1/regions/fr-par/databases` answers `401`
   unauthenticated, where `serverless_sqldb`, `v1beta1` and a bogus route all
   answer `404` — the same discriminator used for the Queues paths. Field names
   (`name`, `cpu_min`, `cpu_max`, `project_id`, `database_id`) come from
   Scaleway's own CLI reference for `scw sdb sql`. Checked 2026-09-06.

   `create` was run against a live account on 2026-09-10 and came back `HTTP
   400 invalid_arguments` with no `version` field in the payload — confirmed
   against Scaleway's own API reference
   (developers.scaleway.com/en/developers/api/serverless-sql-databases), whose
   Create-Database example includes a required `version` field and states only
   PostgreSQL 16 is currently supported. Fixed by sending it, defaulting to
   `"16"`; see `docs/coverage.md` and `CHANGELOG.md`.

   ## Permanent exception: this product cannot be tagged

   Confirmed against Scaleway's own API reference (as above) — the
   Create-Database payload has no `tags` field, and `/databases` and
   `/databases/{id}` responses carry none either. There is no marker to write
   and none to read back, so `Backend.ownershipInfo` returns `none` for this
   kind unconditionally (see `Live.lean`'s `.postgres` arm) and the engine's
   fail-safe (`Engine.lean`, the 2026-09-10 incident) refuses to adopt or
   delete-as-orphan any Serverless SQL Database purely on the ledger's say-so.
   A fleet that already has one from before this fix will see it reported as
   unmanageable until Scaleway adds tag support — this is a permanent,
   intentional gap, not a half-implemented feature: see `AGENTS.md`'s "no
   half-implemented features" rule. -/
namespace ServerlessSql

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "serverless-sqldb" "v1alpha1" region

/-- Databases in the project, as `(name, id, endpoint)`.

    Scoped to the project explicitly: unlike `rdb`, the list is not implicitly
    narrowed, and a fleet must not manage another project's databases. -/
private def listRaw (creds : Credentials) : IO (List (String × String × String)) := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "GET" (prefix' creds.region ++ "/databases")
    (query := [("project_id", project)])
  return (arrayField reply "databases").filterMap fun d =>
    match stringField d "name", stringField d "id" with
    | some n, some id => some (n, id, (stringField d "endpoint").getD "")
    | _, _ => none

def list (creds : Credentials) : IO (List (String × String)) := do
  return (← listRaw creds).map fun (n, _, e) => (n, e)

/-- The id behind a name. Identity is by id here, as it is for `rdb`, while a
    fleet keys on the name. -/
private def requireId (creds : Credentials) (name : String) : IO String := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, id, _) => return id
  | none            => throw (IO.userError
      s!"scaleway serverless sql: no database named '{name}' in this project")

/-- Prove it exists, and report the little there is to report.

    Every field the portable spec carries is absent from this product — no
    node type, no root user, no version, no fixed storage — so all four come
    back empty or `unknown`. That is not a stub: `unknown` means "not
    observed", it diverges from nothing, and the `GET` is what establishes the
    database is actually there. -/
def read (creds : Credentials) (name : String) :
    IO (String × String × Partial String × Partial Nat) := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "GET" (prefix' creds.region ++ s!"/databases/{id}")
  return ("", "", .unknown, .unknown)

/-- Create a database. Returns its endpoint.

    `masterUsername` and `password` are accepted and unused — see the module
    note. They are still in the signature because `Live.lean` calls this and
    the classic path side by side, and dropping them would make the two
    branches look like they differ in more than they do.

    `engineVersion` **is** used, unlike the two above: Scaleway's create
    endpoint requires a `version` field in the payload and rejects the
    request with `HTTP 400 invalid_arguments` without one. Falls back to
    `"16"` — the only PostgreSQL version this product currently supports —
    when the spec left it unset, since `PostgresSpec.version` is optional and
    a serverless target has no other way to pick one. -/
def create (creds : Credentials) (name _masterUsername _password engineVersion : String)
    (minCapacity maxCapacity : Nat) : IO String := do
  let project ← creds.requireProject
  let version := if engineVersion.isEmpty then "16" else engineVersion
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/databases")
    (payload := some (.object
      [ ("name", .string name)
      , ("project_id", .string project)
      , ("version", .string version)
      , ("cpu_min", .number (Float.ofNat minCapacity))
      , ("cpu_max", .number (Float.ofNat maxCapacity)) ]))
  return (stringField reply "endpoint").getD ""

/-- Change the capacity range. -/
def modify (creds : Credentials) (name : String) (minCapacity maxCapacity : Nat) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/databases/{id}")
    (payload := some (.object
      [ ("cpu_min", .number (Float.ofNat minCapacity))
      , ("cpu_max", .number (Float.ofNat maxCapacity)) ]))

/-- Delete the database. -/
def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/databases/{id}")

end ServerlessSql

end Infra.Providers.Kinds.Postgres
