import Infra

/-!
  # The test driver: offline by default, live on request

  `lake test` runs the offline checks and touches no cloud. `lake test -- aws`
  (or `scaleway`, or `gcp`) creates eight or nine real resources, checks the
  fleet converged, and deletes them again.

  ## What a leg creates

  Eleven of the fourteen kinds, on the clouds that have them, in three
  dependency shapes — see the notes above the fleets and above the guards for
  which three kinds are excluded, and why each is a real obstacle rather than
  a to-do.

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

  Eleven of the fourteen kinds, on the clouds that have them — eight or nine
  resources per leg (AWS 9, Scaleway 9, GCP 8). Every one is created from nothing, checked, and deleted,
  so a leg exercises `create`, `list`, `read`, the diff, `delete` and the
  absence check across most of the library rather than one corner of it.

  One resource could never tell a working scheduler from a lucky one: a set is
  applied and torn down as a set, so `create` and `delete` each run eight or nine
  times in a pass. The **shape** matters more than the count, and the three
  dependency patterns are described above the guards below.

  ## The three that are not here, and why each is a real obstacle

  Not an oversight, and not a list that can be worked through by adding lines.
  Each fails for a reason a test cannot arrange:

  - **`scalewayFunction`** needs deployable *code*, not merely an image, and
    there is no public equivalent to point at the way there is for a container.
  - **`awsInstance`** needs an AMI id, which is region-specific and goes stale.
    Hard-coding one puts a rotting constant in a test whose failure would look
    like a bug in this library. It also bills by the second and takes minutes
    to terminate.
  - **`postgres`** takes five to fifteen minutes to create, and as long to
    delete, on every cloud — longer than the workflow's own step timeout. It
    would not be a slow test but a failing one, and it costs real money while
    it exists.

  ## `compute` was on that list and should not have been

  It was excluded for needing an image that already exists, which was true of
  Lambda and assumed of the rest. Cloud Run and Serverless Containers both pull
  **public** images, so Cloud Run runs Google's own sample and the Scaleway
  container pulls nginx, and nothing has to be built or pushed first.

  Lambda really cannot: a container function must come from an ECR repository
  in the same account. That is why `compute` is covered on GCP, its
  provider-local cousin `scalewayContainer` on Scaleway, and neither on AWS.

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

  More kinds means more permissions. `ci/README.md` lists what to grant per
  cloud, and until it is granted a leg fails with the cloud's own refusal —
  which is the correct failure, reported rather than papered over.

  As of 0.4.2: **AWS's leg passes.** Scaleway's is blocked on its permission
  sets. GCP has every role and API it needs and one grant more subtle than a
  role — deploying a Cloud Run service as an identity requires
  `iam.serviceAccounts.actAs` on that identity, which is not implied by being
  allowed to create services.

  Google needs a third thing besides roles and `actAs`, and it is easy to
  mistake for a permission problem: each **API must be enabled on the
  project**, separately from anyone being allowed to call it.
-/

/-- The environment variable holding the test secret's value. -/
def secretValueVar : String := "CI_TESTS_INFRA_SECRET"

/-- The suffix that makes the bucket names globally unique. See the note above:
    change it in a fork. -/
def bucketSuffix : String := "7c1f9a2e"

fleet awsLive in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as awsBase
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    -- Two secrets composed from the same one: a chain (base → derived) and a
    -- fan-out (one node with two dependents). Both edges come from
    -- `HasDeps SecretsSpec`'s `depsReq s.valueFrom`, and both force the base
    -- to be created first and deleted last — in one apply, with no operator
    -- pasting a value in between.
    resource secrets "ci-tests-infra-derived-a"
      { valueFrom := composed expr!"a:{secretValueOf awsBase}" }
    resource secrets "ci-tests-infra-derived-b"
      { valueFrom := composed expr!"b:{secretValueOf awsBase}" }
    resource imageRegistry "ci-tests-infra-images" { immutableTags := true }
    resource objectStore "ci-tests-infra-store-7c1f9a2e" { versioning := true }
    -- Both bucket kinds: they differ in Object Lock, which is creation-time
    -- only, so nothing short of a real create exercises it.
    resource s3Bucket "ci-tests-infra-lock-7c1f9a2e"
      { versioning := true, objectLock := true }
    resource securityGroup "ci-tests-infra-sg"
      { description := "created and destroyed by the infra live test" }
    resource iam "ci-tests-infra-user" {}

