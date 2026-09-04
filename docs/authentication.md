# Authentication

## Problem

`docs/architecture.md` originally said "basic authentication to a service
happens by opening the browser". That turned out not to be what either cloud
wants, and the sections below are kept as the record of how that was worked
out — read them as history, not as a plan.

**What is actually implemented** is a three-source credential chain (config
files, then the OS keychain, then environment variables), described under
"Resolved: where credentials come from". **Browser login is decided against**,
for reasons specific to these two clouds — see "Still open". `Infra.Core.Auth`
remains a stub of a flow that would not be the right one anyway.

## Catching the redirect

**Option A — local loopback HTTP listener.** `redirectUri` points at
`http://localhost:<port>/callback`; `infra` starts a short-lived HTTP server (via Linen's
`Network.HTTP`) that waits for the single incoming request, extracts the `code` query
parameter, then shuts itself down.

- Pros: fully automatic — no copy/paste step; this is what most CLI tools (`gcloud auth
  login`, `aws sso login`) do, so it matches user expectations.
- Cons: needs a free local port and a firewall/loopback exception in some environments
  (locked-down corporate machines, remote dev containers without port forwarding); the
  server needs a real (if small) request-handling and shutdown implementation.

**Option B — manual code paste.** The provider's authorization page displays the code
directly (a redirect URI like `urn:ietf:wg:oauth:2.0:oob`, where supported) or the user
copies the `code` param out of the browser's address bar after redirect; `infra` prompts
for it on stdin.

- Pros: no listener, no port, works identically over SSH/remote/headless sessions.
- Cons: manual step every time (unless the token is cached long-term, see below); the
  `oob` redirect URI is deprecated or unsupported by many providers now, and AWS/Scaleway
  support isn't confirmed either way yet.

Neither is implemented; `Infra.Core.Auth` deliberately stops at building the URL and
opening the browser.

## Token storage

- **Linen's `System.Keychain`** (OS-native credential store — macOS Keychain,
  equivalents elsewhere) keeps the token out of plaintext files and off disk in the clear,
  at the cost of being unavailable on machines without a keychain service (some CI
  runners, some Linux setups) and pulling in whatever Linen's implementation needs.
- **A config file** (e.g. under `.infra/`) is simpler and more portable, works
  everywhere, and is easy to inspect/debug — but stores the token in the clear unless
  encrypted separately, and needs its own gitignore/permissions discipline so it doesn't
  end up committed.

## Not every provider needs OAuth2

AWS commonly authenticates CLIs via SSO or device-code flows (and plain long-lived access
keys); Scaleway's API is typically driven by a static API key/secret pair, not an OAuth2
authorization-code exchange. This is why `Infra.Abstractions.Auth`'s `AuthBackend` class
only requires exposing an `Infra.Core.OAuthConfig` — it deliberately doesn't force every
provider through the OAuth2 flow described above; a provider that only needs an API key
can implement its own, much simpler, credential path outside `AuthBackend` entirely.

## Resolved: where credentials come from

Three sources, tried in order, first hit wins. Implemented in
`Infra/Core/Credentials.lean`.

1. **The config files the official CLIs already write.**
   `~/.aws/credentials` and `~/.aws/config` (INI, honouring `$AWS_PROFILE`),
   and `~/.config/scw/config.yaml` (YAML). A machine where someone has run
   `aws configure` or `scw init` should simply work.
2. **The OS credential store**, via Linen's `System.Keychain`, under service
   `infra` and account `aws`/`scaleway`. Stored as an INI body so the same
   parser reads it as reads `~/.aws/credentials`, and so a human can inspect
   the entry.
3. **Environment variables** — `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
   `AWS_REGION`/`AWS_SESSION_TOKEN` and `SCW_ACCESS_KEY`/`SCW_SECRET_KEY`/
   `SCW_DEFAULT_REGION`. Last because they are the override of last resort and
   the thing CI sets.

Config files come first and the environment last, which is the opposite of the
usual precedence. The reasoning: an explicitly-configured machine should not be
silently overridden by a stale exported variable, and a developer who wants to
override *deliberately* can unset the config or point `$AWS_PROFILE` elsewhere.

Two extra identifiers travel with Scaleway credentials, because its API needs
them and fails opaquely without: `default_project_id` (every create is
project-scoped) and `default_organization_id` (IAM is organization-scoped).

### Scaleway Queues is a detour from this chain

Every other Scaleway kind is signed with the main access/secret key above.
`.queues` cannot be: its SQS-compatible endpoint refuses that key outright and
needs a *dedicated* credential, minted by calling Scaleway's own API
(`activate-sqs` then `sqs-credentials`) using the main key once. That minted
credential is cached under keychain service `infra`, account `scaleway-sqs` —
a second, separate keychain entry from the `scaleway` one above — so it is
provisioned once per machine rather than on every `push`. See
`Infra.Providers.Scaleway.Sqs` and `docs/providers.md`'s "verified against a
real account" note.

### Failure names every place it looked

```
$ infra plan
no aws credentials found; tried:
  - config file ~/.aws/credentials (profile [default])
  - keychain service 'infra' account 'aws'
  - environment AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
