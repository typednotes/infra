import Infra.Core.Engine
import Infra.Core.Credentials
import Infra.Core.Region
import Infra.Core.Bundle
import Infra.Core.GcpAuth
import Infra.Providers.Live
import Infra.Providers.Placeholder
import Infra.Providers.Snapshot
import Infra.Providers.Kinds.Identity
import Infra.Providers

/-
  The command-line front end, as library code.

  A declaration repo declares a fleet; it should not also have to reimplement
  `check | plan | apply | destroy | dump`, decide which clouds to authenticate,
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
          throw (IO.userError s!"{slotId p .postgresMigrations nm}: \
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

    `fleet` is the fleet's resolved name (see `run`), and it reaches the backends here
    because this is the only place they are built. It is the *write* half of
    the marker — the value stamped on what gets created — while the boundary
    itself is the *read* half. `run` passes one field to both, deliberately: a
    fleet that wrote one name and required another would refuse to manage
    everything it had just created. -/
def liveFor (κ : Keys) (regions : Regions := {})
    (fleet : String)
    (routes : ProviderId → List Infra.Providers.Kinds.Migrations.MigrationRoute :=
      fun _ => [])
    (extra : List ProviderId := []) :
    IO (Backends × (ProviderId → Option Credentials)) := do
  let mut creds : List (ProviderId × Credentials) := []
  -- The declared clouds, then the `extra` ones — clouds the fleet's
  -- `Accounts` names without declaring anything there. Those are loaded only
  -- to be scanned: a cloud the fleet has just emptied must still be asked for
  -- what it left behind (see `Infra.Cli.run`).
  let clouds := κ.providers ++ extra.filter (!κ.providers.contains ·)
  for p in clouds do
    -- Not `Credentials.load`: GCP has a fourth source that cannot live there
    -- (minting a token from a service-account key needs HTTP, and HTTP needs
    -- `Credentials`), and `loadWithKeyFile` is the one place that adds it — so
    -- every front end offers the same sources rather than this one being
    -- special. See `Infra.Core.GcpAuth.loadWithKeyFile`.
    let declared := κ.providers.contains p
    -- A cloud named only in `Accounts` is scanned if its credentials are
    -- there, and said out loud if they are not: nothing is declared on it, so
    -- nothing *needs* it — but whatever this fleet left there is not looked
    -- for, and that should not be silent.
    let some c ← (if declared then some <$> Infra.Core.GcpAuth.loadWithKeyFile p
        else do
          match ← (Infra.Core.GcpAuth.loadWithKeyFile p).toBaseIO with
          | .ok c => pure (some c)
          | .error _ =>
            IO.eprintln s!"note: {p.name} is named in this fleet's accounts but declares \
nothing and has no credentials here, so it is not scanned: anything this fleet left \
there is not found. Load its credentials, or drop it from `accounts` once it is empty."
            pure none)
      | continue
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
    -- A cloud with nothing declared on it is scanned in the fleet's own
    -- region for it (`in paris`), else the credentials'.
    let c := if declared then c else
      match regions.region p with
      | some r => { c with region := r.code }
      | none   => c
    if !declared && c.region.isEmpty then
      IO.eprintln s!"note: {p.name} is named in this fleet's accounts but declares nothing, \
and neither the fleet nor the credentials say which region to scan, so it is not scanned."
      continue
    creds := (p, c) :: creds
  let lookup := fun p => (creds.find? fun c => c.1 == p).map (·.2)
  -- One backend per (cloud, region). Cheap: a `Backend` is a record of
  -- closures over the credentials, and the only thing varying is the region
  -- every endpoint builder reads.
  let backendIn := fun (p : ProviderId) (code : String) =>
    match lookup p with
    | some c => Infra.Providers.liveBackend p { c with region := code } fleet (routes p)
    -- A cloud this declaration names nothing on: no credentials, so the
    -- placeholder, which calls nothing. Nothing is routed here — orphans are
    -- only looked for on the clouds the declaration uses.
    | none   => Infra.Providers.placeholderBackend p.name
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
            -- For an orphan, whose region is where the scan found it
            -- (`Orphan.region`) rather than `resolve`'s answer — a placement
            -- table cannot answer for a slot the declaration no longer names.
            -- An empty code means nobody said where it was, which is the same
            -- case `backend` covers.
            backendAt  := fun p code =>
              backendIn p (if code.isEmpty then fallback p else code)
            -- Every region the fleet uses on this cloud, across all kinds —
            -- or the credentials' own if it places nothing there explicitly.
            -- A cloud with no credentials loaded is not scanned at all.
            scanners   := fun p =>
              if (lookup p).isNone then [] else
              let codes := (Finite.elems (α := Kind)).foldl (init := []) fun acc k =>
                (regions.used κ p k (fallback p)).foldl (init := acc) fun acc c =>
                  if acc.contains c then acc else acc ++ [c]
              (if codes.isEmpty then [fallback p] else codes).map fun c => (c, backendIn p c) },
            lookup)

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
  for p in Finite.elems (α := ProviderId) do
    let some expected := want.expect p | continue
    let some c := creds p
      | if κ.providers.contains p then
          throw (IO.userError s!"{p.name} is declared but has no credentials")
        else continue
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
  the edge, before `plan`/`apply` hand the plan to the engine —
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

