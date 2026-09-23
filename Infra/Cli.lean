import Infra.Core.Engine
import Infra.Core.Credentials
import Infra.Core.Region
import Infra.Core.Bundle
import Infra.Core.GcpAuth
import Infra.Providers.Live
import Infra.Providers.Placeholder
import Infra.Providers.Kinds.Identity
import Infra.Providers

/-
  The command-line front end, as library code.

  A declaration repo declares a fleet; it should not also have to reimplement
  `check | refresh | plan | apply | destroy`, decide which clouds to authenticate,
  or remember that a dry run is the default. All of that lives here and is
  parameterised by the fleet, so a consumer's `Main.lean` is a call rather than
  a copy — this file exists because `infra`'s own `Main.lean` and
  `typednotes-infra`'s had drifted into near-identical dispatch blocks.

  ## Only the clouds the fleet uses

  `Infra.Providers.liveFromEnvironment` loads credentials for *both* clouds
  unconditionally, so a Scaleway-only fleet still failed without AWS
  credentials configured. Here the fleet's own key family decides: a provider
  whose every key type is empty (`Keys.uses`) gets the placeholder backend and
  is never authenticated. Together with `pullEntries`' skip of keyless
  `(provider, kind)` pairs, a single-cloud fleet touches exactly one cloud.
-/

namespace Infra.Cli

open Infra.Core
open Infra.Specs (MigrationDecl)

/-- Where the observed-state cache lives, relative to the working directory.
    See `docs/persistence.md`. -/
def defaultCacheRoot : System.FilePath := ".infra"

/-- The declared migration sets, as the backend's routes.

    A `postgresMigrations` resource cannot be observed from its handle
    alone — the name is all a handle carries — so the declaration's own
    names become the table the backend looks them up by. Non-literal names
    are refused here, loudly, rather than silently producing a route that
    cannot answer: those names are schema, not post-apply values, and
    `Plan.migrationsAreSound` refuses the same shape at compile time — this
    is the loud runtime backstop for a fleet that skipped the guard. -/
def migrationRoutesOf (κ : Keys) (T : Plan κ) :
    IO (ProviderId → List Infra.Providers.Kinds.Migrations.MigrationRoute) := do
  let mut table : List (ProviderId × List Infra.Providers.Kinds.Migrations.MigrationRoute) := []
  for p in Finite.elems (α := ProviderId) do
    let mut routes : List Infra.Providers.Kinds.Migrations.MigrationRoute := []
    for key in Finite.elems (α := κ.Key p .postgresMigrations) do
      match T.assign p .postgresMigrations key with
      | .present s =>
        let nm := κ.name p .postgresMigrations key
        match s.database.asLit, s.connectionSecret.asLit, s.observerSecret.asLit,
              s.schema.asLit with
        | some db, some cs, some os, some sc =>
          routes := { resource := nm, database := db
                      connectionSecret := cs, observerSecret := os, schema := sc } :: routes
        | _, _, _, _ =>
          throw (IO.userError s!"{Ledger.slotId p .postgresMigrations nm}: \
database/connectionSecret/observerSecret/schema must be literal names — a migrations \
resource is observed through them, and a composed name would be a resource this fleet \
could never see. See docs/migrations.md")
      | _ => pure ()
    table := (p, routes.reverse) :: table
  return fun p => ((table.find? fun e => e.1 == p).map (·.2)).getD []

