import Lean
import Infra.Core.Ergonomics
import Infra.Core.Region
import Infra.Specs.Build

/-
  Declaring a fleet without writing it down four times.

  Everything else about authoring is plain Lean: `Infra.Core.Coe` removes the
  field wrappers and `Infra.Specs.Build` supplies the defaults, so a resource
  is an ordinary function call. One thing genuinely cannot be a function,
  though — the `Keys`/`Plan` wiring, because the key type has to exist
  *before* the specs that reference it, and the key type is derived from the
  resources. Breaking that circularity is the only reason this command exists.

  Concretely, a resource's name is otherwise written three or four times: in a
  `List String` of names, in a `NamedKey.of` abbreviation, in the spec's own
  `name` field, and in a `Keys.assignFromNamed` entry — and only two of those
  are coupled by a decidable check. Here the name list is *derived* from the
  resources, so "a name missing from its own bucket" stops being expressible.

  ## What it expands to

  Calls to `Keys.build`, `NamedKey.of`, `Keys.assignFromNamed` and
  `Infra.Specs.Build.*` — the same things a hand-written fleet uses, which all
  stay public and supported for anyone who would rather not use this. Nothing
  here is a new mechanism, and no error message comes from inside a macro:
  field typos and type mismatches land on the author's own tokens, because
  every field value is spliced through unchanged.

  ## Syntax

      fleet myFleet where
        resource scaleway secrets "db-password" as dbPassword
          { valueFrom := fromEnv "DB_PASSWORD" }
        resource scaleway postgres "main" as mainDb
          { masterUsername := "dbadmin"
          , masterPasswordSecret := "db-password"
          , minCapacity := 1
          , maxCapacity := 4 }

  Fields are brace-delimited and comma-separated rather than one per bare
  line: Lean's `term` parser continues across newlines, so `x := "a"` followed
  by `y := 1` would parse as `x := "a" y` and fail confusingly.

  The string is the resource's name, and is used for all three of the spec's
  `name` field, the fleet's `Keys.name`, and the bucket's name list — so it
  cannot disagree with itself. `Keys.name` must equal the cloud's physical
  identifier, which is why it is not a separate label.

  A cloud named on every line is noise once a fleet is mostly one cloud, so
  it can be written once instead:

      fleet myFleet in paris where
        provider scaleway where
          resource secrets "db-password" as dbPassword
            { valueFrom := fromEnv "DB_PASSWORD" }
          resource postgres "main" as mainDb
            { masterUsername := "dbadmin", masterPasswordSecret := "db-password" }

  Inside a block a `resource` names only its kind. Blocks and bare
  `resource` lines mix freely and in any order, and a bare line still names
  its own cloud — this is grouping, not a mode. Nothing else changes: the
  buckets, the keys and the plan come out identical, which `Infra/Demo.lean`
  checks by declaring one fleet both ways.

  `as` is optional and only needed for a resource something else references.
  It binds an ordinary Lean identifier, so a reference is type-checked — a key
  of the wrong `Kind` is a type error — and forward references work, because
  every abbreviation is emitted before any spec.

  ## Where it is

      fleet myFleet in paris where …                        -- both clouds' Paris
      fleet myFleet in scaleway "pl-waw" where …            -- one cloud, its own code
      fleet myFleet in aws "eu-west-1", scaleway "fr-par" where …

  An entry without a string is a `Locality` and places *every* cloud the fleet
  uses; an entry with one is that cloud's own region code. A locality must come
  first, because the entries after it override one cloud each — so the clause
  reads left to right as "everywhere here, except these".

  All of it is checked while the fleet elaborates: a locality one of the
  fleet's clouds is not in, a code from the wrong cloud, a typo in a code, and
  a placement that leaves one of the fleet's clouds unplaced are each a compile
  error. See `Infra.Core.Region`.

  Omitting `in` is still allowed and still means what it always did — each
  cloud's region comes from its credentials.

  Generates `myFleet.keys : Keys`, `myFleet.plan : Plan myFleet.keys` and
  `myFleet.regions : Regions`, plus one abbreviation per `as`.
-/

namespace Infra.Core

open Lean Elab Command Term