/-- What `dump` writes: a `Snapshot` of the account as this fleet sees it,
    plus what the next `apply` would make of it.

    * `resources` — every declared resource that exists, and every undeclared
      one carrying this fleet's marker, each with its ownership evidence and
      what the cloud reported (`Snapshot.Resource`). Replayable offline with
      `Snapshot.load` and `Snapshot.backends`.
    * `undeclared` — the slots the next `apply` destroys;
    * `foreign` — declared names held by something without the marker, which
      this fleet leaves alone, with why;
    * `warnings` — what the scan saw but may not claim.

    A snapshot, not a record: nothing reads it back unless a test does. -/
def dumpJson (resources : Infra.Providers.Snapshot.Snapshot) (orphans : List Orphan)
    (foreign : List (String × String)) (warnings : List String)
    (releases : List Orphan := []) : Lean.Json :=
  Lean.Json.mkObj
    [ ("resources", Lean.toJson resources)
    , ("undeclared", Lean.toJson (orphans.map (·.slot)))
    , ("released", Lean.toJson (releases.map (·.slot)))
    , ("foreign", Lean.Json.arr (foreign.map fun (slot, why) => Lean.Json.mkObj
        [ ("slot", Lean.Json.str slot), ("reason", Lean.Json.str why) ]).toArray)
    , ("warnings", Lean.toJson warnings) ]

/-- The snapshot `dump` writes: declared resources that exist, and the
    orphans, each with the evidence its backend reports now. -/
def snapshotOf {κ : Keys} (bs : Backends) (regions : Regions) (entries : List (Entry κ))
    (orphans : List Orphan) : IO Infra.Providers.Snapshot.Snapshot := do
  let mut out : Infra.Providers.Snapshot.Snapshot := []
  for ⟨p, k, key, sighting⟩ in entries do
    let nm := κ.name p k key
    out := out ++ [{ cloud := p, kind := k, name := nm
                     region := (regions.codeFor p k nm).getD ""
                     evidence := ← (bs.backendFor p k nm).ownershipInfo k
                       (observedHandle k sighting.observed)
                     observed := some (Lean.toJson sighting.observed) }]
  for o in orphans do
    out := out ++ [{ cloud := o.cloud, kind := o.kind, name := o.name, region := o.region
                     evidence := ← (bs.backendAt o.cloud o.region).ownershipInfo o.kind ⟨o.name⟩ }]
  return out