fleet scalewayLive in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as scwBase
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-derived-a"
      { valueFrom := composed expr!"a:{secretValueOf scwBase}" }
    resource secrets "ci-tests-infra-derived-b"
      { valueFrom := composed expr!"b:{secretValueOf scwBase}" }
    resource imageRegistry "ci-tests-infra-images" {}
    resource objectStore "ci-tests-infra-store-scw-7c1f9a2e" { versioning := true }
    -- No `iam` here, unlike the AWS and GCP fleets. Scaleway's IAM
    -- applications live in the **organization**, not in a project, so testing
    -- the kind would need CI to hold organization-level IAM rights — and
    -- those cannot be confined to the isolated CI project the rest of this
    -- fleet lives in. One kind of live coverage is the cheaper thing to give
    -- up. `iam` is still covered on the other two clouds, where the identity
    -- is project- or account-scoped.
    resource scalewayFunctionNamespace "ci-tests-infra-fns"
      { description := "created and destroyed by the infra live test" }
    resource scalewayContainerNamespace "ci-tests-infra-ctrs" as scwCtrs
      { description := "created and destroyed by the infra live test" }
    -- Fan-in: this depends on the namespace above (a *key* reference, via
    -- `depsKey`) and on the base secret (via `depsKeys s.secretEnv`), so two
    -- edges of two different provenances converge on one resource. It is the
    -- only place the live test exercises `depsKey`/`depsKeys` rather than an
    -- expression reference, and teardown has to reverse both.
    --
    -- A public image, which is what makes this includable at all: Serverless
    -- Containers can pull from an external registry, so nothing has to be
    -- built and pushed first.
    resource scalewayContainer "ci-tests-infra-ctr"
      { namespace' := scwCtrs
      , image      := "docker.io/library/nginx:alpine"
      , port       := 80
      , minScale   := 0
      , maxScale   := 1
      , memoryMb   := 256
      , timeoutSec := 60
      , secretEnv  := [("BASE", scwBase)] }


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
    resource secrets "ci-tests-infra-secret" as gcpBase
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-derived-a"
      { valueFrom := composed expr!"a:{secretValueOf gcpBase}" }
    resource secrets "ci-tests-infra-derived-b"
      { valueFrom := composed expr!"b:{secretValueOf gcpBase}" }
    resource imageRegistry "ci-tests-infra-images" {}
    resource objectStore "ci-tests-infra-store-gcp-7c1f9a2e" { versioning := true }
    -- `compute` becomes testable here and nowhere else, because Cloud Run will
    -- pull a public image. Google's own sample is used rather than something
    -- of ours: nothing to build, and it will not disappear.
    --
    -- Lambda is why AWS has no `compute` here — a container function must come
    -- from an ECR repository in the same account, so it cannot be created from
    -- nothing.
    resource compute "ci-tests-infra-run"
      { image      := "gcr.io/cloudrun/hello"
      , memoryMb   := 512
      , timeoutSec := 60
      -- Naming the runtime identity, rather than letting Cloud Run pick. Its
      -- default is the project's compute service account, which Google grants
      -- `roles/editor` — so a test that said nothing here would deploy a
      -- container running as an Editor on the whole project, and enshrine
      -- that as the example. Deploying as an identity still requires
      -- `iam.serviceAccounts.actAs` on it; `ci/README.md` has the grant.
      , executionRole := "infra-ci@typednotes.iam.gserviceaccount.com" }
    -- Google constrains a service-account id to 6-30 lowercase characters
    -- starting with a letter. `Gcp.Iam.checkAccountId` rejects a bad one by
    -- naming the rule, because the name is fixed at compile time — so a bad
    -- one fails every apply rather than one of them.
    resource iam "ci-tests-infra-sa" {}

-- One guard per (fleet, kind): the count is what would silently drift if a
-- resource were added to a fleet and forgotten here. It has already caught two
-- scripted edits that added resources to some fleets and not others.
#guard awsLive.keys.count .aws .queues = 1
#guard awsLive.keys.count .aws .secrets = 3
#guard awsLive.keys.count .aws .imageRegistry = 1
#guard awsLive.keys.count .aws .objectStore = 1
#guard awsLive.keys.count .aws .s3Bucket = 1
#guard awsLive.keys.count .aws .securityGroup = 1
#guard awsLive.keys.count .aws .iam = 1

