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

## Open questions

- Loopback listener (Option A) or manual code paste (Option B) — or both, chosen per
  provider/environment?
- Keychain (`System.Keychain`) or a config file for token storage — and if a config file,
  where does it live relative to the `.infra/state/` question raised in
  `docs/persistence.md`?
- Do AWS and Scaleway both end up using `AuthBackend`/OAuth2 at all, or does one/both use
  a separate, non-OAuth2 credential path from the start?
- Token refresh: once a token expires, is refresh handled transparently by the engine, or
  does it always re-open the browser?
