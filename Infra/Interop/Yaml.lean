import Infra.Core.JsonExact
import Linen.Data.Yaml

/-
  A JSON value, written as block-style YAML.

  A building block, and so **pending a move to linen** (`CHANGELOG.md`,
  `[Unreleased]`): linen's `Data.Yaml` parses YAML and has no emitter. It is
  here, not there, only because a linen session was active when
  `infra render` needed it (2026-09-29); when it moves, this file is deleted
  in the same change.

  ## What it writes

  Block mappings and sequences, two spaces per level, with a sequence's `-`
  at its key's own indent — the layout `kubectl get -o yaml` prints. Scalars
  are written plain where that is unambiguous and double-quoted otherwise.

  "Unambiguous" is judged against **YAML 1.1** as well as 1.2, because the
  reader that matters is Kubernetes', and `sigs.k8s.io/yaml` resolves through
  go-yaml, which follows 1.1: there `yes`, `no`, `on`, `off`, `y` and `n` are
  booleans. A plain scalar must therefore be a string under both schemas —
  start with a letter, `_`, `.` or `/`, hold only `[A-Za-z0-9_./:@+-]`, not
  end in `:`, and not be one of those words, `true`/`false`/`null`, or
  `.inf`/`.nan`. Anything else is quoted, so `"80"`, `"1.27"` and `"on"` stay
  strings wherever they are read.

  Numbers go through `Infra.Core.JsonExact`: one linen's renderer would change
  (`1e-7` is written `0.000000`) makes `encode` fail, naming it, rather than
  write a different value.

  Checked by round-tripping through linen's own YAML parser (`#guard`s below).
-/

namespace Infra.Interop.Yaml

open Data.Json (Value)

-- ── Scalars ──

private def yaml11Reserved : List String :=
  [ "y", "n", "yes", "no", "on", "off", "true", "false", "null"
  , ".inf", "-.inf", "+.inf", ".nan" ]

private def plainChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '.' || c == '/' || c == ':' || c == '@' || c == '+'
    || c == '-'

/-- Whether `s` can be written unquoted and read back as the same string by a
    YAML 1.1 or 1.2 reader. -/