/-- One field of a resource's spec. The value is an arbitrary term, spliced
    through unchanged so its errors point at the author's own code. -/
syntax fleetField := ident " := " term

/-- One resource. The kind is a bare identifier naming a `Kind` constructor;
    the provider is another, and may be omitted inside a `provider` block. -/
syntax fleetResource := "resource " ident (ident)? str (" as " ident)? "{" fleetField,* "}"

/-- One resource this fleet used to declare and is releasing.

    Same shape as `fleetResource` minus everything a resource needs and a
    released one does not: no fields, because nothing is being configured, and
    no `as`, because nothing can reference it. -/
syntax fleetForget := "forget " ident (ident)? str

/-- One placement: a bare identifier is a `Locality`, an identifier followed by
    a string is a cloud and its own region code. -/
syntax fleetPlace := ident (str)?

/-- Where the fleet is by default. See the module doc. -/
syntax fleetIn := " in " fleetPlace,+

/-- A fleet's body.

    A category rather than an alias because the two block forms nest: a region
    block inside a provider block, or the other way round, to whatever depth
    the declaration reads best at. -/
declare_syntax_cat fleetItem

/-- A bare resource. -/
syntax fleetResource : fleetItem

/-- A release. Legal anywhere a resource is, including inside blocks, so that
    `forget` sits next to the `resource` line it replaces. -/
syntax fleetForget : fleetItem

/-- A `provider` block: the cloud, written once, for everything under it.

    `withPosition`/`colGt` is what makes it a *block*: an item belongs to it
    only while indented past the `provider` keyword. Without that the item list
    is greedy and a block swallows every sibling that follows it — which it
    did, silently, putting a later `provider scaleway` group inside an earlier
    `in oregon` one and rejecting the fleet for a region Scaleway does not
    have. Indentation is load-bearing here, as it is in the Python `with` this
    reads like. -/
syntax withPosition("provider " ident " where " (colGt fleetItem)*) : fleetItem

/-- A region block: the place, written once, for everything under it. Scoped
    exactly like a `with` in Python — it applies to what is nested inside it
    and to nothing else. Column-sensitive for the same reason as `provider`
    above. -/
syntax withPosition("in " fleetPlace " where " (colGt fleetItem)*) : fleetItem

/-- Declare a fleet: its `Keys`, its `Plan` and its `Regions`, derived from the
    resources and from whatever `in`/`provider` context encloses each. -/
syntax (name := fleetDecl) "fleet " ident (fleetIn)? " where " fleetItem* : command

/-- One `(field := value)` named argument.

    Built as a raw node because there is no quotation for a bare named
    argument, and the whole application must then be a *single* `Term.app`
    node: named arguments are resolved against one application's head, so
    applying them one at a time yields "invalid argument name". -/
private def mkNamedArg (fieldId : Ident) (val : Term) : Syntax :=
  mkNode ``Lean.Parser.Term.namedArgument
    #[mkAtom "(", fieldId, mkAtom " := ", val, mkAtom ")"]

/-- One release with its enclosing `provider` context resolved. No place,
    because nothing is called and so nothing has to be routed here: the region
    a forgotten resource sits in is already in the ledger row being dropped. -/
private structure Rel where
  cloud : Ident
  kind  : Ident
  name  : TSyntax `str

/-- One resource with its enclosing context already resolved.

    Flattening the block structure into this before generating anything is
    what keeps the rest of the elaborator identical to the version that had no
    blocks: blocks are *scoping*, and scoping is finished by the time the
    buckets are built.
    Field named `cloud` rather than `provider`, and `binding` rather than
    `alias`: both of those are parser tokens in this file — `provider` because
    the block syntax above declares it as one — so neither can be an
    identifier here. -/
private structure Res where
  cloud   : Ident
  kind    : Ident
  name    : TSyntax `str
  binding : Option Ident
  fields  : Array (TSyntax `Infra.Core.fleetField)
  /-- The region block this sat inside, if any. -/
  place   : Option (Ident × Option (TSyntax `str))

