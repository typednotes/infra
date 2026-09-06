import Infra

/-!
  # The test driver: offline by default, live on request

  `lake test` runs the offline checks and touches no cloud. `lake test -- aws`
  (or `scaleway`, or `gcp`) creates a real resource, checks it converged,
  and deletes it again.

  ## What a leg creates

  Nine of the fourteen kinds, on the clouds that have them — see the note
  above the fleets for which five are excluded and why each is a real
  obstacle rather than a to-do.

  This began as one queue per cloud, and the reasoning for that choice is
  still the reasoning behind every name here: region-scoped rather than
  globally unique so concurrent runs in different accounts do not collide,
  costing approximately nothing, and creating and deleting in seconds. Buckets
  were excluded for failing the first of those; they are included now because
  a fixed random suffix satisfies it without making the name dynamic.

  ## AWS: sixty seconds between runs

  SQS refuses to create a queue with the name of one deleted less than sixty
  seconds ago (`AWS.SimpleQueueService.QueueDeletedRecently`). A fleet's
  resource names are fixed at compile time, so this test cannot dodge it with a
  unique name per run — back-to-back AWS runs inside that window will fail on
  create, and the error says so plainly enough that it is left to say it rather
  than papered over with a retry that would hide a real failure just as well.

  The workflow's `concurrency` group stops two runs overlapping; it does not
  impose a gap between them. Wait a minute.

  ## Teardown is not conditional

  The whole point of a live test is that it leaves nothing behind, and the
  moment that matters most is when the assertions fail. So `destroy` runs from
  a `finally`, and its own failure is reported *alongside* the original one
  rather than replacing it — a teardown error that masks the real failure is
  how a CI job becomes a mystery and a bill.

  Everything is named `ci-tests-infra-…` so that anything this leaks is
  identifiable at a glance in a console, and safe to delete by hand.
-/

open Infra.Core
open Infra.Specs

/-- The common prefix. Anything in an account with this name was created by a
    CI run of this repository and can be deleted. -/
def ciPrefix : String := "ci-tests-infra-"

/-! ## What the live fleets cover, and what they cannot

  Nine of the fourteen kinds, on the clouds that have them. Every one is
  created from nothing, checked, and deleted, so a leg exercises `create`,
  `list`, `read`, the diff, `delete` and the absence check across most of the
  library rather than one corner of it.

  Two resources were already better than one, because a set is applied and
  torn down as a set — `create` runs more than once in an apply, `delete` more
  than once in a destroy, and a single-resource test cannot tell a working
  scheduler from a lucky one. Nine makes that argument properly.

  ## The five that are not here, and why each is a real obstacle

  Not an oversight, and not a list that can be worked through by adding lines.
  Each fails for a reason a test cannot arrange:

  - **`compute`** cannot be created from nothing. Lambda (container image),
    Cloud Run and Scaleway Containers all require an image that already exists
    in a registry, so testing it means building and pushing a real one first —
    a different job from this one.
  - **`scalewayContainer`** needs an image for the same reason, and
    **`scalewayFunction`** needs deployable code.
  - **`awsInstance`** needs an AMI id, which is region-specific and goes stale.
    Hard-coding one puts a rotting constant in a test whose failure would look
    like a bug in this library. It also bills by the second and takes minutes
    to terminate.
  - **`postgres`** takes five to fifteen minutes to create, and as long to
    delete, on every cloud — longer than the workflow's own step timeout. It
    would not be a slow test but a failing one, and it costs real money while
    it exists.

  The namespaces the Scaleway ones depend on are covered, because those *can*
  be created from nothing.

  ## Bucket names are global, which needed solving rather than avoiding

  Object storage names are unique across an entire cloud, not per account, and
  a fleet's names are fixed at compile time. That is why buckets were kept out
  of this test until now, and the reasoning was sound.

  What makes them includable is a fixed random suffix: unique in practice, so
  nobody else holds the name, and still a compile-time constant. The cost is
  small and worth stating rather than hiding — a **fork running this test will
  collide with this repository's buckets**, and changing `bucketSuffix` is the
  fix. A name that looked generic and failed mysteriously for the next person
  would be worse.

  ## The clouds must be allowed to do all this

  More kinds means more permissions, and the CI identities do not have them
  yet — AWS's role is scoped to SQS alone, and GCP's service account holds only
  `roles/pubsub.editor`. `ci/README.md` lists what to grant per cloud. Until
  it is granted a leg fails with a permission error, which is the correct
  failure: the cloud's own refusal, reported rather than papered over.
