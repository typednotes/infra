import Infra.Core.Kind
import Infra.Providers.Http
import Linen.Crypto.JOSE.JWS
import Linen.Data.Time.Clock
import Lean.Data.Json

/-
  GCP service-account authentication, without the `gcloud` CLI.

  A service-account key is a JSON file holding an RSA private key. Exchanging
  it for an access token is the OAuth2 **JWT bearer** flow (RFC 7523): build an
  assertion claiming to be the service account, sign it RS256, POST it to
  Google's token endpoint, get an hour's access token back.

  This could not be done here until recently — `linen` could *verify* an RSA
  signature and not produce one, so the only way to get a token was to shell
  out to `gcloud`. `linen` 0.13.0 added `rsaSign`, and this is what it was
  added for.

  ## Which method to use

  Three now exist, and they are not interchangeable:

  | Method | Where it belongs |
  |---|---|
  | Workload Identity Federation | **CI.** No key material exists at all; the runner's own OIDC token is exchanged for a short-lived one. Nothing to leak. |
  | Service-account JSON (this file) | A long-running process, or CI on a platform without federation. A real secret on disk, so treat it as one. |
  | `gcloud` CLI | A developer's laptop, where a browser login already happened. |

  All three end in the same place — a bearer token in `Credentials.accessToken`
  — so nothing above this file knows which was used.

  **Federation is the better answer wherever it is available**, and this is not
  it: a JSON key is a long-lived credential that can be copied, committed by
  accident, and used from anywhere. It exists because not every environment can
  federate, not because it is a good default.
-/

-- Opened before the namespace: inside `Infra.Core.GcpAuth`, `Crypto.JOSE`
-- resolves relative to it and the names are not found.
open Lean (Json)
open Infra.Providers
open Crypto.JOSE

namespace Infra.Core.GcpAuth

/-- The fields of a service-account key file this needs. The file has more;
    the rest is not used and is deliberately not parsed. -/
structure ServiceAccount where
  /-- `client_email` — the identity the assertion claims to be. -/
  clientEmail : String
  /-- `private_key` — a PEM-encoded PKCS#8 RSA private key. **A secret.** -/
  privateKeyPem : String
  /-- `token_uri`, which is also the assertion's audience. -/
  tokenUri : String
  /-- `project_id`, so the caller does not have to supply it separately. -/
  projectId : Option String

/-- Never render the key. Same discipline as `Credentials`' own `Repr`: no
    amount of debug printing or error formatting can spill it. -/
instance : Repr ServiceAccount where
  reprPrec s _ :=
    f!"ServiceAccount \{ clientEmail := {repr s.clientEmail}, \
privateKeyPem := <redacted>, tokenUri := {repr s.tokenUri} }"

instance : ToString ServiceAccount where
  toString s := toString (repr s)

private def str? (j : Json) (k : String) : Option String :=
  (j.getObjVal? k).toOption.bind (·.getStr?.toOption)

/-- Parse a service-account key file.

    Rejects a key of the wrong `type` rather than failing later with a
    confusing signature error: an OAuth *client* secret and a *service
    account* key are both JSON files with a `client_email`-shaped feel, and
    mixing them up is an easy mistake to make once. -/
def parse (contents : String) : Except String ServiceAccount := do
  let j ← Json.parse contents
  match str? j "type" with
  | some "service_account" => pure ()
  | some other => throw s!"not a service-account key: type is '{other}'"
  | none       => throw "not a service-account key: no 'type' field"
  let some clientEmail := str? j "client_email"
    | throw "service-account key has no 'client_email'"
  let some privateKeyPem := str? j "private_key"
    | throw "service-account key has no 'private_key'"
  return { clientEmail, privateKeyPem
           tokenUri := (str? j "token_uri").getD "https://oauth2.googleapis.com/token"
           projectId := str? j "project_id" }

/-- Seconds since the Unix epoch. `iat`/`exp` are in these. -/
private def epochSeconds : IO Nat := do
  let now ← Data.Time.getCurrentTime
  return now.nanosSinceEpoch / 1000000000

/-- The scope every call this library makes needs. `cloud-platform` is broad,
    and deliberately so: the alternative is a per-product scope list that
    silently breaks whenever a new kind is implemented. What actually limits
    the damage is the service account's IAM roles, which is where the limit
    belongs. -/
def defaultScope : String := "https://www.googleapis.com/auth/cloud-platform"

/-- JSON-escape a string for embedding in a hand-built claims document. -/
private def esc (s : String) : String :=
  s.replace "\\" "\\\\" |>.replace "\"" "\\\""

/-- Build and sign the assertion (RFC 7523 §2.1).

    Lifetime is ten minutes rather than the maximum hour: the assertion is
    exchanged immediately, so a long window buys nothing and widens the
    replay opportunity if one ever leaks into a log. -/