def plainSafe (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: rest =>
    (c.isAlpha || c == '_' || c == '.' || c == '/')
    && !(c == '.' && (rest.head?.map Char.isDigit).getD false)
    && rest.all plainChar
    && !s.endsWith ":"
    && !(yaml11Reserved.contains s.toLower)

private def hex4 (n : Nat) : String :=
  let digits := Nat.toDigits 16 n
  String.ofList (List.replicate (4 - digits.length) '0' ++ digits)

/-- A YAML double-quoted scalar. The escapes are the ones JSON and YAML share,
    so the result is also the JSON spelling of the string. -/
def quote (s : String) : String :=
  let esc (c : Char) : String :=
    match c with
    | '"'  => "\\\""
    | '\\' => "\\\\"
    | '\n' => "\\n"
    | '\t' => "\\t"
    | '\r' => "\\r"
    | c    => if c.toNat < 0x20 || c.toNat == 0x7f then "\\u" ++ hex4 c.toNat
              else c.toString
  "\"" ++ String.join (s.toList.map esc) ++ "\""

/-- A string, plain if it can be and quoted otherwise. -/
def scalarString (s : String) : String := if plainSafe s then s else quote s

/-- The one-line form of a value, if it has one: every scalar, and an empty
    mapping or sequence. -/
def inline? : Value → Option String
  | .null       => some "null"
  | .bool b     => some (if b then "true" else "false")
  | .number n   => some (Data.Json.Encode.renderNumber n)
  | .string s   => some (scalarString s)
  | .object []  => some "{}"
  | .object _   => none
  | .array xs   => if xs.isEmpty then some "[]" else none

-- ── Blocks ──

private def pad (n : Nat) : String := String.pushn "" ' ' n

/-- The lines of a mapping or a sequence at indent `n`. A scalar has no block
    form and yields nothing; `render` handles it. -/
def block : Value → Nat → List String
  | .object fs, n => fs.attach.flatMap fun ⟨(k, v), _⟩ =>
      let key := pad n ++ scalarString k ++ ":"
      match inline? v with
      | some s => [key ++ " " ++ s]
      | none   =>
        match v with
        -- `kubectl`'s layout: a sequence's dashes at its key's own indent.
        | .array _ => key :: block v n
        | _        => key :: block v (n + 2)
  | .array xs, n => xs.attach.toList.flatMap fun ⟨x, _⟩ =>
      match inline? x with
      | some s => [pad n ++ "- " ++ s]
      | none   =>
        match x with
        -- The compact form: the first key on the dash's line.
        | .object _ =>
          match block x (n + 2) with
          | first :: rest => (pad n ++ "- " ++ (first.drop (n + 2)).toString) :: rest
          | []            => []
        | _ => (pad n ++ "-") :: block x (n + 2)
  | _, _ => []
decreasing_by
  all_goals simp_wf
  all_goals first
    | (have := List.sizeOf_lt_of_mem ‹(_, v) ∈ fs›; simp at this; omega)
    | (have := Array.sizeOf_lt_of_mem ‹x ∈ xs›; omega)

/-- `v` as one YAML document, without a `---` marker, or why it cannot be
    written unchanged (a number the encoder would alter). -/
def encode (v : Value) : Except String String :=
  match Infra.Core.JsonExact.lossyNumbers v with
  | n :: _ => .error s!"the value holds the number {n}, which would be written as \
{Data.Json.Encode.renderNumber n} — a different value"
  | [] =>
    match inline? v with
    | some s => .ok s
    | none   => .ok (String.intercalate "\n" (block v 0))

-- ── Checks ──

/-- linen's YAML value as JSON, for the round trip. -/
def ofYaml : Data.Yaml.Value → Value
  | .null    => .null
  | .bool b  => .bool b
  | .int i   => .number (Float.ofInt i)
  | .float f => .number f
  | .str s   => .string s
  | .seq xs  => .array (xs.attach.map fun ⟨x, _⟩ => ofYaml x).toArray
  | .map kvs => .object (kvs.attach.map fun ⟨(k, x), _⟩ => (k, ofYaml x))
decreasing_by
  all_goals simp_wf
  all_goals first
    | (have := List.sizeOf_lt_of_mem ‹x ∈ xs›; omega)
    | (have := List.sizeOf_lt_of_mem ‹(k, x) ∈ kvs›; simp at this; omega)

/-- Whether `v` survives being written and read back by linen's parser. -/
def roundTrips (v : Value) : Bool :=
  match encode v with
  | .error _ => false
  | .ok text =>
    match Data.Yaml.parse text with
    | .ok y    => ofYaml y == v
    | .error _ => false

private def sample : Value :=
  .object
    [ ("apiVersion", .string "apps/v1"), ("kind", .string "Deployment")
    , ("metadata", .object [("name", .string "web"), ("namespace", .string "default"),
        ("labels", .object [("app", .string "web"), ("managed-by-infra", .string "my-fleet")])])
    , ("spec", .object
        [ ("replicas", .number 2)
        , ("template", .object [("spec", .object [("containers", .array #[.object
            [ ("name", .string "web"), ("image", .string "nginx:1.27")
            , ("ports", .array #[.object [("containerPort", .number 80)]])
            , ("env", .array #[.object [("name", .string "MODE"), ("value", .string "on")],
                               .object [("name", .string "PORT"), ("value", .string "8080")]]) ]])])])
        , ("strategy", .object []), ("args", .array #[]) ]) ]

-- The layout, exactly: nested mappings by two, dashes at their key's indent,
-- the compact `- key:` form, and ambiguous strings quoted.
#guard (encode sample).toOption = some "apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: default
  labels:
    app: web
    managed-by-infra: my-fleet
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: web
        image: nginx:1.27
        ports:
        - containerPort: 80
        env:
        - name: MODE
          value: \"on\"
        - name: PORT
          value: \"8080\"
  strategy: {}
  args: []"

-- And it reads back as the same value through linen's parser.
#guard roundTrips sample

-- Strings that would read as something else, under either schema, are quoted.
#guard ["yes", "No", "on", "OFF", "y", "true", "null", "~", "80", "1.27", ".5", ".inf",
        "", "-x", "a: b", "a:", "#x", "x #y", "*a", "&a", "!t", "{}", "[x]", "a,b", "'q'"].all
  fun s => !plainSafe s && roundTrips (.object [("k", .string s)])
#guard ["web", "nginx:1.27", "apps/v1", "rbac.authorization.k8s.io/v1", "_x", "a.b-c", "yesterday"].all
  plainSafe
-- Escapes, nesting of sequences in sequences, and every scalar type.
#guard roundTrips (.object [("s", .string "line one\nline \"two\"\t\\"),
  ("nested", .array #[.array #[.number 1, .number 2], .array #[.string "a"]]),
  ("t", .bool true), ("f", .bool false), ("z", .null), ("half", .number 0.5), ("neg", .number (-3))])
-- A key that needs quoting is quoted too.
#guard (encode (.object [("on", .string "x"), ("8080", .number 1)])).toOption
  = some "\"on\": x\n\"8080\": 1"
-- A number the encoder would change is refused, not written.
#guard (encode (.object [("x", .number 1e-7)])).toOption.isNone

end Infra.Interop.Yaml