-/

/-- The environment variable holding the test secret's value. -/
def secretValueVar : String := "CI_TESTS_INFRA_SECRET"

/-- The suffix that makes the bucket names globally unique. See the note above:
    change it in a fork. -/
def bucketSuffix : String := "7c1f9a2e"

fleet awsLive in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret"
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource imageRegistry "ci-tests-infra-images" { immutableTags := true }
    resource objectStore "ci-tests-infra-store-7c1f9a2e" { versioning := true }
    -- Both bucket kinds: they differ in Object Lock, which is creation-time
    -- only, so nothing short of a real create exercises it.
    resource s3Bucket "ci-tests-infra-lock-7c1f9a2e"
      { versioning := true, objectLock := true }
    resource securityGroup "ci-tests-infra-sg"
      { description := "created and destroyed by infra's live test" }
    resource iam "ci-tests-infra-user" {}

fleet scalewayLive in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret"
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource imageRegistry "ci-tests-infra-images" {}
    resource objectStore "ci-tests-infra-store-scw-7c1f9a2e" { versioning := true }
    resource iam "ci-tests-infra-app" {}
    resource scalewayFunctionNamespace "ci-tests-infra-fns"
      { description := "created and destroyed by infra's live test" }
    resource scalewayContainerNamespace "ci-tests-infra-ctrs"
      { description := "created and destroyed by infra's live test" }


/-! GCP's leg used to be expected to fail: there was no live GCP backend, so
    it raised on the first call, and this comment said the day one landed the
    leg would start passing on its own. It has, and it does. `queues` on GCP is
    a Pub/Sub topic — see `Infra.Providers.Gcp.PubSub`.

    Note what is *not* asserted as a result. A Pub/Sub topic has no visibility
    timeout — that belongs to a subscription — so `visibilityTimeoutSec := 30`
    below is declared, carried through the plan, and then reported `unknown` by
    the backend. The convergence check still means something, because an
    unknown field is not a divergence; it just does not mean that 30 was
    stored anywhere. It is kept identical to the other two fleets so the three
    legs differ only in the cloud they name. -/

fleet gcpLive in paris where
  provider gcp where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret"
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource imageRegistry "ci-tests-infra-images" {}
    resource objectStore "ci-tests-infra-store-gcp-7c1f9a2e" { versioning := true }
    -- Google constrains a service-account id to 6-30 lowercase characters
    -- starting with a letter. `Gcp.Iam.checkAccountId` rejects a bad one by
    -- naming the rule, because the name is fixed at compile time — so a bad
    -- one fails every apply rather than one of them.
    resource iam "ci-tests-infra-sa" {}

-- One guard per (fleet, kind): the count is what would silently drift if a
-- resource were added to a fleet and forgotten here, and the prefix guards are
-- what make anything this ever leaks identifiable in a console at a glance.
#guard awsLive.keys.count .aws .queues = 1
#guard awsLive.keys.count .aws .secrets = 1
#guard awsLive.keys.count .aws .imageRegistry = 1
#guard awsLive.keys.count .aws .objectStore = 1
#guard awsLive.keys.count .aws .s3Bucket = 1
#guard awsLive.keys.count .aws .securityGroup = 1
#guard awsLive.keys.count .aws .iam = 1

#guard scalewayLive.keys.count .scaleway .queues = 1
#guard scalewayLive.keys.count .scaleway .secrets = 1
#guard scalewayLive.keys.count .scaleway .imageRegistry = 1
#guard scalewayLive.keys.count .scaleway .objectStore = 1
#guard scalewayLive.keys.count .scaleway .iam = 1
#guard scalewayLive.keys.count .scaleway .scalewayFunctionNamespace = 1
#guard scalewayLive.keys.count .scaleway .scalewayContainerNamespace = 1

#guard gcpLive.keys.count .gcp .queues = 1
#guard gcpLive.keys.count .gcp .secrets = 1
#guard gcpLive.keys.count .gcp .imageRegistry = 1
#guard gcpLive.keys.count .gcp .objectStore = 1
#guard gcpLive.keys.count .gcp .iam = 1