/-- Build backends, authenticating only the providers `κ` actually declares
    resources in. The rest get the placeholder, which never calls a network.

    `routes` is how the `postgresMigrations` backend finds each declared
    migration set's database and URL secrets; `run` derives it from the
    declaration, and the default (no routes) is honest: such a backend can
    list nothing for that kind and refuses a read rather than fabricating
    one. See `docs/migrations.md`.

    Credential failures name every place that was searched — see
    `docs/authentication.md`.

    `regions` is where the fleet says it is. A cloud the fleet places is put
    there, **overriding** whatever region the credentials carry: placement is
    part of what the fleet declares, and a declaration loses its meaning if the
    environment can move it. It is not checked against the credentials the way
    the *account* is, because the two are not alike — an API key belongs to one
    account and cannot be pointed at another, whereas which region to build in
    is a free choice, and the declaration is where free choices are recorded.

    Returns the credentials alongside the backends, because `checkAccounts`
    needs them and loading twice would prompt a keychain twice.

    `fleet` is `Ownership.Boundary.fleetName`, and it reaches the backends here
    because this is the only place they are built. It is the *write* half of
    the marker — the value stamped on what gets created — while the boundary
    itself is the *read* half. `run` passes one field to both, deliberately: a
    fleet that wrote one name and required another would refuse to manage
    everything it had just created. -/
def liveFor (κ : Keys) (regions : Regions := {})
    (fleet : Option String := none)
    (routes : ProviderId → List Infra.Providers.Kinds.Migrations.MigrationRoute :=
      fun _ => []) :
    IO (Backends × (ProviderId → Option Credentials)) := do
  let mut creds : List (ProviderId × Credentials) := []
  for p in κ.providers do
    -- Not `Credentials.load`: GCP has a fourth source that cannot live there
    -- (minting a token from a service-account key needs HTTP, and HTTP needs
    -- `Credentials`), and `loadWithKeyFile` is the one place that adds it — so
    -- every front end offers the same sources rather than this one being
    -- special. See `Infra.Core.GcpAuth.loadWithKeyFile`.
    let c ← Infra.Core.GcpAuth.loadWithKeyFile p
    -- Every endpoint is built from the region, so an empty one produces a
    -- malformed host (`ec2..amazonaws.com`) and surfaces as
    -- "hostname resolution failed" — an error that says nothing about the
    -- missing variable. `requireRegion` names it instead, and this is the one
    -- funnel every live command passes through, so checking here covers all
    -- of them before any call is attempted.
    --
    -- Required only for a fleet that leaves something unplaced: a slot the
    -- declaration does not place falls back to the credentials, and that is
    -- exactly when the credentials have to supply one. A fully placed fleet
    -- has already answered the question and never reaches the check.
    unless regions.coversSlotsIn κ p do discard <| c.requireRegion p
    creds := (p, c) :: creds
  let lookup := fun p => (creds.find? fun c => c.1 == p).map (·.2)
  -- One backend per (cloud, region). Cheap: a `Backend` is a record of
  -- closures over the credentials, and the only thing varying is the region
  -- every endpoint builder reads.
  let backendIn := fun (p : ProviderId) (code : String) =>
    match lookup p with
    | some c => Infra.Providers.liveBackend p { c with region := code } fleet (routes p)
    -- Marked unreachable, not merely absent. The engine may hold ledger rows
    -- for a cloud this key family does not name — a stale row, or a teardown
    -- whose declaration names nothing — and routing those through a
    -- placeholder would delete nothing and say it had. `push` refuses instead.
    | none   => { Infra.Providers.placeholderBackend p.name with
                    unreachable := some s!"no {p.name} credentials were loaded, because \
this declaration names no {p.name} resources" }
  -- Where a cloud goes when the fleet does not say: the credentials' region.
  let fallback := fun (p : ProviderId) => ((lookup p).map (·.region)).getD ""
  let resolve := fun p k nm => (regions.codeFor p k nm).getD (fallback p)
  return ({ backend    := fun p     => backendIn p (fallback p)
            backendFor := fun p k nm => backendIn p (resolve p k nm)
            -- Exactly the regions this bucket's own resources live in — so a
            -- single-region fleet still lists once, and no fleet ever lists a
            -- region it declares nothing in.
            listers    := fun p k =>
              (regions.used κ p k (fallback p)).map fun code =>
                (backendIn p code, fun nm => resolve p k nm == code)
            -- For an orphan, whose region comes from its ledger row rather
            -- than from `resolve` — a placement table cannot answer for a slot
            -- the declaration no longer names. An empty code means the row was
            -- written by a fleet that never said where it was, which is the
            -- same case `backend` covers.
            backendAt  := fun p code =>
              backendIn p (if code.isEmpty then fallback p else code) }, lookup)

