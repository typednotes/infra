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

/-- Rewrite one field of a JSON object, leaving every other field — and their
    order — exactly as they were. Appends the field if it is absent.

    The one *writing* helper in a module about reading, and it is here because
    the reason it exists is a reading problem: Google's `setIamPolicy` takes
    back the whole policy object it just handed out, `etag`, `auditConfigs`
    and any field this library has never heard of included, and a rewrite that
    reconstructs the object from the fields it understands **deletes the
    rest**. For a project's IAM policy that means removing other identities'
    access. So the edit is a surgical replacement of one key rather than a
    reconstruction, and nothing outside `bindings` is ever touched.

    Belongs in `linen` alongside the rest of `Data.Json.Value` — noted in
    `CHANGELOG.md`'s pending moves. -/
def setField (v : Value) (k : String) (x : Value) : Value :=
  match v with
  | .object fields =>
    if fields.any (·.1 == k) then
      .object (fields.map fun f => if f.1 == k then (k, x) else f)
    else
      .object (fields ++ [(k, x)])
  | other => other

/- The property the GCP policy edit rests on: everything else survives. -/
#guard setField (.object [("a", .string "1"), ("b", .string "2")]) "b" (.string "9")
     = .object [("a", .string "1"), ("b", .string "9")]
#guard setField (.object [("a", .string "1")]) "b" (.string "2")
     = .object [("a", .string "1"), ("b", .string "2")]

end Infra.Providers.JsonRead
