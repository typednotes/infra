import Infra.Providers.Aws.Protocols
import Infra.Core.Stage

/-
  EC2: security groups and instances, over the Query protocol.

  AWS-only, so there is no Scaleway half to keep portable — `securityGroup` and
  `awsInstance` are provider-local kinds precisely because the portable
  `compute` kind is serverless-shaped and cannot carry a required network
  reference (see `docs/architecture.md`).

  ## Names, not ids

  Both kinds are keyed by a name a person chooses, never by an AWS-assigned id,
  because `Keys.name` has to be writable in the target before the resource
  exists (`Engine.pullEntries` matches it against `observedHandle`).

    * a security group by `GroupName`
    * an instance by its `Name` tag

  The ids (`sg-…`, `i-…`) are post-apply values and live in `ObservedOf`, which
  is where the API calls below get them from.

  ## What is not implemented, and why

  `instanceType` reaches this file as a plain string and leaves it as one:
  `Infra.Core.InstanceType` is a string underneath precisely so that neither
  `RunInstances` nor `DescribeInstances` needs a parse that could fail. The
  family/size split is how a *declaration* is written and checked, not how the
  value travels.

  `instanceType` is classified `forcesReplace` even though EC2 can resize a
  *stopped* instance. Doing that in place would mean stopping the instance,
  polling until it is actually stopped, modifying, and starting again — a
  multi-call state machine this backend deliberately does not have. Replace is
  the honest description of what this tool will do, and a plan says REPLACE
  before anything happens.

  Ingress rules are only ever *added* on update. Revoking a rule that is
  present in the cloud but absent from the target is not implemented; the
  divergence is still reported, so the plan is honest about wanting a change it
  will only partly make. Both limitations are recorded in `docs/providers.md`.

  **None of the field names or response shapes below have been checked against
  a real account.** Signing is verified offline; what is being signed is not.
-/

namespace Infra.Providers.Kinds.Ec2

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws

private def version : String := "2016-11-15"

/-- EC2 always wraps collections in `item` children, so this is
    `Query.listItems` with the leaf tag fixed. -/
private def items (parent : Text.XML.Element) (name : String) : List Text.XML.Element :=
  Query.listItems parent name "item"

-- ══════════════════════════════════════════════════════════════
-- Security groups
-- ══════════════════════════════════════════════════════════════

namespace SecurityGroup

/-- Every group the credentials can see, as `(name, id, vpcId)`. -/
def list (creds : Credentials) (ep : Endpoint) : IO (List (String × String × String)) := do
  let root ← Query.call creds ep "DescribeSecurityGroups" version
  return (items root "securityGroupInfo").filterMap fun g =>
    match g.childText "groupName" with
    | some n => some (n, (g.childText "groupId").getD "", (g.childText "vpcId").getD "")
    | none   => none

/-- The group's own id, by name. Needed by `awsInstance`, which references a
    group by name but must launch with `SecurityGroupId`.

    Filtered server-side. Scanning an unfiltered `list` client-side would pull
    every group in the region to find one, on every instance create. -/
def idOf (creds : Credentials) (ep : Endpoint) (name : String) : IO (Option String) := do
  let root ← Query.call creds ep "DescribeSecurityGroups" version
    [("GroupName.1", name)]
  return (items root "securityGroupInfo").head?.bind (·.childText "groupId")

/-- Description and inbound TCP rules, by name. Rules the spec cannot express
    — anything that is not a single TCP port with a CIDR — are dropped rather
    than misreported, which is why `ingress` diverging can mean "the cloud has
    a rule this tool cannot see". -/
