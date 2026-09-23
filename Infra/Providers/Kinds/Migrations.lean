import Infra.Providers.Kinds.Secrets
import Infra.Core.Backend
import Infra.Core.Diverge
import Infra.Core.Stage
import Linen.Database.SQL.Connection
import Linen.Database.SQL.Session
import Linen.Database.PostgreSQL.LibPQ

/-
  The `postgresMigrations` backend: not a cloud control plane but the
  Postgres wire protocol, through `linen`'s `Database.SQL`.

  ## What this module may read, and where the values go

  Two secrets, two paths, deliberately different:

  * **Apply** (`create`/`update`) reads the *read-write* URL
    (`connectionSecret`) — the one place this kind holds a credential that
    can change anything, and it sits on the apply path, exactly where
    `Kinds.Postgres.fetchMasterPassword` already reads one. Nothing it
    returns is stored, cached, or printed.

  * **Observation** (`list`/`read`, i.e. `refresh`/`plan` pulls) reads the
    *read-only* URL (`observerSecret`). This is the one widening of the
    "planning path holds no secret value" rule this kind costs — recorded
    in `docs/diff-semantics.md`'s ledger — and it is scoped by design: the
    credential the observation path can reach can `SELECT` on one table and
    nothing else. See `docs/migrations.md`, hard edge 2, for why the
    alternative (minting an ephemeral key at refresh) was rejected: it
    would have made refresh *mutating*.

  Both reads go through `Kinds.Secrets.fetchValue`, the same narrowly-scoped
  reader the rest of the library uses, and neither value outlives the
  connection it opened.

  ## What "delete" means here: nothing, on purpose

  The rows this kind manages live in the parent database, and their
  lifetime is the database's, not the declaration's. `delete` is a no-op
  FORGET — the plan prints `FORGET` (`Engine.Action.verb`), the ledger row
  goes, the schema stays. Deleting the `postgres` resource is what drops
  the tables, which is the correct teardown.

  ## Ordering and locking

  `apply` takes a session-level `pg_advisory_lock` keyed by the resource
  name before it reads the history: `apply`'s concurrency group is the real
  serialisation, but nothing stops a local apply racing CI, and the lock is
  one line of defence in depth. The lock is session-level, so the
  connection's release — which `Connection.withConnection` guarantees on
  every path — is what frees it, even when an apply dies mid-migration.

  ## Provider facts, flagged rather than recalled

  * A Serverless SQL Database sleeps when idle; every connection here goes
    through a bounded wake-up retry (~30s) rather than failing the first
    attempt. A database that will not wake is an error, not an empty
    history — an empty `applied` read as "nothing applied" would propose
    re-running every migration.
  * `role_read` is granted `SELECT` on the history table *if that role
    exists*, best effort. Scaleway documents `GRANT` as a command that
    cannot be performed on Serverless SQL — access comes from IAM
    permission sets, which apply to every table — so there the grant is
    expected to be unnecessary and may be refused; a refusal is a `NOTICE`,
    not a failed apply (`grantSql`). Clouds where the role does not exist
    (RDS, Cloud SQL) skip it. See `docs/migrations.md`'s "provider facts".
  * `CREATE SCHEMA` under `ServerlessSQLDatabaseReadWrite` works, although
    Scaleway's permission page lists only `CREATE/ALTER/DROP TABLE` and
    `INDEX` for that set — verified by `typednotes-infra`'s first apply,
    2026-09-23, as is the read identity seeing the history tables.
  * Serverless SQL routes connections by TLS SNI; libpq, which this module
    connects through, sends it.
-/

namespace Infra.Providers.Kinds.Migrations

open Infra.Core
open Infra.Providers.Kinds
open Infra.Specs (Migration MigrationDecl declsOf resolvedMigrations?)
open Database.SQL.Connection
open Database.SQL.Session
open Database.PostgreSQL.LibPQ

/-- How one declared migration set reaches its database: the fleet names of
    the resource, its parent database and its two URL secrets, plus the
    Postgres schema it owns.

    Derived from the declaration by `Infra.Cli.run` — a migrations resource
    cannot be observed from the resource's own handle, which carries only a
    name, and there is no cloud-side place to store the rest. A backend
    built without routes (a direct `liveFromEnvironment` consumer, say)
    answers this kind's `read` with a refusal naming this fact rather than
    a fabricated sighting. -/
