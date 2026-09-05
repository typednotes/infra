import Infra.Core.Kind
import Linen.Data.Ini
import Linen.Data.Yaml
import Linen.System.Keychain

/-
  Where cloud credentials come from.

  Three sources, tried in order, first hit wins:

    1. the CLI config files the official tools already write
    2. the OS credential store
    3. environment variables

  Resolves `docs/authentication.md`'s open question. Config files come first
  because a machine that already has `aws configure` or `scw init` run on it
  should just work; environment variables come last because they are the
  override of last resort and the one CI sets.

  Nothing here ever logs a secret, and nothing here writes one to `.infra/`.
  `Credentials`' `Repr` redacts, so a stray `dbg_trace` or error message cannot
  leak one by accident.
-/

namespace Infra.Core

open Data.Ini (Ini)
open Data.Yaml (Value)

/-- What is needed to sign a request to one cloud. -/
structure Credentials where
  accessKey    : String
  secretKey    : String
  region       : String
  /-- Present only for temporary credentials (STS, instance roles). -/
  sessionToken : Option String := none
  /-- Scaleway scopes created resources to a project; AWS has no equivalent and
      leaves this empty. Creates fail without it, so it travels with the
      credentials rather than being asked for at each call site. -/
  projectId    : Option String := none
  /-- Scaleway IAM is organization-scoped rather than project-scoped, so a
      second identifier is needed for that one product. AWS has no analogue. -/
  organizationId : Option String := none

/-- Redacting. The secret and any session token are never rendered, so no
    amount of debug printing or error formatting can spill them. -/
instance : Repr Credentials where
  reprPrec c _ :=
    let tok := if c.sessionToken.isSome then "<redacted>" else "none"
    f!"Credentials \{ accessKey := {repr c.accessKey}, secretKey := <redacted>, \
region := {repr c.region}, sessionToken := {tok} }"

instance : ToString Credentials where
  toString c := toString (repr c)

/-- The files the official CLIs write. Parameterised rather than read from
    `$HOME` at the point of use, so the chain can be exercised against a
    scratch directory. -/
structure Paths where
  awsCredentials : System.FilePath
  awsConfig      : System.FilePath
  scwConfig      : System.FilePath

/-- The conventional locations, relative to `home`. -/
def Paths.under (home : System.FilePath) : Paths where
  awsCredentials := home / ".aws" / "credentials"
  awsConfig      := home / ".aws" / "config"
  scwConfig      := home / ".config" / "scw" / "config.yaml"

/-- The conventional locations for the current user. -/
def Paths.default : IO Paths := do
  let home := (← IO.getEnv "HOME").getD "."
  return Paths.under home

private def readIfExists (p : System.FilePath) : IO (Option String) := do
  if ← p.pathExists then return some (← IO.FS.readFile p) else return none

-- ── Source 1: the CLI config files ──

/-- The AWS profile to read, from `$AWS_PROFILE`, defaulting to `default`. -/
def awsProfile : IO String := do
  return (← IO.getEnv "AWS_PROFILE").getD "default"

/-- Read `~/.aws/credentials` and `~/.aws/config`.

    The two files name the same profile differently: `credentials` uses
    `[dev]` while `config` uses `[profile dev]` — except for the default
    profile, which is `[default]` in both. Both spellings are tried rather
    than assuming, since `aws configure` writes whichever suits the file. -/
def fromAwsFiles (paths : Paths) (profile : String) : IO (Option Credentials) := do
  let some credText ← readIfExists paths.awsCredentials | return none
  let credIni ← match Data.Ini.parse credText with
    | .ok i    => pure i
    | .error e => throw (IO.userError s!"{paths.awsCredentials}: {e}")
  let some accessKey := credIni.lookup profile "aws_access_key_id" | return none
  let some secretKey := credIni.lookup profile "aws_secret_access_key" | return none
  -- The region normally lives in the other file.
  let configIni ← match ← readIfExists paths.awsConfig with
    | none      => pure ({} : Ini)
    | some text => match Data.Ini.parse text with
      | .ok i    => pure i
      | .error e => throw (IO.userError s!"{paths.awsConfig}: {e}")
  let configSection := if profile == "default" then "default" else s!"profile {profile}"
  let region :=
    (configIni.lookup configSection "region").getD
      ((credIni.lookup profile "region").getD "")
  return some
    { accessKey, secretKey, region
      sessionToken := credIni.lookup profile "aws_session_token" }

