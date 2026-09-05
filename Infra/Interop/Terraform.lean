import Infra.Core.Engine
import Infra.Core.Region
import Lean.Data.Json

/-
  Terraform / OpenTofu interoperability, in both directions.

  Neither direction is a round trip, and pretending otherwise would be the
  usual way this feature is oversold. What each one honestly is:

  - **`toHcl`** turns a fleet into `.tf` text. Every resource the fleet
    declares becomes a `resource` block, with the provider blocks its
    placement implies. Fields the exporter can read as literals are emitted;
    anything computed — a reference, a composed secret, an `Expr` over
    post-apply state — becomes a `# TODO` comment naming what was dropped,
    because HCL has no equivalent of an applicative over unknown state and a
    silently wrong value is worse than a visible hole.

  - **`fleetOfState`** goes the other way, and produces **Lean source text**
    rather than a `Plan`. It has to: a fleet's key type is derived from its
    resource names at elaboration, so importing means *writing a declaration*
    for you to paste and compile, not building a value at runtime. This is the
    same shape `example/ScalewayPull.lean` already uses for observed state.

  Input for the import direction is `terraform show -json` — the state, not
  the `.tf` files. There is no HCL parser here and adding one would be a
  large, separate piece of work; the JSON is a documented, stable interface
  and both Terraform and OpenTofu emit it.

  ## Fidelity, stated up front

  The `(provider, kind) → resource type` table below is a **best guess** for
  several rows and has not been checked against either registry. It is in the
  same position as the endpoint shapes in `Infra/Providers/Kinds/*.lean` —
  see `docs/providers.md`. Attribute *names* within each block are guessed
  more loosely still. Treat generated HCL as a starting point to review, not
  as something to apply unread.
-/

namespace Infra.Interop.Terraform

open Infra.Core
open Infra.Specs
open Lean (Json)

/-! ## The type table -/

/-- What Terraform calls this `(provider, kind)` pair, if it has a name for it.

    `none` means the pair is not expressible: an AWS-only kind under Scaleway,
    or the reverse. Total over both axes, so adding a `Kind` fails here until
    it is answered.

    **Unverified against either provider registry.** -/
def resourceType : ProviderId → Kind → Option String
  | .aws, .iam                        => some "aws_iam_user"
  | .aws, .objectStore                => some "aws_s3_bucket"
  | .aws, .compute                    => some "aws_lambda_function"
  | .aws, .queues                     => some "aws_sqs_queue"
  | .aws, .secrets                    => some "aws_secretsmanager_secret"
  | .aws, .imageRegistry              => some "aws_ecr_repository"
  | .aws, .postgres                   => some "aws_db_instance"
  | .aws, .s3Bucket                   => some "aws_s3_bucket"
  | .aws, .securityGroup              => some "aws_security_group"
  | .aws, .awsInstance                => some "aws_instance"
  | .aws, .scalewayFunctionNamespace  => none
  | .aws, .scalewayFunction           => none
  | .aws, .scalewayContainerNamespace => none
  | .aws, .scalewayContainer          => none
  | .scaleway, .iam                        => some "scaleway_iam_application"
  | .scaleway, .objectStore                => some "scaleway_object_bucket"
  | .scaleway, .compute                    => some "scaleway_container"
  | .scaleway, .queues                     => some "scaleway_mnq_sqs_queue"
  | .scaleway, .secrets                    => some "scaleway_secret"
  | .scaleway, .imageRegistry              => some "scaleway_registry_namespace"
  | .scaleway, .postgres                   => some "scaleway_rdb_instance"
  | .scaleway, .scalewayFunctionNamespace  => some "scaleway_function_namespace"
  | .scaleway, .scalewayFunction           => some "scaleway_function"
  | .scaleway, .scalewayContainerNamespace => some "scaleway_container_namespace"
  | .scaleway, .scalewayContainer          => some "scaleway_container"
  | .scaleway, .s3Bucket                   => none
  | .scaleway, .securityGroup              => none
  | .scaleway, .awsInstance                => none

/-- The reverse lookup, for import. Ambiguity is resolved toward the portable
    kind: `aws_s3_bucket` maps to `objectStore` rather than `s3Bucket`, because
    the portable kind is the one that keeps a declaration usable on either
    cloud, and reaching for `s3Bucket` should be a deliberate edit. -/