#guard scalewayLive.keys.count .scaleway .queues = 1
#guard scalewayLive.keys.count .scaleway .secrets = 3
#guard scalewayLive.keys.count .scaleway .imageRegistry = 1
#guard scalewayLive.keys.count .scaleway .objectStore = 1
#guard scalewayLive.keys.count .scaleway .scalewayFunctionNamespace = 1
#guard scalewayLive.keys.count .scaleway .scalewayContainerNamespace = 1
#guard scalewayLive.keys.count .scaleway .scalewayContainer = 1
-- And deliberately none: adding one would silently require organization-level
-- IAM rights that the isolated CI project cannot contain. See the fleet.
#guard scalewayLive.keys.count .scaleway .iam = 0

#guard gcpLive.keys.count .gcp .queues = 1
#guard gcpLive.keys.count .gcp .secrets = 3
#guard gcpLive.keys.count .gcp .imageRegistry = 1
#guard gcpLive.keys.count .gcp .objectStore = 1
#guard gcpLive.keys.count .gcp .iam = 1
#guard gcpLive.keys.count .gcp .compute = 1

-- Every name carries the prefix, on every kind. Checked per kind rather than
-- in aggregate, because a name that escaped the convention would otherwise be
-- invisible until it leaked into an account.
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
#guard scalewayLive.names.scaleway.scalewayFunctionNamespace.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.scalewayContainerNamespace.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.scalewayContainer.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.queues.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.secrets.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.imageRegistry.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.objectStore.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.iam.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.compute.all (ciPrefix.isPrefixOf ·)

-- EC2 constrains a security group's description to
--     a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*
-- and an apostrophe is not in it, which "created and destroyed by infra's
-- live test" fell foul of on the first live run that reached this resource.
-- The description is a compile-time constant, so an invalid one fails every
-- apply — which makes it exactly the sort of thing to check here.
private def ec2DescriptionOk (d : String) : Bool :=
  d.length < 256 && d.all (fun c => c.isAlphanum || " ._-:/()#,@[]+=&;{}!$*".any (· == c))

#guard ec2DescriptionOk "created and destroyed by the infra live test"
#guard ec2DescriptionOk "created and destroyed by infra's live test" = false

-- The bucket names carry the uniqueness suffix, which is the whole reason
-- buckets could be included at all.
#guard awsLive.names.aws.objectStore.all (·.endsWith bucketSuffix)
#guard awsLive.names.aws.s3Bucket.all (·.endsWith bucketSuffix)
#guard scalewayLive.names.scaleway.objectStore.all (·.endsWith bucketSuffix)
#guard gcpLive.names.gcp.objectStore.all (·.endsWith bucketSuffix)

-- No plaintext secret is committed, in any of the three, including the two
-- composed ones. Decidable, so the compiler establishes it rather than a
-- reviewer.
#guard awsLive.plan.secretsAreSound
#guard scalewayLive.plan.secretsAreSound
#guard gcpLive.plan.secretsAreSound

-- Each fleet is single-cloud, so a run for one provider never authenticates
-- another — which is what lets the workflow pass one set of secrets.
#guard awsLive.keys.providers = [.aws]
#guard scalewayLive.keys.providers = [.scaleway]
#guard gcpLive.keys.providers = [.gcp]

/-! ## The dependency patterns, pinned offline before they are run live

  Three shapes, and the point of testing them against a real account is that
  each fails differently when ordering is wrong:

  - **A chain.** `derived-a` composes the base secret's *value*, so the base
    must exist and be readable before the derived one is written. Get this
    backwards live and the create fails on a secret that is not there.
  - **A fan-out.** `derived-a` and `derived-b` both depend on the same base, so
    one node has two dependents — and on teardown, both must go before it.
  - **A fan-in.** Scaleway's container depends on its namespace *and* on the
    base secret, by two different mechanisms: `depsKey` for the namespace and
    `depsKeys` for `secretEnv`. It is the only place here that exercises key
    references rather than expression references.

  The guards below pin the ordering in the plan, so a regression in the
  scheduler is a compile error rather than something discovered against a
  cloud. `liveRoundTrip` then checks the same fleets converge and tear down
  for real.
-/

/-- Where a slot first appears in the create order, or `none`. -/
private def createIndexOf {κ : Keys} (T : Plan κ) (slot : String) : Option Nat :=
  ((actions T (worldOf [])).map Action.render).findIdx?
    (fun rendered => (rendered.splitOn slot).length > 1)

/-- Does `a` come strictly before `b` in the create order? `false` if either is
    absent, so a typo in a slot name fails the guard rather than passing it
    vacuously. -/
private def before {κ : Keys} (T : Plan κ) (a b : String) : Bool :=
  match createIndexOf T a, createIndexOf T b with
  | some i, some j => i < j
  | _,      _      => false

