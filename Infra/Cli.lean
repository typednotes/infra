import Infra.Core.Engine
import Infra.Core.Credentials
import Infra.Core.Region
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

/-- Where the observed-state cache lives, relative to the working directory.
    See `docs/persistence.md`. -/
def defaultCacheRoot : System.FilePath := ".infra"

/-- Build backends, authenticating only the providers `κ` actually declares
    resources in. The rest get the placeholder, which never calls a network.

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
    needs them and loading twice would prompt a keychain twice. -/
def liveFor (κ : Keys) (regions : Regions := {}) :
    IO (Backends × (ProviderId → Option Credentials)) := do
  let mut creds : List (ProviderId × Credentials) := []
  for p in κ.providers do
    -- GCP has a fourth source that cannot live in `Credentials.load`: minting
    -- a token from a service-account key needs HTTP, and HTTP needs
    -- `Credentials`. Tried first, because a key file is an explicit choice
    -- whereas `gcloud` is whatever the developer last logged into.
    let c ← match p with
      | .gcp => do
        match ← Infra.Core.GcpAuth.fromKeyFile with
        | some c => pure c
        | none   => Credentials.load p
      | _ => Credentials.load p
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
    let unplaced := (Finite.elems (α := Kind)).any fun k =>
      (Finite.elems (α := κ.Key p k)).any fun key =>
        (regions.codeFor p k (κ.name p k key)).isNone
    if unplaced then discard <| c.requireRegion p
    creds := (p, c) :: creds
  let lookup := fun p => (creds.find? fun c => c.1 == p).map (·.2)
  -- One backend per (cloud, region). Cheap: a `Backend` is a record of
  -- closures over the credentials, and the only thing varying is the region
  -- every endpoint builder reads.
  let backendIn := fun (p : ProviderId) (code : String) =>
    match lookup p with
    | some c => Infra.Providers.liveBackend p { c with region := code }
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

/-- The plan, against the placeholder backends: what a bare invocation shows.

    Offline, credential-free and free of charge, which is what makes it a safe
    default for `run`'s `selfCheck`. Every example had its own copy of this
    loop plus a hand-written "that was the placeholder backend" trailer; the
    trailer names the real subcommands, so it belongs next to `usage` where
    those are defined rather than in three files that can drift from it. -/
def offlinePlan {κ : Keys} (target : Plan κ) (headline : String := "") : IO Unit := do
  let colour ← Ansi.wanted
  unless headline.isEmpty do IO.println s!"{Ansi.style colour Ansi.bold headline}\n"
  for line in ← push Infra.Providers.all target (worldOf []) { colour } do
    IO.println line
  IO.println (Ansi.style colour Ansi.dim
    "\nThat was the placeholder backend — no cloud was contacted.")
  IO.println (Ansi.style colour Ansi.dim
    "For the real thing: `plan` (reads), then `apply` (changes).")

def usage (exe : String) : String := String.intercalate "\n"
  [ s!"usage: {exe} [check | refresh | plan [--destroy] | apply [--force] | destroy]"
  , ""
  , "  check            run the offline self-checks (default)"
  , "  refresh          observe the declared clouds and cache what is there"
  , "  plan             show what would change, without changing anything"
  , "  plan --destroy   show what tearing the fleet down would delete"
  , "  apply            actually reconcile"
  , "  apply --force    reconcile even if that destroys most of the fleet"
  , "  destroy          delete everything this fleet declares"
  , ""
  , "  Deleting a resource from the declaration destroys it, because the"
  , "  ledger and not the declaration records what is managed. To stop"
  , "  managing something without destroying it, say `forget` in the"
  , "  declaration. `destroy` is `apply` against an empty declaration."
  ]