def kindOfResourceType (ty : String) : Option (ProviderId × Kind) :=
  match ty with
  | "aws_iam_user"                  => some (.aws, .iam)
  | "aws_s3_bucket"                 => some (.aws, .objectStore)
  | "aws_lambda_function"           => some (.aws, .compute)
  | "aws_sqs_queue"                 => some (.aws, .queues)
  | "aws_secretsmanager_secret"     => some (.aws, .secrets)
  | "aws_ecr_repository"            => some (.aws, .imageRegistry)
  | "aws_db_instance"               => some (.aws, .postgres)
  | "aws_security_group"            => some (.aws, .securityGroup)
  | "aws_instance"                  => some (.aws, .awsInstance)
  | "scaleway_iam_application"      => some (.scaleway, .iam)
  | "scaleway_object_bucket"        => some (.scaleway, .objectStore)
  | "scaleway_mnq_sqs_queue"        => some (.scaleway, .queues)
  | "scaleway_secret"               => some (.scaleway, .secrets)
  | "scaleway_registry_namespace"   => some (.scaleway, .imageRegistry)
  | "scaleway_rdb_instance"         => some (.scaleway, .postgres)
  | "scaleway_function_namespace"   => some (.scaleway, .scalewayFunctionNamespace)
  | "scaleway_function"             => some (.scaleway, .scalewayFunction)
  | "scaleway_container_namespace"  => some (.scaleway, .scalewayContainerNamespace)
  | "scaleway_container"            => some (.scaleway, .scalewayContainer)
  | _                               => none

/-! ## Rendering HCL values -/

/-- One attribute of a `resource` block. `missing` is a field the exporter
    could not read — a reference, or a value that only exists after an apply —
    and is emitted as a comment rather than guessed at. -/
inductive Attr where
  | str  (name value : String)
  | bool (name : String) (value : Bool)
  | num  (name : String) (value : Nat)
  | list (name : String) (values : List String)
  /-- An unquoted HCL expression — what a cross-resource reference becomes. -/
  | raw  (name value : String)
  | «missing» (name reason : String)

private def quote (s : String) : String :=
  "\"" ++ (s.replace "\\" "\\\\" |>.replace "\"" "\\\"") ++ "\""

def Attr.render : Attr → String
  | .str n v      => s!"  {n} = {quote v}"
  | .bool n v     => s!"  {n} = {if v then "true" else "false"}"
  | .num n v      => s!"  {n} = {v}"
  | .list n vs    => s!"  {n} = [{String.intercalate ", " (vs.map quote)}]"
  | .raw n v      => s!"  {n} = {v}"
  | .missing n why => s!"  # TODO {n}: {why}"

/-- A Terraform label: `[A-Za-z0-9_-]`, not starting with a digit. Resource
    names here can contain dots and other characters a label cannot. -/
def label (s : String) : String :=
  let cleaned := s.map fun c =>
    if c.isAlphanum || c == '_' || c == '-' then c else '_'
  match cleaned.toList with
  | []      => "unnamed"
  | c :: _  => if c.isDigit then "_" ++ cleaned else cleaned

/-! ## Reading what the authored spec can offer -/

variable {K : ProviderId → Kind → Type}

/-- A required field's literal, if it is one. `Expr.asLit` is `none` for
    anything computed, which is exactly the case that must not be guessed. -/
private def req {α : Type} (e : Expr K α) : Option α := e.asLit

/-- An optional field's literal: absent if not specified, or if specified as
    something computed. -/
private def opt {α : Type} : Partial (Expr K α) → Option α
  | .known e => e.asLit
  | .unknown => none

private def strReq (n : String) (e : Expr K String) : Attr :=
  match req e with
  | some v => .str n v
  | none   => .missing n "computed — resolve by hand"

private def strOpt (n : String) (f : Partial (Expr K String)) : List Attr :=
  match f with
  | .unknown => []
  | .known e => match e.asLit with
    | some v => [.str n v]
    | none   => [.missing n "computed — resolve by hand"]

private def boolOpt (n : String) (f : Partial (Expr K Bool)) : List Attr :=
  match opt f with | some v => [.bool n v] | none => []

private def natOpt (n : String) (f : Partial (Expr K Nat)) : List Attr :=
  match opt f with | some v => [.num n v] | none => []