-- The chain, and the fan-out's two arms, on every cloud.
#guard before awsLive.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-derived-a"
#guard before awsLive.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-derived-b"
#guard before scalewayLive.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-derived-a"
#guard before scalewayLive.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-derived-b"
#guard before gcpLive.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-derived-a"
#guard before gcpLive.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-derived-b"

-- The fan-in: both of the container's dependencies are scheduled before it.
#guard before scalewayLive.plan "container-namespace/ci-tests-infra-ctrs" "container/ci-tests-infra-ctr"
#guard before scalewayLive.plan "secrets/ci-tests-infra-secret" "container/ci-tests-infra-ctr"

-- And the negative direction, so the guards above are not passing for the
-- trivial reason that everything is "before" everything.
#guard before awsLive.plan "secrets/ci-tests-infra-derived-a" "secrets/ci-tests-infra-secret" = false
#guard before scalewayLive.plan "container/ci-tests-infra-ctr" "container-namespace/ci-tests-infra-ctrs" = false

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

/-- Delete everything the fleet declares, and prove it is gone.

    Factored out of `liveRoundTrip` so the workflow's backstop can call it
    without creating anything first — see `main`'s `destroy` argument. The two
    callers must not drift: a backstop that tore down differently from the
    round trip would be a second, less-tested code path on the one operation
    where being wrong costs money. -/
def liveTeardown {κ : Keys} (name : String) (target : Plan κ) (regions : Regions) :
    IO Unit := do
  let cacheRoot : System.FilePath := ".infra" / s!"live-{name}"
  let (bs, _) ← Infra.Cli.liveFor κ regions
  IO.println s!"[{name}] destroying…"
  let w ← pull (κ := κ) cacheRoot bs
  discard <| push bs (Plan.absent κ) w { apply := true } (edges := target)
  -- Waiting for it to *appear* is not possible in general, so what this
  -- asserts is that after the delete settles a fresh listing shows nothing —
  -- and it polls to get there, because a destroy issued while a resource was
  -- still invisible would find nothing to do and report success.
  let leftover ← waitFor cacheRoot bs (fun w => (actions (Plan.absent κ) w).isEmpty)
    (fun w => (actions (Plan.absent κ) w).map Action.render)
  unless leftover.isEmpty do
    throw (IO.userError s!"[{name}] {leftover.length} resource(s) survived destroy \
after {settleSeconds}s — look for 'ci-tests-infra-*' in the account")
  let cached ← Persistence.load (κ := κ) cacheRoot
  unless cached.isEmpty do
    throw (IO.userError
      s!"[{name}] destroyed, but the cache still lists {cached.length} resource(s)")
  IO.println s!"[{name}] destroyed, and the cache is empty"

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

  -- Teardown runs whether or not the checks below pass, and is the same code
  -- the backstop runs.
  let teardown : IO Unit := liveTeardown name target regions
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
  "usage: lake test [-- <aws|scaleway|gcp> [destroy]]\n\n\
  With no argument:     the offline checks. No cloud, no credentials, no cost.\n\
  With a provider:      creates eight to ten real resources, all named\n\
                        'ci-tests-infra-*', checks the fleet converged, and\n\
                        deletes them again.\n\
  …plus 'destroy':      tears down and creates nothing. This is what CI's\n\
                        backstop runs after a failed leg — the full command is\n\
                        a create *and* a destroy, so re-running it to clean up\n\
                        would create again.\n\n\
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
  -- Teardown without the round trip. The workflow's backstop used to re-run
  -- the whole test, on the reasoning that destroy is idempotent — but `lake
  -- test -- aws` is not a destroy, it is a create *and* a destroy. So a failed
  -- run was followed by a second create, which failed the same way and could
  -- leave more behind than it cleaned up. That is what the first extended AWS
  -- run actually did.
  | [p, "destroy"] =>
    let run : IO Unit ← match p with
      | "aws"      => pure (liveTeardown "aws" awsLive.plan awsLive.regions)
      | "scaleway" => pure (liveTeardown "scaleway" scalewayLive.plan scalewayLive.regions)
      | "gcp"      => pure (liveTeardown "gcp" gcpLive.plan gcpLive.regions)
      | other      => throw (IO.userError s!"unknown provider '{other}'\n\n{usage}")
    match ← run.toBaseIO with
    | .ok _    => IO.println s!"[{p}] torn down"; return 0
    | .error e => IO.eprintln s!"error: {e}"; return 1
  | _ => IO.eprintln usage; return 2
