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
  commands need AWS credentials, and nothing else — the region is declared
  below (`in paris`), so `AWS_REGION` is neither read nor needed:

      export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…

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
  3. **The region comes from this file.** `in paris` below places the fleet,
     and `Infra.Cli` builds every AWS endpoint from that rather than from
     `creds.region` — so "Paris" here means Paris, whatever the credentials
     say. That matters more than convenience: the AMI in point 2 is
     region-specific, and until placement was declarable this same file built
     a different fleet for every operator who ran it. The account guard checks
     the account; `in paris` checks the place, and both are checked before
     anything is created.
  4. **This backend has now been run, once.** An apply against a real account
     created the group and both instances, so the EC2 parameter names in
     `Kinds/Ec2.lean` are no longer guesses. `destroy` has *not* been
     exercised, which is the half that costs money to get wrong — read
     "Tearing it down" below before you need it.
-/

open Infra.Core
open Infra.Specs

/-- Amazon Linux 2023, `eu-west-3`. An AMI id is region-specific, which is why
    it is written down rather than derived: this one is meaningless in any
    other region, and there is no lookup here that would hide that. -/
def al2023Paris : String := "ami-0d3c032f5934e1b41"

-- `in paris` places every cloud this fleet uses — AWS only, here — at the
-- `Locality.paris` region, which for AWS is `eu-west-3`. The alternative
-- spelling is AWS's own code, `in aws "eu-west-3"`, and both are checked while
-- this file elaborates. See "Where it cannot be" below.
--
-- The fleet is `webTier` rather than `paris`: `fleet paris in paris` read as
-- though the two names were one thing, and they are not — the first is this
-- declaration, the second is a `Locality`. Only the second is Paris.
fleet webTier in paris where
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
    , instanceType  := InstanceType.of .t3 .nano
    , securityGroup := web }

  resource aws awsInstance "web-2"
    { imageId       := al2023Paris
    , instanceType  := InstanceType.of .t3 .nano
    , securityGroup := web }

/-! ## What cannot be written

  The messages are the compiler's own, from actually writing each broken
  version. -/

-- **No security group at all.** `securityGroup` has no default, so the
-- resource is a *function* still waiting for one — which is how Lean reports
-- a missing required field, with the binder naming it:
--
--   resource aws awsInstance "web-3"
--     { imageId := al2023Paris, instanceType := InstanceType.of .t3 .nano }
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
--   NamedKey.of webTier.names.aws.securityGroup "does-not-exist"
--
--   could not synthesize default value for parameter 'h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (NamedKey.indexOfAux webTier.names.aws.securityGroup "does-not-exist").isSome
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

-- **A size the family does not come in.** `instanceType` is a family and a
-- size rather than a string, so the pair is checked: `t3` stops at `2xlarge`
-- and has no bare metal at all.
--
--   instanceType := InstanceType.of .t3 .xlarge32
--
--   could not synthesize default value for parameter '_h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (InstanceFamily.t3.sizes.contains InstanceSize.xlarge32)
--   is false
--
-- The same check catches the subtler cases a curated list of strings would
-- not: gen-7 Intel skips `32xlarge` and jumps `24xlarge` → `48xlarge`, so
-- `InstanceType.of .m7i .xlarge32` is rejected while `.m7a .xlarge32` is
-- fine. And there is no longer a `"t3.nanoo"` to write.

/-! ## Where it cannot be

  Placement is checked the same way, and by the same mechanism — a decidable
  side-condition discharged while the fleet elaborates. -/

-- **A place this fleet's cloud is not in.** Scaleway has a Warsaw region and
-- AWS does not, so `in warsaw` is a compile error *for this fleet* and would
-- not be for a Scaleway-only one. The proposition names both the place and
-- the fleet. `keys` in the message is this fleet's own `webTier.keys`, printed
-- without its prefix:
--
--   fleet webTier in warsaw where …
--
--   could not synthesize default value for parameter '_h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (Locality.warsaw.covers keys)
--   is false

-- **A region code from the wrong cloud**, or one that does not exist. Both are
-- the same check, against the codes that cloud actually has:
--
--   fleet webTier in aws "fr-par" where …
--
--   Tactic `decide` proved that the proposition
--     Assert ((knownRegions ProviderId.aws).contains "fr-par")
--   is false

-- Both hold for this fleet, which is what the two errors above assert the
-- negation of. `covers` is the whole check: every cloud the fleet uses has a
-- region at that place.
#guard Locality.paris.covers webTier.keys = true
#guard Locality.warsaw.covers webTier.keys = false