```

A source that is merely *absent* falls through; a source that is **present but
malformed** raises. Silently skipping a config file with a typo in it would look
exactly like having no credentials at all.

An environment variable that is **set but empty counts as absent**
(`normalizeEnv`). This is not pedantry: CI binds a variable to an undefined
secret by setting it to the empty string — GitHub Actions does — so without
this rule an unset secret produced credentials with an empty access key, and
the first sign of trouble was a TLS handshake failure or an opaque provider
error, neither of which points at the missing secret. Now the chain falls
through to the message above.

### A missing region is caught by name

Every endpoint is built from `Credentials.region`, so an empty one produces a
malformed host — `ec2..amazonaws.com` — and the failure surfaces from the
network layer as:

```
uncaught exception: connect: invalid address or hostname resolution failed
```

which says nothing about the cause. `Credentials.requireRegion` existed for
exactly this and was called from nowhere; `Infra.Cli.liveFor` now calls it for
every provider a fleet declares into, before any request is attempted, so the
error names the variable instead:

```
no region configured for aws; set AWS_REGION or the region in its config file
```

Exporting `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` without `AWS_REGION`
is the easy way to hit this, since the config-file source usually supplies the
region and the environment source does not have to.

### Running in CI needs a CA bundle

Not a credential problem, but it surfaces at the same moment and looks like
one, so it belongs here. A live call from a CI runner can fail with:

```
uncaught exception: error:0A000086:SSL routines::certificate verify failed
```

Linen's TLS client calls `SSL_CTX_set_default_verify_paths`, which resolves
against the *compile-time* `OPENSSLDIR` of the OpenSSL it was built against —
and Lean's toolchain bundles a static OpenSSL whose `OPENSSLDIR` points at the
machine that built it (`/opt/homebrew/etc/openssl@3` in the macOS toolchain).
On a fresh runner that path does not exist, so there is no trust store and
every certificate fails to verify.

The fix is to point OpenSSL at the runner's own bundle, which
`set_default_verify_paths` honours:

```yaml
- run: |
    echo "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" >> "$GITHUB_ENV"
    echo "SSL_CERT_DIR=/etc/ssl/certs" >> "$GITHUB_ENV"
```

`infra`'s own CI never hit this because it runs only the offline self-checks;
the first live call from CI is where it appears. See `typednotes-infra`'s
workflows for a working example.

### Which account, verified before anything happens

Credentials being *valid* is not the same as their being the *right* ones. The
chain has three sources, so what is in force is whatever the environment, the
keychain or a config file happened to supply — and an exported `AWS_PROFILE`, a
stale keychain entry or a CI secret pointing at another account all look
identical at the point of use. The first visible sign would be a plan proposing
to build a fleet somewhere it does not belong.

So a fleet states which accounts it is for (`Infra.Cli.Accounts`), and every
live command checks the claim before listing anything:

```
$ lake exe typednotes-infra plan
aws: account 616568506952 ok
scaleway: organization 4d7c630f-df06-43fe-b9e5-df729c8be4e3 ok
```

and otherwise refuses:

```
wrong AWS account: credentials are for 999988887777
(arn:aws:iam::999988887777:user/someone), but this fleet is declared for 616568506952
```

AWS uses `sts:GetCallerIdentity`, which is the right call and no other: it
requires no permissions, so it cannot fail for a reason unrelated to the
answer, and it behaves identically for an IAM user, an assumed role and an
Identity Center session. Scaleway has no equivalent, so the organization comes
from the API key's own record, falling back to `default_organization_id`.

A claim that cannot be *established* is a failure, never a pass — the check is
never silently skipped. Only the clouds a fleet uses are checked, and only
those it names an id for, so it costs one call per cloud per run and nothing
for a fleet that opts out. `infra` itself names no accounts: whose they are is
the declaring repo's business, and neither id is a secret (an account id
appears in every ARN, an organization id in the console URL).

### Secrets never render

`Credentials`' `Repr` redacts the secret key and any session token, so no
`dbg_trace`, error message or log line can leak one by accident. This is
checked, not merely intended — `infra check` asserts that formatting a loaded
credential does not contain the secret.

## Still open

- **Browser login is decided against, for now.** Static keys stay the only
  mechanism. The reasons are specific rather than a matter of taste:

  * **Scaleway has no browser flow to use.** API access is by access key and
    secret key, created in the console. There is no OAuth or device grant for
    programmatic credentials, so no amount of work here would cover that half.
  * **AWS has one, but only via IAM Identity Center**, which the account this
    is aimed at does not use — it is reached with plain IAM keys.

  Worth recording for whoever revisits this: `Infra.Core.Auth` is **not the
  right starting point**. It sketches the OAuth2 *authorization-code* flow
  (build a URL, open a browser, catch a redirect), and its own comment says the
  callback listener and token exchange are deliberately absent. AWS browser
  login is the *device authorization* grant instead — `RegisterClient`,
  `StartDeviceAuthorization`, open the browser, poll `CreateToken`, then
  `sso:GetRoleCredentials` — which needs no redirect listener at all and so
  reuses almost none of that file. The pieces it *would* reuse already exist:
  `Auth.openBrowser`, the HTTP client, and `Credentials.sessionToken`, which
  already carries temporary credentials through signing.

  Cheaper than either, if it ever comes up: read the token the AWS CLI's own
  `aws sso login` already caches under `~/.aws/sso/cache/`, and call
  `GetRoleCredentials` with it — a fourth source in the chain rather than a
  new flow.
- **Token refresh.** Static keys do not expire, so nothing refreshes.
  Temporary AWS credentials (`AWS_SESSION_TOKEN`) are *accepted* and signed
  with, but this tool will not renew them when they lapse.
- **Restricted INI and YAML readers.** The credential chain uses Linen's
  `Data.Ini` and `Data.Yaml`, which are real parsers — but see
  `docs/providers.md` for what each config format is actually relied upon to
  contain.