/-- An HCL reference to another resource in the same file: `type.label.id`.

    This is the payoff of a reference being an index into the fleet rather than
    a string — the target's Terraform type and label are both derivable, so the
    export emits a real reference instead of a hole. -/
private def refTo (nameOf : (p : ProviderId) → (k : Kind) → K p k → String)
    (p : ProviderId) (k : Kind) (key : K p k) : Option String :=
  (resourceType p k).map fun ty => s!"{ty}.{label (nameOf p k key)}.id"

/-- The attributes of one resource, per kind.

    Total over `Kind`, so a new kind cannot silently export as an empty block.
    `nameOf` resolves a referenced key to its name, which is what lets a
    reference come out as HCL rather than as a `# TODO`.

    Attribute names are the loosest guess in this file. -/
def attrsOf (nameOf : (p : ProviderId) → (k : Kind) → K p k → String) :
    (k : Kind) → SpecOf.{1} k K Partial (Expr K) → List Attr
  | .iam, s => [strReq "name" s.name]
  | .objectStore, s =>
    [strReq "bucket" s.name] ++ boolOpt "versioning" s.versioning
    ++ (match s.tags with
        | .unknown => []
        | .known _ => [.missing "tags" "map value — copy from the fleet"])
  | .queues, s => [strReq "name" s.name] ++ natOpt "visibility_timeout_seconds" s.visibilityTimeoutSec
  | .secrets, s =>
    [strReq "name" s.name,
     .missing "value" "a secret's value is never in the declaration; wire it up in Terraform yourself"]
  | .imageRegistry, s => [strReq "name" s.name] ++ boolOpt "image_tag_mutability" s.immutableTags
  | .compute, s =>
    [strReq "function_name" s.name, strReq "image_uri" s.image]
    ++ strOpt "role" s.executionRole ++ natOpt "memory_size" s.memoryMb
    ++ natOpt "timeout" s.timeoutSec
  | .postgres, s =>
    [strReq "identifier" s.name, strReq "username" s.masterUsername]
    ++ strOpt "instance_class" s.instanceClass ++ strOpt "engine_version" s.version
    ++ natOpt "allocated_storage" s.storageGb
    ++ [.missing "password" "held as a secret reference, not a value"]
  | .s3Bucket, s =>
    [strReq "bucket" s.name] ++ boolOpt "versioning" s.versioning
    ++ boolOpt "object_lock_enabled" s.objectLock
  | .securityGroup, s =>
    [strReq "name" s.name, strReq "description" s.description]
    ++ (match s.ingress with
        | .unknown => []
        | .known _ => [.missing "ingress" "nested blocks — copy from the fleet"])
  | .awsInstance, s =>
    [strReq "ami" s.imageId,
     (match req s.instanceType with
      | some t => .str "instance_type" t.name
      | none   => .missing "instance_type" "computed"),
     (match req s.securityGroup with
      | some key => match refTo nameOf .aws .securityGroup key with
        | some r => .raw "vpc_security_group_ids" s!"[{r}]"
        | none   => .missing "vpc_security_group_ids" "no Terraform type for that kind"
      | none => .missing "vpc_security_group_ids" "computed reference")]
    ++ strOpt "key_name" s.keyName ++ strOpt "subnet_id" s.subnetId
  | .scalewayFunctionNamespace, s  => [strReq "name" s.name] ++ strOpt "description" s.description
  | .scalewayContainerNamespace, s => [strReq "name" s.name] ++ strOpt "description" s.description
  | .scalewayFunction, s =>
    [strReq "name" s.name, strReq "runtime" s.runtime,
     (match req s.namespace' with
      | some key => match refTo nameOf .scaleway .scalewayFunctionNamespace key with
        | some r => .raw "namespace_id" r
        | none   => .missing "namespace_id" "no Terraform type for that kind"
      | none => .missing "namespace_id" "computed reference")]
  | .scalewayContainer, s =>
    [strReq "name" s.name, strReq "registry_image" s.image,
     (match req s.namespace' with
      | some key => match refTo nameOf .scaleway .scalewayContainerNamespace key with
        | some r => .raw "namespace_id" r
        | none   => .missing "namespace_id" "no Terraform type for that kind"
      | none => .missing "namespace_id" "computed reference")]
    ++ natOpt "port" s.port ++ natOpt "min_scale" s.minScale ++ natOpt "max_scale" s.maxScale
    ++ natOpt "memory_limit" s.memoryMb ++ natOpt "cpu_limit" s.cpuLimit