def assertion (sa : ServiceAccount) (scope : String) : IO String := do
  let now ← epochSeconds
  let header := "{\"alg\":\"RS256\",\"typ\":\"JWT\"}"
  let claims :=
    "{\"iss\":\"" ++ esc sa.clientEmail ++ "\"," ++
    "\"scope\":\"" ++ esc scope ++ "\"," ++
    "\"aud\":\"" ++ esc sa.tokenUri ++ "\"," ++
    "\"iat\":" ++ toString now ++ "," ++
    "\"exp\":" ++ toString (now + 600) ++ "}"
  let der ← FFI.privkeyPemToDer sa.privateKeyPem
  match ← JWS.signCompact .RS256 der header claims with
  | some jwt => return jwt
  | none     => throw (IO.userError "gcp: RS256 signing is unavailable")

/-- Exchange a signed assertion for an access token.

    The body is form-encoded, which is what the endpoint requires — the one
    place in this library that posts a form rather than JSON or XML. -/
def exchange (sa : ServiceAccount) (jwt : String) : IO String := do
  let body :=
    "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" ++ jwt
  -- `Http.request` takes host and path separately, so the endpoint URL is
  -- split rather than parsed: it is always `https://<host>/<path>`, and
  -- `token_uri` in a key file is always absolute.
  let stripped := (sa.tokenUri.replace "https://" "").replace "http://" ""
  let (host, path) := match stripped.splitOn "/" with
    | h :: rest => (h, "/" ++ String.intercalate "/" rest)
    | []        => (stripped, "/")
  let reply ← Http.sendChecked (Http.request "POST" host path []
    [("Content-Type", "application/x-www-form-urlencoded")] (some body.toUTF8))
  let text := Http.bodyText reply
  match Json.parse text with
  | .error e => throw (IO.userError s!"gcp: token endpoint returned unparseable JSON: {e}")
  | .ok j =>
    match str? j "access_token" with
    | some t => return t
    -- The endpoint reports failures as 200-with-an-error-body about as often
    -- as it uses a status code, so this is a real path, not a formality.
    | none =>
      let err := (str? j "error").getD "unknown"
      let desc := (str? j "error_description").getD ""
      throw (IO.userError s!"gcp: token exchange failed: {err} {desc}")

/-- A service-account key file to an access token, in one call. -/
def tokenFromKeyFile (path : System.FilePath) (scope : String := defaultScope) :
    IO (String × Option String) := do
  let contents ← IO.FS.readFile path
  match parse contents with
  | .error e => throw (IO.userError s!"{path}: {e}")
  | .ok sa =>
    let jwt ← assertion sa scope
    return (← exchange sa jwt, sa.projectId)

/-- The standard variable pointing at a key file. Google's own libraries read
    it, so a machine already set up for `gcloud`-free service-account auth
    needs no extra configuration here. -/
def keyFileVar : String := "GOOGLE_APPLICATION_CREDENTIALS"

/-- Credentials from a key file named by the environment, if there is one.

    Lives here rather than in `Infra.Core.Credentials` only because of an
    import cycle: exchanging the assertion needs `Infra.Providers.Http`, which
    needs `Credentials`. `Infra.Cli.liveFor` calls this as the first GCP
    source, so the chain a user sees is still one chain. -/
def fromKeyFile : IO (Option Credentials) := do
  let some path ← (do return (← IO.getEnv keyFileVar)) | return none
  if path.trimAscii.isEmpty then return none
  let (token, project) ← tokenFromKeyFile path
  return some
    { accessKey := "", secretKey := "", region := ""
      accessToken := some token, projectId := project }

/-! ## Self-checks

  The signing and exchange paths need a real key and a network, so what is
  checked here is the parsing — which is where a confusing failure would
  otherwise come from. -/

-- A well-formed key parses, and the token URI defaults when absent.
#guard (parse "{\"type\":\"service_account\",\"client_email\":\"a@b.iam.gserviceaccount.com\",
  \"private_key\":\"-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----\\n\",
  \"project_id\":\"proj\"}").toOption.map (·.tokenUri)
  = some "https://oauth2.googleapis.com/token"

#guard ((parse
  "{\"type\":\"service_account\",\"client_email\":\"a@b\",\"private_key\":\"k\"}").toOption.map
  (·.clientEmail)) = some "a@b"

-- An OAuth *client* secret is a different file that looks similar enough to
-- be pasted in by mistake; it is rejected by name rather than by a later
-- signature error.
#guard (parse "{\"type\":\"authorized_user\",\"client_id\":\"x\"}").isOk = false

-- Missing pieces are named.
#guard (parse "{\"type\":\"service_account\",\"client_email\":\"a@b\"}").isOk = false
#guard (parse "not json").isOk = false

-- The key is never rendered, whatever anyone does with `repr` or `toString`.
private def secretSa : ServiceAccount :=
  { clientEmail := "a@b", privateKeyPem := "SUPER-SECRET-KEY"
    tokenUri := "https://oauth2.googleapis.com/token", projectId := none }

#guard ((toString secretSa).splitOn "SUPER-SECRET-KEY").length == 1
#guard ((toString secretSa).splitOn "<redacted>").length == 2

end Infra.Core.GcpAuth