def read (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (String × String × Partial (List (Nat × String))) := do
  let root ← Query.call creds ep "DescribeSecurityGroups" version
    [("GroupName.1", name)]
  match (items root "securityGroupInfo").head? with
  | none   => return ("", "", .unknown)
  | some g =>
    let description := (g.childText "groupDescription").getD ""
    let rules := (items g "ipPermissions").flatMap fun perm =>
      match perm.childText "ipProtocol", (perm.childText "fromPort").bind String.toNat? with
      | some "tcp", some port =>
        (items perm "ipRanges").filterMap fun r => (r.childText "cidrIp").map (port, ·)
      | _, _ => []
    return ((g.childText "groupId").getD "", description, .known rules)

/-- Authorize one inbound TCP port from one CIDR.

    Shared by `create` and `update` so the parameter names exist once: they are
    unverified against a real account, and the first correction should not have
    to be made twice. -/
private def authorize (creds : Credentials) (ep : Endpoint) (groupId : String)
    (port : Nat) (cidr : String) : IO Unit := do
  let _ ← Query.call creds ep "AuthorizeSecurityGroupIngress" version
    [ ("GroupId", groupId), ("IpPermissions.1.IpProtocol", "tcp")
    , ("IpPermissions.1.FromPort", toString port)
    , ("IpPermissions.1.ToPort", toString port)
    , ("IpPermissions.1.IpRanges.1.CidrIp", cidr) ]

/-- Create the group, then authorize its rules. Two calls, because
    `CreateSecurityGroup` takes no rules. Returns the new group's id; the VPC
    is not reported by this call, and the caller says so rather than having a
    blank threaded back through here. -/
def create (creds : Credentials) (ep : Endpoint)
    (name description : String) (ingress : List (Nat × String)) : IO String := do
  let root ← Query.call creds ep "CreateSecurityGroup" version
    [("GroupName", name), ("GroupDescription", description)]
  let groupId := (root.childText "groupId").getD ""
  for (port, cidr) in ingress do
    authorize creds ep groupId port cidr
  return groupId

/-- Authorize any rule in the target that the cloud does not already have.

    Additive only: see the module note. Already-present rules are skipped
    rather than re-authorized, because EC2 rejects a duplicate outright. -/
def update (creds : Credentials) (ep : Endpoint) (name : String)
    (ingress : List (Nat × String)) : IO String := do
  -- One describe, not two: `read` already returns the id alongside the rules.
  let (groupId, _, existing) ← read creds ep name
  if groupId.isEmpty then
    throw (IO.userError s!"security group '{name}' disappeared between plan and apply")
  let have' := existing.getD []
  for (port, cidr) in ingress do
    unless have'.contains (port, cidr) do
      authorize creds ep groupId port cidr
  return groupId

/-- Delete, retrying while AWS still says something depends on the group.

    `Instance'.delete` already waits for `terminated`, so by the time this runs
    the instances are gone — but detaching their network interfaces can lag a
    little behind that, and AWS reports the gap as `DependencyViolation`. It is
    the one error here that is worth retrying rather than surfacing: it means
    "not yet", where every other failure means "no".

    Any other error propagates immediately, so a genuinely undeletable group
    still fails fast. -/
private def deleteRetrying (creds : Credentials) (ep : Endpoint) (name : String) :
    Nat → IO Unit
  | 0 => do
    -- Out of patience: make the last attempt's real error the one reported.
    let _ ← Query.call creds ep "DeleteSecurityGroup" version [("GroupName", name)]
  | n + 1 => do
    match ← (Query.call creds ep "DeleteSecurityGroup" version
              [("GroupName", name)]).toBaseIO with
    | .ok _ => pure ()
    | .error e =>
      if ((toString e).splitOn "DependencyViolation").length > 1 then
        IO.sleep 3000
        deleteRetrying creds ep name n
      else
        throw e

def delete (creds : Credentials) (ep : Endpoint) (name : String) : IO Unit :=
  deleteRetrying creds ep name 20

end SecurityGroup

-- ══════════════════════════════════════════════════════════════
-- Instances
-- ══════════════════════════════════════════════════════════════

namespace Instance'

/-- The `Name` tag of an instance, which is this fleet's identifier for it. -/
private def nameTag (i : Text.XML.Element) : Option String :=
  (items i "tagSet").findSome? fun t =>
    if t.childText "key" == some "Name" then t.childText "value" else none

/-- Every instance with a `Name` tag, as `(name, id, privateIp, state)`.

    Terminated instances are dropped: EC2 keeps reporting them for about an
    hour, and treating one as existing would make a plan refuse to recreate
    something that is genuinely gone. -/
def list (creds : Credentials) (ep : Endpoint) :
    IO (List (String × String × String × String)) := do
  let root ← Query.call creds ep "DescribeInstances" version
  let instances := (items root "reservationSet").flatMap fun r => items r "instancesSet"
  return instances.filterMap fun i =>
    let state := match i.child "instanceState" with
      | some st => (st.childText "name").getD ""
      | none    => ""
    if state == "terminated" || state == "shutting-down" then none
    else match nameTag i with
      | some n => some (n, (i.childText "instanceId").getD "",
                        (i.childText "privateIpAddress").getD "", state)
      | none   => none

/-- The live instance carrying this `Name` tag, as `(id, privateIp, state)`.

    Filtered server-side by the tag, and shared by `Live.lean`'s `update` and
    `delete`, which both need an instance id and only have a name. Doing it
    here rather than in the dispatch layer keeps the "terminated does not
    count" rule in one place, next to `list`'s copy of the same reasoning. -/
def byName (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (Option (String × String × String)) := do
  let root ← Query.call creds ep "DescribeInstances" version
    [("Filter.1.Name", "tag:Name"), ("Filter.1.Value.1", name)]
  let instances := (items root "reservationSet").flatMap fun r => items r "instancesSet"
  return instances.findSome? fun i =>
    let state := match i.child "instanceState" with
      | some st => (st.childText "name").getD ""
      | none    => ""
    if state == "terminated" || state == "shutting-down" then none
    else some ((i.childText "instanceId").getD "",
               (i.childText "privateIpAddress").getD "", state)

/-- Instance type, image, security group name and launch-time placement, by
    `Name` tag. The security group is reported by *name*, matching how the
    spec references it. -/
def read (creds : Credentials) (ep : Endpoint) (name : String) :
    IO (String × String × String × Partial String × Partial String) := do
  let root ← Query.call creds ep "DescribeInstances" version
    [("Filter.1.Name", "tag:Name"), ("Filter.1.Value.1", name)]
  let instances := (items root "reservationSet").flatMap fun r => items r "instancesSet"
  let live := instances.filter fun i =>
    match i.child "instanceState" with
    | some st => (st.childText "name").getD "" != "terminated"
    | none    => true
  match live.head? with
  | none   => return ("", "", "", .unknown, .unknown)
  | some i =>
    let imageId := (i.childText "imageId").getD ""
    let instanceType := (i.childText "instanceType").getD ""
    let group := (items i "groupSet").findSome? (·.childText "groupName") |>.getD ""
    let keyName := match i.childText "keyName" with
      | some k => Partial.known k
      | none   => .known ""
    let subnetId := match i.childText "subnetId" with
      | some sn => Partial.known sn
      | none    => .known ""
    return (imageId, instanceType, group, keyName, subnetId)

/-- Launch one instance and tag it.

    `securityGroup` arrives as a group *name* (a settled `Handle
    .securityGroup`), so its id is looked up first: `SecurityGroupId` works in
    every VPC, whereas the name-based parameter only works in the default one.
    That lookup is the reason this takes the endpoint rather than just
    parameters. -/
def create (creds : Credentials) (ep : Endpoint)
    (name imageId instanceType securityGroupName keyName subnetId : String) :
    IO (String × String × String) := do
  let groupId ← match ← SecurityGroup.idOf creds ep securityGroupName with
    | some gid => pure gid
    | none     => throw (IO.userError
        s!"security group '{securityGroupName}' not found in {ep.region}; \
it must exist before an instance can reference it")
  let params :=
    [ ("ImageId", imageId), ("InstanceType", instanceType)
    , ("MinCount", "1"), ("MaxCount", "1")
    , ("SecurityGroupId.1", groupId) ]
    ++ (if keyName.isEmpty then [] else [("KeyName", keyName)])
    ++ (if subnetId.isEmpty then [] else [("SubnetId", subnetId)])
  let root ← Query.call creds ep "RunInstances" version params
  match (items root "instancesSet").head? with
  | none => throw (IO.userError s!"RunInstances returned no instance for '{name}'")
  | some i =>
    let instanceId := (i.childText "instanceId").getD ""
    -- The `Name` tag is this fleet's identifier, so it must be set before the
    -- next `pull` can recognise what was just created.
    let _ ← Query.call creds ep "CreateTags" version
      [("ResourceId.1", instanceId), ("Tag.1.Key", "Name"), ("Tag.1.Value", name)]
    let state := match i.child "instanceState" with
      | some st => (st.childText "name").getD ""
      | none    => ""
    return (instanceId, (i.childText "privateIpAddress").getD "", state)

/-- Retag, and reassign the security group. The only two changes
    `Divergent .awsInstance` classifies as mutable. -/
def update (creds : Credentials) (ep : Endpoint) (instanceId : String)
    (name securityGroupName : String) : IO Unit := do
  let _ ← Query.call creds ep "CreateTags" version
    [("ResourceId.1", instanceId), ("Tag.1.Key", "Name"), ("Tag.1.Value", name)]
  match ← SecurityGroup.idOf creds ep securityGroupName with
  | none     => throw (IO.userError s!"security group '{securityGroupName}' not found")
  | some gid =>
    let _ ← Query.call creds ep "ModifyInstanceAttribute" version
      [("InstanceId", instanceId), ("GroupId.1", gid)]

/-- The state AWS reports for one instance id, unfiltered.

    Unlike `byName` this hides nothing: `shutting-down` and `terminated` both
    come back, which is the entire point — they are the states the caller has
    to be able to tell apart. `none` means AWS no longer reports the instance
    at all, which it eventually stops doing. -/
def stateById (creds : Credentials) (ep : Endpoint) (instanceId : String) :
    IO (Option String) := do
  let root ← Query.call creds ep "DescribeInstances" version
    [("InstanceId.1", instanceId)]
  let instances := (items root "reservationSet").flatMap fun r => items r "instancesSet"
  return instances.head?.map fun i =>
    match i.child "instanceState" with
    | some st => (st.childText "name").getD ""
    | none    => ""

/-- Poll until the instance is really gone, or give up with a named error. -/
private def awaitTerminated (creds : Credentials) (ep : Endpoint) (instanceId : String) :
    Nat → IO Unit
  | 0 => throw (IO.userError
      s!"instance {instanceId} did not reach 'terminated' in time; its security group \
cannot be deleted until it does — re-run `destroy` once it has")
  | n + 1 => do
    match ← stateById creds ep instanceId with
    | none               => pure ()          -- no longer reported at all
    | some "terminated"  => pure ()
    | some _             => IO.sleep 3000; awaitTerminated creds ep instanceId n

/-- Terminate by instance id, and **wait for it to finish**.

    `TerminateInstances` is asynchronous: it returns as soon as the request is
    accepted, and the instance then spends up to a minute or so in
    `shutting-down`, during which its network interface still references its
    security group. Deleting that group meanwhile fails with

        DependencyViolation: resource sg-… has a dependent object

    which is what a `destroy` of `example/ParisInstances.lean` hit — the
    scheduler ordered the instance before the group, correctly, and then raced
    it. Ordering alone is not enough when a provider's delete is asynchronous;
    something has to wait.

    Bounded at a couple of minutes, then a named error telling the operator to
    re-run rather than hanging indefinitely. -/
def delete (creds : Credentials) (ep : Endpoint) (instanceId : String) : IO Unit := do
  let _ ← Query.call creds ep "TerminateInstances" version [("InstanceId.1", instanceId)]
  awaitTerminated creds ep instanceId 40

end Instance'

end Infra.Providers.Kinds.Ec2