/-! ## Export -/

/-- One `resource` block. -/
def blockOf (p : ProviderId) (k : Kind) (name : String) (attrs : List Attr) : Option String :=
  (resourceType p k).map fun ty =>
    let body := String.intercalate "\n" (attrs.map Attr.render)
    s!"resource {quote ty} {quote (label name)} \{\n{body}\n}"

/-- The `provider` blocks a fleet's placement implies — one per cloud, with
    the region it is placed in.

    A fleet spanning several regions of one cloud needs *aliased* providers in
    Terraform, and each resource then needs a `provider =` meta-argument. That
    is emitted as a comment rather than guessed at, because getting it wrong
    silently builds in the wrong region. -/
def providerBlocks (κ : Keys) (rs : Regions) : List String :=
  κ.providers.map fun p =>
    let regions := (Finite.elems (α := Kind)).foldl (init := ([] : List String))
      fun acc k => (rs.used κ p k "").foldl (init := acc) fun a c =>
        if c.isEmpty || a.contains c then a else a ++ [c]
    match regions with
    | []      => s!"provider {quote p.name} \{\n  # TODO region: this fleet does not declare one\n}"
    | [r]     => s!"provider {quote p.name} \{\n  region = {quote r}\n}"
    | r :: rest =>
      let aliases := String.intercalate "\n" (rest.map fun c =>
        s!"provider {quote p.name} \{\n  alias  = {quote (label c)}\n  region = {quote c}\n}")
      s!"provider {quote p.name} \{\n  region = {quote r}\n}\n\n{aliases}\n\n\
# NOTE: this fleet spans several regions of {p.name}. Terraform needs one\n\
# aliased provider per region and a `provider = {p.name}.<alias>` argument on\n\
# each resource; which resource belongs to which is NOT emitted here."

/-- A whole fleet as `.tf` text.

    Deliberately does not claim to be applyable. Read it, fix the `# TODO`
    lines, then decide. -/
def toHcl {κ : Keys} (T : Plan κ) (rs : Regions := {}) : String :=
  let header :=
    "# Generated by `infra` (Lean) — https://github.com/typednotes/infra\n\
#\n\
# A STARTING POINT, NOT A ROUND TRIP. Every `# TODO` below is a value the\n\
# exporter could not express in HCL: a reference between resources, a secret,\n\
# or a value computed from state that does not exist yet. Review before use."
  let providers := providerBlocks κ rs
  let resources := (Finite.elems (α := ProviderId)).flatMap fun p =>
    (Finite.elems (α := Kind)).flatMap fun k =>
      (Finite.elems (α := κ.Key p k)).filterMap fun key =>
        match T.assign p k key with
        | .present spec => blockOf p k (κ.name p k key) (attrsOf κ.name k spec)
        | _             => none
  String.intercalate "\n\n" (header :: providers ++ resources) ++ "\n"

/-! ## Import -/

/-- The identifier the `fleet` DSL uses for a kind — its `Kind` constructor.

    Not derived from `Kind.name`, which is the kebab-cased *display* name
    (`object-store`) and would not elaborate. A separate total match, so a new
    kind cannot import as something unparseable. -/
def kindIdent : Kind -> String
  | .iam => "iam"
  | .objectStore => "objectStore"
  | .compute => "compute"
  | .queues => "queues"
  | .secrets => "secrets"
  | .imageRegistry => "imageRegistry"
  | .postgres => "postgres"
  | .s3Bucket => "s3Bucket"
  | .securityGroup => "securityGroup"
  | .awsInstance => "awsInstance"
  | .scalewayFunctionNamespace => "scalewayFunctionNamespace"
  | .scalewayFunction => "scalewayFunction"
  | .scalewayContainerNamespace => "scalewayContainerNamespace"
  | .scalewayContainer => "scalewayContainer"

/-- One resource read out of `terraform show -json`. -/
structure Found where
  provider : ProviderId
  kind     : Kind
  name     : String
  deriving Repr, DecidableEq

/-- The name a resource carries, by the attribute each type uses for it,
    falling back to Terraform's own label. -/
