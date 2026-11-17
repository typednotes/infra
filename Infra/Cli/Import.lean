import Infra.Interop.KubernetesImport

/-
  `infra import`: Kubernetes YAML, or a Helm chart rendered with chosen
  values, as `kubernetesObject` declarations (`Interop.KubernetesImport`).

  Fleet-independent — it reads manifests, not a declaration — so it lives on
  the `infra` executable beside `new`, not on a fleet's own CLI. The Lean
  source goes to stdout; a one-line summary to stderr.

  `import helm` runs `helm template` and imports its output. One chart with
  one set of values is one import: Go templates, `lookup` and chart
  dependencies are Helm's, and are not translated. Hooks are left out
  (`--no-hooks`), CRDs are included (`--include-crds`), and every object
  the chart renders without a namespace takes `--namespace`.
-/

namespace Infra.Cli.Import

open Infra.Core
open Infra.Interop.KubernetesImport

/-- The arguments both commands share. -/
structure Common where
  opts        : Options := {}
  cloud       : ProviderId := .scaleway
  fleet       : String := "imported"
  objectsOnly : Bool := false
  /-- Whatever is left: the source (FILE, `-`, CHART) and `helm` flags. -/
  rest        : List String := []

/-- A Lean identifier for the `fleet` line: a letter, then letters, digits
    and `_`. -/
def isFleetIdent (s : String) : Bool :=
  match s.toList with
  | c :: cs => c.isAlpha && cs.all fun c => c.isAlphanum || c == '_'
  | [] => false

/-- Read the shared flags, leaving the others in `rest`, or why not. -/
def parseCommon : List String → Common → Except String Common
  | [], c => .ok { c with rest := c.rest.reverse }
  | "--cluster" :: v :: more, c =>
    if Infra.Specs.isClusterName v then parseCommon more { c with opts := { c.opts with cluster := v } }
    else .error s!"'{v}' is not a cluster name (a DNS-1035 label of at most 40)"
  | "--namespace" :: v :: more, c =>
    if Infra.Specs.isDns1123Label v then parseCommon more { c with opts := { c.opts with ns := v } }
    else .error s!"'{v}' is not a namespace (a DNS-1123 label)"
  | "--cloud" :: v :: more, c =>
    match (Finite.elems (α := ProviderId)).find? (·.name == v) with
    | some p => parseCommon more { c with cloud := p }
    | none => .error s!"'{v}' is not a cloud ({String.intercalate ", "
        ((Finite.elems (α := ProviderId)).map (·.name))})"
  | "--fleet" :: v :: more, c =>
    if isFleetIdent v then parseCommon more { c with fleet := v }
    else .error s!"'{v}' is not a Lean identifier for the fleet"
  | "--objects-only" :: more, c => parseCommon more { c with objectsOnly := true }
  | a :: more, c => parseCommon more { c with rest := a :: c.rest }

def usage : String := String.intercalate "\n"
  [ "usage: lake exe infra import kubernetes FILE|- [OPTIONS]"
  , "       lake exe infra import helm CHART [--release NAME] [--values FILE]... [--set K=V]..."
  , "                                        [--version V] [OPTIONS]"
  , ""
  , "  Prints `kubernetesObject` declarations, as Lean source, for the objects read."
  , "  An object gets a typed shape only when it renders back exactly; otherwise it is"
  , "  raw, whole. Secrets, owned objects, Endpoints/Events and Helm hooks are skipped"
  , "  and listed; what cannot be declared fails the import, naming the object."
  , ""
  , "  --cluster NAME      the cluster every address names (default main)"
  , "  --namespace NS      the namespace of an object that names none (default default)"
  , "  --cloud CLOUD       the provider block (default scaleway)"
  , "  --fleet IDENT       the fleet's identifier (default imported)"
  , "  --objects-only      print only the resource lines, to paste into a fleet"
  ]

/-- All of standard input. -/
def readStdin : IO String := do
  let stdin ← IO.getStdin
  let mut out := ""
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    out := out ++ line
  return out

/-- Import `text` and print the declaration. -/
def emit (c : Common) (origin text : String) : IO UInt32 := do
  match importText c.opts text with
  | .error e =>
    IO.eprintln s!"error: cannot import {origin}:\n{e}"
    return 1
  | .ok items =>
    IO.print (fleetSource c.fleet c.cloud c.opts origin items c.objectsOnly)
    let imported := items.filter (· matches .imported _)
    IO.eprintln s!"imported {imported.length} object(s) from {origin}; skipped \
{items.length - imported.length}"
    return 0

/-- `helm template`'s arguments for `import helm`'s, or why not. -/
def helmArgs (ns : String) : List String → Except String (String × Array String)
  | chart :: flags =>
    let rec go : List String → String → Array String → Except String (String × Array String)
      | [], release, acc => .ok (release, acc)
      | "--release" :: r :: more, _, acc => go more r acc
      | "--values" :: f :: more, release, acc => go more release (acc ++ #["--values", f])
      | "--set" :: kv :: more, release, acc => go more release (acc ++ #["--set", kv])
      | "--version" :: v :: more, release, acc => go more release (acc ++ #["--version", v])
      | a :: _, _, _ => .error s!"'{a}' is not an option of import helm"
    match go flags "release" #[] with
    | .ok (release, extra) =>
      .ok (chart, #["template", release, chart, "--namespace", ns, "--include-crds",
        "--no-hooks"] ++ extra)
    | .error e => .error e
  | [] => .error "import helm needs a chart"

#guard (helmArgs "web" ["./chart", "--values", "v.yaml", "--release", "r"]).toOption =
  some ("./chart", #["template", "r", "./chart", "--namespace", "web", "--include-crds",
    "--no-hooks", "--values", "v.yaml"])
#guard (helmArgs "default" ["./chart", "--bogus"]).toOption.isNone

def run (args : List String) : IO UInt32 := do
  match args with
  | "kubernetes" :: rest =>
    match parseCommon rest {} with
    | .error e => IO.eprintln s!"error: {e}"; return 2
    | .ok c =>
    match c.rest with
    | ["-"] => emit c "standard input" (← readStdin)
    | [path] =>
      let text ← try IO.FS.readFile path catch e =>
        IO.eprintln s!"error: cannot read {path}: {e}"; return 1
      emit c path text
    | _ => IO.eprintln usage; return 2
  | "helm" :: rest =>
    match parseCommon rest {} with
    | .error e => IO.eprintln s!"error: {e}"; return 2
    | .ok c =>
    match helmArgs c.opts.ns c.rest with
    | .error e => IO.eprintln s!"error: {e}\n\n{usage}"; return 2
    | .ok (chart, hargs) =>
      let out ← try IO.Process.output { cmd := "helm", args := hargs } catch e =>
        IO.eprintln s!"error: could not run helm ({e}); install it, or render the chart \
yourself and use `import kubernetes`"
        return 1
      if out.exitCode != 0 then
        IO.eprintln s!"error: helm template failed:\n{out.stderr}"
        return 1
      emit c s!"Helm chart {chart} (helm template, without hooks)" out.stdout
  | _ => IO.eprintln usage; return 2

end Infra.Cli.Import
