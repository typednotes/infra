import Infra.Providers.Placeholder

/-
  GCP, at the placeholder tier.

  The same shape as `Infra.Providers.Aws` and `Infra.Providers.Scaleway`: this
  is what an offline plan reconciles against, so it lists nothing, reports
  nothing known, and raises on any mutation — naming the kind and the cloud,
  because a create that silently does nothing is a lie.

  This is the *offline* backend, and it stays a placeholder: an offline plan
  reconciles against nothing, whichever cloud it names.

  The live one is no longer entirely absent. `.queues` is implemented over
  Pub/Sub topics — see `Infra.Providers.Gcp.PubSub` — and every other kind
  still raises from `Infra.Providers.Live`. What is live regardless of any
  backend is everything above it: GCP resources can be declared, placed,
  referenced, scheduled, diffed and exported to HCL. See `docs/coverage.md`.
-/

namespace Infra.Providers.Gcp

open Infra.Core

def backend : Backend := Infra.Providers.placeholderBackend "gcp"

end Infra.Providers.Gcp
