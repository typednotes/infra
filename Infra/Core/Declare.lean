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

/-- One resource. Provider and kind are bare identifiers naming `ProviderId`
    and `Kind` constructors. -/
syntax fleetResource := "resource " ident ident str (" as " ident)? "{" fleetField,* "}"

/-- One placement: a bare identifier is a `Locality`, an identifier followed by
    a string is a cloud and its own region code. -/
syntax fleetPlace := ident (str)?

/-- Where the fleet is. See the module doc. -/
syntax fleetIn := " in " fleetPlace,+

/-- Declare a fleet: its `Keys`, its `Plan` and its `Regions`, derived from the
    resources and the optional `in` clause. -/
syntax (name := fleetDecl) "fleet " ident (fleetIn)? " where " fleetResource* : command

/-- One `(field := value)` named argument.

    Built as a raw node because there is no quotation for a bare named
    argument, and the whole application must then be a *single* `Term.app`
    node: named arguments are resolved against one application's head, so
    applying them one at a time yields "invalid argument name". -/
private def mkNamedArg (fieldId : Ident) (val : Term) : Syntax :=
  mkNode ``Lean.Parser.Term.namedArgument
    #[mkAtom "(", fieldId, mkAtom " := ", val, mkAtom ")"]

elab_rules : command
  | `(command| fleet $fleetName:ident $[$placement:fleetIn]? where $ress:fleetResource*) => do
    -- Group resources by `(provider, kind)`, preserving declaration order —
    -- which is also the key order within a bucket.
    let mut buckets :
        Array (Ident × Ident ×
          Array (TSyntax `str × Option Ident × Array (TSyntax `Infra.Core.fleetField))) := #[]
    for r in ress do
      match r with
      | `(fleetResource| resource $p:ident $k:ident $nm:str $[as $al:ident]? { $fs,* }) =>
        let entry := (nm, al, fs.getElems)
        match buckets.findIdx? (fun b => b.1.getId == p.getId && b.2.1.getId == k.getId) with
        | some i =>
          let b := buckets[i]!
          buckets := buckets.set! i (b.1, b.2.1, b.2.2.push entry)
        | none => buckets := buckets.push (p, k, #[entry])
      | _ => throwErrorAt r "malformed resource declaration"

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
        if perCloud then
          placeTerm ← `(Infra.Core.Regions.covering $keysId $placeTerm)
      | _ => throwErrorAt clause "malformed `in` clause"
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
        assign := fun p k => match p, k with $assignAlts:matchAlt*
        outside := Infra.Core.Status.unmanaged))

    for c in cmds do
      elabCommand c

end Infra.Core
