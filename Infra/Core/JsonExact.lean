import Linen.Data.Json.Encode
import Linen.Data.Json.Decode

/-
  Encoding JSON without changing it.

  linen's `Data.Json.Encode.renderNumber` writes an integer-valued number
  exactly and any other number through `Float.toString`, which keeps six
  digits after the point: `0.5` is `0.500000` (the same value), but
  `1.23456789` is `1.234568` and `1e-7` is `0.000000` — a non-zero number sent
  as zero. (linen v1.8.0, read 2026-09-29; the fix belongs in linen's
  renderer, and is listed in `CHANGELOG.md` under `[Unreleased]`.)

  Until it is fixed there, infra never sends such a body. Every request body
  and the Terraform export are encoded through `encodeExact` (via
  `encodeOrThrow`), which refuses a value holding a number the encoder would
  change, and names the number; a raw Kubernetes manifest holding one is
  refused at plan time too (`ObjectShape.problem`), so a declaration finds out
  from its own `#guard` rather than from a run.

  The test is behavioural — encode, decode, compare — not a guess at which
  numbers are safe, so it stays right if linen's renderer changes, and
  `lossyNumbers` of every value becomes `[]` the day it is fixed.
-/

namespace Infra.Core.JsonExact

open Data.Json (Value)

/-- Whether `n` reads back as itself after linen renders it. `false` for NaN
    and the infinities, which render as `null`. -/
def survives (n : Float) : Bool :=
  match Data.Json.Decode.decode (Data.Json.Encode.renderNumber n) with
  | .ok (.number m) => m == n
  | _               => false

/-- Every number in `v` that `survives` refuses, in document order. -/
def lossyNumbers : Value → List Float
  | .number n  => if survives n then [] else [n]
  | .array xs  => xs.attach.toList.flatMap fun ⟨x, _⟩ => lossyNumbers x
  | .object fs => fs.attach.flatMap fun ⟨(_, x), _⟩ => lossyNumbers x
  | _          => []
decreasing_by
  all_goals simp_wf
  · have := Array.sizeOf_lt_of_mem ‹x ∈ xs›; omega
  · have := List.sizeOf_lt_of_mem ‹(_, x) ∈ fs›; simp at this; omega

/-- `v` as JSON text, or why it cannot be sent unchanged. `what` names the
    request, for the message. -/
def encodeExact (what : String) (v : Value) : Except String String :=
  match lossyNumbers v with
  | [] => .ok (Data.Json.Encode.encode v)
  | n :: rest =>
    let more := if rest.isEmpty then "" else s!" (and {rest.length} more)"
    .error s!"{what}: the JSON holds the number {n}{more}, which the encoder would write as \
{Data.Json.Encode.renderNumber n} — a different value — so it was not sent. Write it as a \
string, or as an integer in smaller units"

/-- `encodeExact`, raising. -/
def encodeOrThrow (what : String) (v : Value) : IO String :=
  match encodeExact what v with
  | .ok s    => pure s
  | .error e => throw (IO.userError e)

-- Integers, and numbers whose six-decimal rendering is the same value, pass.
#guard [0, 1, 42, 1000, 0.5, 0.25, 0.1, 1e21].all survives
-- Numbers the encoder changes do not — `1e-7` would be sent as zero.
#guard ![1.23456789, 1e-7, 3.14159265358979].any survives
#guard ![(0.0 / 0.0 : Float), (1.0 / 0.0 : Float)].any survives
-- Found wherever they are nested, and only those.
#guard lossyNumbers (.object [("a", .array #[.number 1, .object [("b", .number 1e-7)]]),
                              ("c", .number 0.5), ("d", .string "1e-7")]) = [1e-7]
#guard (encodeExact "t" (.object [("n", .number 3), ("x", .number 0.5)])).toOption
  = some "{\"n\":3,\"x\":0.500000}"
#guard (encodeExact "t" (.object [("x", .number 1e-7)])).toOption.isNone

end Infra.Core.JsonExact
