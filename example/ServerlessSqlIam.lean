import Infra

/-!
  # Example: a database only an IAM identity can open

  Scaleway's Serverless SQL Database has **no master user**. There is no root
  password to set, no `masterUsername` that means anything: authentication is
  IAM. The PostgreSQL user name is an IAM application's *id*, and the password
  is that application's API secret key.

  That breaks the usual shape of a declaration, because the one credential
  that has to travel does not exist when the file is written and cannot be
  read back after it does. Scaleway returns an API key's secret half **once**,
  at creation; `GET /api-keys` reports it as null for ever after. So it can be
  neither an environment variable (nobody has it yet) nor an observed value
  (observed state is cached in `.infra/` and printed in plans).

  `SecretSource.apiKeyFor` is the answer: it mints the key at the moment the
  secret is created and writes the secret half straight in, which is the one
  operation in this library that is already write-only. The halves that are
  *not* secret — the access key, and the application id the database wants as
  its user name — come back in `SecretsObserved`, where `expr!` can reach
  them.

  So the whole thing is four resources and one apply:

      iam reports-app ──┐
                        ├──▶ secrets app-key ──┐
                        │    (mints the key)   ├──▶ secrets app-db-url
      postgres reports ─┴──────────────────────┘    (the connection string)

  ## Three things that are easy to get wrong, and are wrong loudly

  Each of these cost a real debugging session before being written down, and
  each is pinned by a `#guard` in `Infra/Demo.lean`:

  * **The user name is the application id, not the access key.** The access
    key (`SCW…`) looks far more like a username than a UUID does, and it is
    the wrong answer. `principalOf` gives the id; `accessKeyOf` gives the
    access key. Using the second fails with `password authentication failed
    for user "SCW…"`, which points squarely at the password.
  * **The database is named after the resource.** `resource scaleway postgres
    "reports"` creates a database called `reports`, and nothing else. Getting
    it wrong fails with `database "…" does not exist` — after apply has
    already reported success.
  * **`?sslmode=require` is mandatory** and `endpointOf` does not supply it.
    The backend strips the query string off the endpoint Scaleway reports, so
    that `.endpoint` means `host:port` here as it does for every other kind.

  ## The permission set

  `ServerlessSQLDatabaseDataReadWrite` is the **data plane** — connecting and
  running SQL. `ServerlessSQLDatabaseReadWrite` is the management plane —
  creating and configuring databases. They are not the same grant, and an
  identity holding only the second can create this database and then fail to
  connect to it. An organization-wide `AllProductsFullAccess` does not cover
  the data plane either.

  On Scaleway, `policies` is a list of permission-set names, granted over the
  credentials' **project**. See `Infra/Providers/Kinds/Iam.lean` for what the
  same field means on the other two clouds.

  ## Ownership

  `namePrefix` is set, and this fleet is the reason the field exists. A
  Serverless SQL Database carries no tags and no description — there is
  nothing on one but the name it was created with — so the name is the only
  marker available, and without a prefix to check it against this fleet could
  create the database and then never be allowed to adopt or destroy it. The
  IAM application and both secrets are tagged normally; only the database
  falls to the name rung. See `Infra/Core/Ownership.lean`.

  Run with:

      lake exe serverless-sql-iam          -- offline: the plan, from placeholders
      lake exe serverless-sql-iam plan     -- reads the account
      lake exe serverless-sql-iam apply    -- creates all four, for real money

  `apply` creates a billable database. `lake exe serverless-sql-iam destroy`
  removes all four; the secret is deleted before the identity, and deleting
  the secret deletes the API key it minted.
-/
open Infra.Core
open Infra.Specs

/-- The data-plane permission set. See the header for why this is not
    `ServerlessSQLDatabaseReadWrite`. -/
def dataPlane : String := "ServerlessSQLDatabaseDataReadWrite"

