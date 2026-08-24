import Linen.Data.Json.Decode

/-
  Reading JSON replies.

  Shared by both JSON dialects — AWS-JSON and Scaleway's REST API — because
  pulling a named field out of a reply is the same job either way. These lived
  in the Scaleway client until the SQS mapping needed them too, which made the
  placement wrong: SQS is an AWS protocol.

  Deliberately lenient about scalar types. Cloud APIs are inconsistent about
  whether a number or a boolean arrives quoted, and a caller reading an
  identifier should not have to care.
-/

namespace Infra.Providers.JsonRead

open Data.Json (Value)

/-- A field of a JSON object, or `none` if this is not an object or has no such
    field. -/
def field (v : Value) (k : String) : Option Value :=
  match v with
  | .object fields => (fields.find? (·.1 == k)).map (·.2)
  | _              => none

/-- A field as text, rendering numbers and booleans rather than rejecting
    them. -/
def stringField (v : Value) (k : String) : Option String :=
  match field v k with
  | some (.string s) => some s
  | some (.number n) => some (toString n)
  | some (.bool b)   => some (if b then "true" else "false")
  | _                => none

/-- A field as a natural number, accepting both `3` and `"3"`. -/
def natField (v : Value) (k : String) : Option Nat :=
  match field v k with
  | some (.number n) => some n.toUInt64.toNat
  | some (.string s) => s.toNat?
  | _                => none

/-- A field as a boolean, accepting both `true` and `"true"`. -/
def boolField (v : Value) (k : String) : Option Bool :=
  match field v k with
  | some (.bool b)   => some b
  | some (.string s) => if s == "true" then some true
                        else if s == "false" then some false
                        else none
  | _                => none

/-- A field as a list. Missing or non-array fields give `[]`, since every
    caller here treats "absent" and "empty" alike. -/
def arrayField (v : Value) (k : String) : List Value :=
  match field v k with
  | some (.array xs) => xs.toList
  | _                => []

/-- The strings of an array field, dropping anything that is not one. -/
def stringArrayField (v : Value) (k : String) : List String :=
  (arrayField v k).filterMap fun
    | .string s => some s
    | _         => none

/-- A whole value as text, for elements of a string array. -/
def asString (v : Value) : Option String :=
  match v with
  | .string s => some s
  | .number n => some (toString n)
  | .bool b   => some (if b then "true" else "false")
  | _         => none

end Infra.Providers.JsonRead