private def nameOf (values : Json) (label : String) : String :=
  let try? := fun (k : String) => (values.getObjVal? k).toOption.bind (·.getStr?.toOption)
  ((try? "bucket").orElse fun _ =>
    (try? "name").orElse fun _ =>
      (try? "identifier").orElse fun _ =>
        try? "function_name").getD label

/-- Pull every resource `infra` has a kind for out of `terraform show -json`.

    Resources of a type this library does not model are skipped rather than
    guessed at, and `fleetOfState` says how many were skipped. -/
def resourcesOfState (j : Json) : List Found × Nat :=
  let arr :=
    (j.getObjVal? "values").toOption
      |>.bind (·.getObjVal? "root_module" |>.toOption)
      |>.bind (·.getObjVal? "resources" |>.toOption)
      |>.bind (·.getArr?.toOption)
      |>.getD #[]
  arr.foldl (init := ([], 0)) fun (acc, skipped) r =>
    let ty  := (r.getObjVal? "type").toOption.bind (·.getStr?.toOption) |>.getD ""
    let lbl := (r.getObjVal? "name").toOption.bind (·.getStr?.toOption) |>.getD ""
    let vals := (r.getObjVal? "values").toOption.getD Json.null
    match kindOfResourceType ty with
    | some (p, k) => (acc ++ [{ provider := p, kind := k, name := nameOf vals lbl }], skipped)
    | none        => (acc, skipped + 1)

/-- Terraform state as a `fleet` declaration, ready to paste and compile.

    Source text rather than a value, and it has to be: a fleet's key type is
    derived from its resource names while the file elaborates, so there is no
    runtime `Plan` to build. Fields are left empty on purpose — importing the
    *shape* is what saves the work, and importing guessed configuration would
    produce a declaration that quietly disagrees with reality on the next
    plan. -/
def fleetOfState (name : String) (j : Json) : String :=
  let (found, skipped) := resourcesOfState j
  if found.isEmpty then
    s!"-- No resource in this state maps to a kind `infra` models.\n\
-- {skipped} resource(s) were skipped."
  else
    let byProvider := (Finite.elems (α := ProviderId)).filterMap fun p =>
      let mine := found.filter (·.provider == p)
      if mine.isEmpty then none
      else
        let lines := mine.map fun f =>
          let ident := kindIdent f.kind
          s!"    resource {ident} {quote f.name} \{ }"
        some (s!"  provider {p.name} where\n" ++ String.intercalate "\n" lines)
    let skippedNote :=
      if skipped == 0 then ""
      else s!"\n\n-- {skipped} resource(s) of types `infra` does not model were skipped."
    s!"-- Imported from `terraform show -json`.\n\
--\n\
-- Fields are left empty deliberately: the *shape* is what is worth importing,\n\
-- and guessed configuration would quietly disagree with reality on the first\n\
-- plan. This will NOT compile as it stands, and that is the point — every\n\
-- resource with a required field fails to elaborate until you supply it, and\n\
-- the error names the field. Work through them, then add a placement\n\
-- (`in <locality>`) and you have a fleet.\n\
fleet {name} where\n{String.intercalate "\n" byProvider}{skippedNote}"

/-! ## Self-checks -/

#guard resourceType .aws .objectStore = some "aws_s3_bucket"
#guard resourceType .scaleway .s3Bucket = none
#guard resourceType .aws .scalewayFunction = none

-- Every type the exporter can emit is one the importer recognises again, and
-- lands back on the same cloud. Not a full round trip — the portable kind is
-- preferred on the way back — but the *cloud* must never change.
#guard (Finite.elems (α := ProviderId)).all fun p =>
  (Finite.elems (α := Kind)).all fun k =>
    match resourceType p k with
    | none    => true
    | some ty => match kindOfResourceType ty with
      | some (p', _) => p' == p
      | none         => false

#guard label "my-bucket.example" = "my-bucket_example"
#guard label "9lives" = "_9lives"
#guard label "" = "unnamed"

#guard Attr.render (.str "bucket" "a\"b") = "  bucket = \"a\\\"b\""
#guard Attr.render (.bool "versioning" true) = "  versioning = true"
#guard Attr.render (.missing "tags" "map") = "  # TODO tags: map"
#guard Attr.render (.raw "namespace_id" "scaleway_function_namespace.ns.id")
     = "  namespace_id = scaleway_function_namespace.ns.id"

end Infra.Interop.Terraform
