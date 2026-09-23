/-
  Which tables a piece of SQL creates, and which it references.

  This is how `infra` orders two migration histories on one database without
  being told: a history whose SQL says `references orgs(id)` must apply after
  the history whose SQL says `create table orgs`. The foreign key already
  states the dependency, so declaring it a second time (the `after` field
  0.14.0 was first drafted with) would be a copy that can drift.

  ## Conservative by design

  This is a scanner, not a SQL parser. It recognises exactly two shapes:

      CREATE [OR REPLACE] [GLOBAL|LOCAL] [TEMP|TEMPORARY|UNLOGGED] TABLE [IF NOT EXISTS] name
      REFERENCES name

  where `name` is `ident` or `ident.ident`, each part plain (folded to lower
  case, as Postgres does) or `"quoted"` (kept as written). Comments
  (`--`, nested `/* */`), string literals (`'…'` with `''`) and dollar-quoted
  bodies (`$$…$$`, `$tag$…$tag$`) are skipped, so a `references` inside a
  function body or a comment creates no edge.

  What it cannot see is handled by *refusing*, never by guessing: the plan
  check in `Fleet.lean` (`Plan.migrationDepsProblem`) rejects a reference to
  a table no declared history on that database creates, and a table two
  histories create. So a dependency this scanner misses — a table created
  inside a `DO` block, say — surfaces as an error naming the table, not as a
  silently missing edge. Dependencies that are not foreign keys at all
  (views, functions, seed data) are outside what the SQL states; a service
  whose *code* needs another's tables says so on its container
  (`migrations` lists every history the rollout waits for).

  An unqualified name means schema `public`: `infra` never sets
  `search_path` (and Scaleway's Serverless SQL warns that `SET search_path`
  leaks across pooled connections), so that is what Postgres resolves it to.
  Temporary tables are not recorded — they do not outlive the session.
-/

namespace Infra.Core.SqlDeps

/-- A token of the little language this module reads. -/
inductive Tok where
  /-- An unquoted word — keyword, identifier or number — folded to lower case. -/
  | word (s : String)
  /-- A `"quoted"` identifier, exactly as written. -/
  | quoted (s : String)
  /-- Any other single character that matters, like `.` or `(`. -/
  | punct (c : Char)
  deriving Repr, DecidableEq, BEq

private inductive Mode where
  | normal | word | dash | slash | lineComment | blockComment
  | squote | squoteEnd | dquote | dquoteEnd | dollarTag | dollarBody
  deriving DecidableEq

private structure St where
  mode  : Mode := .normal
  cur   : String := ""
  toks  : Array Tok := #[]
  prev  : Char := ' '
  depth : Nat := 0
  tag   : String := ""
  tail  : String := ""

private def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'
private def isIdentChar (c : Char) : Bool := c.isAlphanum || c == '_' || c == '$'

/-- What a character does when nothing is pending. Every transition out of
    a multi-character construct ends here, so none of them recurses. -/
private def stepNormal (s : St) (c : Char) : St :=
  if c.isWhitespace then { s with mode := .normal }
  else if isIdentStart c || c.isDigit then { s with mode := .word, cur := c.toLower.toString }
  else if c == '\'' then { s with mode := .squote }
  else if c == '"' then { s with mode := .dquote, cur := "" }
  else if c == '$' then { s with mode := .dollarTag, tag := "" }
  else if c == '-' then { s with mode := .dash }
  else if c == '/' then { s with mode := .slash }
  else { s with mode := .normal, toks := s.toks.push (.punct c) }

private def flushWord (s : St) : St :=
  { s with toks := s.toks.push (.word s.cur), cur := "" }

private def step (s : St) (c : Char) : St :=
  match s.mode with
  | .normal => stepNormal s c
  | .word =>
    if isIdentChar c then { s with cur := s.cur.push c.toLower }
    else stepNormal (flushWord s) c
  | .dash =>
    if c == '-' then { s with mode := .lineComment }
    else stepNormal { s with toks := s.toks.push (.punct '-') } c
  | .slash =>
    if c == '*' then { s with mode := .blockComment, depth := 1, prev := ' ' }
    else stepNormal { s with toks := s.toks.push (.punct '/') } c
  | .lineComment => if c == '\n' then { s with mode := .normal } else s
  | .blockComment =>
    -- Postgres block comments nest. `prev` is reset after a pair is
    -- consumed, so `/*/` does not count its `*` twice.
    if s.prev == '*' && c == '/' then
      if s.depth ≤ 1 then { s with mode := .normal, depth := 0, prev := ' ' }
      else { s with depth := s.depth - 1, prev := ' ' }
    else if s.prev == '/' && c == '*' then { s with depth := s.depth + 1, prev := ' ' }
    else { s with prev := c }
  | .squote => if c == '\'' then { s with mode := .squoteEnd } else s
  | .squoteEnd =>
    -- `''` inside a string is an escaped quote; anything else ended it.
    if c == '\'' then { s with mode := .squote } else stepNormal { s with mode := .normal } c
  | .dquote => if c == '"' then { s with mode := .dquoteEnd } else { s with cur := s.cur.push c }
  | .dquoteEnd =>
    if c == '"' then { s with mode := .dquote, cur := s.cur.push '"' }
    else stepNormal { s with toks := s.toks.push (.quoted s.cur), cur := "" } c
  | .dollarTag =>
    if c == '$' then { s with mode := .dollarBody, tail := "" }
    else if isIdentChar c && c != '$' && !(s.tag.isEmpty && c.isDigit) then
      { s with tag := s.tag.push c }
    else
      -- Not a dollar quote after all (`$1`, a lone `$`): nothing to skip.
      stepNormal { s with mode := .normal } c
  | .dollarBody =>
    let close := "$" ++ s.tag ++ "$"
    let grown := (s.tail.push c).toList
    -- Only the last `close.length` characters can ever complete the tag.
    let tail := String.ofList (grown.drop (grown.length - close.length))
    if tail == close then { s with mode := .normal, tail := "" } else { s with tail }

