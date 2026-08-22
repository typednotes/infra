import Infra.Core.Auth

/-
  Authentication, abstracted across backends (`docs/architecture.md`'s Abstractions section).
  Deliberately not forcing every provider through OAuth2 (Scaleway may just use API keys) —
  this is why `AuthBackend` exposes `Infra.Core.OAuthConfig` rather than owning a `Diffable`
  pair of its own: there's no target/current state to reconcile, only a way to start a login.
-/

namespace Infra.Abstractions

class AuthBackend (α : Type) where
  config : α → Infra.Core.OAuthConfig

end Infra.Abstractions
