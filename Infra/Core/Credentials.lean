import Infra.Core.Kind
import Linen.Cloud.Credentials.Chain

/-
  Where cloud credentials come from: linen's chain, with infra's keychain
  service.

  The chain itself — the CLI config files, the OS credential store, the
  environment, and for GCP a service-account key file (RFC 7523) and `gcloud`
  first — is `Linen.Cloud.Credentials` (`Cloud.Credentials.Chain.load`). It
  lived here, and in `Infra.Core.GcpAuth`, until infra moved onto
  `Linen.Cloud` (0.20.0); linen's copy is now the only one. What stays is the
  seam between the two:

  * **`Credentials` is `Cloud.Credentials`**, so every signature in infra
    keeps its name.
  * **The keychain service is `"infra"`**, not linen's default `"linen"`, so
    credentials a user stored with an older infra — and the shared Scaleway
    Queues credential cache (`Scaleway.Sqs`) — are still found, and the
    not-found message names the service that was actually searched.
  * **Failures raise.** The engine is written against `IO` exceptions, and
    linen answers `Except Cloud.Error`; `orThrow` is the one conversion.

  Nothing here ever logs a secret: `Cloud.Credentials`' `Repr` redacts.
-/

namespace Infra.Core

/-- What is needed to sign a request to one cloud: linen's structure. -/
abbrev Credentials := Cloud.Credentials

/-- The files the official CLIs write, parameterised so the chain can run
    against a scratch directory. -/
abbrev Paths := Cloud.Paths

/-- The same cloud, in linen's enumeration. -/
def ProviderId.toCloud : ProviderId → Cloud.Provider
  | .aws      => .aws
  | .scaleway => .scaleway
  | .gcp      => .gcp

#guard (Finite.elems (α := ProviderId)).all fun p => p.toCloud.name == p.name

/-- The keychain service infra's entries live under. -/
def keychainService : String := "infra"

/-- Raise a linen error as an `IO` error carrying its message. -/
def orThrow {α : Type} : Except Cloud.Error α → IO α
  | .ok a    => pure a
  | .error e => throw (IO.userError e.message)

/-- Where each source looks, in the order they are tried — for the not-found
    message, and asserted by `infra check`. -/
def sourceDescriptions (paths : Paths) (provider : ProviderId) (profile : String) :
    List String :=
  Cloud.sourceDescriptions paths provider.toCloud profile keychainService

/-- The whole chain from `paths`, raising a message that names every source
    when none has credentials. -/
def loadFrom (paths : Paths) (provider : ProviderId) : IO Credentials := do
  orThrow (← Cloud.Credentials.Chain.loadFrom Cloud.Transport.network paths provider.toCloud
    (service := keychainService))

/-- Load credentials for a cloud from the conventional locations — the whole
    chain, GCP's key file included (it used to need `GcpAuth.loadWithKeyFile`,
    because minting a token needed HTTP above this module; linen's chain takes
    a transport instead). -/
def Credentials.load (provider : ProviderId) : IO Credentials := do
  loadFrom (← Cloud.Paths.default) provider

/-- A named keychain account under infra's service, for a credential that is
    not a cloud's main one (Scaleway's Queues key). -/
def fromKeychainAccount (account : String) : IO (Option Credentials) :=
  Cloud.Credentials.Keychain.fromAccount account keychainService

def storeInKeychainAccount (account : String) (c : Credentials) : IO Unit :=
  Cloud.Credentials.Keychain.storeInAccount account c keychainService

/-- The bearer token, or a clear failure. -/
def Credentials.requireToken (c : Credentials) (provider : ProviderId) : IO String :=
  orThrow (Cloud.Credentials.requireToken c provider.toCloud)

/-- The project (Scaleway's, or GCP's), or a clear failure. -/
def Credentials.requireProject (c : Credentials) : IO String :=
  orThrow (Cloud.Credentials.requireProject c)

/-- The Scaleway organization, or a clear failure. -/
def Credentials.requireOrganization (c : Credentials) : IO String :=
  orThrow (Cloud.Credentials.requireOrganization c)

/-- The region, or a clear failure. Worded for infra, which has a better
    answer than linen's generic one: only reached for a cloud the fleet does
    not place itself, so declaring where the fleet is comes first. -/
def Credentials.requireRegion (c : Credentials) (provider : ProviderId) : IO String := do
  if c.region.isEmpty then
    let (_, _, rv, _) := Cloud.envVars provider.toCloud
    throw (IO.userError
      s!"no region configured for {provider.name}; declare where the fleet is \
(`fleet myFleet in paris where …`), or set {rv}, or set the region in its config file")
  return c.region

/-! ## Self-checks -/

-- The not-found message names infra's keychain service, not linen's.
#guard ((sourceDescriptions (Cloud.Paths.under "/h") .aws "default")[1]!.splitOn "'infra'").length == 2
#guard (sourceDescriptions (Cloud.Paths.under "/h") .gcp "default").length == 4

end Infra.Core