fleet reportsStack in paris where
  resource scaleway iam "tn-reports-app"
    { policies := [dataPlane] }

  -- Serverless, not classic: capacity bounds and no `instanceClass`, which is
  -- what routes `Live.lean` to the Serverless SQL backend. `masterUsername`
  -- and `masterPasswordSecret` are required by `PostgresSpec` and discarded
  -- by this product, which has no master user at all — so they say that,
  -- rather than naming a plausible `dbadmin` that is never created. Naming a
  -- plausible one is exactly what made an earlier version of this fleet look
  -- correct while provisioning no credentials whatsoever.
  --
  -- `masterPasswordSecret` is *empty*, which is how a serverless target says
  -- "there is no master password". That only became sayable in 0.12.1: the
  -- create used to fetch the secret before it branched on `instanceClass`,
  -- and `fetchMasterPassword` rejects a missing name and `""` alike, so this
  -- field had to name a secret that really existed even though nothing would
  -- read it. This file named `unused-serverless-sql-is-iam-only` and so could
  -- not be applied as written; a consumer that copied the line hit
  -- `no secret named 'unused-…'` at create, after the IAM application had
  -- already been made. On a classic target the empty string still fails, and
  -- loudly, which is the right answer there.
  resource scaleway postgres "tn-reports-db" as reportsDb
    { masterUsername := "unused-serverless-sql-is-iam-only",
      masterPasswordSecret := "",
      minCapacity := 0,
      maxCapacity := 8 }

  -- Minted at apply. The value is the key's secret half and is never read
  -- back; `accessKey` and `principal` come back as observed state.
  resource scaleway secrets "tn-reports-key" as reportsKey
    { valueFrom := apiKeyFor "tn-reports-app" }

  -- `principalOf` — the application id — is the user. Not `accessKeyOf`.
  resource scaleway secrets "tn-reports-url"
    { valueFrom := composed
        expr!"postgres://{principalOf reportsKey}:{secretValueOf reportsKey}\
@{endpointOf reportsDb}/tn-reports-db?sslmode=require" }

/-- The boundary, which the `fleet` command has no syntax for: it is an
    argument to `Infra.Cli.run`, below.

    `namePrefix` is here because of the database. A Serverless SQL Database
    carries no tags and no description — there is nothing on one but the name
    it was created with — so the name is the only marker available, and
    without a prefix to check it against this fleet could create the database
    and then never be allowed to adopt or destroy it. The IAM application and
    both secrets are tagged normally and do not need this; only the database
    falls to the name rung. Every resource above is named to match. -/
def reportsBoundary : Boundary :=
  { fleetName := some "tn-reports", namePrefix := some "tn-reports-" }

/- Nothing in this fleet holds a value; both secrets hold recipes. -/
#guard reportsStack.plan.secretsAreSound

/- Every resource is inside the prefix. This is what the name rung checks,
   and what nothing else would catch: a resource named outside it would apply
   perfectly cleanly and then be unmanageable for ever. -/
#guard (Finite.elems (α := ProviderId)).all fun p =>
  (Finite.elems (α := Kind)).all fun k =>
    (Finite.elems (α := reportsStack.keys.Key p k)).all fun key =>
      (reportsStack.keys.name p k key).startsWith "tn-reports-"

/- Scaleway only, so Paris is legal and so is Amsterdam — though Serverless
   SQL Database itself is `fr-par`-only today, which is a product limit rather
   than a placement one. -/
#guard (reportsStack.regions.region .scaleway).map Region.code = some "fr-par"
#guard reportsStack.regions.covers reportsStack.keys

/- Four resources, one apply, no manual step in between. Before `apiKeyFor`
   this was three `scw` commands and a secret pasted in by hand. -/
#guard reportsStack.keys.count .scaleway .secrets = 2
#guard reportsStack.keys.count .scaleway .iam = 1
#guard reportsStack.keys.count .scaleway .postgres = 1

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "serverless-sql-iam" reportsStack
    (accounts := ← Infra.Cli.Accounts.fromEnv) (boundary := reportsBoundary) (args := args)