/-- Walk the body, carrying the enclosing `provider` and `in` context down.

    The context-manager reading, exactly: an item sees the blocks it is nested
    inside and nothing else, and an inner block overrides an outer one of the
    same sort. -/
private partial def flatten (ctxProvider : Option Ident)
    (ctxPlace : Option (Ident × Option (TSyntax `str))) (item : Syntax) :
    CommandElabM (Array Res × Array Rel) := do
  match item with
  | `(fleetItem| provider $p:ident where $is*) => flattenAll (some p) ctxPlace is
  | `(fleetItem| in $pl:fleetPlace where $is*) =>
    let some (a, c) := parsePlace pl | throwErrorAt pl "malformed placement"
    -- `in aws "eu-west-1"` names a cloud as well as a region, so it supplies
    -- the provider context too — the code could not mean anything otherwise.
    let inner := match c with | some _ => some a | none => ctxProvider
    flattenAll inner (some (a, c)) is
  | `(fleetItem| $f:fleetForget) =>
    match f with
    | `(fleetForget| forget $a:ident $[$b:ident]? $nm:str) =>
      match b, ctxProvider with
      | some k, _      => return (#[], #[⟨a, k, nm⟩])
      | none,   some p => return (#[], #[⟨p, a, nm⟩])
      | none,   none   => throwErrorAt f s!"this `forget` names only a kind, so it needs \
a provider: write `forget <provider> {a.getId} …`, or put it inside a `provider … where` block"
    | _ => throwErrorAt f "malformed forget declaration"
  | `(fleetItem| $r:fleetResource) =>
    match r with
    | `(fleetResource| resource $a:ident $[$b:ident]? $nm:str $[as $al:ident]? { $fs,* }) =>
      match b, ctxProvider with
      -- `resource scaleway secrets "x"` — the cloud is on the line.
      | some k, _      => return (#[⟨a, k, nm, al, fs.getElems, ctxPlace⟩], #[])
      -- `resource secrets "x"` — the cloud comes from an enclosing block.
      | none,   some p => return (#[⟨p, a, nm, al, fs.getElems, ctxPlace⟩], #[])
      | none,   none   => throwErrorAt r s!"this resource names only a kind, so it needs \
a provider: write `resource <provider> {a.getId} …`, or put it inside a `provider … where` \
or `in <provider> \"<region>\" … where` block"
    | _ => throwErrorAt r "malformed resource declaration"
  | _ => throwErrorAt item "malformed fleet item"
where
  /-- Both block arms and the top level do the same thing to a list of items,
      and each used to spell out its own two-accumulator loop. -/
  flattenAll (ctxP : Option Ident) (ctxPl : Option (Ident × Option (TSyntax `str)))
      (is : Array Syntax) : CommandElabM (Array Res × Array Rel) := do
    let parts ← is.mapM (flatten ctxP ctxPl)
    return (parts.flatMap (·.1), parts.flatMap (·.2))
  /-- `paris` or `aws "eu-west-3"`. -/
  parsePlace (pl : Syntax) : Option (Ident × Option (TSyntax `str)) :=
    match pl with
    | `(fleetPlace| $a:ident $[$c:str]?) => some (a, c)
    | _ => none

elab_rules : command
  | `(command| fleet $fleetName:ident $[$placement:fleetIn]? where $items*) => do
    -- Blocks are resolved first, so everything below sees a flat list of
    -- resources that each know their own cloud and their own place.
    let parts ← items.mapM (flatten none none)
    let flat := parts.flatMap (·.1)
    let released := parts.flatMap (·.2)

    -- Group resources by `(provider, kind)`, preserving declaration order —
    -- which is also the key order within a bucket.
    let mut buckets :
        Array (Ident × Ident ×
          Array (TSyntax `str × Option Ident × Array (TSyntax `Infra.Core.fleetField))) := #[]
    for r in flat do
      let entry := (r.name, r.binding, r.fields)
      match buckets.findIdx? (fun b =>
          b.1.getId == r.cloud.getId && b.2.1.getId == r.kind.getId) with
      | some i =>
        let b := buckets[i]!
        buckets := buckets.set! i (b.1, b.2.1, b.2.2.push entry)
      | none => buckets := buckets.push (r.cloud, r.kind, #[entry])

    -- The name-list identifier is a pure function of the bucket, so it is
    -- recomputed where needed rather than kept in an array that has to stay
    -- index-aligned with `buckets`.
    let nameId := fun (p k : Ident) =>
      mkIdentFrom fleetName (fleetName.getId ++ `names ++ p.getId ++ k.getId)
    -- `matchAltExpr` coerces to `matchAlt`, but not through the antiquotation,
    -- so the cast is spelled once here instead of at each of four sites.
    let alt := fun (a : TSyntax ``Lean.Parser.Term.matchAltExpr) =>
      (⟨a.raw⟩ : TSyntax ``Lean.Parser.Term.matchAlt)
    let keysId    := mkIdentFrom fleetName (fleetName.getId ++ `keys)
    let tableId   := mkIdentFrom fleetName (fleetName.getId ++ `table)
    let planId    := mkIdentFrom fleetName (fleetName.getId ++ `plan)
    let regionsId := mkIdentFrom fleetName (fleetName.getId ++ `regions)

    -- 1. One name list per bucket. `KeySpec.named`'s `namesNodup` auto-param
    --    is checked against these, so a duplicate name fails at elaboration.
    let mut cmds : Array (TSyntax `command) := #[]
    for (p, k, entries) in buckets do
      let strs := entries.map (·.1)
      cmds := cmds.push (← `(def $(nameId p k) : List String := [$strs,*]))

    -- 2. The table, then the `Keys`. Buckets not declared are `.unused`, which
    --    is what leaves everything else in the account alone, unconditionally.
    let mut tableAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    for (p, k, _) in buckets do
      tableAlts := tableAlts.push (alt (← `(Lean.Parser.Term.matchAltExpr|
        | .$p:ident, .$k:ident => Infra.Core.KeySpec.named $(nameId p k))))
    tableAlts := tableAlts.push (alt (← `(Lean.Parser.Term.matchAltExpr|
      | _, _ => Infra.Core.KeySpec.unused)))
    cmds := cmds.push (← `(
      def $tableId : Infra.Core.ProviderId → Infra.Core.Kind → Infra.Core.KeySpec :=
        fun p k => match p, k with $tableAlts:matchAlt*))
    cmds := cmds.push (← `(
      def $keysId : Infra.Core.Keys := Infra.Core.Keys.build $tableId))

    -- 3. Where it is. No `in` clause means the empty placement, which is what
    --    every fleet had before this existed: each cloud's region comes from
    --    its credentials. A clause that says *something* is held to saying it
    --    about every cloud the fleet uses — that is `Regions.covering`, and it
    --    is the check a per-cloud list would otherwise let you skip by
    --    forgetting a cloud.
    let mut placeTerm : Term ← `(({} : Infra.Core.Regions))
    -- A lone locality needs no coverage check: `everywhere`'s own obligation
    -- already says every cloud the fleet uses is there, so wrapping it would
    -- only report the same mistake twice.
    let mut perCloud := false
    if let some clause := placement then
      match clause with
      | `(fleetIn| in $places,*) =>
        let elems := places.getElems
        for i in [0 : elems.size] do
          match elems[i]! with
          | `(fleetPlace| $p:ident $[$c:str]?) =>
            match c with
            -- A cloud and its own code: overrides just that cloud.
            | some code =>
              perCloud := true
              placeTerm ← `(($placeTerm).set (Infra.Core.Region.of .$p:ident $code))
            -- A locality: places every cloud at once, so it replaces rather
            -- than overrides, and may only be the first entry. Allowing it
            -- later would silently discard the entries before it.
            | none =>
              unless i == 0 do
                throwErrorAt elems[i]! s!"a locality must be the first entry of an `in` \
clause: it places every cloud, so anything before it would be discarded. Write \
`in {p.getId}` first and override single clouds after it."
              placeTerm ← `(Infra.Core.Regions.everywhere $keysId .$p:ident)
          | pl => throwErrorAt pl "malformed placement"
      | _ => throwErrorAt clause "malformed `in` clause"
    -- Then every region block, as a per-slot override on top of that. A block
    -- naming a locality resolves it per cloud, so `in paris` over an AWS
    -- resource and a Scaleway one gives `eu-west-3` and `fr-par` — and fails
    -- to elaborate over a resource in a cloud that is not there.
    for r in flat do
      if let some (a, c) := r.place then
        let region : Term ← match c with
          | some code =>
            unless a.getId == r.cloud.getId do
              throwErrorAt r.name s!"this resource is in `{r.cloud.getId}`, but the block \
around it names a `{a.getId}` region; a region code belongs to one cloud"
            `(Infra.Core.Region.of .$a:ident $code)
          | none => `(Infra.Core.Locality.region .$a:ident .$(r.cloud):ident)
        -- Deliberately does *not* set `perCloud`: `Regions.covering` is a
        -- cloud-level check, and a resource in a block is placed by
        -- construction, so there is nothing for it to add here. See
        -- `Regions.covers` for why it cannot be per-slot.
        placeTerm ← `(($placeTerm).setSlot .$(r.kind):ident $(r.name) $region)
    if perCloud then
      placeTerm ← `(Infra.Core.Regions.covering $keysId $placeTerm)
    cmds := cmds.push (← `(def $regionsId : Infra.Core.Regions := $placeTerm))

    -- 4. Every `as` abbreviation, all of them before any spec, so a resource
    --    may reference one declared later in the block.
    for (p, k, entries) in buckets do
      for (nm, al, _) in entries do
        if let some a := al then
          cmds := cmds.push (← `(
            abbrev $a : ($keysId).Key .$p:ident .$k:ident :=
              Infra.Core.NamedKey.of $(nameId p k) $nm))

    -- 5. The plan: one `assignFromNamed` bucket per row, plus the total
    --    `.unmanaged` fallback for every pair this fleet does not declare.
    let mut assignAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    for (p, k, entries) in buckets do
      let mut pairs : Array Term := #[]
      for (nm, _, fields) in entries do
        -- `name` comes from the declaration's own label, never written twice.
        let mut args : Array Syntax := #[mkNamedArg (mkIdent `name) nm]
        for f in fields do
          match f with
          | `(fleetField| $fid:ident := $v:term) =>
            args := args.push
              (mkNamedArg (mkIdentFrom fid fid.getId.eraseMacroScopes) v)
          | _ => throwErrorAt f "malformed field"
        let call : Term := ⟨mkNode ``Lean.Parser.Term.app
          #[mkIdent (`Infra.Specs.Build ++ k.getId), mkNullNode args]⟩
        pairs := pairs.push (← `(($nm, Infra.Core.Status.present $call)))
      assignAlts := assignAlts.push (alt (← `(Lean.Parser.Term.matchAltExpr|
        | .$p:ident, .$k:ident =>
            Infra.Core.Keys.assignFromNamed (κ := $keysId) .$p:ident .$k:ident [$pairs,*])))
    assignAlts := assignAlts.push (alt (← `(Lean.Parser.Term.matchAltExpr|
      | _, _ => fun _ => Infra.Core.Status.unmanaged)))
    cmds := cmds.push (← `(
      def $planId : Infra.Core.Plan $keysId where
        assign := fun p k => match p, k with $assignAlts:matchAlt*))

    -- `forget` declarations, as the triples `Infra.Cli.run` and
    -- `Action.actionsOrphaned` consume.
    --
    -- Each carries a decidable side-condition that the name is *not* one this
    -- fleet still declares, discharged here by `by decide`. So `forget`ting
    -- something you also declare does not elaborate, and the two statements
    -- can never both be in force. Without it the plan would say "manage this"
    -- and "stop managing this" at once, and which won would depend on the
    -- order of two passes.
    let forgetsId := mkIdentFrom fleetName (fleetName.getId ++ `forgets)
    let forgetTerms : Array Term ← released.mapM fun r =>
      `((Infra.Core.releasing $keysId .$(r.cloud):ident .$(r.kind):ident $(r.name)))
    cmds := cmds.push (← `(
      def $forgetsId : List (Infra.Core.Released $keysId) :=
        [$forgetTerms,*]))

    for c in cmds do
      elabCommand c

end Infra.Core
