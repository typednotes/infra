/-
  Object identity, independent of `Diffable` and of any future persistence format
  (see `docs/persistence.md`).
-/

namespace Infra.Core

structure ObjectKey where
  provider : String
  service  : String
  id       : String
deriving Repr

class Keyed (α : Type) where
  key : α → ObjectKey

end Infra.Core