/-- Read `~/.config/scw/config.yaml`. -/
def fromScalewayFile (paths : Paths) : IO (Option Credentials) := do
  let some text ← readIfExists paths.scwConfig | return none
  let doc ← match Data.Yaml.parse text with
    | .ok v    => pure v
    | .error e => throw (IO.userError s!"{paths.scwConfig}: {e}")
  let str (k : String) : Option String := (doc.get? k).bind (·.asString?)
  let some accessKey := str "access_key" | return none
  let some secretKey := str "secret_key" | return none
  return some
    { accessKey, secretKey
      region         := (str "default_region").getD ""
      projectId      := str "default_project_id"
      organizationId := str "default_organization_id" }

-- ── Source 2: the OS credential store ──

/-- The keychain service these entries live under. -/
def keychainService : String := "infra"

/-- Read credentials from an arbitrary keychain account under `keychainService`.

    Stored as an INI body — `access_key`, `secret_key`, `region`,
    optional `session_token` — so the same parser reads it as reads
    `~/.aws/credentials`, and so a human can inspect the entry.

    A missing entry is `none`, not an error: on a machine with no keychain
    service at all the call fails, and that must fall through to the next
    source rather than abort the chain.

    Not every credential in the chain names a `ProviderId` — a dedicated
    per-product credential (e.g. Scaleway's SQS-specific key, see
    `Infra.Providers.Scaleway.Sqs`) needs its own account name. -/
def fromKeychainAccount (account : String) : IO (Option Credentials) := do
  let entry := System.Keychain.Entry.new keychainService account
  let raw ← try
      pure (some (← entry.getPassword))
    catch _ => pure none
  let some text := raw | return none
  let ini ← match Data.Ini.parse text with
    | .ok i    => pure i
    | .error _ => return none      -- a malformed entry is not a usable one
  let some accessKey := ini.lookupGlobal "access_key" | return none
  let some secretKey := ini.lookupGlobal "secret_key" | return none
  return some
    { accessKey, secretKey
      region := (ini.lookupGlobal "region").getD ""
      sessionToken := ini.lookupGlobal "session_token" }

def fromKeychain (provider : ProviderId) : IO (Option Credentials) :=
  fromKeychainAccount provider.name

/-- Write credentials to an arbitrary keychain account under `keychainService`.
    See `fromKeychainAccount`. -/
def storeInKeychainAccount (account : String) (c : Credentials) : IO Unit := do
  let entry := System.Keychain.Entry.new keychainService account
  let body := Data.Ini.render
    { globals :=
        [("access_key", c.accessKey), ("secret_key", c.secretKey), ("region", c.region)]
        ++ (match c.sessionToken with
            | some t => [("session_token", t)]
            | none   => []) }
  entry.setPassword body

/-- Write credentials to the OS credential store, for `infra login`-style
    provisioning. The only function here that handles a secret in the writing
    direction. -/
def storeInKeychain (provider : ProviderId) (c : Credentials) : IO Unit :=
  storeInKeychainAccount provider.name c

-- ── Source 3: the environment ──

/-- The environment variables each cloud's own tooling reads. -/
def envVars : ProviderId → (String × String × String × Option String)
  | .aws      => ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION",
                  some "AWS_SESSION_TOKEN")
  | .scaleway => ("SCW_ACCESS_KEY", "SCW_SECRET_KEY", "SCW_DEFAULT_REGION", none)

/-- "Set but empty" means unset.

    The distinction matters more than it looks. A CI runner binds a variable to
    an undefined secret by setting it to the *empty string* rather than leaving
    it out — GitHub Actions does exactly this — so `IO.getEnv` returns
    `some ""` and a naive read yields credentials with an empty access key.
    Those fail much later, inside a TLS handshake or as an opaque provider
    error, with nothing pointing at the cause. Treating empty as absent makes
    the chain fall through to its not-found message, which names every place it
    looked.

    Pure, and separate from the `IO` that reads the variable, so the rule is
    checkable by `#guard` — Lean has no `setenv`, so the environment source
    itself cannot be driven from a self-check. -/
def normalizeEnv : Option String → Option String
  | some v => if v.trimAscii.isEmpty then none else some v
  | none   => none

/-- An environment variable, with `normalizeEnv` applied. -/
private def getEnvNonEmpty (name : String) : IO (Option String) :=
  normalizeEnv <$> IO.getEnv name

