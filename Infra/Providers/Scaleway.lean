import Infra.Providers.Placeholder

/-
  Scaleway. One `Backend` for the whole cloud — see the note in `Infra.Providers.Aws`.

  No live client yet; see `Infra.Providers.placeholderBackend`.
-/

namespace Infra.Providers.Scaleway

open Infra.Core

def backend : Backend := Infra.Providers.placeholderBackend "scaleway"

end Infra.Providers.Scaleway