/-- Which accounts a fleet is for.

    A total function over `ProviderId` rather than one named field per cloud:
    the enum is `Finite` and the rest of the library already treats it
    uniformly (`Keys.providers`, `Credentials.envVars`), so a third cloud
    should be a row rather than a third copy of the check below. `none` for a
    provider means "do not check it", which is the right default for one a
    fleet does not use. -/
structure Accounts where
  expect : ProviderId → Option String := fun _ => none

/-- The environment variable naming the expected account for each cloud,
    alongside `Credentials.envVars` in spirit. -/
def Accounts.envVar : ProviderId → String
  | .aws      => "INFRA_EXPECT_AWS_ACCOUNT"
  | .scaleway => "INFRA_EXPECT_SCALEWAY_ORG"
  -- GCP's unit of ownership is the project, which is also what every API call
  -- is scoped to — so unlike the other two this is not a separate lookup.
  | .gcp      => "INFRA_EXPECT_GCP_PROJECT"

/-- The accounts named by the environment, for a fleet that cannot hardcode
    them.

    A *declaration* repo should write its account ids down — they are part of
    what it declares. `infra`'s own examples cannot: they ship with the
    library, so an id baked into one would make it refuse to run for anybody
    but its author. An unset variable means "do not check that cloud", so an
    example still runs unguarded by default and gains the guard the moment
    someone says which account they mean. -/
def Accounts.fromEnv : IO Accounts := do
  let mut table : List (ProviderId × String) := []
  for p in Finite.elems (α := ProviderId) do
    if let some v := normalizeEnv (← IO.getEnv (Accounts.envVar p)) then
      table := (p, v) :: table
  return { expect := fun p => (table.find? fun e => e.1 == p).map (·.2) }

/-- Refuse to go further unless the credentials in force point where the fleet
    says they should.

    Runs before anything is listed, so a fleet aimed at the wrong account fails
    in one call rather than after proposing to create it somewhere else. Only
    the clouds the fleet actually declares into are checked (`κ.providers`),
    and only those it names an id for — a claim that cannot be established is a
    failure, never a pass. -/
def checkAccounts (κ : Keys) (want : Accounts) (creds : ProviderId → Option Credentials)
    (colour : Bool := false) : IO Unit := do
  for p in κ.providers do
    let some expected := want.expect p | continue
    let some c := creds p
      | throw (IO.userError s!"{p.name} is declared but has no credentials")
    -- Per-cloud only in *how* the answer is obtained: AWS asks STS, Scaleway
    -- reads the API key's own record. Both answer the same question, and
    -- "could not establish" is a failure for both.
    let (actual, detail) ← match p with
      | .aws =>
        let (account, arn) ← Infra.Providers.Kinds.Identity.awsCaller c
        pure (some account, s!" ({arn})")
      | .scaleway =>
        pure (← Infra.Providers.Kinds.Identity.scalewayOwner c, "")
      -- No API call: the project is part of the credential itself, from
      -- `gcloud config get-value project` or `GOOGLE_CLOUD_PROJECT`. Checking
      -- it is still worth doing — it is the difference between building in
      -- your sandbox and building in production.
      | .gcp => pure (c.projectId, "")
    let some actual := actual
      | throw (IO.userError s!"could not establish which {p.name} account these \
credentials belong to; for Scaleway, set default_organization_id (or \
SCW_DEFAULT_ORGANIZATION_ID) so the check can run")
    unless actual == expected do
      throw (IO.userError s!"wrong {p.name} account: credentials are for \
{actual}{detail}, but this fleet is declared for {expected}")
    -- The region rides along on the same line rather than getting one of its
    -- own: account and region together are the whole of "where is this about
    -- to build", and reading them apart is what let a fleet aimed at the right
    -- account in the wrong region look fine.
    IO.println s!"{p.name}: {actual} in {c.region} {Ansi.style colour Ansi.green "ok"}"

