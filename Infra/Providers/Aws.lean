import Infra.Providers.Placeholder

/-
  AWS. One `Backend` for the whole cloud, rather than one module per service: the
  service-by-service abstraction now lives in `Kind`/`SpecOf`, which is provider-independent,
  so a provider has nothing left to abstract — only CRUD to implement.

  No live client yet; see `Infra.Providers.placeholderBackend`.
-/

namespace Infra.Providers.Aws

open Infra.Core

def backend : Backend := Infra.Providers.placeholderBackend "aws"

end Infra.Providers.Aws
