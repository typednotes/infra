import Infra.Core.Image
import Infra.Providers.Http
import Infra.Providers.Aws.Protocols
import Linen.Data.Base64
import Linen.Data.Hex
import Linen.Crypto.SHA256
import Linen.System.Process

/- Resolve live infrastructure image selectors through OCI/Docker Registry
   v2 before reconciliation. Pin the manifest/index, not a platform-specific
   layer or config. Docker auths/helpers and native cloud registry credentials
   are read without logging them. The deployed reference records the digest:
   an observed tag is never re-resolved to today's content. -/
namespace Infra.Providers.Images

open Infra.Core
open Network.HTTP.Client

def accept : String := String.intercalate ", "
  ["application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
   "application/vnd.docker.distribution.manifest.list.v2+json",
   "application/vnd.docker.distribution.manifest.v2+json"]

def header (r : Response) (name : String) : Option String :=
  (r.headers.find? fun h => h.1 == Data.CI.mk' name).map (·.2)

/-- Bearer challenge's quoted parameters; malformed challenges are refused. -/
def bearerParameters (challenge : String) : Option (List (String × String)) := do
  if (challenge.take 7).toString.toLower != "bearer " then none
  let parts ← ((challenge.drop 7).toString.splitOn ",").mapM fun part => do
    let pair := part.trimAscii.toString.splitOn "="
    let key := pair.headD "" |>.trimAscii.toString
    let value := String.intercalate "=" (pair.drop 1) |>.trimAscii.toString
    if key.isEmpty || !value.startsWith "\"" || !value.endsWith "\"" || value.length < 2 then none
    let value := (value.drop 1).toString.dropEnd 1 |>.toString
    if value.toList.any (fun c => c == '"' || c == '\\' || c == '\r' || c == '\n') then none
    return (key, value)
  if (parts.map (·.1)).eraseDups.length != parts.length then none
  return parts

def tokenEndpoint (realm : String) : Option (String × String × String) := do
  if !realm.startsWith "https://" || realm.contains '@' || realm.contains '#' then none
  let pieces := (realm.drop 8).toString.splitOn "/"
  let host := pieces.headD ""
  if host.isEmpty || !host.toList.all (fun c => c.isAlphanum || ".:-".contains c) then none
  let ps := ("/" ++ String.intercalate "/" (pieces.drop 1)).splitOn "?"
  return (host, ps.headD "/", String.intercalate "?" (ps.drop 1))

/-- Credentials never follow an arbitrary authentication realm. Docker Hub's
    separate token host is its documented exception. -/
def mayForwardAuth (registry realmHost : String) : Bool :=
  registry == realmHost ||
    (registry == "registry-1.docker.io" && realmHost == "auth.docker.io")

private def requestAt (authority path : String)
    (query : Network.HTTP.Types.Query := []) (headers : List (String × String) := []) :
    IO Request := do
  let (host, port) ← match authority.splitOn ":" with
    | [h] => pure (h, 443)
    | [h, p] => match p.toNat? with
        | some n => if n > 0 && n <= 65535 then pure (h, n) else
            throw (IO.userError "image registry: invalid HTTPS port")
        | none => throw (IO.userError "image registry: invalid HTTPS port")
    | _ => throw (IO.userError "image registry: invalid authority")
  return { Http.request "GET" host path query headers with port := port.toUInt16 }

/-- Resolve with an injected transport, so the real protocol is exercised by
    offline tests, including authentication, moved tags and hash mismatches. -/
def resolveWith (send : Request → IO Response) (raw : String)
    (auth : Option String := none) (refreshToken : Option String := none) : IO String := do
  let some ref := Image.parse? raw
    | throw (IO.userError s!"image '{raw}': not a valid HTTPS OCI/Docker reference")
  if Image.isDigest ref.selector then return ref.pinned ref.selector
  let path := s!"/v2/{ref.repository}/manifests/{ref.selector}"
  let hs := [("Accept", accept)] ++ (auth.map fun a => [("Authorization", a)]).getD []
  let initial ← send (← requestAt ref.host path (headers := hs))
  let response ← if initial.statusCode.statusCode != 401 then pure initial else do
    let some params := (header initial "WWW-Authenticate").bind bearerParameters
      | throw (IO.userError s!"image '{raw}': authentication failed; configure Docker registry credentials")
    let some (tokenHost, tokenPath, existingQuery) := (params.lookup "realm").bind tokenEndpoint
      | throw (IO.userError s!"image '{raw}': invalid HTTPS token endpoint")
    -- Do not copy a scope which could grant push/delete from the challenge.
    let query : Network.HTTP.Types.Query :=
      [("scope", some s!"repository:{ref.repository}:pull")] ++
      (params.lookup "service").toList.map fun service => ("service", some service)
    let tokenHs := if mayForwardAuth ref.host tokenHost then
        (auth.map fun a => [("Authorization", a)]).getD [] else []
    let req ← match refreshToken with
      | none => do
        let req ← requestAt tokenHost tokenPath query tokenHs
        let qs := if existingQuery.isEmpty then req.queryString else
          "?" ++ existingQuery ++ "&" ++ (req.queryString.drop 1).toString
        pure { req with queryString := qs }
      | some token => do
        unless mayForwardAuth ref.host tokenHost do
          throw (IO.userError s!"image '{raw}': refusing to forward a refresh token to a foreign realm")
        let form := Network.HTTP.Types.canonicalQuery
          (query ++ [("grant_type", some "refresh_token"), ("client_id", some "infra"),
                     ("refresh_token", some token)])
        let req ← requestAt tokenHost tokenPath
          (headers := [("Content-Type", "application/x-www-form-urlencoded")])
        pure { req with
          method := Network.HTTP.Types.parseMethod "POST"
          queryString := if existingQuery.isEmpty then "" else "?" ++ existingQuery
          body := some form.toUTF8 }
    let reply ← send req
    unless reply.statusCode.statusCode == 200 do
      throw (IO.userError s!"image '{raw}': token service returned HTTP {reply.statusCode.statusCode}; configure Docker registry credentials")
    let json ← match Data.Json.Decode.decode (← Http.bodyText reply) with
      | .ok v => pure v
      | .error _ => throw (IO.userError s!"image '{raw}': token response is not JSON")
    let some token := (json.lookupText "token").orElse (fun _ => json.lookupText "access_token")
      | throw (IO.userError s!"image '{raw}': token response contains no token")
    if token.isEmpty || token.toList.any (fun c => c == '\r' || c == '\n') then
      throw (IO.userError s!"image '{raw}': token response is malformed")
    send (← requestAt ref.host path
      (headers := [("Accept", accept), ("Authorization", "Bearer " ++ token)]))
  unless response.statusCode.statusCode == 200 do
    throw (IO.userError s!"image '{raw}': registry returned HTTP {response.statusCode.statusCode}; the tag must exist and these credentials must be able to pull it")
  let media := (header response "Content-Type").getD ""
  unless (accept.splitOn ", ").contains ((media.splitOn ";").headD "").trimAscii.toString do
    throw (IO.userError s!"image '{raw}': registry did not return an OCI/Docker v2 manifest or index")
  let digest := "sha256:" ++ Data.Hex.encode (← Crypto.SHA256.digest response.body)
  if let some advertised := header response "Docker-Content-Digest" then
    unless advertised == digest do
      throw (IO.userError s!"image '{raw}': manifest content does not match the registry digest")
  return ref.pinned digest

private def basic (user password : String) : String :=
  "Basic " ++ Data.Base64.encode (user ++ ":" ++ password).toUTF8

/-- Credentials never have a printable instance. Docker identity tokens are
    refresh tokens, not access tokens to send directly to a registry. -/
structure RegistryAuth where
  authorization : Option String := none
  refreshToken : Option String := none

def dockerKeys (registry : String) : List String :=
  [registry, "https://" ++ registry, "https://" ++ registry ++ "/v1/"] ++
  if registry == "docker.io" then ["https://index.docker.io/v1/"] else []

private def dockerAuth (registry : String) : IO (Option RegistryAuth) := do
  let dir ← match ← IO.getEnv "DOCKER_CONFIG" with
    | some dir => pure (dir : System.FilePath)
    | none => match ← IO.getEnv "HOME" with
        | some home => pure ((home : System.FilePath) / ".docker")
        | none => return none
  let file := dir / "config.json"
  unless ← file.pathExists do return none
  let cfg ← match Data.Json.Decode.decode (← IO.FS.readFile file) with
    | .ok cfg => pure cfg
    | .error _ => throw (IO.userError "image registry: Docker config is not JSON")
  let keys := dockerKeys registry
  let entry := keys.findSome? fun key => (cfg.lookup "auths").bind (·.lookup key)
  if let some encoded := entry.bind (Data.Json.Value.lookupText "auth") then
    unless encoded.isEmpty do return some { authorization := some ("Basic " ++ encoded) }
  if let some token := entry.bind (Data.Json.Value.lookupText "identitytoken") then
    unless token.isEmpty do return some { refreshToken := some token }
  let helper := (keys.findSome? fun key =>
      (cfg.lookup "credHelpers").bind (Data.Json.Value.lookupText key)).orElse
        (fun _ => cfg.lookupText "credsStore")
  let some helper := helper | return none
  unless !helper.isEmpty && helper.toList.all (fun c => c.isAlphanum || "_-".contains c) do
    throw (IO.userError "image registry: invalid Docker credential helper name")
  let server := if registry == "docker.io" then "https://index.docker.io/v1/" else registry
  let result ← try
    System.Process.run ("docker-credential-" ++ helper) #["get"] 30000
      (input := some (server ++ "\n"))
  catch _ =>
    throw (IO.userError s!"image registry: Docker credential helper '{helper}' could not run")
  -- Never print stdout/stderr: either can hold a password or token.
  unless result.ok do return none
  let parsed ← match Data.Json.Decode.decode result.stdout with
    | .ok parsed => pure parsed
    | .error _ => throw (IO.userError "image registry: credential helper returned invalid JSON")
  match parsed.lookupText "Username", parsed.lookupText "Secret" with
  | some "<token>", some token => return some { refreshToken := some token }
  | some user, some password => return some { authorization := some (basic user password) }
  | _, _ => throw (IO.userError "image registry: credential helper omitted username or secret")

/-- Native auth is used only for known hosts of the selected cloud. Other
    registries use Docker's config/helpers or anonymous Bearer exchange. -/
def resolve (provider : ProviderId) (creds : Credentials) (raw : String) : IO String := do
  let some ref := Image.parse? raw
    | throw (IO.userError s!"image '{raw}': invalid OCI/Docker reference")
  if Image.isDigest ref.selector then return ref.pinned ref.selector
  -- Public pulls should not be broken by a stale login or unavailable helper
  -- in Docker's config. Credentials are consulted only after an auth refusal;
  -- a missing manifest, malformed reply or transport error still fails closed.
  match ← (resolveWith Http.send raw).toBaseIO with
  | .ok pinned => return pinned
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 401").length > 1 || (msg.splitOn "HTTP 403").length > 1
        || (msg.splitOn "authentication failed").length > 1 do throw e
  let explicitAuth ← dockerAuth ref.registry
  let auth ← match explicitAuth with
    | some auth => pure auth
    | none => do
      if provider == .scaleway && ["rg.fr-par.scw.cloud", "rg.nl-ams.scw.cloud", "rg.pl-waw.scw.cloud"].contains ref.registry then
        pure ({ authorization := some (basic "nologin" creds.secretKey) } : RegistryAuth)
      else if provider == .gcp && (ref.registry.endsWith "-docker.pkg.dev" ||
          ["gcr.io", "us.gcr.io", "eu.gcr.io", "asia.gcr.io"].contains ref.registry) then
        pure ({ authorization := creds.accessToken.map fun token => basic "oauth2accesstoken" token } : RegistryAuth)
      else if provider == .aws then
        match ref.registry.splitOn "." with
        | [account, "dkr", "ecr", region, "amazonaws", "com"] =>
          if account.length != 12 || !account.toList.all Char.isDigit then pure ({} : RegistryAuth) else do
          let reply ← Aws.Json.call creds (Aws.Json.ecrEndpoint region)
            "AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken" (.object [])
          let data := (reply.lookup "authorizationData").bind (·.asArray) |>.getD #[]
          let token := data.toList.findSome? (Data.Json.Value.lookupText "authorizationToken")
          pure ({ authorization := token.map ("Basic " ++ ·) } : RegistryAuth)
        | _ => pure ({} : RegistryAuth)
      else pure ({} : RegistryAuth)
  resolveWith Http.send raw auth.authorization auth.refreshToken

end Infra.Providers.Images