/-! ## Migration sources

  A `postgresMigrations` history may read its SQL from URLs (`github`), so
  the SQL stays in the service's own repository. The fetch happens here, at
  the edge, before `plan`/`apply`/`refresh` hand the plan to the engine —
  which refuses a plan with an unfetched source (`Engine.push`). `check`
  never fetches: it stays offline, and says what it could not check. -/

/-- Rewrite every present history's migrations with `f`, leaving every other
    kind, and every non-present history, exactly as it was. -/
def mapMigrationDecls {κ : Keys} (T : Plan κ)
    (f : ProviderId → String → List MigrationDecl → List MigrationDecl) : Plan κ :=
  { assign := fun p k key =>
      match k, key with
      | .postgresMigrations, key =>
        match T.assign p .postgresMigrations key with
        | .present s =>
          match s.migrations.asLit with
          | some ms => .present { s with migrations := .lit (f p (κ.name p .postgresMigrations key) ms) }
          | none    => .present s
        | other => other
      | k, key => T.assign p k key }

/-- Every distinct `url` source the plan declares. -/
def migrationSourceUrls {κ : Keys} (T : Plan κ) : List String :=
  ((Finite.elems (α := ProviderId)).flatMap fun p =>
    (Finite.elems (α := κ.Key p .postgresMigrations)).flatMap fun key =>
      match T.assign p .postgresMigrations key with
      | .present s => (s.migrations.asLit.getD []).filterMap fun m =>
          match m.source with
          | .url u  => some u
          | .text _ => none
      | _ => []).eraseDups

/-- The body of an `https://` URL, as UTF-8 text: a `200`, decodable, and not
    empty — anything else fails, naming the URL, because a migration whose
    SQL could not be read must never be applied as if it said nothing.
    Retries transient failures like every other call (`Http.send`). -/
def fetchSql (url : String) : IO String := do
  let rest := String.ofList (url.toList.drop "https://".length)
  let (hostPath, query) := match rest.splitOn "?" with
    | [hp]       => (hp, "")
    | hp :: q    => (hp, String.intercalate "?" q)
    | []         => (rest, "")
  let (host, path) := match hostPath.splitOn "/" with
    | h :: segs => (h, "/" ++ String.intercalate "/" segs)
    | []        => (hostPath, "/")
  if !url.startsWith "https://" || host.isEmpty then
    throw (IO.userError s!"migration source {url}: only https:// URLs are fetched")
  let resp ← Infra.Providers.Http.send (Infra.Providers.Http.requestPresigned "GET" host path query)
  let status := resp.statusCode.statusCode
  unless status == 200 do
    throw (IO.userError s!"migration source {url}: HTTP {status} — is the tag or commit \
pushed, and the path right?")
  let some body := String.fromUTF8? resp.body
    | throw (IO.userError s!"migration source {url}: the body is not UTF-8 text")
  if body.trimAscii.isEmpty then
    throw (IO.userError s!"migration source {url}: the body is empty")
  return body

/-- The SQL behind every `url` source the plan declares, as `(url, sql)`.
    Each URL is read once per run, and the text is never cached across runs:
    a moved tag is seen the next time, and an applied migration whose
    content changed is then refused by the append-only check against the
    database's own record. -/
def fetchMigrationSources {κ : Keys} (T : Plan κ) : IO (List (String × String)) := do
  let mut fetched : List (String × String) := []
  for u in migrationSourceUrls T do
    fetched := (u, ← fetchSql u) :: fetched
  return fetched.reverse

/-- The plan with every `url` source replaced by its fetched SQL. A URL
    missing from `fetched` stays a URL, and `Engine.push` refuses it. -/
