import Infra.Providers.Placeholder

/-
  GCP, at the placeholder tier.

  The same shape as `Infra.Providers.Aws` and `Infra.Providers.Scaleway`: this
  is what an offline plan reconciles against, so it lists nothing, reports
  nothing known, and raises on any mutation — naming the kind and the cloud,
  because a create that silently does nothing is a lie.

  The live GCP backend is not written yet. What *is* live from day one is
  everything above the backend: GCP resources can be declared, placed,
  referenced, scheduled, diffed and exported to HCL, because none of that
  depends on a backend existing. See `docs/coverage.md`.
-/

namespace Infra.Providers.Gcp

open Infra.Core

def backend : Backend := Infra.Providers.placeholderBackend "gcp"

end Infra.Providers.Gcp
