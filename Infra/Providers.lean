import Infra.Providers.Aws
import Infra.Providers.Scaleway
import Infra.Providers.Gcp

/-
  Every cloud the engine can reach, as one total function over `ProviderId`.
-/

namespace Infra.Providers

open Infra.Core

/-- Total over `ProviderId`, matching `Plan.assign`'s totality over the same index: adding a
    cloud means every plan and every backend lookup has to account for it. -/
def all : Backends where
  backend
    | .aws      => Aws.backend
    | .scaleway => Scaleway.backend
    | .gcp      => Gcp.backend

end Infra.Providers