def usage (exe : String) : String := String.intercalate "\n"
  [ s!"usage: {exe} [check | plan [--destroy] | apply [--force] | destroy | dump [FILE]]"
  , ""
  , "  check            run the offline self-checks (default)"
  , "  plan             show what would change, without changing anything"
  , "  plan --destroy   show what tearing the fleet down would delete"
  , "  apply            actually reconcile"
  , "  apply --force    reconcile even if that destroys most of the fleet"
  , "  destroy          delete everything this fleet manages"
  , "  dump [FILE]      write what this fleet manages, as JSON, to FILE or stdout"
  , ""
  , "  What a fleet manages is what carries its marker in the account, read off"
  , "  the resources on every run; nothing is stored locally. So deleting a"
  , "  resource from the declaration destroys it, from any machine, and only"
  , "  marked resources are ever changed or destroyed. To stop managing"
  , "  something without destroying it, say `forget` in the declaration, and"
  , "  keep saying it for as long as the resource carries the marker."
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

    **Nothing is stored locally.** What this fleet manages is read off the
    resources' markers on every run (`Engine.claimUndeclared`,
    `Engine.foreignDeclared`) — there is no ledger and no cache, so every
    machine, a fresh CI runner included, reaches the same plan. `dump` writes
    a snapshot when one is wanted.

    `boundary` is the realm and exclusion legs of the ownership model
    (`Infra.Core.Ownership.Boundary`): exclusions, an optional cutoff date
    below which an unmarked-but-old resource is treated as pre-dating `infra`
    rather than foreign, `fleetName` — an override of the fleet's name — and
    `namePrefix` — the marker of last resort, for the kinds a cloud offers no
    writable field to tag (`Infra.Core.Ownership`'s ladder).

    **The fleet's name** is `boundary.fleetName` if set, else `F.name` — the
    `fleet` command's identifier. It is resolved here, once, and is one value
    feeding both directions: `liveFor` stamps it on everything created,
    `ownershipOf` requires it back. It must be a valid marker value on every
    cloud (`Ownership.validFleetName`), checked before any live command —
    `fleet myFleet` fails there with a message saying to set `fleetName`.
    Renaming the declaration renames the fleet: its resources then carry
    another name, read as foreign and are left alone (never destroyed) until
    `fleetName` pins the old one.

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
    (boundary : Boundary := {}) (args : List String) :
    IO UInt32 := do
  -- Resolved once, at the edge: whether stdout is a terminal is a property of
  -- this invocation, not of a plan, so the engine is told rather than asking.
  let colour ← Ansi.wanted
  -- The fleet's name: the override if given, else the declaration's own.
  -- Resolved into the boundary so that every reader downstream sees `some`.
  let override := boundary.fleetName
  let name := override.getD F.name
  let boundary := { boundary with fleetName := some name }
  let withLive (act : Backends → IO Unit) : IO Unit := do
    unless validFleetName name do
      let fix := match override with
        | none => s!"It comes from the declaration (`fleet {F.name}`): rename the declaration, \
or pass `(boundary := \{ fleetName := some \"...\" })` to `Infra.Cli.run`."
        | some _ => "Fix `fleetName` in the boundary passed to `Infra.Cli.run`."
      throw (IO.userError (s!"'{name}' cannot be this fleet's name: it is the value of the \
'{markerKey}' marker on every cloud, so it must be 1-63 characters of lowercase letters, digits, \
'-' and '_', starting with a letter. " ++ fix))
    -- Every cloud `accounts` names is scanned, declared or not: removing a
    -- cloud's last line must still destroy what is left there, and the
    -- account check below is what makes scanning an undeclared cloud safe.
    let named := (Finite.elems (α := ProviderId)).filter (accounts.expect · |>.isSome)
    let (bs, creds) ← liveFor F.keys F.regions name
      (← migrationRoutesOf F.keys F.plan) (extra := named)
    checkAccounts F.keys accounts creds colour
    act bs
  -- Failures are reported, not thrown out of `main`. An escaping exception
  -- prints as "uncaught exception: …", which reads like a crash in the tool
  -- rather than a refusal by a cloud — and buries the message in a prefix
  -- that carries no information.
  -- The undeclared resources carrying this fleet's marker, found by asking
  -- the cloud (`Engine.claimUndeclared`); warnings for what it saw but may
  -- not claim go to stderr.
  let discover (bs : Backends) : IO Discovered := do
    let found ← claimUndeclared (κ := F.keys) bs boundary F.forgets
    for w in found.warnings do IO.eprintln w
    return found
  let reporting (act : IO Unit) : IO UInt32 := do
    match ← act.toBaseIO with
    | .ok _    => return 0
    | .error e =>
      IO.eprintln s!"{Ansi.style colour Ansi.red "error"}: {e}"
      return 1
  match args with
  | [] | ["check"] => reporting selfCheck
  -- A snapshot of what this fleet manages, as JSON: to stdout, or to the file
  -- named. Read-only, like `plan`.
  | ["dump"] | ["dump", _] =>
    reporting <| withLive fun bs => do
      let entries ← pullEntries (κ := F.keys) bs
      let foreign ← foreignDeclared bs F.plan (worldOf entries) boundary
      let found ← claimUndeclared (κ := F.keys) bs boundary F.forgets
      let snap ← snapshotOf bs F.regions entries found.orphans
      let out := (dumpJson snap found.orphans foreign found.warnings found.releases).pretty
      match args with
      | ["dump", path] => IO.FS.writeFile path (out ++ "\n"); IO.eprintln s!"wrote {path}"
      | _              => IO.println out
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
      let entries ← pullEntries (κ := F.keys) bs
      let world := worldOf entries
      -- The forgotten resources still marked as this fleet's are released on
      -- a teardown too: a fleet that is gone should not keep claims.
      let found ← discover bs
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
      let opts : PushOptions := { apply := doIt, colour, force := forced }
      -- `edges := F.plan` matters only for a teardown: `Plan.absent` carries
      -- no specs, so without the fleet's own declaration there is nothing to
      -- order deletions by. See `orderActions`.
      for line in ← push bs wanted world opts (edges := resolved) (orphans := found.orphans)
                        (boundary := boundary) (seen := some entries)
                        (releases := found.releases) do
        IO.println line
  | _ =>
    IO.eprintln (usage exe)
    return 2

end Infra.Cli
