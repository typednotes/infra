import Infra.Providers.Kinds.Secrets
import Infra.Core.Stage
import Infra.Core.Ownership
import Infra.Providers.Marker

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
  never stored in a `Sighting`, and so never reaches a plan or a `dump`. The
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
    match reply.lookupText "SecretString" with
    | some v => return v
    | none   => throw (IO.userError s!"secret '{secretName}' holds no string value")
  | .scaleway =>
    -- Scaleway returns the value base64-encoded from a versioned endpoint.
    let pfx := Scaleway.regionalPrefix "secret-manager" "v1beta1" creds.region
    let listing ← Scaleway.listAll creds "scaleway secrets" (pfx ++ "/secrets") "secrets"
      (query := [("project_id", ← creds.requireProject), ("name", secretName)])
    match listing.find? (fun s => s.lookupText "name" == some secretName) with
    | none => throw (IO.userError s!"scaleway secrets: no secret named '{secretName}'")
    | some s =>
      let id := (s.lookupText "id").getD ""
      let reply ← Scaleway.call creds "GET" (pfx ++ s!"/secrets/{id}/versions/latest/access")
      match reply.lookupText "data" with
      | some encoded =>
        match Data.Base64.decode encoded with
        | some bytes => Http.utf8Text s!"secret '{secretName}'" bytes
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

/-- Every instance, every page: `Marker` both ways, 100 a page by default
    (botocore, `rds/2014-10-31`, read 2026-09-29). -/
def list (creds : Credentials) (ep : Endpoint) : IO (List (String × String)) := do
  let roots ← Query.callAll creds ep "DescribeDBInstances" version [] "Marker" fun root =>
    (root.child "DescribeDBInstancesResult").bind (·.childText "Marker")
  return (roots.flatMap (instances · "DescribeDBInstancesResult")).filterMap fun i =>
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

/-- One instance's tags, by ARN. -/
private def tagsOfArn (creds : Credentials) (ep : Endpoint) (arn : String) :
    IO (List (String × String)) := do
  let root ← Query.call creds ep "ListTagsForResource" version [("ResourceName", arn)]
  return match root.child "ListTagsForResourceResult" with
    | some r => (Query.listItems r "TagList" "Tag").filterMap fun t =>
        match t.childText "Key", t.childText "Value" with
        | some k, some v => some (k, v)
        | _, _           => none
    | none => []

/-- Tags, for `Ownership.ownershipOf`. `createdAt` is left `none`, matching
    every other kind's first tranche, though `InstanceCreateTime` is available
    on the instance if a later pass wants it. -/
def readOwnership (creds : Credentials) (ep : Endpoint) (name : String) :
    IO Evidence := do
  match ← arnOf creds ep name with
  | none     => return .unreadable
  | some arn => return .tags (← tagsOfArn creds ep arn) none

/-- Take this fleet's ownership marker off the instance, leaving its other
    tags.

    `RemoveTagsFromResource` removes by key alone (RDS API reference:
    `ResourceName`, `TagKeys.member.N`), so the value is checked first against
    a fresh `ListTagsForResource`. -/
def releaseMarker (creds : Credentials) (ep : Endpoint) (name fleet : String) : IO Unit := do
  match ← arnOf creds ep name with
  | none     => pure ()
  | some arn =>
    if (Marker.releaseTags fleet (← tagsOfArn creds ep arn)).isSome then
      discard <| Query.call creds ep "RemoveTagsFromResource" version
        [("ResourceName", arn), ("TagKeys.member.1", markerKey)]

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

/-- A provider-reported public endpoint must carry a real bounded TCP port.
    Constructors are private; URL composition consumes only validated endpoints.
    Scaleway SDK `api/rdb/v1`, checked 2026-10-01: `endpoints` supersedes the
    deprecated singular `endpoint`, and a public endpoint has `load_balancer`. -/
private structure PublicEndpoint where
  host : String
  port : Nat
  portBound : 0 < port ∧ port < 65536
  safeHost : (!host.isEmpty && host.toList.all (fun c => decide (c.toNat < 128) && (c.isAlphanum || c == '.' || c == '-'))) = true

private def PublicEndpoint.parse (value : Value) : Option PublicEndpoint := do
  let host ← match value.lookupText "hostname", value.lookupText "ip" with
    | some host, none | none, some host => some host
    | _, _ => none
  let port ← value.lookupNat "port"
  if h : (!host.isEmpty && host.toList.all (fun c => decide (c.toNat < 128) && (c.isAlphanum || c == '.' || c == '-'))) = true then
    if p : 0 < port ∧ port < 65536 then some ⟨host, port, p, h⟩ else none
  else none