def fromEnvironment (provider : ProviderId) : IO (Option Credentials) := do
  let (kv, sv, rv, tv) := envVars provider
  let some accessKey ← getEnvNonEmpty kv | return none
  let some secretKey ← getEnvNonEmpty sv | return none
  let region := (← getEnvNonEmpty rv).getD ""
  let sessionToken ← match tv with
    | some v => getEnvNonEmpty v
    | none   => pure none
  let projectId ← match provider with
    | .scaleway => getEnvNonEmpty "SCW_DEFAULT_PROJECT_ID"
    | .aws      => pure none
  let organizationId ← match provider with
    | .scaleway => getEnvNonEmpty "SCW_DEFAULT_ORGANIZATION_ID"
    | .aws      => pure none
  return some { accessKey, secretKey, region, sessionToken, projectId, organizationId }

-- ── The chain ──

/-- Where each source would have looked, for the not-found message. Naming all
    three is the difference between a usable error and a mystery. -/
private def sourceDescriptions (paths : Paths) (provider : ProviderId) (profile : String) :
    List String :=
  let (kv, sv, _, _) := envVars provider
  match provider with
  | .aws =>
    [ s!"config file {paths.awsCredentials} (profile [{profile}])"
    , s!"keychain service '{keychainService}' account 'aws'"
    , s!"environment {kv} and {sv}" ]
  | .scaleway =>
    [ s!"config file {paths.scwConfig}"
    , s!"keychain service '{keychainService}' account 'scaleway'"
    , s!"environment {kv} and {sv}" ]

/-- Try each source in order and return the first that yields credentials.

    A source that is merely absent falls through; a source that is *present but
    malformed* raises, because silently skipping a config file with a typo in
    it would look exactly like having no credentials at all. -/
def loadFrom (paths : Paths) (provider : ProviderId) : IO Credentials := do
  let profile ← awsProfile
  let fromFiles ← match provider with
    | .aws      => fromAwsFiles paths profile
    | .scaleway => fromScalewayFile paths
  let found ← match fromFiles with
    | some c => pure (some c)
    | none   => do
      match ← fromKeychain provider with
      | some c => pure (some c)
      | none   => fromEnvironment provider
  match found with
  | some c => return c
  | none =>
    let tried := String.join ((sourceDescriptions paths provider profile).map (s!"\n  - {·}"))
    throw (IO.userError s!"no {provider.name} credentials found; tried:{tried}")

/-- Load credentials for a cloud from the conventional locations. -/
def Credentials.load (provider : ProviderId) : IO Credentials := do
  loadFrom (← Paths.default) provider

/-- The Scaleway project, or a clear failure. Creating anything on Scaleway
    needs one, and its absence otherwise surfaces as an opaque API error. -/
def Credentials.requireProject (c : Credentials) : IO String := do
  match c.projectId with
  | some p => return p
  | none   => throw (IO.userError
      "no Scaleway project configured; set SCW_DEFAULT_PROJECT_ID or \
default_project_id in ~/.config/scw/config.yaml")

/-- The Scaleway organization, or a clear failure. IAM is organization-scoped
    and fails opaquely without one. -/
def Credentials.requireOrganization (c : Credentials) : IO String := do
  match c.organizationId with
  | some o => return o
  | none   => throw (IO.userError
      "no Scaleway organization configured; set SCW_DEFAULT_ORGANIZATION_ID or \
default_organization_id in ~/.config/scw/config.yaml")

/-- The region, or a clear failure. Most APIs are regional and a blank region
    produces a baffling signing error much later, so it is caught here.

    Only reached for a cloud the fleet does not place itself. The declaration
    is the better answer of the three the message offers, so it is named
    first — see `Infra.Core.Region`. -/
def Credentials.requireRegion (c : Credentials) (provider : ProviderId) : IO String := do
  if c.region.isEmpty then
    let (_, _, rv, _) := envVars provider
    throw (IO.userError
      s!"no region configured for {provider.name}; declare where the fleet is \
(`fleet myFleet in paris where …`), or set {rv}, or set the region in its config file")
  return c.region

/-! ## Self-checks -/

-- An undefined CI secret arrives as `some ""`, and must read as absent, so the
-- credential chain reports "not found" instead of building empty credentials
-- that fail later inside a TLS handshake.
#guard normalizeEnv (some "") = none
#guard normalizeEnv (some "   ") = none
#guard normalizeEnv none = none
#guard normalizeEnv (some "SCWXXXXXXXXXXXXXXXXX") = some "SCWXXXXXXXXXXXXXXXXX"

end Infra.Core