structure MigrationRoute where
  /-- The fleet name of the `postgresMigrations` resource. -/
  resource          : String
  /-- The fleet name of the parent `postgres` resource. Ordering edge, and
      the parent whose ownership verdict this kind inherits. -/
  database          : String
  /-- The fleet name of the secret holding the read-write connection URL.
      Read on the apply path only. -/
  connectionSecret  : String
  /-- The fleet name of the secret holding the read-only connection URL.
      Read on the observation path. -/
  observerSecret    : String
  /-- The Postgres schema this service owns. -/
  schema            : String
  deriving Repr

-- ────────────────────────────────────────────────────────────────────
-- Connection
-- ────────────────────────────────────────────────────────────────────

private def settingsOf (resource url : String) : IO Settings := do
  if h : url.length > 0 then
    return Settings.uri url h
  else
    throw (IO.userError s!"{resource}: the connection URL is empty — a composed \
secret settled to nothing, which means one of its ingredients is missing")

/-- One connection's worth of work, with bounded retries for a serverless
    database that is still waking.

    `act` runs on a fresh connection per attempt, so nothing in it may
    carry state across attempts — which is fine, because the only thing
    that does carry is the advisory lock, and that is per-connection by
    design. -/
private def withDb {α : Type} (resource url : String) (act : Connection → IO α) : IO α := do
  let settings ← settingsOf resource url
  let mut last := "no attempt was made"
  for attempt in [0:15] do
    unless attempt == 0 do IO.sleep 2000
    match ← withConnection settings act with
    | .ok a    => return a
    | .error e => last := toString e
  throw (IO.userError s!"{resource}: could not connect to the database within ~30s — \
a serverless database may still be waking, or the connection URL may be wrong. \
Last error: {last}")

-- ────────────────────────────────────────────────────────────────────
-- Identifiers and the history table
-- ────────────────────────────────────────────────────────────────────

/-- Belt and braces: the schema name is already restricted to a simple
    identifier by `PostgresMigrationsSpec.historyIsSound`, so the quotes
    here can never meet a quote. Quoting anyway means a future weakening of
    that check cannot become an injection. -/
private def quoteIdent (s : String) : String := "\"" ++ s.replace "\"" "\"\"" ++ "\""

private def historyTable (schema : String) : String :=
  s!"{quoteIdent schema}.infra_migrations"

/-- The advisory-lock key: one fixed namespace plus the resource name, so
    two services migrating two schemas in one database still serialise
    against *their own* resource only. -/
private def lockSql (resource : String) : String :=
  s!"SELECT pg_advisory_lock(hashtext('infra/postgres-migrations/{resource}'))"

private def unlockSql (resource : String) : String :=
  s!"SELECT pg_advisory_unlock(hashtext('infra/postgres-migrations/{resource}'))"

private def ensureSchemaSql (schema : String) : String :=
  s!"CREATE SCHEMA IF NOT EXISTS {quoteIdent schema}"

private def ensureTableSql (schema : String) : String :=
  s!"CREATE TABLE IF NOT EXISTS {historyTable schema} \
(id text PRIMARY KEY, sql text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())"

/-- `SELECT` for the observer role, but only where such a role exists, and
    only where the cloud allows it — see the module note. A plain `GRANT`
    would fail outright on RDS and Cloud SQL, where `role_read` is nobody.

    **Best effort, and a refusal is not an error.** Scaleway's "Known
    differences between Serverless SQL Databases and PostgreSQL" page
    (checked 2026-09-23) lists `GRANT SELECT ON TABLE … TO role` among the
    commands that *cannot be performed*: access is managed only through IAM
    permission sets, which apply to every table. So on the one cloud this
    grant was written for, it may be both unnecessary and refused — and a
    refused `GRANT` used to abort the whole apply session, before any
    migration ran. The inner block turns that into a `NOTICE`; the
    observation path's own read (`appliedOf`) still fails loudly if the
    observer really cannot see the table, which is the check that matters. -/
private def grantSql (schema : String) : String :=
  s!"DO $grant$ BEGIN \
IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_read') THEN \
BEGIN \
EXECUTE 'GRANT SELECT ON {historyTable schema} TO role_read'; \
EXCEPTION WHEN OTHERS THEN \
RAISE NOTICE 'infra: GRANT on %.infra_migrations refused (%); access is expected to come from the cloud''s IAM instead', '{schema}', SQLERRM; \
END; \
END IF; END $grant$"

