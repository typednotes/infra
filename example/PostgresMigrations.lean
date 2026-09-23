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

  The whole fleet is eleven resources and one apply (two of them histories,
  one ordered after the other because its SQL references the other's table
  — see "One history after another" below):

      iam migrator-app ──┐  (ServerlessSQLDatabaseReadWrite: DDL)
      iam observer-app ──┤  (ServerlessSQLDatabaseReadOnly: SELECT only)
                          ├──▶ secrets migrator-key ──▶ secrets migrator-url
      postgres svc-db ────┤    (read-write, for apply)
                          ├──▶ secrets observer-key ──▶ secrets observer-url
                          └────                      (read-only, for plan/dump)

  Two identities, because the two paths are different: **apply** reads the
  read-write URL (where `fetchMasterPassword` already reads one), while
  **observation** — `plan`, `dump`, every pull — reads the read-only one.
  That is the one widening of "the planning path holds no secret value" the
  kind costs, and the credential it can reach can `SELECT` on one table and
  nothing else (`docs/diff-semantics.md`'s ledger records it).

  ## FORGET, not DELETE

  Deleting the `postgresMigrations` line releases the history from
  management and destroys nothing: the schema's lifetime is the database's.
  The plan prints `FORGET` for it, and nothing is called. What actually
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

  -- A second service's history on the same database, whose schema points
  -- into the first's: `REFERENCES svc.events(id)` fails against a database
  -- where `svc.events` does not exist yet. Both histories are ready in the
  -- same scheduling wave — same database, same secrets — so the order has
  -- to come from somewhere: it comes from that `REFERENCES` itself
  -- (`Infra.Core.SqlDeps`). Nothing is declared twice.
  --
  -- **Declared first on purpose**: declaration order is the wrong order
  -- here, so the `runsBefore` guard below can only pass because of the
  -- inferred edge.
  resource scaleway postgresMigrations "tn-svc-audit-history" as auditHistory
    { database := "tn-svc-db",
      connectionSecret := "tn-svc-migrator-url",
      observerSecret := "tn-svc-observer-url",
      schema := "audit",
      migrations := inlineMigrations [("0001",
        "CREATE TABLE IF NOT EXISTS audit.seen \
(event text NOT NULL REFERENCES svc.events(id))")] }

  -- The declared history. `id` is the application order, matching the
  -- `sql/0001_…` convention. Inline SQL here, so everything in this file is
  -- checkable offline; a real service keeps its SQL in its own repository
  -- and declares `github "owner/repo" "vX.Y.Z" ["sql/0001_init.sql"]`
  -- instead (see `remoteSources` below).
  resource scaleway postgresMigrations "tn-svc-history" as svcHistory
    { database := "tn-svc-db",
      connectionSecret := "tn-svc-migrator-url",
      observerSecret := "tn-svc-observer-url",
      schema := "svc",
      migrations := inlineMigrations [("0001",
        "CREATE TABLE IF NOT EXISTS svc.events \
(id text PRIMARY KEY, at timestamptz NOT NULL DEFAULT now())")] }

  -- The rollout waits for the histories it names: a container update whose
  -- migrations have not applied is new code against an old schema, which is
  -- exactly the state the ordering edge exists to make unrepresentable as a
  -- *plan*. A list, because a service can need another service's schema as
  -- well as its own — this one reads both. The references are the whole job
  -- of the field — nothing cloud side reports them, so they never drift.
  resource scaleway scalewayContainerNamespace "tn-svc-ns" as svcNs
    { description := "example namespace for the migrations fleet" }
  resource scaleway scalewayContainer "tn-svc-api" as svcApi
    { namespace' := svcNs,
      image := "rg.fr-par.scw.cloud/tn-svc-ns/tn-svc-api:latest",
      migrations := [svcHistory, auditHistory],
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

/- Eleven resources, one apply. The two `iam` applications exist because
   Serverless SQL is IAM-only; the two key secrets mint their keys; the two
   URL secrets compose them with the database's endpoint; two services each
   own a history on the one database. -/
#guard migrationsStack.keys.count .scaleway .iam = 2
#guard migrationsStack.keys.count .scaleway .secrets = 4
#guard migrationsStack.keys.count .scaleway .postgres = 1
#guard migrationsStack.keys.count .scaleway .postgresMigrations = 2
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

/- One history after another: `tn-svc-audit-history` is declared *before*
   `tn-svc-history` and is still scheduled after it, because its SQL
   references `svc.events`, which the other creates. Declaration order would
   have run the `REFERENCES` first. And the container waits for both. -/
#guard runsBefore "scaleway/postgres-migrations/tn-svc-history"
  "scaleway/postgres-migrations/tn-svc-audit-history"
#guard runsBefore "scaleway/postgres-migrations/tn-svc-audit-history"
  "scaleway/scaleway-container/tn-svc-api"

/- What the SQL cannot settle is refused, never guessed. A reference to a
   table no history on the database creates — a missing history, a typo, or
   a table created where the scanner cannot see — fails here, at compile
   time, rather than applying in an order nobody chose. -/
fleet unresolvedRef in paris where
  resource scaleway postgresMigrations "tn-orphan-history"
    { database := "tn-orphan-db",
      connectionSecret := "tn-orphan-url",
      observerSecret := "tn-orphan-url",
      schema := "orphan",
      migrations := inlineMigrations [("0001",
        "CREATE TABLE t (org uuid REFERENCES orgs(id))")] }

#guard !unresolvedRef.plan.migrationsAreSound
#guard ((unresolvedRef.plan.migrationDepsProblem.getD "").splitOn "public.orgs").length > 1

/- A table two histories on one database both create: which one a
   `REFERENCES` means would be a guess. -/
fleet twoCreators in paris where
  resource scaleway postgresMigrations "tn-a-history"
    { database := "tn-dup-db", connectionSecret := "tn-dup-url",
      observerSecret := "tn-dup-url", schema := "a",
      migrations := inlineMigrations [("0001", "CREATE TABLE shared (id int PRIMARY KEY)")] }
  resource scaleway postgresMigrations "tn-b-history"
    { database := "tn-dup-db", connectionSecret := "tn-dup-url",
      observerSecret := "tn-dup-url", schema := "b",
      migrations := inlineMigrations [("0001", "CREATE TABLE shared (id int PRIMARY KEY)")] }

#guard !twoCreators.plan.migrationsAreSound

/- The same table name on two *different* databases is two tables: no
   ambiguity, and no edge between the histories. -/
fleet twoDatabases in paris where
  resource scaleway postgresMigrations "tn-x-history"
    { database := "tn-x-db", connectionSecret := "tn-x-url",
      observerSecret := "tn-x-url", schema := "x",
      migrations := inlineMigrations [("0001", "CREATE TABLE shared (id int PRIMARY KEY)")] }
  resource scaleway postgresMigrations "tn-y-history"
    { database := "tn-y-db", connectionSecret := "tn-y-url",
      observerSecret := "tn-y-url", schema := "y",
      migrations := inlineMigrations [("0001", "CREATE TABLE shared (id int PRIMARY KEY)")] }

#guard twoDatabases.plan.migrationsAreSound

/- SQL kept in the service's repository, read at a release tag. The URLs are
   checked offline (`https://`, ids from the file names); the content, and
   the order it implies, are checked once `plan` has fetched it. -/
fleet remoteSources in paris where
  resource scaleway postgresMigrations "tn-remote-history"
    { database := "tn-remote-db", connectionSecret := "tn-remote-url",
      observerSecret := "tn-remote-url", schema := "remote",
      migrations := github "typednotes/ledger" "v0.2.0" ["sql/0001_init.sql"] }

#guard remoteSources.plan.migrationsAreSound
#guard remoteSources.plan.unresolvedMigrationSources = ["scaleway/postgres-migrations/tn-remote-history"]

/- A misnamed file has no id, and a plain `http://` URL is refused. -/
fleet badSources in paris where
  resource scaleway postgresMigrations "tn-badsrc-history"
    { database := "tn-badsrc-db", connectionSecret := "tn-badsrc-url",
      observerSecret := "tn-badsrc-url", schema := "badsrc",
      migrations := github "typednotes/ledger" "v0.2.0" ["sql/init.sql"] }
fleet plainHttp in paris where
  resource scaleway postgresMigrations "tn-http-history"
    { database := "tn-http-db", connectionSecret := "tn-http-url",
      observerSecret := "tn-http-url", schema := "http",
      migrations := ([{ id := "0001", source := .url "http://example.com/0001_x.sql" }] : List MigrationDecl) }

#guard !badSources.plan.migrationsAreSound
#guard !plainHttp.plan.migrationsAreSound

/- Regression: before 0.14.0 the empty-`sql` check sat inside the lambda of
   the pairwise-order check, so a *one*-migration history — no pairs — was
   never checked at all, and this fleet passed. -/
fleet emptySql in paris where
  resource scaleway postgresMigrations "tn-empty-history"
    { database := "tn-empty-db",
      connectionSecret := "tn-empty-url",
      observerSecret := "tn-empty-url",
      schema := "empty",
      migrations := inlineMigrations [("0001", "")] }

#guard !emptySql.plan.migrationsAreSound

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "postgres-migrations" migrationsStack
    (accounts := ← Infra.Cli.Accounts.fromEnv) (boundary := migrationsBoundary) (args := args)