-- Every name carries the prefix, on every kind. Checked per kind rather than
-- in aggregate, because a name that escaped the convention would otherwise be
-- invisible until it leaked.
#guard awsLive.names.aws.queues.all (ciPrefix.isPrefixOf ·)
#guard awsLive.names.aws.secrets.all (ciPrefix.isPrefixOf ·)
#guard awsLive.names.aws.imageRegistry.all (ciPrefix.isPrefixOf ·)
#guard awsLive.names.aws.objectStore.all (ciPrefix.isPrefixOf ·)
#guard awsLive.names.aws.s3Bucket.all (ciPrefix.isPrefixOf ·)
#guard awsLive.names.aws.securityGroup.all (ciPrefix.isPrefixOf ·)
#guard awsLive.names.aws.iam.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.queues.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.secrets.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.imageRegistry.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.objectStore.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.iam.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.scalewayFunctionNamespace.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.scalewayContainerNamespace.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.queues.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.secrets.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.imageRegistry.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.objectStore.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.iam.all (ciPrefix.isPrefixOf ·)

-- The bucket names carry the uniqueness suffix. Without it they are one
-- collision away from making this test permanently unrunnable, and the whole
-- reason buckets could be included at all.
#guard awsLive.names.aws.objectStore.all (·.endsWith bucketSuffix)
#guard awsLive.names.aws.s3Bucket.all (·.endsWith bucketSuffix)
#guard scalewayLive.names.scaleway.objectStore.all (·.endsWith bucketSuffix)
#guard gcpLive.names.gcp.objectStore.all (·.endsWith bucketSuffix)

-- No plaintext secret is committed, in any of the three. Decidable, so the
-- compiler establishes it rather than a reviewer.
#guard awsLive.plan.secretsAreSound
#guard scalewayLive.plan.secretsAreSound
#guard gcpLive.plan.secretsAreSound

-- Each fleet is single-cloud, so a run for one provider never authenticates
-- another — which is what lets the workflow pass one set of secrets.
#guard awsLive.keys.providers = [.aws]
#guard scalewayLive.keys.providers = [.scaleway]
#guard gcpLive.keys.providers = [.gcp]

/-- How long to let a cloud's listing catch up before calling it a failure.

    Raised from 60 when the fleets went from one resource to seven. It is not
    the count that matters but the slowest member: Scaleway's Functions and
    Containers namespaces take tens of seconds to become visible and tens more
    to disappear, and a bucket's listing is not instant either. The old bound
    was comfortable for a queue and would have made those look like failures.

    Both polls use it, so the worst case is twice this, which still fits inside
    the workflow's twelve-minute step timeout. -/
def settleSeconds : Nat := 180

/-- Re-`pull` until `done` holds, or until `settleSeconds` have passed.

    Every cloud list API here is eventually consistent to some degree, so a
    single read immediately after a write measures propagation delay rather
    than correctness. Returns whatever `report` says is outstanding at the end,
    which is empty exactly when it succeeded.

    Fixed one-second steps rather than a backoff: the waits are short, and a
    backoff would make the worst case unpredictable in a job that has a
    timeout. No `partial` — `go` recurses on a decreasing `Nat`, so the bound
    is a real measure. -/
def waitFor {κ : Keys} (root : System.FilePath) (bs : Backends)
    (done : World κ → Bool) (report : World κ → List String) : IO (List String) := do
  let rec go (left : Nat) : IO (List String) := do
    let w ← pull (κ := κ) root bs
    if done w then return []
    match left with
    | 0     => return report w
    | n + 1 => IO.sleep 1000; go n
  go settleSeconds

/-- Create, check, and delete — with the delete guaranteed.

    `apply` twice would be the stronger convergence check, but the second run
    is what this asserts instead: after one apply, the plan must be empty.
    That is the same property `example/MultiRegion.lean` guards offline, here
    against a real account. -/