def withFetchedSources {κ : Keys} (T : Plan κ) (fetched : List (String × String)) : Plan κ :=
  mapMigrationDecls T fun _ _ ms => ms.map fun m =>
    match m.source with
    | .url u  => match fetched.lookup u with
      | some sql => { m with source := .text sql }
      | none     => m
    | .text _ => m

/-- For offline `check` only: stand-in SQL for every `url` source — a comment
    naming the URL, which creates and references nothing — so the offline
    plan can be printed. Ordering the SQL would imply is not known offline;
    `offlinePlan` says so. -/
def placeholderMigrationSources {κ : Keys} (T : Plan κ) : Plan κ :=
  mapMigrationDecls T fun _ _ ms => ms.map fun m =>
    match m.source with
    | .url u  => { m with source := .text s!"-- {u}\n-- not fetched: `check` is offline" }
    | .text _ => m

/-- The plan, against the placeholder backends: what a bare invocation shows.

    Offline, credential-free and free of charge, which is what makes it a safe
    default for `run`'s `selfCheck`. Every example had its own copy of this
    loop plus a hand-written "that was the placeholder backend" trailer; the
    trailer names the real subcommands, so it belongs next to `usage` where
    those are defined rather than in three files that can drift from it. -/
def offlinePlan {κ : Keys} (target : Plan κ) (headline : String := "") : IO Unit := do
  let colour ← Ansi.wanted
  unless headline.isEmpty do IO.println s!"{Ansi.style colour Ansi.bold headline}\n"
  for line in ← push Infra.Providers.all (placeholderMigrationSources target) (worldOf []) { colour } do
    IO.println line
  let remote := (migrationSourceUrls target).length
  if remote > 0 then
    IO.println (Ansi.style colour Ansi.dim
      s!"\n{remote} migration source(s) are URLs and were not fetched: the order between \
histories their SQL implies, and their content, are checked by `plan`.")
  IO.println (Ansi.style colour Ansi.dim
    "\nThat was the placeholder backend — no cloud was contacted.")
  IO.println (Ansi.style colour Ansi.dim
    "For the real thing: `plan` (reads), then `apply` (changes).")

def usage (exe : String) : String := String.intercalate "\n"
  [ s!"usage: {exe} [check | refresh | discover | plan [--destroy] | apply [--force] | destroy]"
  , ""
  , "  check            run the offline self-checks (default)"
  , "  refresh          observe the declared clouds and cache what is there"
  , "  discover         rebuild the ledger from real ownership evidence, for"
  , "                   the kinds a backend can report a marker for"
  , "  plan             show what would change, without changing anything"
  , "  plan --destroy   show what tearing the fleet down would delete"
  , "  apply            actually reconcile"
  , "  apply --force    reconcile even if that destroys most of the fleet"
  , "  destroy          delete everything this fleet declares"
  , ""
  , "  Deleting a resource from the declaration destroys it, because the"
  , "  ledger and not the declaration records what is managed. To stop"
  , "  managing something without destroying it, say `forget` in the"
  , "  declaration. `destroy` is `apply` against an empty declaration. The"
  , "  ledger is a cache: `discover` rebuilds what it can from the marker tag"
  , "  `infra` itself writes, rather than trusting past runs to have it right."
  ]