private def PublicEndpoint.address (endpoint : PublicEndpoint) : String :=
  s!"{endpoint.host}:{endpoint.port}"

private def absentEndpointKind (value : Value) (field : String) : Bool :=
  match value.lookup field with
  | none | some .null => true
  | _ => false

private def publicEndpointKind (value : Value) : Bool :=
  match value.lookup "load_balancer" with
  | some (.object _) => true
  | _ => false

/-- No private-network endpoint, implicit port, or ambiguous public selector.
    The legacy field is accepted only when the modern field is absent. -/
def endpointAddress? (reply : Value) : Option String := do
  let value ← match reply.lookup "endpoints" with
    | some (.array endpoints) =>
      match endpoints.toList.filter (fun e => publicEndpointKind e &&
          absentEndpointKind e "private_network" && absentEndpointKind e "direct_access") with
      | [endpoint] => some endpoint
      | _ => none
    | some _ => none
    | none => do
      let endpoint ← reply.lookup "endpoint"
      if !absentEndpointKind endpoint "private_network" || !absentEndpointKind endpoint "direct_access" then none
      else some endpoint
  return (← PublicEndpoint.parse value).address

private def endpointFixture (port : Nat) : Value := .object
  [("ip", .string "192.0.2.7"), ("port", .number (Float.ofNat port)), ("load_balancer", .object [])]

#guard endpointAddress? (.object [("endpoints", .array #[endpointFixture 25432])]) = some "192.0.2.7:25432"
#guard endpointAddress? (.object [("endpoint", endpointFixture 5432)]) = some "192.0.2.7:5432"
#guard endpointAddress? (.object [("endpoints", .array #[endpointFixture 0])]) = none
#guard endpointAddress? (.object [("endpoints", .array #[endpointFixture 65536])]) = none
#guard endpointAddress? (.object [("endpoints", .array #[endpointFixture 5432, endpointFixture 25432])]) = none
#guard endpointAddress? (.object [("endpoints", .array #[]), ("endpoint", endpointFixture 5432)]) = none
#guard endpointAddress? (.object [("endpoint", .object [("ip", .string "x/other"), ("port", .number 5432)])]) = none
#guard endpointAddress? (.object [("endpoint", .object [("ip", .string "192.0.2.7"), ("port", .number 5432),
  ("private_network", .object [])])]) = none
#guard endpointAddress? (.object [("endpoints", .array #[.object [("hostname", .string "db.example.invalid"),
  ("port", .number 25432), ("load_balancer", .object []), ("private_network", .null),
  ("direct_access", .null)]])]) = some "db.example.invalid:25432"

