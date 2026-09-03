import Lean
import Infra.Core.Ergonomics
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

  Generates `myFleet.keys : Keys` and `myFleet.plan : Plan myFleet.keys`, plus
  one abbreviation per `as`.
-/

namespace Infra.Core

open Lean Elab Command Term

/-- One field of a resource's spec. The value is an arbitrary term, spliced
    through unchanged so its errors point at the author's own code. -/
syntax fleetField := ident " := " term

/-- One resource. Provider and kind are bare identifiers naming `ProviderId`
    and `Kind` constructors. -/
syntax fleetResource := "resource " ident ident str (" as " ident)? "{" fleetField,* "}"

/-- Declare a fleet: its `Keys` and its `Plan`, derived from the resources. -/
syntax (name := fleetDecl) "fleet " ident " where " fleetResource* : command

/-- One `(field := value)` named argument.

    Built as a raw node because there is no quotation for a bare named
    argument, and the whole application must then be a *single* `Term.app`
    node: named arguments are resolved against one application's head, so
    applying them one at a time yields "invalid argument name". -/
private def mkNamedArg (fieldId : Ident) (val : Term) : Syntax :=
  mkNode ``Lean.Parser.Term.namedArgument
    #[mkAtom "(", fieldId, mkAtom " := ", val, mkAtom ")"]

elab_rules : command
  | `(command| fleet $fleetName:ident where $ress:fleetResource*) => do
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

    let keysId  := mkIdentFrom fleetName (fleetName.getId ++ `keys)
    let tableId := mkIdentFrom fleetName (fleetName.getId ++ `table)
    let planId  := mkIdentFrom fleetName (fleetName.getId ++ `plan)

    -- 1. One name list per bucket. `KeySpec.named`'s `namesNodup` auto-param
    --    is checked against these, so a duplicate name fails at elaboration.
    let mut cmds : Array (TSyntax `command) := #[]
    let mut nameListIds : Array Ident := #[]
    for (p, k, entries) in buckets do
      let id := mkIdentFrom fleetName (fleetName.getId ++ `names ++ p.getId ++ k.getId)
      nameListIds := nameListIds.push id
      let strs := entries.map (·.1)
      cmds := cmds.push (← `(def $id : List String := [$strs,*]))

    -- 2. The table, then the `Keys`. Buckets not declared are `.unused`, which
    --    is what leaves everything else in the account alone, unconditionally.
    let mut tableAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    for i in [0:buckets.size] do
      let (p, k, _) := buckets[i]!
      let names := nameListIds[i]!
      tableAlts := tableAlts.push ⟨(← `(Lean.Parser.Term.matchAltExpr|
        | .$p:ident, .$k:ident => Infra.Core.KeySpec.named $names)).raw⟩
    tableAlts := tableAlts.push ⟨(← `(Lean.Parser.Term.matchAltExpr|
      | _, _ => Infra.Core.KeySpec.unused)).raw⟩
    cmds := cmds.push (← `(
      def $tableId : Infra.Core.ProviderId → Infra.Core.Kind → Infra.Core.KeySpec :=
        fun p k => match p, k with $tableAlts:matchAlt*))
    cmds := cmds.push (← `(
      def $keysId : Infra.Core.Keys := Infra.Core.Keys.build $tableId))

    -- 3. Every `as` abbreviation, all of them before any spec, so a resource
    --    may reference one declared later in the block.
    for i in [0:buckets.size] do
      let (p, k, entries) := buckets[i]!
      let names := nameListIds[i]!
      for (nm, al, _) in entries do
        if let some a := al then
          cmds := cmds.push (← `(
            abbrev $a : ($keysId).Key .$p:ident .$k:ident :=
              Infra.Core.NamedKey.of $names $nm))

    -- 4. The plan: one `assignFromNamed` bucket per row, plus the total
    --    `.unmanaged` fallback for every pair this fleet does not declare.
    let mut assignAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    for (p, k, entries) in buckets do
      let mut pairs : Array Term := #[]
      for (nm, _, fields) in entries do
        -- `name` comes from the declaration's own label, never written twice.
        let mut args : Array Syntax := #[mkNamedArg (mkIdent `name) (← `($nm))]
        for f in fields do
          match f with
          | `(fleetField| $fid:ident := $v:term) =>
            args := args.push
              (mkNamedArg (mkIdentFrom fid fid.getId.eraseMacroScopes) v)
          | _ => throwErrorAt f "malformed field"
        let call : Term := ⟨mkNode ``Lean.Parser.Term.app
          #[mkIdent (`Infra.Specs.Build ++ k.getId), mkNullNode args]⟩
        pairs := pairs.push (← `(($nm, Infra.Core.Status.present $call)))
      assignAlts := assignAlts.push ⟨(← `(Lean.Parser.Term.matchAltExpr|
        | .$p:ident, .$k:ident =>
            Infra.Core.Keys.assignFromNamed (κ := $keysId) .$p:ident .$k:ident [$pairs,*])).raw⟩
    assignAlts := assignAlts.push ⟨(← `(Lean.Parser.Term.matchAltExpr|
      | _, _ => fun _ => Infra.Core.Status.unmanaged)).raw⟩
    cmds := cmds.push (← `(
      def $planId : Infra.Core.Plan $keysId where
        assign := fun p k => match p, k with $assignAlts:matchAlt*
        outside := Infra.Core.Status.unmanaged))

    for c in cmds do
      elabCommand c

end Infra.Core
