# Postgres migrations as a declared resource

**Status: implemented, in 0.13.0.** This page began as the proposal the
implementation was judged against — doc first, code after, in the spirit of
`AGENTS.md` — and it remains the design doc. Where the implementation
deviated from the proposal, the section at the end records why; the body
describes what now *is*, not what was argued for. `docs/coverage.md` carries
the kind's rows and its exercise level.

## Problem

The services deployed as Scaleway Serverless Containers — `typednotes`,
`liaison`, `ledger`, … — each own a schema in a Serverless SQL Database, and
that schema has to be migrated somehow. Today each service answers alone:
`typednotes` migrates on server startup (its CLAUDE.md names the server "the
sole migration runner in production"), `ledger` has a `migrate` subcommand
(`lake exe ledger migrate`) that nothing in the deploy path calls.

Startup migration works, and remains the fallback. Its costs, concretely:

- **Nobody reviews the SQL that runs against production.** The first any human
  hears of migration `0013` is the server having already applied it on a cold
  start. `apply.yml`'s typed-confirmation gate covers every cloud resource and
  none of the schema.
- **The runtime identity needs structure-editing rights.** Scaleway's
  `ServerlessSQLDatabaseDataReadWrite` cannot `CREATE` in schema `public`
  (see `typednotes-infra`'s README for the full permission-set trap), so every
  serving container holds `ServerlessSQLDatabaseReadWrite` forever, for an
  operation it performs once per release.
- **Concurrent cold starts race.** Scaleway starts N instances at once; the
  migration runner needs a `pg_advisory_lock` it currently doesn't have.

The proposal: make the migration set a **declared resource** in the fleet, so
`plan` shows the pending SQL and `apply` runs it — ordered before the
container update by the same reference machinery that already orders a
namespace before its container.

## The kind

One new `Kind` constructor, `.postgresMigrations`. Because `SpecOf`,
`ObservedOf`, `Fillable` and every backend match are total over `Kind`, adding
the constructor fails the build everywhere until it is handled — the mechanism
`Infra/Core/Kind.lean`'s module note exists for, and the reason a half-wired
kind cannot quietly ship.

The spec is provider-independent in the same sense `PostgresSpec` is: nothing
in "an ordered list of SQL migrations, applied to a database" names a cloud.
What differs from every existing kind is the *backend*: not a cloud control
plane but the Postgres wire protocol, through `linen`'s `Database.SQL`. One
implementation serves every `(provider, .postgresMigrations)` pair; what the
provider axis still contributes is where the endpoint and credentials come
from (the referenced `postgres` resource's observed state and the fleet's
secrets).

```lean
structure Migration where
  id  : String    -- "0001", lexicographic application order
  sql : String    -- carried verbatim; see "Observed state"
  deriving Repr, DecidableEq, BEq, ToJson, FromJson

structure PostgresMigrationsSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name             : Field .required o f String
  /-- The fleet name of the parent `postgres` resource — a *name*, not a
      typed reference, for the portability reason below. -/
  database         : Field .required o f String
  /-- The fleet name of the secret holding the read-write connection URL.
      Read on the apply path only. -/
  connectionSecret : Field .required o f String
  /-- The fleet name of the secret holding the read-only connection URL.
      Read on the observation path. See hard edge 2. -/
  observerSecret   : Field .required o f String
  /-- The Postgres schema this service owns. One resource per service, one
      schema per service: two services never share a migration resource. -/
  schema           : Field .required o f String
  migrations       : Field .required o f (List Migration)
```

The cross-resource fields are plain names rather than typed references on
purpose: a reference has type `K p k` and so names a provider, and this kind
is portable — one Postgres-wire backend serves all three clouds. The
scheduler edges come from `Engine.impliedByName` instead, same-cloud, which
is `PostgresSpec.masterPasswordSecret`'s precedent exactly.

### Where the SQL lives

In the service's own repository, as plain `.sql` files — never copied into
the fleet, and never re-expressed in Lean. A migration is declared with a
**source** (`SqlSource`): inline text, or an `https://` URL. `github` builds
the URLs for a public repository at a ref:

```lean
migrations := github "typednotes/ledger" "v0.2.0" ["sql/0001_init.sql"]
```

`Infra.Cli.run` fetches every URL before `plan` and `apply`
(`fetchMigrationSources`, then `withFetchedSources`), and `Engine.push`
refuses a plan that still holds an unfetched one. `check` stays offline: it
prints the plan with a labelled stand-in and says which sources it did not
read.

- **Files are listed, not directories.** Adopting a new migration is a
  one-line diff of the declaration — the review surface — and nothing is
  applied that the fleet does not name. Ids come from the file names
  (`0001_init.sql` → `0001`); a misnamed file has no id and is refused at
  compile time.
- **Pin the ref to the release the image comes from.** A consumer keeps one
  version value per service and builds both the image tag and the ref from
  it, so schema and code cannot drift apart.
- **A URL is not trusted to be immutable.** A tag can be moved. Once a
  migration is applied, the database's own record of its SQL is what the
  append-only check compares against, so changed content behind an applied
  URL is refused, not re-applied. Unapplied content is simply what the ref
  says at plan time.
- **What moved from compile time to plan time.** Inline SQL is checked by
  `#guard … migrationsAreSound` (content and the order it implies); for a
  URL, only its shape is checkable offline, and its content and ordering are
  checked by `plan`.

The first draft of this section had each service expose its SQL as a Lean
value that the consumer `require`d. It worked, and was replaced before
release: it put Lean files into Rust repositories purely to satisfy the
consumer's build, and it tied the fleet's compile to every service's
package graph.

### Soundness, at the decidable tier

`MigrationsSpec.historyIsSound`, a `Bool`-valued check in the shape of
`SecretsSpec.sourceIsSound` / `PostgresSpec.hasCapacityChoice`: migration ids
are unique and strictly ordered, and no `sql` is empty. Usable as
`Assert … := by decide` at authoring time, lifted fleet-wide next to
`Plan.secretsAreSound`.

## Observed state

```lean
structure PostgresMigrationsObserved where
  handle  : Handle .postgresMigrations
  applied : List (String × String)   -- (id, sql), in applied order
```

The handle is the fleet name, qualified by the parent database's handle —
there is no provider-assigned id to carry, the same situation
`SecurityGroupObserved` resolved by making the name the handle. `applied` is
read from a table infra owns:

```
SELECT id, sql FROM <schema>.infra_migrations ORDER BY id
```

Storing the `sql` verbatim — rather than a digest of it — is what makes
"migration `0007` exists but not with the content this declaration
remembers" an exact diff rather than a silent rewrite of history, and it
needs no hash whose stability across toolchain versions would become its
own conflict story: id present with different content is drift that fails the
plan, not a no-op. The proposal sketched a `(id, sha)` shape; the
implementation carries the content itself, because an exact comparison
cannot collide and the history table is not large.

## The three hard edges

### 1. Delete is a no-op forget, loudly

This is the edge the whole design stands or falls on, and it is named first
because of the 2026-09-10 incident: `destroy.yml` reconciles against an empty
declaration, every resource flips to `absent`, and `delete` is called on each.
For this kind, `delete` must **do nothing to the schema** — print `FORGET`
(not `DELETE`) and touch nothing else — and say so in the plan output. (Until
0.16.0 it also dropped a ledger row; there is no local record any more, so it
now simply does nothing.) The tables
themselves die with the `postgres` resource's own deletion, which is the
correct teardown: the schema's lifetime is the database's, not the
declaration's.

A subtler case is not deletion of the resource but removal of one applied
migration from the target list. That is refused at plan time — "history is
append-only: `0007` is applied but no longer declared" — because the observed
applied set must be a prefix of the target's migration list for any plan to be
honest. Removing a *not yet applied* migration is an ordinary `UPDATE`. The
prefix check needs observed state, so it lands in the runtime tier of
`docs/diff-semantics.md`'s ledger, recorded there alongside the check's name.

### 2. Observing needs a secret, and the planning path cannot read secrets

The connection string is a composed secret (`secrets-db-url`'s shape), and
`docs/architecture.md` is precise: values are read in exactly two places, both
on the apply path, and "the planning path cannot reach either — a dry run
cannot print a secret because it never has one." A live observation of this
kind needs the connection string, so one of two things has to give:

- **(a) Refresh reads the secret; plan reads the cache.** `refresh` is already
  a live, credentialed command; it gains one sanctioned secret-value read —
  same shape as `Kinds.Postgres.fetchMasterPassword`, confined to one named
  function, never stored, never printed. The applied set it fetches is what
  lands in `.infra/`, and `plan` diffs against that. The invariant being
  widened is real, and goes into `docs/diff-semantics.md`'s ledger as a tier
  change, the way the `composed` secret extension did — not smuggled in as a
  helper nobody flagged.
- **(b) No live observation at all.** `plan` prints "would sync migrations
  (pending set computed at apply)". The invariant survives intact; the main
  win of the design — a human reading the pending SQL before it runs — does
  not. A kind that cannot be observed live is a provisioner wearing a
  resource's clothes; under (b) this design loses to the cheaper alternatives
  and should not be built.
- **(c) Refresh reads a *read-only* secret.** The fleet declares a second
  identity the way it already declares `secrets-db-app`: a `migrations-reader`
  IAM application holding only the data-read permission set, an `apiKeyFor`
  key minted into a secret at apply, a composed read-only connection-string
  secret. Refresh reads **that** secret. This is (a) with a smaller recorded
  widening: the credential the planning path can reach cannot modify
  anything, so the blast radius of the widening is a `SELECT`.

  The obvious refinement — mint an *ephemeral* key at refresh instead
  (`CreateAPIKey` accepts an `expires_at`; verified against the IAM API
  reference, 2026-09-23), read, delete — was considered and rejected. It
  preserves the secret invariant's letter by breaking a bigger one: plan is
  read-only ("plan pulls live state and prints what would change,
  but change nothing" — `typednotes-infra`'s README). The CI token behind
  `plan.yml`, which runs a live plan on every push to `main`, would need
  API-key-minting rights, and per the same IAM reference, *"access management
  at resource level is not yet available"* — permission sets scope to a
  Project or Organization, so that token could mint keys for **any**
  application in the project, including the ReadWrite one. DDL rights on one
  database traded for project-wide key minting, held by the most exposed
  credential in the fleet, plus orphaned keys on crash and quota churn: a
  worse trade on every axis.

(These options were argued when a `refresh` command wrote observed state to a
cache under `.infra/`; both have since been removed. What shipped is (c)
without the cache: every live pull — `plan`, `apply`, `dump` — reads the
read-only secret directly. See `docs/persistence.md`.)

The recommendation is **(c)** — (a)'s mechanics against a read-only
credential — because plan-time review of schema changes is the point of the
exercise, and (c) buys it at the smallest invariant widening available. If
even that widening is refused, startup migration with an advisory lock is the
better design and this kind should not exist.

Two provider facts remain to verify before (c) is trusted, checked against
Scaleway's own references rather than recalled: the exact
permission-set → Postgres role mapping for Serverless SQL
(`ServerlessSQLDatabaseDataRead` → `role_read`?), and whether that role can
`SELECT` a table created by the ReadWrite role without an explicit `GRANT`.
If it cannot, the apply path issues
`GRANT SELECT ON <schema>.infra_migrations` itself — infra owns the DDL
either way.

Operational note for the backend either way: a Serverless SQL Database sleeps
when idle, so the observing connection needs bounded wake-up retries, and a
database that will not wake is an error, not an empty result — an empty
`applied` read as "nothing applied" would propose re-running every migration.

### 3. Fresh fleets are unobservable at plan time

On a first apply the database does not exist at plan time, so there is
nothing to connect to. The kind answers "unobservable → would CREATE + would
apply N migrations" rather than failing — the same posture `SecretSource.composed`
takes toward values that only exist post-apply. The apply path re-observes
after its dependencies settle: the `database` reference orders the `postgres`
resource first, the `connectionSecret` reference orders the composed URL
first, and only then does the migrator connect.

## Apply semantics

Ordered after both references, one migration at a time:

1. Connect via `linen`'s `Database.SQL`, using the secret value read through
   the one confined path above. The value is handed to the connection and
   never stored, cached, or returned — `fetchMasterPassword`'s discipline.
2. `SELECT pg_advisory_lock(hashtext(<fleet name>))`. `apply.yml`'s
   concurrency group is the real serialisation, but nothing stops a local
   apply running concurrently with CI, and the lock is one line of defence in
   depth.
3. `CREATE TABLE IF NOT EXISTS <schema>.infra_migrations` — the table's
   existence is also the ownership marker; see below.
4. Re-read `applied`; compute the pending suffix; for each pending migration,
   in a single transaction: apply the `sql`, insert the `(id, sha)` row. A
   failure aborts the apply there — and because the container references this
   resource (below), a failed migration means the new image never rolls out.
   The old code keeps running against a schema its forward-only migrations
   kept compatible, which is the correct failure state.

**Ordering against the container.** One optional field on the compute
specs — typed references on `scalewayContainer`, names on portable `compute`
— whose entire job is the edges: it is what turns "migrate, then roll out"
from a runbook step into the plan's topological order. Since 0.14.0 it is a
**list**: a service can need another service's schema as well as its own.

**Ordering between histories** (0.14.0) — **read from the SQL.** Two
services on one database can depend on each other's schema: `ledger`'s
`usage_events` carries `references orgs(id)`, and `orgs` is created by the
app. Both histories name the same database and URL secrets, so as of 0.13.0
they became ready in the same scheduling wave and ran in *declaration
order*. The foreign key already states the dependency, so infra reads it:
`Infra.Core.SqlDeps` scans each migration for `CREATE TABLE name` and
`REFERENCES name`, and a history is scheduled after every other history on
its database that creates a table it references (`Plan.historyDeps`, used by
the scheduler's `dependsOn`).

- **A scanner, conservative by construction.** Comments, string literals and
  dollar-quoted bodies are skipped; unquoted names fold to lower case;
  unqualified names mean `public` (infra never sets `search_path`);
  temporary tables are ignored.
- **What it cannot settle is refused, never guessed**
  (`Plan.migrationDepsProblem`): a reference to a table no history on that
  database creates, and a table two histories create. A table created where
  the scanner cannot see (inside a `DO` block) therefore surfaces as an
  error naming it, not as a missing edge. Checked at compile time for inline
  SQL (`migrationsAreSound`) and by `push` once URLs are fetched.
- **Only foreign keys.** A dependency that lives in a service's *code* —
  a broker writing the ledger's tables — is not in its SQL, so it is not a
  history edge. It belongs on the container, whose `migrations` is a list:
  the broker's rollout waits for the ledger's history as well as its own.
- **A failure still stops what follows.** An apply stops at the first failed
  action, so a history whose dependency failed never runs against a
  half-migrated schema. A cycle is refused by `orderActions`.

The first draft of 0.14.0 had an explicit `after : List String` field
instead. It was replaced before release: it declared a second time what the
foreign key already says, and a copy can drift.

`example/PostgresMigrations.lean` declares the dependent history *first*, so
its `runsBefore` guard can only pass because of the inferred edge — checked
by removing the `REFERENCES` and watching the guard fail.

## Ownership

The ladder applied honestly, because a kind that answers "I cannot tell you"
is a hole:

- No tags exist — the object is rows inside a database, not a cloud resource.
- Rung 2 by construction: the `<schema>.infra_migrations` table is something
  this tool wrote, and its presence is the marker.
- The resource is **subordinate**: its ownership verdict is its `database`
  reference's verdict. A migrations resource pointing at a database this fleet
  does not own is `foreign` — never managed, never touched — and the check is
  the parent's, not a new mechanism.
- `list` returns `[]`, deliberately and documented: "everything of this kind
  the credentials can see" is not enumerable without connecting to every
  database the account holds, so the scan for undeclared resources
  (`Engine.claimUndeclared`) skips the kind: there is nothing for it to find.
  This is safe *only because* delete is a no-op forget — the two properties
  are one design decision, and `docs/coverage.md` must carry them together,
  enumerated, not left to a catch-all.

## What it cost

- **The link line.** `infra`'s lakefile used to declare, verbatim, that
  "there is no need for Linen's libpq or DuckDB flags here." This kind makes
  `infra` reach `linen`'s libpq FFI, so the `⟪native-link-flags⟫` block gained
  `libpq` — and `ci/check-lakefile-sync.sh` forces the mirrored copy in
  `Infra/Cli/New.lean`, and every consumer lakefile (typednotes-infra's
  duplicated block), to move with it. Two things the change taught: the
  absolute-path probe needed the macOS `.dylib` extension (`ledger`'s lakefile
  already had it; a `.so`-only probe fell back to a bare `-lpq` that nothing
  could find), and the check is the standing one — `lake exe infra new /tmp/x`
  and build the result.
- **A new observed-state shape.** Derived `FromJson` rather than the
  `SecretsObserved` precedent's hand-written one: there is no legacy cache to
  load, this being a new kind, and the hand-written decoder is for caches
  written before a field existed. (The cache has since been removed; the
  encoding now serves `dump`.)
- **The secret-read widening** (hard edge 2), recorded in
  `docs/diff-semantics.md`'s ledger.
- **The ordering field**, on `scalewayContainer` (typed reference) and
  portable `compute` (name-based) both, so the edge exists for every
  compute-shaped resource rather than the one this fleet happens to use.
- The four surfaces in `AGENTS.md`, moved together: the
  `docs/coverage.md` rows, the `docs/internals.md` trace, the
  placeholder-backed `example/PostgresMigrations.lean`, and the release
  checklist's nine version places.

## Alternatives considered

- **Startup migration with `pg_advisory_lock`** (the status quo, hardened).
  A day of work, no engine changes, and it keeps `typednotes`' "server is the
  sole migration runner" convention. It buys none of the review surface, keeps
  structure-editing rights on the runtime identity, and pays a migration check
  on every cold start. Remains the right answer if hard edge 2's widening is
  refused.
- **A CI step running `lake exe ledger migrate`** between image publish and
  `apply`. No engine changes either, and the ordering is right, but it is a
  runbook step outside the declaration — the plan says nothing about it, and
  the two-step deploy can skew when only half runs. This is the design this
  proposal replaces, not one it can coexist with unnoticed.

## What this buys

One `apply` still deploys the whole fleet — now including the schema. The
plan names the migration work — `UPDATE scaleway/postgres-migrations/x` for
pending history, `FORGET` for a dropped line — and the SQL under review is
the diff of the declaration, which is where a reviewer reads it. The runtime
identity drops to data-only rights. The advisory-lock race and the
cold-start migration check disappear. And a failed migration stops the
rollout by construction, because the rollout is ordered after it.

## Implementation notes

Where the shipped kind differs from the proposal this page argued, and why:

- **Names, not typed references.** The proposal sketched
  `database : K .scaleway .postgres`; the shipped spec carries plain
  `String`s, because a typed reference names a provider and this kind is
  portable — one wire backend, three clouds. The edges moved to
  `Engine.impliedByName` (same-cloud, `masterPasswordSecret`'s precedent),
  which also settled the proposal's open question about how the ordering
  edges should reach the scheduler.
- **`sql` verbatim, not `(id, sha)`.** No hash: exact comparison, no
  collision or toolchain-stability story, and the history table stays small.
- **A second plan-time check the proposal didn't have.**
  `Plan.migrationsAreSound` at the decidable tier (ids ordered, `sql`
  non-empty, schema quotable, literals throughout) and
  `Plan.migrationsAppendOnly` at the runtime tier (refused by `push` before
  any action is derived), with the `Divergent` table and the backend behind
  it — three tiers over one contract, because a rewritten history is cheap to
  refuse and expensive to misapply.
- **The pending SQL is not printed in the plan line.** The proposal's
  "would apply 0013, 0014" would have needed field-level detail in an action
  render that carries none. The review surface is the declaration diff —
  the SQL lives in the fleet — and the plan line names the resource that
  gates the rollout.
- **Provider facts, checked.** `ServerlessSQLDatabaseReadOnly` maps to
  exactly `SELECT`, and `ServerlessSQLDatabaseReadWrite` to the DDL suite —
  Scaleway's "Manage user permissions for Serverless SQL Databases" page,
  reviewed 2025-09-17, checked 2026-09-23 — so option (c)'s read-only
  observer identity is real. Scaleway's "Known differences" page (checked
  2026-09-23) says `GRANT` cannot be performed on Serverless SQL — access is
  IAM's, per permission set — so the backend's guarded grant is best effort
  since 0.14.0: a refusal is a `NOTICE`, where before it would have aborted
  the apply session before any migration ran. **Verified live on
  2026-09-23** (`typednotes-infra`'s first apply, four histories on two
  databases): the DDL set may `CREATE SCHEMA` although the permission page
  lists only `TABLE` and `INDEX`, and the read identity sees every table the
  DDL identity created — the history tables and the services' own — with
  `SELECT` and nothing more (`INSERT` is refused). One more fact the run
  turned up: Serverless SQL routes connections by **TLS SNI** and refuses a
  client that does not send one (`Database hostname wasn't sent to
  server`). The backend's libpq sends it; a consumer's own tools may not
  (Go's `lib/pq` does not), and Scaleway's fix for those is an
  `options=databaseid%3D<id>` connection parameter.
