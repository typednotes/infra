import Infra.Abstractions.Secrets

/-
  Scaleway secret management, backed entirely by `Infra.Abstractions.Secrets` — see
  `docs/architecture.md`'s Abstractions section. No live Scaleway client yet: `Backend` is an
  empty placeholder handle and every method returns an honest placeholder value.
-/

namespace Infra.Providers.Scaleway.Secrets

open Infra.Abstractions
open Infra.Core

structure Backend where

instance : SecretsBackend Backend where
  listSecrets _ := pure []
  createSecret _ t := pure { name := t.name.getD "unnamed", id := "placeholder-id", value := t.value.getD "" }
  updateSecret _ c d := pure (Diffable.apply (Target := SecretTarget) c d)
  deleteSecret _ _ := pure ()

end Infra.Providers.Scaleway.Secrets
