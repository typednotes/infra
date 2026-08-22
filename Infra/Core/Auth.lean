import Linen.Network.OAuth2

/-
  "Basic authentication to a service happens by opening the browser" — the settled part of
  `docs/architecture.md`'s Authentication section. What catches the redirect and where the
  resulting token is stored is undecided; see `docs/authentication.md`. Do not implement the
  OAuth callback listener or token exchange here.
-/

namespace Infra.Core

structure OAuthConfig where
  clientId          : String
  authorizeEndpoint : Network.URI.URI
  redirectUri       : Network.URI.URI
  scopes            : List String := []

/-- The URL to open in the browser to start the authorization-code flow. -/
def authorizationUrl (cfg : OAuthConfig) : Network.URI.URI :=
  let oa : Network.OAuth2.OAuth2 :=
    { oauth2ClientId := cfg.clientId
      oauth2AuthorizeEndpoint := cfg.authorizeEndpoint
      oauth2RedirectUri := cfg.redirectUri }
  Network.OAuth2.authorizationUrlWithParams [("scope", String.intercalate " " cfg.scopes)] oa

/-- Opens `url` in the user's default browser: `open` on macOS, `xdg-open` elsewhere. -/
def openBrowser (url : String) : IO Unit := do
  let cmd := if System.Platform.isOSX then "open" else "xdg-open"
  discard <| IO.Process.run { cmd := cmd, args := #[url] }

end Infra.Core
