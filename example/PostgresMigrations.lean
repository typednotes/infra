import Infra

/-!
  # Example: a declared migration history

  The services deployed as Scaleway Serverless Containers each own a schema
  in a Serverless SQL Database, and that schema has to migrate somehow. The
  startup-migration answer works — but nobody reviews the SQL before it
  runs, the running container holds structure-editing rights forever for an
  operation it performs once per release, and a cold start has to win an
  advisory lock before it may serve.

  `postgresMigrations` is the declared answer. The migration list is a
  *value in the fleet*, so the diff of the declaration is the review; the
  plan names the resource, the apply runs the pending suffix, and a failed
  migration stops the rollout because the rollout is ordered after it.

  The whole fleet is eight resources and one apply:

      iam migrator-app ──┐  (ServerlessSQLDatabaseReadWrite: DDL)
      iam observer-app ──┤  (ServerlessSQLDatabaseReadOnly: SELECT only)
                          ├──▶ secrets migrator-key ──▶ secrets migrator-url
      postgres svc-db ────┤    (read-write, for apply)
                          ├──▶ secrets observer-key ──▶ secrets observer-url
                          └────                      (read-only, for refresh/plan)

  Two identities, because the two paths are different: **apply** reads the
  read-write URL (where `fetchMasterPassword` already reads one), while
  **observation** — `refresh`, `plan`, every pull — reads the read-only one.
  That is the one widening of "the planning path holds no secret value" the
  kind costs, and the credential it can reach can `SELECT` on one table and
  nothing else (`docs/diff-semantics.md`'s ledger records it).

  ## FORGET, not DELETE

  Deleting the `postgresMigrations` line releases the history from
  management and destroys nothing: the schema's lifetime is the database's.
  The plan prints `FORGET` for it, and the ledger row goes. What actually
  drops the tables is deleting the `postgres` line — the teardown deletes
  in reverse dependency order, so the database goes last.

  ## Run

      lake exe postgres-migrations            -- offline: the plan, from placeholders
      lake exe postgres-migrations plan       -- reads the account (and the database)
      lake exe postgres-migrations apply      -- migrates for real, then deploys

  `apply` creates a billable database. `destroy` removes everything; the
  secrets are deleted before the identities, and deleting a secret deletes
  the API key it minted. The schema goes with the database, which is the
  point of FORGET.
-/
open Infra.Core
open Infra.Specs

/-- The migrator's permission set: data *and table structure*, which is
    what applying a migration needs. Not `DataReadWrite`, whose name
    suggests it: that one cannot `CREATE` in a schema, which is the exact
    trap `typednotes-infra`'s README documents. Verified against Scaleway's
    "Manage user permissions for Serverless SQL Databases" page (reviewed
    2025-09-17): this set is SELECT/UPDATE/INSERT/DELETE plus
    CREATE/ALTER/DROP TABLE and INDEX. -/
def migratorPlane : String := "ServerlessSQLDatabaseReadWrite"

/-- The observer's permission set: `SELECT`, and — the same page — *only*
    `SELECT`. This is what scopes the observation path's secret read: the
    URL the plan path can fetch opens a connection that can read the
    history table and change nothing. -/
def observerPlane : String := "ServerlessSQLDatabaseReadOnly"

fleet migrationsStack in paris where
  resource scaleway iam "tn-svc-migrator"
    { policies := [migratorPlane] }
  resource scaleway iam "tn-svc-observer"
    { policies := [observerPlane] }

  -- Serverless SQL is IAM-only: no master user, so the two fields the
  -- portable spec requires say exactly that. See
  -- `example/ServerlessSqlIam.lean` for the full story.
  resource scaleway postgres "tn-svc-db" as svcDb
    { masterUsername := "unused-serverless-sql-is-iam-only",
      masterPasswordSecret := "",
      minCapacity := 0,
      maxCapacity := 4 }

  resource scaleway secrets "tn-svc-migrator-key" as migratorKey
    { valueFrom := apiKeyFor "tn-svc-migrator" }
  resource scaleway secrets "tn-svc-observer-key" as observerKey
    { valueFrom := apiKeyFor "tn-svc-observer" }

  -- `?sslmode=require` is mandatory and `endpointOf` does not supply it;
  -- the user is the application *id* (`principalOf`), not the access key.
  -- Both mistakes fail late and point at the password.
  resource scaleway secrets "tn-svc-migrator-url"
    { valueFrom := composed
        expr!"postgres://{principalOf migratorKey}:{secretValueOf migratorKey}\
@{endpointOf svcDb}/tn-svc-db?sslmode=require" }
  resource scaleway secrets "tn-svc-observer-url"
    { valueFrom := composed
        expr!"postgres://{principalOf observerKey}:{secretValueOf observerKey}\
@{endpointOf svcDb}/tn-svc-db?sslmode=require" }

  -- The declared history. `id` is the application order, matching
  -- `ledger`'s `sql/0001_…` convention; the SQL is carried verbatim
  -- because the declaration is the review surface.
  resource scaleway postgresMigrations "tn-svc-history" as svcHistory
    { database := "tn-svc-db",
      connectionSecret := "tn-svc-migrator-url",
      observerSecret := "tn-svc-observer-url",
      schema := "svc",
      migrations := ([{
        id := "0001",
        sql := "CREATE TABLE IF NOT EXISTS svc.events \
(id text PRIMARY KEY, at timestamptz NOT NULL DEFAULT now())" }] : List Migration) }

  -- The rollout waits for the history: a container update whose migrations
  -- have not applied is new code against an old schema, which is exactly
  -- the state the ordering edge exists to make unrepresentable as a
  -- *plan*. The reference is the whole job of the field — nothing cloud
  -- side reports it, so it never drifts.
  resource scaleway scalewayContainerNamespace "tn-svc-ns" as svcNs
    { description := "example namespace for the migrations fleet" }
  resource scaleway scalewayContainer "tn-svc-api" as svcApi
    { namespace' := svcNs,
      image := "rg.fr-par.scw.cloud/tn-svc-ns/tn-svc-api:latest",
      migrations := some svcHistory,
      port := 8080 }

def migrationsBoundary : Boundary :=
  { fleetName := some "tn-svc", namePrefix := some "tn-svc-" }

/- Nothing here holds a value: the two URL secrets hold recipes, and the two
   key secrets are minted at apply. -/
#guard migrationsStack.plan.secretsAreSound

/- The history itself is sound: ids in order, no empty SQL, a quotable
   schema. This is the `migrationsAreSound` companion of the guard above,
   and a fleet that wrote `0002` before `0001` fails here rather than
   applying in an order nobody wrote down. -/
#guard migrationsStack.plan.migrationsAreSound

/- Eight resources, one apply. The two `iam` applications exist because
   Serverless SQL is IAM-only; the two key secrets mint their keys; the two
   URL secrets compose them with the database's endpoint. -/
#guard migrationsStack.keys.count .scaleway .iam = 2
#guard migrationsStack.keys.count .scaleway .secrets = 4
#guard migrationsStack.keys.count .scaleway .postgres = 1
#guard migrationsStack.keys.count .scaleway .postgresMigrations = 1
#guard migrationsStack.keys.count .scaleway .scalewayContainerNamespace = 1
#guard migrationsStack.keys.count .scaleway .scalewayContainer = 1

/- The ordering the whole example exists to prove, pinned offline. The
   history waits for its database and both URL secrets; the container waits
   for its namespace and — the edge this release added — its history. A
   plan's work-list is a topological sort, so this is the guarantee a
   startup migration cannot give: the migration *cannot* be scheduled
   after the rollout, because nothing in the declaration says it may.

   `runsBefore` mirrors `Infra/Demo.lean`'s: the *scheduled* order, not the
   declaration order, and a missing slot answers false so a rename fails
   the guard instead of quietly satisfying it. -/
private def migrationsOrder : List String :=
  match orderActions migrationsStack.plan
        (actions migrationsStack.plan (worldOf [])) with
  | .ok ordered => ordered.map Action.slot
  | .error _    => []

private def runsBefore (a b : String) : Bool :=
  match migrationsOrder.idxOf? a, migrationsOrder.idxOf? b with
  | some i, some j => i < j
  | _,      _      => false

#guard runsBefore "scaleway/postgres/tn-svc-db" "scaleway/postgres-migrations/tn-svc-history"
#guard runsBefore "scaleway/secrets/tn-svc-observer-url" "scaleway/postgres-migrations/tn-svc-history"
#guard runsBefore "scaleway/postgres-migrations/tn-svc-history" "scaleway/scaleway-container/tn-svc-api"

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "postgres-migrations" migrationsStack
    (accounts := ← Infra.Cli.Accounts.fromEnv) (boundary := migrationsBoundary) (args := args)