/-- The tokens of `sql`, with comments, strings and dollar-quoted bodies
    removed. Total: one pass over the characters, no recursion. -/
def tokens (sql : String) : List Tok :=
  let s := sql.foldl step {}
  let s := match s.mode with
    | .word      => flushWord s
    | .dquoteEnd => { s with toks := s.toks.push (.quoted s.cur) }
    | _          => s
  s.toks.toList

/-- A table name, schema-qualified: `public` when the SQL did not say. -/
structure TableName where
  schema : String
  name   : String
  deriving Repr, DecidableEq, BEq

instance : ToString TableName := ⟨fun t => s!"{t.schema}.{t.name}"⟩

private def identOf : Tok → Option String
  | .word s   => some s
  | .quoted s => some s
  | .punct _  => none

/-- A (possibly qualified) name at the head of `ts`, and what follows it. -/
private def nameAt : List Tok → Option (TableName × List Tok)
  | a :: .punct '.' :: b :: rest =>
    match identOf a, identOf b with
    | some sch, some n => some ({ schema := sch, name := n }, rest)
    | _, _             => none
  | a :: rest => (identOf a).map fun n => ({ schema := "public", name := n }, rest)
  | [] => none

/-- After `create`: skip the modifiers that may precede `table`. Returns
    whether the table is temporary, and the tokens after `table`, if this is
    a `create … table` at all. -/
private def afterCreate : List Tok → Bool → Option (Bool × List Tok)
  | .word "or" :: .word "replace" :: rest, temp => afterCreate rest temp
  | .word "global" :: rest, temp    => afterCreate rest temp
  | .word "local" :: rest, temp     => afterCreate rest temp
  | .word "unlogged" :: rest, temp  => afterCreate rest temp
  | .word "temp" :: rest, _         => afterCreate rest true
  | .word "temporary" :: rest, _    => afterCreate rest true
  | .word "table" :: rest, temp     => some (temp, rest)
  | _, _ => none

private def skipIfNotExists : List Tok → List Tok
  | .word "if" :: .word "not" :: .word "exists" :: rest => rest
  | ts => ts

/-- Every table `sql` creates (temporary ones excepted), in order. -/
def creates (sql : String) : List TableName :=
  go (tokens sql) []
where
  go : List Tok → List TableName → List TableName
    | [], acc => acc.reverse
    | .word "create" :: rest, acc =>
      match afterCreate rest false with
      | some (temp, afterTable) =>
        match nameAt (skipIfNotExists afterTable) with
        | some (t, _) => go rest (if temp then acc else t :: acc)
        | none        => go rest acc
      | none => go rest acc
    | _ :: rest, acc => go rest acc

/-- Every table `sql` references through a foreign key, in order. -/
def references (sql : String) : List TableName :=
  go (tokens sql) []
where
  go : List Tok → List TableName → List TableName
    | [], acc => acc.reverse
    | .word "references" :: rest, acc =>
      match nameAt rest with
      | some (t, _) => go rest (t :: acc)
      | none        => go rest acc
    | _ :: rest, acc => go rest acc

/-! ## Guards

  The shapes that matter, pinned — including the ones that must *not* count. -/

private def pub (n : String) : TableName := { schema := "public", name := n }

-- The plain cases, and the real schemas this was written for.
#guard creates "create table orgs (id uuid primary key)" = [pub "orgs"]
#guard references "org_id uuid not null references orgs(id)" = [pub "orgs"]
#guard creates "CREATE TABLE IF NOT EXISTS svc.events (id text)" = [{ schema := "svc", name := "events" }]
#guard references "event text REFERENCES svc.events(id)" = [{ schema := "svc", name := "events" }]
#guard creates "create unlogged table cache (k text)" = [pub "cache"]
#guard references "alter table a add constraint fk foreign key (b) references b (id)" = [pub "b"]

-- Unquoted names fold to lower case; quoted ones do not.
#guard creates "CREATE TABLE Orgs ()" = [pub "orgs"]
#guard creates "create table \"Orgs\" ()" = [pub "Orgs"]
#guard creates "create table \"a\"\"b\" ()" = [pub "a\"b"]

-- Temporary tables do not outlive their session, so they create nothing.
#guard creates "create temporary table t (x int); create temp table u (y int)" = []

-- Comments, strings and dollar-quoted bodies are not SQL to this scanner.
#guard references "-- references orgs(id)\nselect 1" = []
#guard references "/* references orgs /* nested */ still comment */ select 1" = []
#guard references "select 'references orgs(id)', 'it''s references x'" = []
#guard creates "do $$ begin create table hidden (x int); end $$" = []
#guard creates "do $body$ begin execute 'x'; end $body$; create table seen ()" = [pub "seen"]

-- `$1` is a parameter, not the start of a dollar quote.
#guard references "insert into t values ($1) ; alter table t add foreign key (x) references u(id)" = [pub "u"]

-- The ledger's real shape: two creates, and references into core's tables
-- and into its own.
#guard references "create table credit_ledger (org_id uuid not null references orgs(id), \
  usage_event uuid references usage_events(id))" = [pub "orgs", pub "usage_events"]

end Infra.Core.SqlDeps
