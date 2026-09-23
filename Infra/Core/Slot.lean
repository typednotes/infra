import Infra.Core.Kind
import Infra.Core.Finite

/-
  How a resource is addressed outside the key family.

  A key (`κ.Key p k`) can only name what the declaration names. Two things need
  to name resources it does not: an action on an undeclared resource carrying
  this fleet's marker (which `push` destroys), and every plan line, which must
  print the same string whichever of the two produced it.
-/

namespace Infra.Core

/-- A stable identifier for a resource slot, `cloud/kind/name`. A string, so
    steps of different kinds can share one list — the dependent key cannot. -/
def slotId (p : ProviderId) (k : Kind) (name : String) : String :=
  s!"{p.name}/{k.name}/{name}"

/-- A resource carrying this fleet's marker that the declaration does not name
    — found by asking the cloud (`Engine.claimUndeclared`), and destroyed by
    `push`.

    `region` is where it was found, which is what routes the delete
    (`Backends.backendAt`): a name the placement table no longer holds cannot
    be placed by it. Named `cloud`, not `provider`, because `provider` is a
    parser token of the `fleet` command. -/
structure Orphan where
  cloud  : ProviderId
  kind   : Kind
  name   : String
  region : String
  deriving Repr, DecidableEq, BEq

def Orphan.slot (o : Orphan) : String := slotId o.cloud o.kind o.name

/-- Names parsed back from the same table that writes them. -/
def providerOfName? (s : String) : Option ProviderId :=
  (Finite.elems (α := ProviderId)).find? fun p => p.name == s

def kindOfName? (s : String) : Option Kind :=
  (Finite.elems (α := Kind)).find? fun k => k.name == s

end Infra.Core
