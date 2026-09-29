import Linen.Data.Json.Decode

/-
  Reading JSON replies: the two list reads infra needs beyond linen's.

  Scalar reads are linen's — `Data.Json.Value.lookup` for a field, and the
  lenient `lookupText` / `lookupNat` / `lookupBool`, which accept a number or
  boolean whether or not the API quoted it. So is the one write,
  `Data.Json.Value.setField`, which GCP's `setIamPolicy` edit rests on. All
  four lived here (`field`, `stringField`, `natField`, `boolField`,
  `setField`) until linen 1.8.0 took them; this module keeps only what no
  other sibling has asked for.
-/

namespace Infra.Providers.JsonRead

open Data.Json (Value)

/-- A field as a list. Missing or non-array fields give `[]`, since every
    caller here treats "absent" and "empty" alike. -/
def arrayField (v : Value) (k : String) : List Value :=
  match v.lookup k with
  | some (.array xs) => xs.toList
  | _                => []

/-- The strings of an array field, dropping anything that is not one. -/
def stringArrayField (v : Value) (k : String) : List String :=
  (arrayField v k).filterMap fun
    | .string s => some s
    | _         => none

end Infra.Providers.JsonRead