/-- The whole front end for one fleet.

    `selfCheck` is whatever offline checks the consumer wants run by `check`
    (and by a bare invocation); it must not need credentials or a network.

    `accounts` is which accounts the fleet is for. Every live command verifies
    it before touching anything — see `checkAccounts`. Omitting it means no
    check, which is the old behaviour and a worse default: a fleet that names
    its accounts cannot be applied into someone else's.

    `regions` is where the fleet is, and the `fleet` command's `in` clause
    generates it (`myFleet.regions`). Omitting it means each cloud's region
    comes from its credentials, which is what every fleet did before placement
    was expressible — and which fails, by design, when the credentials carry
    no region at all.

    `cacheRoot` defaults to `.infra/<exe>`, not `.infra`: two fleets have
    different key families and their caches must never be read as if they were
    the same shape. Making that structural means a second fleet cannot forget
    to override it.

    The ledger lives under `cacheRoot` too, and is **not** committed. It was,
    briefly, on the reasoning that what a fleet manages is intent; that was
    wrong, and CI is where it showed. `Infra.Core.Ownership` records the
    reasoning and sketches the marker-and-boundary model meant to replace it,
    which is not yet wired to anything.

    `forgets` is the `forget` declarations, which the `fleet` command generates
    as `myFleet.forgets`. Each one releases a resource from the ledger without
    deleting it.

    **Deliberately has no default.** It had one, and that was a silent
    catastrophe waiting: a fleet could write `forget scaleway queues "x"`,
    compile, discharge the `Assert`, and then destroy the queue, because the
    releases never reached the engine. `forget` exists precisely to prevent
    that. With no default the compiler asks every fleet, and `Released κ`'s
    index means it cannot be answered with another fleet's list. Same reasoning
    as `cacheRoot` above: making it structural is what stops a second fleet
    forgetting. -/
def run {κ : Keys} (exe : String) (target : Plan κ)
    (selfCheck : IO Unit := offlinePlan target)
    (accounts : Accounts := {})
    (regions : Regions := {})
    (cacheRoot : System.FilePath := defaultCacheRoot / exe)
    (forgets : List (Released κ)) (args : List String) :
    IO UInt32 := do
  -- Resolved once, at the edge: whether stdout is a terminal is a property of
  -- this invocation, not of a plan, so the engine is told rather than asking.
  let colour ← Ansi.wanted
  let withLive (act : Backends → IO Unit) : IO Unit := do
    let (bs, creds) ← liveFor κ regions
    checkAccounts κ accounts creds colour
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
      let world ← pull (κ := κ) cacheRoot bs
      let rows ← Ledger.load cacheRoot
      let outstanding := (plan target world rows forgets).length
      IO.println s!"refreshed; {rows.length} managed; {outstanding} action(s) outstanding"
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
      let entries ← observe (κ := κ) cacheRoot bs
      let world := worldOf entries
      let rows ← Ledger.load cacheRoot
      -- `Plan.absent` is the empty declaration: the same keys, every one
      -- `.absent`. So `destroy` is not a second teardown mechanism, it is
      -- this one with an empty target, and the guard below checks that.
      let wanted := if tearDown then Plan.absent κ else target
      -- No teardown special-case here: `push` decides that from the target,
      -- because `Plan.absent` declares nothing and that is exactly what a
      -- teardown is. `--force` stays for the other case, a declaration that
      -- still declares things and drops most of them.
      let store : Store κ :=
        { root     := some cacheRoot
        , rows, forgets
        -- The same resolution `backendFor` routes on, so a row records the
        -- region the resource was actually created in rather than a second,
        -- differently-defaulted answer.
        , regionOf := fun p k nm => (regions.codeFor p k nm).getD "" }
      let opts : PushOptions := { apply := doIt, colour, force := forced }
      -- `edges := target` matters only for a teardown: `Plan.absent` carries
      -- no specs, so without the fleet's own declaration there is nothing to
      -- order deletions by. See `orderActions`.
      for line in ← push bs wanted world opts (edges := target) (store := store)
                        (seen := some entries) do
        IO.println line
  | _ =>
    IO.eprintln (usage exe)
    return 2

end Infra.Cli
