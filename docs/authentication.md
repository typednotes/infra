# Authentication

## Problem

Per the "Authentication" section of `docs/architecture.md`: "Basic authentication to a
service happens by opening the browser. Later, other means of authentication will be
used." That much is settled and implemented — `Infra.Core.Auth.openBrowser` and
`authorizationUrl` build the OAuth2 authorization-code URL (via Linen's `Network.OAuth2`)
and open it in the user's default browser. What's open is what happens after the browser
opens: how the authorization-code redirect is caught, and where the resulting token ends
up stored so later `pull`/`push` calls can use it.

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

### Secrets never render

`Credentials`' `Repr` redacts the secret key and any session token, so no
`dbg_trace`, error message or log line can leak one by accident. This is
checked, not merely intended — `infra check` asserts that formatting a loaded
credential does not contain the secret.

## Still open

- **Loopback listener or manual paste** for an OAuth2 authorization code. Not
  needed yet: both clouds authenticate with static keys, so
  `Infra.Core.Auth`'s browser flow remains unused. It becomes relevant if AWS
  SSO or a Scaleway OAuth flow is added.
- **Token refresh.** Same: static keys do not expire, so nothing refreshes.
  Temporary AWS credentials (`AWS_SESSION_TOKEN`) are *accepted* and signed
  with, but this tool will not renew them when they lapse.
- **Restricted INI and YAML readers.** The credential chain uses Linen's
  `Data.Ini` and `Data.Yaml`, which are real parsers — but see
  `docs/providers.md` for what each config format is actually relied upon to
  contain.
