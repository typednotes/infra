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

      lake exe paris-instances                # offline: the plan, from placeholders
      lake exe paris-instances plan           # reads the real account
      lake exe paris-instances apply          # CREATES REAL, BILLABLE INSTANCES
      lake exe paris-instances plan --destroy # what tearing it down would delete
      lake exe paris-instances destroy        # terminate them again

  A bare invocation is offline, credential-free and free of charge. The live
  commands need AWS credentials **and a region** — the region is what puts
  this fleet in Paris (see point 3 below), and nothing in the declaration
  supplies it:

      export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…
      export AWS_REGION=eu-west-3

  To have them refuse to run against the wrong account — worth doing before
  creating anything billable:

      export INFRA_EXPECT_AWS_ACCOUNT=<your-account-id>

  ## Before the first apply, four things worth knowing

  1. **`t3.nano` costs money** and both instances run until something
     terminates them — `destroy` is that something, and is the reason to read
     the "Tearing it down" section below before applying. Removing a resource
     from this file does *not* delete it; it un-manages it, and the instance
     keeps running and keeps billing.
  2. **`al2023Paris` below is unverified.** An AMI id is region-specific and
     they are rotated; if it is stale, `RunInstances` fails with
     `InvalidAMIID.NotFound`. That is the most likely first failure.
  3. **The region comes from your credentials, not from this file.** Nothing in
     `AwsInstanceSpec` names a region — `Live.lean` builds the EC2 endpoint from
     `creds.region` — so "Paris" here means "your credentials say `eu-west-3`".
     Point them elsewhere and this same declaration builds the same fleet in
     another region against an AMI that does not exist there. The account guard
     checks the *account*, not the region.
  4. **This backend has never been run.** Signing is verified offline; every
     EC2 parameter name in `Kinds/Ec2.lean` is a best guess until an apply says
     otherwise. Expect to iterate, and read `docs/providers.md` first.
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

/-! ## Tearing it down

  `destroy` reconciles against `Plan.absent`, which keeps this fleet's keys and
  declares every one `.absent`. That is the "empty infra": *not* deleting the
  `resource` lines above, which would remove the keys and leave the instances
  running, unmanaged.

  Deletion order is the reverse of creation order, so the instances go before
  the group they sit in — which matters, because EC2 refuses to delete a
  security group that an instance still references.

  **That order is currently incidental, not derived.** `orderActions`
  topologically sorts *creations* and merely reverses destructions, so what
  makes this come out right is that `securityGroup` precedes `awsInstance` in
  the `Kind` enum. The guard below pins it, so reordering that enum fails here
  rather than failing against a real account. -/

/-- The same fleet, already applied: enough to make `.absent` produce deletes
    rather than no-ops, since `actions` only deletes what it can see. -/
def existing : World paris.keys :=
  worldOf
    [ ⟨.aws, .securityGroup, web,
        { observed := { handle := ⟨"web"⟩, groupId := "sg-x", vpcId := "vpc-x" }
          reported := { name := "web"
                        description := "http and https from anywhere, ssh from nowhere"
                        ingress := .unknown } }⟩
    , ⟨.aws, .awsInstance, NamedKey.of paris.names.aws.awsInstance "web-1",
        { observed := { handle := ⟨"web-1"⟩, instanceId := "i-1"
                        privateIp := "10.0.0.1", state := "running" }
          reported := { name := "web-1", imageId := al2023Paris
                        instanceType := "t3.nano", securityGroup := ⟨"web"⟩
                        keyName := .unknown, subnetId := .unknown } }⟩ ]

-- Two resources exist here, so the empty declaration deletes two.
#guard (actions (Plan.absent paris.keys) existing).length = 2

/-- What `push` actually executes: `orderActions` schedules creations
    topologically and *reverses* destructions, so this is the list to assert
    on. Raw `actions` comes back in enumeration order — group first — which is
    exactly the order that would fail against EC2. -/
private def teardown : List String :=
  match orderActions (Plan.absent paris.keys) (actions (Plan.absent paris.keys) existing) with
  | .ok ordered => ordered.map Action.slot
  | .error _    => []

-- The instance goes before the group it references. Reordering the `Kind`
-- enum would break this, which is why it is written down.
#guard teardown = ["aws/aws-instance/web-1", "aws/security-group/web"]

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

/-- `check` (the default) stays offline: `Infra.Cli.run`'s own `offlinePlan`
    shows the plan from the placeholder backends. `plan` reads the account;
    `apply` creates **real, billable** instances that run until
    terminated. -/
def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "paris-instances" paris.plan
    (selfCheck := Infra.Cli.offlinePlan paris.plan
      "paris: two t3.nano behind one security group")
    (accounts := ← Infra.Cli.Accounts.fromEnv) (args := args)
