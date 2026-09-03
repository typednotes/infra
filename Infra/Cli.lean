import Infra.Core.Engine
import Infra.Core.Credentials
import Infra.Providers.Live
import Infra.Providers.Placeholder

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
    `docs/authentication.md`. -/
def liveFor (κ : Keys) : IO Backends := do
  let mut creds : List (ProviderId × Credentials) := []
  for p in κ.providers do
    creds := (p, ← Credentials.load p) :: creds
  return { backend := fun p =>
    match creds.find? (fun c => c.1 == p) with
    | some c => Infra.Providers.liveBackend p c.2
    | none   => Infra.Providers.placeholderBackend p.name }

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
    (and by a bare invocation); it must not need credentials or a network. -/
def run {κ : Keys} (exe : String) (target : Plan κ) (selfCheck : IO Unit)
    (cacheRoot : System.FilePath := defaultCacheRoot) (args : List String) :
    IO UInt32 := do
  let withLive (act : Backends → IO Unit) : IO Unit := do act (← liveFor κ)
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