-- ────────────────────────────────────────────────────────────────────
-- Reading what the database has applied
-- ────────────────────────────────────────────────────────────────────

private def readApplied (schema : String) : Session (List (String × String)) := do
  let result ← Session.query
    s!"SELECT id, sql FROM {historyTable schema} ORDER BY id" #[]
  let n ← ntuples result
  let mut rows : List (String × String) := []
  for i in [0:n.toNat] do
    let idx := UInt32.ofNat i
    rows := (← getvalue result idx 0, ← getvalue result idx 1) :: rows
  return rows.reverse

/-- The applied history, or `none` when this schema has no history table
    yet — the resource's own reading of "does not exist".

    "does not exist" is matched on the rendered message because that is
    what the session layer hands back (`Http.sendChecked` flattened its
    structure first, and `SessionError` never carried one); narrow on
    purpose, since the only relation in play is a table this module named
    itself. Anything else — permissions, a dropped schema mid-pull — is an
    error, not an empty history, for the reason the module note gives. -/
private def appliedOf (conn : Connection) (resource schema : String) :
    IO (Option (List (String × String))) := do
  match ← Session.run (readApplied schema) conn with
  | .ok rows    => return some rows
  | .error e    =>
    let msg := toString e
    if (msg.splitOn "does not exist").length > 1 then
      return none
    else
      throw (IO.userError s!"{resource}: could not read {historyTable schema}: {msg}")

-- ────────────────────────────────────────────────────────────────────
-- Reading the URL secrets
-- ────────────────────────────────────────────────────────────────────

/-- Fetch a URL secret, reading "not there yet" as absence and everything
    else as failure.

    The absent case is a first apply: the parent database or the URL secret
    has not been created, so the resource cannot exist either. The not-found
    spellings are the curated list `readsAsAbsent` already keeps, plus
    Scaleway's own "no secret named …", which that list predates. A
    *credential* error reaching this function is rethrown: reading it as
    absence would let a fleet with broken credentials propose re-applying
    every migration. -/
private def urlOf (provider : ProviderId) (creds : Credentials) (secret what resource : String) :
    IO (Option String) := do
  match ← (Secrets.fetchValue provider creds secret).toBaseIO with
  | .ok v        => return some v
  | .error e     =>
    let msg := toString e
    if readsAsAbsent msg || (msg.splitOn "no secret named").length > 1 then
      return none
    else
      throw (IO.userError s!"{resource}: could not read the {what} URL secret '{secret}': {msg}")

-- ────────────────────────────────────────────────────────────────────
-- Observation: `list` and `read`
-- ────────────────────────────────────────────────────────────────────

/-- One route's observed state, or `none` when the resource is absent —
    the secret is not there yet, or the schema has no history table. -/
private def observeRoute (provider : ProviderId) (creds : Credentials)
    (route : MigrationRoute) : IO (Option PostgresMigrationsObserved) := do
  let some url ← urlOf provider creds route.observerSecret "observer" route.resource
    | return none
  withDb route.resource url fun conn => do
    let some applied ← appliedOf conn route.resource route.schema
      | return none
    return some { handle := ⟨route.resource⟩, applied }

/-- Every declared route that answers. `list` for this kind is
    route-driven rather than account-driven — "everything the credentials
    can see" is not enumerable without connecting to every database in the
    account — so it can only ever report what the *declaration* names, and
    `discover` cannot rebuild these ledger rows. That is safe because
    `delete` is a no-op FORGET: the two properties are one design decision,
    recorded together in `docs/coverage.md`. -/
def list (provider : ProviderId) (creds : Credentials) (routes : List MigrationRoute) :
    IO (List PostgresMigrationsObserved) := do
  let mut out : List PostgresMigrationsObserved := []
  for route in routes do
    if let some o ← observeRoute provider creds route then
      out := o :: out
  return out.reverse

/-- The configuration actually in force: the applied history, verbatim,
    with the route's own names for the fields the database cannot know.

    Reached only for a resource the declaration names and the database
    answers, so a route is always available through `Infra.Cli.run`; the
    refusal below is what a backend built without routes says instead of
    fabricating a sighting. -/
