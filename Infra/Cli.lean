import Infra.Core.Engine
import Infra.Core.Credentials
import Infra.Providers.Live
import Infra.Providers.Placeholder
import Infra.Providers.Kinds.Identity

/-
  The command-line front end, as library code.

  A declaration repo declares a fleet; it should not also have to reimplement
  `check | pull | plan | push [--apply]`, decide which clouds to authenticate,
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

    Returns the credentials alongside the backends, because `checkAccounts`
    needs them and loading twice would prompt a keychain twice. -/
def liveFor (κ : Keys) : IO (Backends × (ProviderId → Option Credentials)) := do
  let mut creds : List (ProviderId × Credentials) := []
  for p in κ.providers do
    creds := (p, ← Credentials.load p) :: creds
  let lookup := fun p => (creds.find? fun c => c.1 == p).map (·.2)
  return ({ backend := fun p =>
    match lookup p with
    | some c => Infra.Providers.liveBackend p c
    | none   => Infra.Providers.placeholderBackend p.name }, lookup)

/-- Which accounts a fleet is for.

    Stated by the declaration repo, not by this library: `infra` has no opinion
    about whose accounts it is pointed at, but a *fleet* does. Either field left
    `none` means "do not check this cloud", which is the right default for a
    fleet that does not use it. -/
structure Accounts where
  /-- The 12-digit AWS account id. -/
  aws : Option String := none
  /-- The Scaleway organization (owner) id. -/
  scaleway : Option String := none

/-- Refuse to go further unless the credentials in force point where the fleet
    says they should.

    Runs before anything is listed, so a fleet aimed at the wrong account fails
    in one call rather than after proposing to create it somewhere else. Only
    the clouds the fleet actually uses are checked, and only those it names an
    id for — a claim that cannot be established is a failure, never a pass. -/
def checkAccounts (κ : Keys) (want : Accounts) (creds : ProviderId → Option Credentials) :
    IO Unit := do
  if κ.uses .aws then
    if let some expected := want.aws then
      match creds .aws with
      | none => throw (IO.userError "aws is declared but has no credentials")
      | some c =>
        let (actual, arn) ← Infra.Providers.Kinds.Identity.awsCaller c
        unless actual == expected do
          throw (IO.userError s!"wrong AWS account: credentials are for {actual} \
({arn}), but this fleet is declared for {expected}")
        IO.println s!"aws: account {actual} ok"
  if κ.uses .scaleway then
    if let some expected := want.scaleway then
      match creds .scaleway with
      | none => throw (IO.userError "scaleway is declared but has no credentials")
      | some c =>
        match ← Infra.Providers.Kinds.Identity.scalewayOwner c with
        | none => throw (IO.userError
            "could not establish which Scaleway organization these credentials belong to; \
set default_organization_id (or SCW_DEFAULT_ORGANIZATION_ID) so the check can run")
        | some actual =>
          unless actual == expected do
            throw (IO.userError s!"wrong Scaleway organization: credentials are for \
{actual}, but this fleet is declared for {expected}")
          IO.println s!"scaleway: organization {actual} ok"

def usage (exe : String) : String := String.intercalate "\n"
  [ s!"usage: {exe} [check | plan | pull | push [--apply]]"
  , ""
  , "  check           run the offline self-checks (default)"
  , "  pull            observe the declared clouds and cache what is there"
  , "  plan            show what would change, without changing anything"
  , "  push            same as plan — a dry run"
  , "  push --apply    actually reconcile"
  ]

/-- The whole front end for one fleet.

    `selfCheck` is whatever offline checks the consumer wants run by `check`
    (and by a bare invocation); it must not need credentials or a network.

    `accounts` is which accounts the fleet is for. Every live command verifies
    it before touching anything — see `checkAccounts`. Omitting it means no
    check, which is the old behaviour and a worse default: a fleet that names
    its accounts cannot be applied into someone else's. -/
def run {κ : Keys} (exe : String) (target : Plan κ) (selfCheck : IO Unit)
    (accounts : Accounts := {})
    (cacheRoot : System.FilePath := defaultCacheRoot) (args : List String) :
    IO UInt32 := do
  let withLive (act : Backends → IO Unit) : IO Unit := do
    let (bs, creds) ← liveFor κ
    checkAccounts κ accounts creds
    act bs
  match args with
  | [] | ["check"] => selfCheck; return 0
  | ["pull"] =>
    withLive fun bs => do
      let world ← pull (κ := κ) cacheRoot bs
      IO.println s!"pulled; {(plan target world).length} action(s) outstanding"
    return 0
  | ["plan"] | ["push"] =>
    withLive fun bs => do
      let world ← pull (κ := κ) cacheRoot bs
      for line in ← push bs target world {} do IO.println line
    return 0
  | ["push", "--apply"] =>
    withLive fun bs => do
      let world ← pull (κ := κ) cacheRoot bs
      for line in ← push bs target world { apply := true } do IO.println line
    return 0
  | _ =>
    IO.eprintln (usage exe)
    return 2

end Infra.Cli