private def listRaw (creds : Credentials) : IO (List (String × String × String × List String)) := do
  let instances ← Scaleway.listAll creds "scaleway rdb instances"
      (prefix' creds.region ++ "/instances") "instances"
      (query := [("project_id", ← creds.requireProject)])
  return instances.filterMap fun i =>
    match i.lookupText "name", i.lookupText "id" with
    | some n, some id =>
      let host := (endpointAddress? i).getD ""
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
    IO Evidence := do
  match (← listRaw creds).find? (·.1 == name) with
  | some (_, _, _, tags) => return .tags (tags.map Scaleway.decodeTag) none
  | none                 => return .unreadable

def read (creds : Credentials) (name : String) :
    IO (String × String × Partial String × Partial Nat) := do
  let id ← requireId creds name
  let i ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/instances/{id}")
  let cls := (i.lookupText "node_type").getD ""
  -- Scaleway reports the engine as e.g. `PostgreSQL-16`; only the version part
  -- is comparable with what a target writes.
  let ver := match i.lookupText "engine" with
    | some e => match (e.splitOn "-").getLast? with
      | some v => Partial.known v
      | none   => .unknown
    | none => .unknown
  let storage := match i.lookup "volume" with
    | some v => match v.lookupNat "size" with
      -- Reported in bytes; targets are written in gigabytes.
      | some bytes => Partial.known (bytes / 1000000000)
      | none       => .unknown
    | none => .unknown
  -- Instance does not report its initial username. Returning "" fabricated
  -- immutable drift and would replace a correctly configured compute DB.
  -- Resolve the sole administrator from this project-bound instance instead;
  -- ambiguity refuses the plan rather than guessing which user is the master.
  let users ← Scaleway.listAll creds "scaleway rdb users"
    (prefix' creds.region ++ s!"/instances/{id}/users") "users"
  let admins := users.filterMap fun user =>
    if user.lookupBool "is_admin" == some true then user.lookupText "name" else none
  let username ← match admins with
    | [name] => pure name
    | _ => throw (IO.userError s!"scaleway rdb: '{name}' must have one unambiguous administrator to compare masterUsername")
  return (cls, username, ver, storage)

/-- Classic instances use SBS 5K block storage. Scaleway rejects new `bssd`
    volumes as deprecated (Typednotes apply, 2026-10-01). The RDB v1 create
    schema names the replacement `sbs_5k`; the live `fr-par` node catalogue
    confirmed it supports `db-dev-s` with 10 GB on the same date. Size stays
    in decimal GB, independently of node size, as with the old block volume. -/
private def createPayload
    (project name nodeType masterUsername password engineVersion markerValue : String)
    (storageGb : Nat) : Value :=
  .object
    [ ("name", .string name)
    , ("engine", .string s!"PostgreSQL-{engineVersion}")
    , ("node_type", .string nodeType)
    , ("user_name", .string masterUsername)
    , ("password", .string password)
    , ("volume_size", .number (Float.ofNat (storageGb * 1000000000)))
    , ("volume_type", .string "sbs_5k")
    , ("project_id", .string project)
    , ("tags", .array #[.string (Scaleway.encodeTag (markerKey, markerValue))]) ]

-- The actual request builder must select supported block storage and retain
-- the declared size; default local storage would silently use the node's size.
#guard
  let payload := createPayload "project" "typednotes-compute-db" "db-dev-s"
    "typednotes_compute" "unused-test-password" "16" "typednotes" 10
  payload.lookupText "volume_type" == some "sbs_5k" &&
    payload.lookupNat "volume_size" == some 10000000000

def create (creds : Credentials)
    (name nodeType masterUsername password engineVersion markerValue : String)
    (storageGb : Nat) : IO String := do
  let project ← creds.requireProject
  let reply ← Scaleway.call creds "POST" (prefix' creds.region ++ "/instances")
    (payload := some (createPayload project name nodeType masterUsername password
      engineVersion markerValue storageGb))
  let id ← match reply.lookupText "id" with
    | some id => pure id
    | none => throw (IO.userError "scaleway rdb: create reply has no instance id")
  let started ← IO.monoMsNow
  repeat
    let current ← Scaleway.call creds "GET" (prefix' creds.region ++ s!"/instances/{id}")
    match current.lookupText "status" with
    | some "ready" =>
      match endpointAddress? current with
      | some address => return address
      | none => throw (IO.userError "scaleway rdb: ready instance has no unambiguous public host/port endpoint")
    | some "error" => throw (IO.userError s!"scaleway rdb: instance '{name}' entered error during creation")
    | _ => pure ()
    if (← IO.monoMsNow) - started >= 900000 then
      throw (IO.userError s!"scaleway rdb: instance '{name}' did not become ready within 15 minutes")
    IO.sleep 2000

def modify (creds : Credentials) (name nodeType : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/instances/{id}")
    (payload := some (.object [("node_type", .string nodeType)]))

/-- Whether a Managed Database instance by this name exists — how `release`
    tells this product (tag rung) from Serverless SQL (name rung) behind one
    `Handle`, the same try-this-one-first `ownershipInfo` does. -/
def hasInstance (creds : Credentials) (name : String) : IO Bool := do
  return ((← listRaw creds).find? (·.1 == name)).isSome

/-- Take this fleet's ownership marker off the instance, leaving every other
    tag byte-for-byte.

    `PATCH /instances/{id}` — the endpoint `modify` already uses — with the
    full new `tags` list: `UpdateInstanceRequest` carries `Tags *[]string`
    (Scaleway SDK, `api/rdb/v1`), and a list replaces the old one. Nothing
    else is sent, so node type, volume and settings are untouched. -/
def releaseMarker (creds : Credentials) (name fleet : String) : IO Unit := do
  match (← listRaw creds).find? (·.1 == name) with
  | none                  => pure ()
  | some (_, id, _, tags) =>
    match Scaleway.dropTag (markerKey, fleet) tags with
    | none      => pure ()
    | some rest =>
      discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/instances/{id}")
        (payload := some (.object [("tags", .array (rest.map Value.string).toArray)]))

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

   So `Live.lean` fetches the master password *inside* the classic branch,
   and this backend is handed `""`. Until 0.12.1 the fetch happened before the
   branch on `instanceClass`, which made `masterPasswordSecret` name a secret
   that had to really exist for a product that discards it —
   `fetchMasterPassword` rejects a missing name and `""` alike, so there was
   no way to say "there isn't one". It failed at create, after the IAM
   identity this product's access depends on had already been made.

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

   ## Permanent exception: this product cannot be tagged, so the name is the
   marker

   Re-checked 2026-09-19 against Scaleway's own SDK
   (`scaleway-sdk-go/api/serverless_sqldb/v1alpha1`), which is generated from
   the API definition: `CreateDatabaseRequest` is `project_id`, `name`,
   `cpu_min`, `cpu_max`, `from_backup_id` and nothing else, `UpdateDatabaseRequest`
   is the two capacity fields, and `Database` carries no `tags` and no
   `description`. There is genuinely nothing writable on one of these but the
   name it was created with.

   So this kind sits on the **third rung** of `Ownership`'s ladder —
   `Evidence.named`, decided by `Boundary.namePrefix` — rather than being
   unverifiable outright, which is what it used to be. A fleet that sets a
   prefix and names its databases with it manages them like anything else; a
   fleet that does not is exactly where it was, and `push` now says which of
   the two it is instead of only "cannot verify".

   Unlike most kinds here, `created_at` **is** reported, so `Boundary.since`
   works on this rung too. -/
namespace ServerlessSql

private def prefix' (region : String) : String :=
  Scaleway.regionalPrefix "serverless-sqldb" "v1alpha1" region

/-- Scaleway's `endpoint` field, for this product, is a full connection URI
    (`postgres://user@host:port/db?sslmode=require`), not the bare `host:port`
    every other backend's `.endpoint` carries and `Compose.endpointOf` assumes.
    Strip the scheme, any userinfo, and everything from the path or query
    onward, leaving just `host:port` — or the input unchanged if it does not
    look like a URI, so a future API shape that already returns `host:port`
    is not mangled. -/
private def hostPortOfEndpoint (s : String) : String :=
  let afterScheme := match s.splitOn "://" with
    | [_, rest] => rest
    | _ => s
  let afterUserinfo := match afterScheme.splitOn "@" with
    | [] => afterScheme
    | parts => parts.getLast!
  (afterUserinfo.splitOn "/").head!.splitOn "?" |>.head!

/-- Databases in the project, as `(name, id, endpoint)`.

    Scoped to the project explicitly: unlike `rdb`, the list is not implicitly
    narrowed, and a fleet must not manage another project's databases. -/
private def listRaw (creds : Credentials) : IO (List (String × String × String)) := do
  let project ← creds.requireProject
  let databases ← Scaleway.listAll creds "scaleway serverless sql databases"
    (prefix' creds.region ++ "/databases") "databases" (query := [("project_id", project)])
  return databases.filterMap fun d =>
    match d.lookupText "name", d.lookupText "id" with
    | some n, some id =>
        some (n, id, hostPortOfEndpoint ((d.lookupText "endpoint").getD ""))
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
  return hostPortOfEndpoint ((reply.lookupText "endpoint").getD "")

/-- Change the capacity range. -/
def modify (creds : Credentials) (name : String) (minCapacity maxCapacity : Nat) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "PATCH" (prefix' creds.region ++ s!"/databases/{id}")
    (payload := some (.object
      [ ("cpu_min", .number (Float.ofNat minCapacity))
      , ("cpu_max", .number (Float.ofNat maxCapacity)) ]))

/-- Ownership, on the name rung. See the note above this namespace.

    `listRaw` does not carry `created_at`, so this reads the database object
    itself: the cutoff is worth a call here precisely because the name rung is
    the weakest evidence in the system, and `since` is the one thing that can
    strengthen it. -/
def readOwnership (creds : Credentials) (name : String) : IO Evidence := do
  match ← (requireId creds name).toBaseIO with
  | .error _ => return .unreadable
  | .ok id   =>
    match ← (Scaleway.call creds "GET" (prefix' creds.region ++ s!"/databases/{id}")).toBaseIO with
    | .error _ => return .unreadable
    | .ok d    => return .named name (d.lookupText "created_at")

/-- Delete the database. -/
def delete (creds : Credentials) (name : String) : IO Unit := do
  let id ← requireId creds name
  discard <| Scaleway.call creds "DELETE" (prefix' creds.region ++ s!"/databases/{id}")

end ServerlessSql

end Infra.Providers.Kinds.Postgres
