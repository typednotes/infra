import Infra

/-!
  # Example: two EC2 instances in Paris, and why one cannot exist alone

  Two `t3.nano` — the smallest current-generation x86 instance — in
  `eu-west-3`, behind one security group.

  The point of the example is the **required reference**. `AwsInstanceSpec`'s
  `securityGroup` field is `Field .required`, holding
  `K .aws .securityGroup`: a key into this very fleet. Three different
  mistakes therefore stop being possible, and none of them is caught by a
  validation pass — they are all rejected where the resource is written:

  1. **An instance with no security group.** The field is required, so the
     resource is not fully applied without one. There is no `Option`, no
     default, and nothing to forget.
  2. **An instance pointing at a security group that does not exist.** The
     field's type is an index into this fleet's own keys, so there is no
     "not found" case to handle.
  3. **An instance pointing at something that is not a security group.**
     `Key` is indexed by provider *and* kind, so a bucket key or a
     Scaleway key is a different type.

  It is also the reason `awsInstance` is a provider-local kind rather than
  something bolted onto the portable `compute` kind: `compute` is deliberately
  serverless-shaped, and a *required* network reference would make it
  undeployable on serverless functions. See `docs/architecture.md`.

  The ordering falls out of the same reference: the group is created before
  either instance, and neither instance can even be settled until the group
  exists, because settling resolves the reference to a real handle.

      lake exe paris-instances

  Runs against the placeholder backends: no credentials, no network, nothing
  billable. The AWS backend behind these kinds is real (`Kinds/Ec2.lean`) but
  has never been run against an account — see `docs/providers.md`.
-/

open Infra.Core
open Infra.Specs

/-- Amazon Linux 2023, `eu-west-3`. An AMI id is region-specific, which is why
    it is written down rather than derived: this one is meaningless in any
    other region, and there is no lookup here that would hide that. -/
def al2023Paris : String := "ami-0d3c032f5934e1b41"

fleet paris where
  -- Referenced by both instances below. Nothing references *it*, which is why
  -- it has no `as`-less twin: `as web` is what the instances name.
  resource aws securityGroup "web" as web
    { description := "http and https from anywhere, ssh from nowhere"
      -- The element type is written out because the list holds *numerals*:
      -- their type stays a metavariable, and a coercion is only found when the
      -- source type is already known. Same limitation as a bare `[]` — see
      -- `Infra.Core.Coe`.
    , ingress     := ([(80, "0.0.0.0/0"), (443, "0.0.0.0/0")] : List (Nat × String)) }

  resource aws awsInstance "web-1"
    { imageId       := al2023Paris
    , instanceType  := "t3.nano"
    , securityGroup := web }

  resource aws awsInstance "web-2"
    { imageId       := al2023Paris
    , instanceType  := "t3.nano"
    , securityGroup := web }

/-! ## What cannot be written

  The messages are the compiler's own, from actually writing each broken
  version. -/

-- **No security group at all.** `securityGroup` has no default, so the
-- resource is a *function* still waiting for one — which is how Lean reports
-- a missing required field, with the binder naming it:
--
--   resource aws awsInstance "web-3"
--     { imageId := al2023Paris, instanceType := "t3.nano" }
--
--   Application type mismatch: The argument
--     fun securityGroup => Build.awsInstance (Expr.lit "no-group") … securityGroup
--   has type
--     Expr ?m (?m ProviderId.aws Kind.securityGroup) → AwsInstanceSpec ?m Partial (Expr ?m)
--   but is expected to have type
--     SpecOf Kind.awsInstance keys.Key Partial (Expr keys.Key)
--
-- Note what this is *not*: a check that runs later and complains. There is no
-- moment at which a group-less instance exists as a value.

-- **A group that is not in this fleet.** There is nothing to write. A
-- reference is `keys.Key .aws .securityGroup`, whose inhabitants are exactly
-- the groups declared above — a string naming some other group is not of that
-- type, and `NamedKey.of` rejects an unlisted name at elaboration:
--
--   NamedKey.of paris.names.aws.securityGroup "does-not-exist"
--
--   could not synthesize default value for parameter 'h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (NamedKey.indexOfAux paris.names.aws.securityGroup "does-not-exist").isSome
--   is false

-- **Something that is not a security group.** Right cloud, wrong kind:
--
--   securityGroup := someBucketKey
--
--   Application type mismatch: The argument
--     bucket
--   has type
--     keys.Key ProviderId.aws Kind.s3Bucket
--   but is expected to have type
--     Expr keys.Key (keys.Key ProviderId.aws Kind.securityGroup)

/-! ## What the fleet says -/

#guard paris.keys.count .aws .securityGroup = 1
#guard paris.keys.count .aws .awsInstance = 2

-- AWS only: no Scaleway credentials are read, and no Scaleway API is called.
#guard paris.keys.providers = [.aws]

-- Three resources: the group and two instances.
#guard (actions paris.plan (worldOf [])).length = 3

-- Each instance depends on the group — and on exactly one thing. This is the
-- required reference showing up as a scheduling edge; `sourceBucket`, being
-- optional, contributes nothing when unset, whereas this cannot be unset.
#guard (HasDeps.deps (S := AwsInstanceSpec)
         (Build.awsInstance (K := paris.keys.Key)
           (name := "web-1") (imageId := al2023Paris)
           (instanceType := "t3.nano") (securityGroup := web))).length = 1

def main : IO Unit := do
  IO.println "paris: two t3.nano behind one security group\n"
  for line in ← push Infra.Providers.all paris.plan (worldOf []) {} do
    IO.println line
  IO.println "\nThe group is scheduled first. Not because the file lists it"
  IO.println "first — because each instance's `securityGroup` is a reference,"
  IO.println "and an instance cannot even be settled until it resolves."