-- And the placement it produced is AWS's own name for Paris.
#guard (webTier.regions.region .aws).map Region.code = some "eu-west-3"
#guard webTier.regions.covers webTier.keys = true

/-! ## Tearing it down

  `destroy` reconciles against `Plan.absent`, which keeps this fleet's keys and
  declares every one `.absent`. That is the "empty infra": *not* deleting the
  `resource` lines above, which would remove the keys and leave the instances
  running, unmanaged.

  Deletion order is the reverse of creation order, so the instances go before
  the group they sit in — which matters, because EC2 refuses to delete a
  security group that an instance still references.

  **That order is derived.** It used not to be: `orderActions` topologically
  sorted creations and merely *reversed* destructions, so this came out right
  only because `securityGroup` happens to precede `awsInstance` in the `Kind`
  enum. It is now a topological sort of the same graph, reversed, so where the
  enum sits no longer matters — the guard below stays as a check on the result
  rather than as a tripwire on the enum.

  One wrinkle worth knowing, because it shows up in the call below:
  `Plan.absent` carries no specs, so it has no edges to sort by. The fleet's
  own plan is what supplies them, which is `orderActions`' third argument.
  `Infra.Cli` passes it for every teardown; a caller that forgets falls back to
  the old, undeserved behaviour. -/

/-- The same fleet, already applied: enough to make `.absent` produce deletes
    rather than no-ops, since `actions` only deletes what it can see. -/
def existing : World webTier.keys :=
  worldOf
    [ ⟨.aws, .securityGroup, web,
        { observed := { handle := ⟨"web"⟩, groupId := "sg-x", vpcId := "vpc-x" }
          reported := { name := "web"
                        description := "http and https from anywhere, ssh from nowhere"
                        ingress := .unknown } }⟩
    , ⟨.aws, .awsInstance, NamedKey.of webTier.names.aws.awsInstance "web-1",
        { observed := { handle := ⟨"web-1"⟩, instanceId := "i-1"
                        privateIp := "10.0.0.1", state := "running" }
          reported := { name := "web-1", imageId := al2023Paris
                        instanceType := InstanceType.of .t3 .nano
                        securityGroup := ⟨"web"⟩
                        keyName := .unknown, subnetId := .unknown } }⟩ ]

-- Two resources exist here, so the empty declaration deletes two.
#guard (actions (Plan.absent webTier.keys) existing).length = 2

/-- What `push` actually executes. Raw `actions` comes back in enumeration
    order — group first — which is exactly the order that would fail against
    EC2; `orderActions` is what turns it round.

    `webTier.plan` is the third argument: the edges to sort the deletions by,
    which `Plan.absent` cannot supply. -/
private def teardown : List String :=
  match orderActions (Plan.absent webTier.keys)
          (actions (Plan.absent webTier.keys) existing) webTier.plan with
  | .ok ordered => ordered.map Action.slot
  | .error _    => []

-- The instance goes before the group it references, because the instance
-- *references* it — not because of where either sits in the `Kind` enum.
#guard teardown = ["aws/aws-instance/web-1", "aws/security-group/web"]

/-! ## What the fleet says -/

-- The two axes render to AWS's own spelling, which is what reaches the wire.
#guard (InstanceType.of .t3 .nano).name = "t3.nano"

#guard webTier.keys.count .aws .securityGroup = 1
#guard webTier.keys.count .aws .awsInstance = 2

-- AWS only: no Scaleway credentials are read, and no Scaleway API is called.
#guard webTier.keys.providers = [.aws]

-- Three resources: the group and two instances.
#guard (actions webTier.plan (worldOf [])).length = 3

-- Each instance depends on the group — and on exactly one thing. This is the
-- required reference showing up as a scheduling edge; `sourceBucket`, being
-- optional, contributes nothing when unset, whereas this cannot be unset.
#guard (HasDeps.deps (S := AwsInstanceSpec)
         (Build.awsInstance (K := webTier.keys.Key)
           (name := "web-1") (imageId := al2023Paris)
           (instanceType := InstanceType.of .t3 .nano)
           (securityGroup := web))).length = 1

/-- `check` (the default) stays offline: `Infra.Cli.run`'s own `offlinePlan`
    shows the plan from the placeholder backends. `plan` reads the account;
    `apply` creates **real, billable** instances that run until
    terminated. -/
def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "paris-instances" webTier.plan
    (selfCheck := Infra.Cli.offlinePlan webTier.plan
      "paris: two t3.nano behind one security group")
    (accounts := ← Infra.Cli.Accounts.fromEnv)
    (regions := webTier.regions) (args := args)