/-- The whole front end for one fleet.

    `F` is the declaration, whole: its keys, its plan, its placement and its
    releases, which the `fleet` command emits as the single value `myFleet`.
    These used to be three separate arguments, and every call site spelled the
    same fleet's name three times to supply them — `run "x" x.plan (regions :=
    x.regions) (forgets := x.forgets)`. Taking one value is not only shorter:
    `Regions` is not indexed by the key family, so the three-argument form
    accepted one fleet's plan alongside another's placement and built it in the
    wrong place. See `Infra.Core.Fleet`.

    `selfCheck` is whatever offline checks the consumer wants run by `check`
    (and by a bare invocation); it must not need credentials or a network. It
    defaults to the plan against the placeholder backends, under `headline` —
    which is all three examples ever wanted from it, and which no longer needs
    the plan named a second time to say.

    `accounts` is which accounts the fleet is for. Every live command verifies
    it before touching anything — see `checkAccounts`. Omitting it means no
    check, which is the old behaviour and a worse default: a fleet that names
    its accounts cannot be applied into someone else's.

    `cacheRoot` defaults to `.infra/<exe>`, not `.infra`: two fleets have
    different key families and their caches must never be read as if they were
    the same shape. Making that structural means a second fleet cannot forget
    to override it.

    The ledger lives under `cacheRoot` too, and is **not** committed. It was,
    briefly, on the reasoning that what a fleet manages is intent; that was
    wrong, and CI is where it showed. `Infra.Core.Ownership`'s marker-and-
    boundary model is what actually decides membership now — the adoption
    loop and the orphan-delete check in `Engine.push` both consult it — for
    every kind a backend can report a marker for (`Backend.ownershipInfo`);
    the ledger itself is the cache of that decision, rebuildable with
    `discover`. A kind whose marker cannot be read is refused rather than
    claimed.

    `boundary` is the realm and exclusion legs of the ownership model
    (`Infra.Core.Ownership.Boundary`): exclusions, an optional cutoff date
    below which an unmarked-but-old resource is treated as pre-dating `infra`
    rather than foreign, and `fleetName` — this fleet's own name, which is written
    into the marker's value and required back out of it, and `namePrefix` —
    the marker of last resort, for the kinds a cloud offers no writable field
    to tag (`Infra.Core.Ownership`'s ladder). Empty by default,
    which is the same as not having the model at all for a fleet that never
    sets it.

    `fleetName` is what makes two fleets in one account safe rather than merely
    refused, and it is one field feeding both directions: `liveFor` stamps it
    on everything created, `ownershipOf` requires it back. Setting it to
    `some exe` is the obvious choice and is deliberately *not* the default —
    see `Ownership.legacyMarkerValue` for what that would do to an estate
    tagged before the name existed.

    The releases (`F.forgets`) reach the engine because they are part of the
    declaration rather than an argument someone has to remember — see
    `Infra.Core.Fleet` for why that field has no default of its own. It was an
    argument here, and briefly a defaulted one, which was a silent catastrophe
    waiting: a fleet could write `forget scaleway queues "x"`, compile,
    discharge the `Assert`, and then destroy the queue, because the releases
    never reached the engine. -/
def run (exe : String) (F : Fleet)
    (headline : String := "")
    (selfCheck : IO Unit := offlinePlan F.plan headline)
    (accounts : Accounts := {})
    (cacheRoot : System.FilePath := defaultCacheRoot / exe)
    (boundary : Boundary := {}) (args : List String) :
    IO UInt32 := do
  -- Resolved once, at the edge: whether stdout is a terminal is a property of
  -- this invocation, not of a plan, so the engine is told rather than asking.
  let colour ← Ansi.wanted
  let withLive (act : Backends → IO Unit) : IO Unit := do
    let (bs, creds) ← liveFor F.keys F.regions boundary.fleetName
      (← migrationRoutesOf F.keys F.plan)
    checkAccounts F.keys accounts creds colour
    act bs
  -- Failures are reported, not thrown out of `main`. An escaping exception
  -- prints as "uncaught exception: …", which reads like a crash in the tool
  -- rather than a refusal by a cloud — and buries the message in a prefix
  -- that carries no information.
  let reporting (act : IO Unit) : IO UInt32 := do
    match ← act.toBaseIO with
    | .ok _    => return 0
    | .error e =>
      IO.eprintln s!"{Ansi.style colour Ansi.red "error"}: {e}"
      return 1
  match args with
  | [] | ["check"] => reporting selfCheck
  -- `refresh` rather than `pull`: it is Terraform's name for exactly this
  -- (observe reality, record it), and it deliberately has no destructive
  -- counterpart that rhymes with it — `pull`/`push` would differ by one
  -- character while differing completely in consequence. Terraform's own
  -- `state pull`/`state push` mean something else again: moving a state file
  -- to and from a remote backend.
  -- `refresh` deliberately does not write the ledger. It observes, and
  -- observing is not a decision about what is managed. Only `apply` and
  -- `destroy` change membership.
  | ["refresh"] =>
    reporting <| withLive fun bs => do
      let world ← pull (κ := F.keys) cacheRoot bs
      let rows ← Ledger.load cacheRoot
      let wanted := withFetchedSources F.plan (← fetchMigrationSources F.plan)
      let outstanding := (plan wanted world rows F.forgets).length
      IO.println s!"refreshed; {rows.length} managed; {outstanding} action(s) outstanding"
  -- Rebuilds the ledger as what it is documented to be: a cache of ownership,
  -- not the record of it. Only kinds whose marker a backend can actually read
  -- (`Backend.ownershipInfo`) are re-derived; every other kind's rows are
  -- carried over untouched, so a fleet holding one does not lose what it
  -- already knew about it.
  | ["discover"] =>
    reporting <| withLive fun bs => do
      let before ← Ledger.load cacheRoot
      let after ← discover (κ := F.keys) bs boundary
        (fun p k nm => (F.regions.codeFor p k nm).getD "") before
      Ledger.save cacheRoot after
      IO.println s!"discovered; {after.length} managed (was {before.length})"
  -- Four commands, one body. They vary in two independent ways — *which*
  -- declaration to reconcile against, and whether to actually do it — so
  -- writing them out separately would be four copies of the same three lines.
  -- `Plan.absent` is the "empty declaration": same keys, every one `.absent`.
  | ["plan"] | ["apply"] | ["apply", "--force"]
  | ["plan", "--destroy"] | ["destroy"] | ["destroy", "--force"] =>
    let tearDown := args.head? == some "destroy" || args == ["plan", "--destroy"]
    let doIt     := args.head? == some "apply" || args.head? == some "destroy"
    let forced   := args.contains "--force"
    reporting <| withLive fun bs => do
      let entries ← observe (κ := F.keys) cacheRoot bs
      let world := worldOf entries
      let rows ← Ledger.load cacheRoot
      -- `Plan.absent` is the empty declaration: the same keys, every one
      -- `.absent`. So `destroy` is not a second teardown mechanism, it is
      -- this one with an empty target, and the guard below checks that.
      -- A teardown needs no SQL (a history's delete is a FORGET), so only a
      -- reconcile fetches the migration sources.
      let fetched ← if tearDown then pure [] else fetchMigrationSources F.plan
      let resolved := withFetchedSources F.plan fetched
      let wanted := if tearDown then Plan.absent F.keys else resolved
      -- No teardown special-case here: `push` decides that from the target,
      -- because `Plan.absent` declares nothing and that is exactly what a
      -- teardown is. `--force` stays for the other case, a declaration that
      -- still declares things and drops most of them.
      let store : Store F.keys :=
        { root     := some cacheRoot
        , rows
        , forgets  := F.forgets
        -- The same resolution `backendFor` routes on, so a row records the
        -- region the resource was actually created in rather than a second,
        -- differently-defaulted answer.
        , regionOf := fun p k nm => (F.regions.codeFor p k nm).getD ""
        , boundary }
      let opts : PushOptions := { apply := doIt, colour, force := forced }
      -- `edges := F.plan` matters only for a teardown: `Plan.absent` carries
      -- no specs, so without the fleet's own declaration there is nothing to
      -- order deletions by. See `orderActions`.
      for line in ← push bs wanted world opts (edges := resolved) (store := store)
                        (seen := some entries) do
        IO.println line
  | _ =>
    IO.eprintln (usage exe)
    return 2

end Infra.Cli