def liveRoundTrip {κ : Keys} (name : String) (target : Plan κ) (regions : Regions) :
    IO Unit := do
  let cacheRoot : System.FilePath := ".infra" / s!"live-{name}"
  let (bs, _) ← Infra.Cli.liveFor κ regions
  IO.println s!"[{name}] creating…"
  let world ← pull (κ := κ) cacheRoot bs
  discard <| push bs target world { apply := true } (edges := target)

  -- Teardown runs whether or not the checks below pass.
  let teardown : IO Unit := do
    IO.println s!"[{name}] destroying…"
    let w ← pull (κ := κ) cacheRoot bs
    discard <| push bs (Plan.absent κ) w { apply := true } (edges := target)
    -- Same again on the way down, and it matters more here: a `destroy` that
    -- ran while the resource was still invisible would find nothing to do and
    -- report success, leaving it behind. Waiting for it to *appear* is not
    -- possible in general, so what this asserts is that after the delete
    -- settles, a fresh listing shows nothing — and it polls to get there.
    let leftover ← waitFor cacheRoot bs (fun w => (actions (Plan.absent κ) w).isEmpty)
      (fun w => (actions (Plan.absent κ) w).map Action.render)
    unless leftover.isEmpty do
      throw (IO.userError s!"[{name}] {leftover.length} resource(s) survived destroy \
after {settleSeconds}s — look for 'ci-tests-infra-*' in the account")
    -- And the cache must agree. `save` used to leave the file of an emptied
    -- `(provider, kind)` pair on disk untouched, so the cache went on listing
    -- what had just been deleted. Checking it here is what would have caught
    -- that against a real account rather than by reading the files by hand.
    let cached ← Persistence.load (κ := κ) cacheRoot
    unless cached.isEmpty do
      throw (IO.userError
        s!"[{name}] destroyed, but the cache still lists {cached.length} resource(s)")
    IO.println s!"[{name}] destroyed, and the cache is empty"

  let checks : IO Unit := do
    -- Poll rather than read once. A cloud's list API is eventually consistent
    -- — SQS's `ListQueues` explicitly so — and a resource created a moment ago
    -- may simply not be visible yet. Checking immediately tests the API's
    -- propagation delay rather than this library, which is what the first live
    -- run of this test actually did.
    let outstanding ← waitFor cacheRoot bs (fun w => (plan target w).isEmpty)
      (fun w => (plan target w).map Action.render)
    unless outstanding.isEmpty do
      throw (IO.userError s!"[{name}] did not converge after {settleSeconds}s: \
{String.intercalate ", " outstanding}")
    IO.println s!"[{name}] converged: a second apply would do nothing"

  match ← checks.toBaseIO with
  | .ok _ => teardown
  | .error e =>
    -- Report both. A teardown failure that swallowed the real error is how a
    -- CI job becomes a mystery and a bill.
    match ← teardown.toBaseIO with
    | .ok _     => throw e
    | .error e2 => throw (IO.userError s!"{e}\nand teardown also failed: {e2}")

def usage : String :=
  "usage: lake test [-- <aws|scaleway|gcp>]\n\n\
  With no argument: the offline checks, no cloud, no credentials, no cost.\n\
  With a provider:  creates a real queue and a real secret, both named\n\
                    'ci-tests-infra-*', checks the fleet converged, and\n\
                    deletes both again.\n\n\
  The secret's value is read from the environment, never from the fleet: a\n\
  committed literal would not compile, which is what `secretsAreSound`\n\
  proves. Set " ++ secretValueVar ++ " before running a live leg."

def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    -- The safe default, and what `lake test` runs in ordinary CI.
    Infra.Cli.offlinePlan awsLive.plan "offline checks — no cloud contacted"
    IO.println "\nFor a live round trip: lake test -- <aws|scaleway|gcp>"
    return 0
  | [p] =>
    let run : IO Unit ← match p with
      | "aws"      => pure (liveRoundTrip "aws" awsLive.plan awsLive.regions)
      | "scaleway" => pure (liveRoundTrip "scaleway" scalewayLive.plan scalewayLive.regions)
      | "gcp"      => pure (liveRoundTrip "gcp" gcpLive.plan gcpLive.regions)
      | other      => throw (IO.userError s!"unknown provider '{other}'\n\n{usage}")
    match ← run.toBaseIO with
    | .ok _    => IO.println s!"[{p}] ok"; return 0
    | .error e => IO.eprintln s!"error: {e}"; return 1
  | _ => IO.eprintln usage; return 2