def read (provider : ProviderId) (creds : Credentials) (routes : List MigrationRoute)
    (h : Handle .postgresMigrations) : IO (Reported .postgresMigrations) := do
  let some route := routes.find? fun r => r.resource == h.raw
    | throw (IO.userError s!"{h.raw}: no migration route — this backend was built without \
the declaration's routes, so nothing can observe this kind here. `Infra.Cli.run` derives \
them; see docs/migrations.md")
  let some url ← urlOf provider creds route.observerSecret "observer" route.resource
    | throw (IO.userError s!"{h.raw}: the observer URL secret \
'{route.observerSecret}' did not answer; cannot report what is applied")
  withDb route.resource url fun conn => do
    let applied ← appliedOf conn route.resource route.schema
    let migrations : List Migration := (applied.getD []).map fun (id, sql) =>
      ({ id, sql } : Migration)
    return { name := route.resource
             database := route.database
             connectionSecret := route.connectionSecret
             observerSecret := route.observerSecret
             schema := route.schema
             migrations := declsOf migrations }

-- ────────────────────────────────────────────────────────────────────
-- Apply: the one body behind `create` and `update`
-- ────────────────────────────────────────────────────────────────────

/-- One apply, as a session: lock, ensure the history table, re-verify the
    append-only contract against what is really there, then apply the
    pending suffix one migration per transaction. See `apply` for the
    contract commentary. -/
private def applySession (spec : ProviderSpec .postgresMigrations) :
    Session PostgresMigrationsObserved := do
  -- Session-level: the connection's release is what frees it, on every
  -- path — `withDb` guarantees that — so the explicit unlock below is
  -- politeness, not the guarantee.
  Session.sql (lockSql spec.name)
  Session.sql (ensureSchemaSql spec.schema)
  Session.sql (ensureTableSql spec.schema)
  Session.sql (grantSql spec.schema)
  let applied ← readApplied spec.schema
  -- The contract, checked against the database rather than the cache: what
  -- is applied must be a prefix of what is declared, content and all.
  -- `none` from `migrationsConflict` covers equal and strict-prefix both,
  -- and the suffix is the work.
  let appliedM : List Migration := applied.map fun (id, sql) => ({ id, sql } : Migration)
  -- Only fetched SQL reaches a backend (`Engine.push` refuses the rest);
  -- checked again here because this is the step that runs it.
  let some declared := resolvedMigrations? spec.migrations
    | throw (SessionError.resultError "migration sources have not been fetched; refusing to \
apply SQL whose content is unknown")
  match Infra.Core.migrationsConflict appliedM declared with
  | some id =>
      throw (SessionError.resultError s!"applied migration '{id}' does not match the declaration's \
history — migrations are append-only, and this check is the backend's own third line of \
defence after the plan-time one; see docs/migrations.md")
  | none =>
      let pending := declared.drop appliedM.length
      for m in pending do
        Session.transaction do
          Session.sql m.sql
          let _ ← Session.query
            s!"INSERT INTO {historyTable spec.schema} (id, sql) VALUES ($1, $2)"
            #[some m.id, some m.sql]
      Session.sql (unlockSql spec.name)
      let finalApplied := applied ++ pending.map fun m => (m.id, m.sql)
      return { handle := ⟨spec.name⟩, applied := finalApplied }

/-- Bring one schema up to its declared history.

    `create` and `update` are the same operation because the resource is
    its history: "create" is the first update, and the table's existence —
    not a cloud-side object — is what makes it observable. The append-only
    check in `applySession` is the backend's own, the third tier after
    `Plan.migrationsAppendOnly` (refused at plan time) and the `Divergent`
    table (conflict can never read as quietly fixable) — cheap at every
    tier, fatal at none.

    A migration's `sql` runs through libpq's simple query path, so a
    migration file may hold several statements (it is `ledger`'s
    whole-file convention, not this module's, that a migration contains no
    explicit `BEGIN`/`COMMIT` of its own — the transaction here is the
    wrapper that makes one migration atomic). -/
def apply (provider : ProviderId) (creds : Credentials)
    (spec : ProviderSpec .postgresMigrations) : IO PostgresMigrationsObserved := do
  let some url ← urlOf provider creds spec.connectionSecret "read-write" spec.name
    | throw (IO.userError s!"{spec.name}: the read-write URL secret \
'{spec.connectionSecret}' did not answer; cannot apply migrations")
  withDb spec.name url fun conn => do
    match ← Session.run (applySession spec) conn with
    | .ok observed => return observed
    | .error e     => throw (IO.userError s!"{spec.name}: {e}")

end Infra.Providers.Kinds.Migrations
