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

  ## Two kinds have names that are global, which needed solving rather than avoiding

  Object storage names are unique across an entire cloud, not per account, and
  a fleet's names are fixed at compile time. That is why buckets were kept out
  of this test until now, and the reasoning was sound.

  **Scaleway's registry namespaces are the same shape and it is far less
  obvious**, because nothing about the kind suggests it: the name *is* the
  hostname path, `rg.fr-par.scw.cloud/<name>`, so it is unique per region
  across every project. A leftover from a failed run blocks every later run in
  any project with `400 Namespace already exist`. Found the hard way, and the
  same suffix fixes it.

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

/-! ## Three stages per cloud, and the same shape on all three

  The live legs used to be one declaration each: create it, check it converged,
  destroy it. That exercises `create` and `delete` and nothing in between —
  and, more importantly, nothing about *membership*. A resource is only ever
  destroyed by asking for an empty target, which is a different code path from
  the one an operator actually uses, which is editing a file.

  So each cloud now runs a **sequence of declarations**, applied in order
  against one ledger:

  | Stage | What it declares | What that has to make happen |
  |---|---|---|
  | 1 `full` | the whole fleet | `create`, and a dependency order that works |
  | 2 `trimmed` | two resources dropped, one field changed, one added | `deleteOrphan` for the dropped, `update` for the changed, `create` for the added |
  | 3 `empty` | nothing at all | `deleteOrphan` for everything left |

  Stage 2 is the one worth having, and it is the one nothing tested before. Its
  dropped resources have no key in stage 2's key family at all — their lines
  are *gone*, exactly as if a person had deleted them — so the only thing that
  knows they exist is the ledger. If membership were still derived from the
  declaration, stage 2 would silently abandon them and stage 3 would have
  nothing to clean up, and both stages would pass while leaking two billable
  resources per cloud. The assertion that catches that is in `liveSequence`:
  after each stage the account must contain *exactly* what the stage declares.

  Stage 3 is `apply` against a declaration with no resources in it, not the
  `destroy` verb. Those are the same operation — see `Plan.absent` — and this
  is the half that had never run.

  ### The dependency graph, identical on all three clouds

  Five secrets, shaped to be more than a chain:

      base ──┬──▶ a ──┐
             ├──▶ b ──┼──▶ sink ──▶ tail
             └────────┘

  A fan-out of two from `base`, a fan-in of three on `sink` (including a
  redundant direct edge from `base`, which the two paths through `a` and `b`
  already imply), and a four-deep chain `base → a → sink → tail`. It is the
  same shape `Infra/Demo.lean`'s `dagFleet` checks offline against a
  recomputed topological order, so the offline and live tests agree on what a
  hard graph looks like. Every edge comes from `HasDeps SecretsSpec`, so all
  five are created in one apply and deleted in the reverse of that order.

  Names are prefixed `ci-tests-infra-` and, where a cloud's namespace is wider
  than the project, suffixed — see the notes on `bucketSuffix` and on
  Scaleway's registry namespaces below. -/

/-! ### Stage 1: the whole fleet -/

fleet awsFull in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as awsBase
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as awsA
      { valueFrom := composed expr!"a:{secretValueOf awsBase}" }
    resource secrets "ci-tests-infra-b" as awsB
      { valueFrom := composed expr!"b:{secretValueOf awsBase}" }
    -- Fan-in of three, one edge of which is redundant.
    resource secrets "ci-tests-infra-sink" as awsSink
      { valueFrom := composed
          expr!"{secretValueOf awsA}|{secretValueOf awsB}|{secretValueOf awsBase}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf awsSink}" }
    resource imageRegistry "ci-tests-infra-images" { immutableTags := true }
    resource objectStore "ci-tests-infra-store-7c1f9a2e" { versioning := true }
    -- Both bucket kinds: they differ in Object Lock, which is creation-time
    -- only, so nothing short of a real create exercises it.
    resource s3Bucket "ci-tests-infra-lock-7c1f9a2e"
      { versioning := true, objectLock := true }
    resource securityGroup "ci-tests-infra-sg"
      { description := "created and destroyed by the infra live test" }
    resource iam "ci-tests-infra-user" {}

/-! ### Stage 2: two resources dropped, one changed, one added

  `ci-tests-infra-b` and `ci-tests-infra-sg` are simply absent below, which
  also shortens the graph: with `b` gone, `sink` fans in on two instead of
  three. `queues`' visibility timeout goes from 30 to 60, which is a mutable
  field and so an `update` rather than a replace. And `ci-tests-infra-late`
  is new. -/

fleet awsTrimmed in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 60 }
    resource secrets "ci-tests-infra-secret" as awsBase'
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as awsA'
      { valueFrom := composed expr!"a:{secretValueOf awsBase'}" }
    resource secrets "ci-tests-infra-sink" as awsSink'
      { valueFrom := composed expr!"{secretValueOf awsA'}|{secretValueOf awsBase'}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf awsSink'}" }
    resource secrets "ci-tests-infra-late"
      { valueFrom := composed expr!"late:{secretValueOf awsBase'}" }
    resource imageRegistry "ci-tests-infra-images" { immutableTags := true }
    resource objectStore "ci-tests-infra-store-7c1f9a2e" { versioning := true }
    resource s3Bucket "ci-tests-infra-lock-7c1f9a2e"
      { versioning := true, objectLock := true }
    resource iam "ci-tests-infra-user" {}

fleet scalewayFull in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as scwBase
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as scwA
      { valueFrom := composed expr!"a:{secretValueOf scwBase}" }
    resource secrets "ci-tests-infra-b" as scwB
      { valueFrom := composed expr!"b:{secretValueOf scwBase}" }
    resource secrets "ci-tests-infra-sink" as scwSink
      { valueFrom := composed
          expr!"{secretValueOf scwA}|{secretValueOf scwB}|{secretValueOf scwBase}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf scwSink}" }
    -- The suffix is here for the same reason it is on the buckets, and the
    -- reason is not obvious until you look at the endpoint: a Scaleway
    -- registry namespace's name *is* its hostname path —
    -- `rg.fr-par.scw.cloud/<name>` — so names are unique per region across
    -- every project, not per project.
    --
    -- Two consequences, both met in practice. A leftover namespace from a
    -- failed run blocks every future run, in any project, with
    -- `400 Namespace already exist` — the same permanent-deadlock shape as the
    -- SQS credential name. And a fork would collide with this repository.
    resource imageRegistry "ci-tests-infra-images-7c1f9a2e" {}
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
    -- Fan-in of a *different* provenance from the secrets graph: this depends
    -- on the namespace above (a key reference, via `depsKey`) and on the base
    -- secret (via `depsKeys s.secretEnv`), so two edges of two different kinds
    -- converge on one resource. It is the only place the live test exercises
    -- `depsKey`/`depsKeys` rather than an expression reference, and teardown
    -- has to reverse both.
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

/-! Stage 2 drops `b` and the container — the latter deliberately, because it
  is the resource with the two key-typed edges, so dropping it makes an orphan
  whose deletion has to precede a namespace that is *still declared*. That is
  the ordering case a single-stage test cannot produce. -/
fleet scalewayTrimmed in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 60 }
    resource secrets "ci-tests-infra-secret" as scwBase'
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as scwA'
      { valueFrom := composed expr!"a:{secretValueOf scwBase'}" }
    resource secrets "ci-tests-infra-sink" as scwSink'
      { valueFrom := composed expr!"{secretValueOf scwA'}|{secretValueOf scwBase'}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf scwSink'}" }
    resource secrets "ci-tests-infra-late"
      { valueFrom := composed expr!"late:{secretValueOf scwBase'}" }
    resource imageRegistry "ci-tests-infra-images-7c1f9a2e" {}
    resource objectStore "ci-tests-infra-store-scw-7c1f9a2e" { versioning := true }
    resource scalewayFunctionNamespace "ci-tests-infra-fns"
      { description := "created and destroyed by the infra live test" }
    resource scalewayContainerNamespace "ci-tests-infra-ctrs"
      { description := "created and destroyed by the infra live test" }

/-! GCP's leg used to be expected to fail: there was no live GCP backend, so
    it raised on the first call, and this comment said the day one landed the
    leg would start passing on its own. It has, and it does. `queues` on GCP is
    a Pub/Sub topic — see `Infra.Providers.Gcp.PubSub`.

    Note what is *not* asserted as a result. A Pub/Sub topic has no visibility
    timeout — that belongs to a subscription — so `visibilityTimeoutSec` below
    is declared, carried through the plan, and then reported `unknown` by the
    backend. The convergence check still means something, because an unknown
    field is not a divergence; it just does not mean the number was stored
    anywhere. In particular stage 2's change from 30 to 60 is a real `update`
    on AWS and Scaleway and a no-op here, which is why the stage assertions
    are about *which resources exist* rather than about action counts. -/

fleet gcpFull in paris where
  provider gcp where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as gcpBase
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as gcpA
      { valueFrom := composed expr!"a:{secretValueOf gcpBase}" }
    resource secrets "ci-tests-infra-b" as gcpB
      { valueFrom := composed expr!"b:{secretValueOf gcpBase}" }
    resource secrets "ci-tests-infra-sink" as gcpSink
      { valueFrom := composed
          expr!"{secretValueOf gcpA}|{secretValueOf gcpB}|{secretValueOf gcpBase}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf gcpSink}" }
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

/-! Stage 2 drops `b` and Cloud Run. Dropping `compute` is the expensive-orphan
  case: it is the only kind here that costs by the second, so a stage that
  failed to delete it would show up on a bill rather than in a listing. -/
fleet gcpTrimmed in paris where
  provider gcp where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 60 }
    resource secrets "ci-tests-infra-secret" as gcpBase'
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as gcpA'
      { valueFrom := composed expr!"a:{secretValueOf gcpBase'}" }
    resource secrets "ci-tests-infra-sink" as gcpSink'
      { valueFrom := composed expr!"{secretValueOf gcpA'}|{secretValueOf gcpBase'}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf gcpSink'}" }
    resource secrets "ci-tests-infra-late"
      { valueFrom := composed expr!"late:{secretValueOf gcpBase'}" }
    resource imageRegistry "ci-tests-infra-images" {}
    resource objectStore "ci-tests-infra-store-gcp-7c1f9a2e" { versioning := true }
    resource iam "ci-tests-infra-sa" {}

/-! ### Stage 3: nothing at all

  One declaration, shared by all three clouds, that declares no resources. Its
  key family is empty, so it cannot name anything — which is the point:
  everything the ledger records becomes an orphan, and orphans are what get
  destroyed. This is `apply` reaching the same place `destroy` does. -/

fleet nothingAtAll where

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

/-! ### Coverage, and the naming rule that makes debris identifiable -/

/- Which kinds each cloud's stage 1 reaches, pinned per kind rather than as a
   total so that dropping one is a failure and not just a smaller number. Five
   secrets on every cloud: that is the DAG. -/
#guard awsFull.keys.count .aws .queues = 1
#guard awsFull.keys.count .aws .secrets = 5
#guard awsFull.keys.count .aws .imageRegistry = 1
#guard awsFull.keys.count .aws .objectStore = 1
#guard awsFull.keys.count .aws .s3Bucket = 1
#guard awsFull.keys.count .aws .securityGroup = 1
#guard awsFull.keys.count .aws .iam = 1

#guard scalewayFull.keys.count .scaleway .queues = 1
#guard scalewayFull.keys.count .scaleway .secrets = 5
#guard scalewayFull.keys.count .scaleway .imageRegistry = 1
#guard scalewayFull.keys.count .scaleway .objectStore = 1
#guard scalewayFull.keys.count .scaleway .scalewayFunctionNamespace = 1
#guard scalewayFull.keys.count .scaleway .scalewayContainerNamespace = 1
#guard scalewayFull.keys.count .scaleway .scalewayContainer = 1
-- Zero on purpose, and the zero is the assertion: see the note where the
-- fleet is declared for why Scaleway's IAM cannot be confined to a project.
#guard scalewayFull.keys.count .scaleway .iam = 0

#guard gcpFull.keys.count .gcp .queues = 1
#guard gcpFull.keys.count .gcp .secrets = 5
#guard gcpFull.keys.count .gcp .imageRegistry = 1
#guard gcpFull.keys.count .gcp .objectStore = 1
#guard gcpFull.keys.count .gcp .compute = 1
#guard gcpFull.keys.count .gcp .iam = 1

/- The symmetric core — same kinds, same names, same graph — is what makes the
   three legs comparable. Each cloud then adds what only it can test. -/
#guard awsFull.keys.count .aws .compute = 0        -- Lambda needs an ECR image
#guard gcpFull.keys.count .gcp .s3Bucket = 0       -- an S3-only concept
#guard awsFull.keys.count .aws .scalewayContainer = 0

-- The fan-out's two arms, on every cloud.
#guard before awsFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-a"
#guard before awsFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-b"
#guard before scalewayFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-a"
#guard before scalewayFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-b"
#guard before gcpFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-a"
#guard before gcpFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-b"

-- The fan-in of three on `sink`, including the redundant direct edge from
-- `base` that the paths through `a` and `b` already imply.
#guard before awsFull.plan "secrets/ci-tests-infra-a" "secrets/ci-tests-infra-sink"
#guard before awsFull.plan "secrets/ci-tests-infra-b" "secrets/ci-tests-infra-sink"
#guard before awsFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-sink"
#guard before scalewayFull.plan "secrets/ci-tests-infra-b" "secrets/ci-tests-infra-sink"
#guard before gcpFull.plan "secrets/ci-tests-infra-b" "secrets/ci-tests-infra-sink"

-- And the four-deep chain: base → a → sink → tail. The last hop is what a
-- fan-out-only graph would not have caught.
#guard before awsFull.plan "secrets/ci-tests-infra-sink" "secrets/ci-tests-infra-tail"
#guard before scalewayFull.plan "secrets/ci-tests-infra-sink" "secrets/ci-tests-infra-tail"
#guard before gcpFull.plan "secrets/ci-tests-infra-sink" "secrets/ci-tests-infra-tail"
#guard before awsFull.plan "secrets/ci-tests-infra-secret" "secrets/ci-tests-infra-tail"

-- The other fan-in, of a different provenance: the container's two edges are
-- a key reference and a secret-value reference, not two expressions.
#guard before scalewayFull.plan "container-namespace/ci-tests-infra-ctrs" "container/ci-tests-infra-ctr"
#guard before scalewayFull.plan "secrets/ci-tests-infra-secret" "container/ci-tests-infra-ctr"

-- And the negative direction, so the guards above are not passing for the
-- trivial reason that everything is "before" everything.
#guard before awsFull.plan "secrets/ci-tests-infra-a" "secrets/ci-tests-infra-secret" = false
#guard before awsFull.plan "secrets/ci-tests-infra-tail" "secrets/ci-tests-infra-sink" = false
#guard before scalewayFull.plan "container/ci-tests-infra-ctr" "container-namespace/ci-tests-infra-ctrs" = false

/-- Print a progress line and flush it.

    `IO.println` alone is not enough here. Stdout is buffered, so on a run that
    takes minutes the progress lines all appear at once when the process
    exits — while the notes and warnings, which go to stderr, appear
    immediately. The result is a CI log that shows a credential warning and
    then nothing at all for eight minutes, which is indistinguishable from a
    hang.

    Everything this driver prints as progress goes through here. -/
def progress (line : String) : IO Unit := do
  IO.println line
  (← IO.getStdout).flush

/-- How long to let a cloud's listing catch up before calling it a failure.

    Raised from 60 when the fleets went from one resource to seven. It is not
    the count that matters but the slowest member: Scaleway's Functions and
    Containers namespaces take tens of seconds to become visible and tens more
    to disappear, and a bucket's listing is not instant either. The old bound
    was comfortable for a queue and would have made those look like failures.

    Seconds, and now actually seconds: `waitFor` measures elapsed wall-clock
    time. It used to decrement this once per poll iteration, and an iteration
    is a whole `pull` — so the number was silently multiplied by the cost of
    listing the fleet, and a 180 here meant twelve minutes for Scaleway.

    Both polls use it, so the worst case is twice this plus the time to create
    and delete, which fits inside the workflow's step timeout. -/
def settleSeconds : Nat := 180

/-- Re-`pull` until `done` holds, or until `settleSeconds` have actually
    elapsed.

    Every cloud list API here is eventually consistent to some degree, so a
    single read immediately after a write measures propagation delay rather
    than correctness.

    **The deadline is wall-clock, and it was not always.** This used to count
    iterations: `settleSeconds` decremented once per loop, and each loop is a
    whole `pull` — for the Scaleway fleet that is sixteen HTTP calls — plus a
    one-second sleep. So a "180 second" window took 180 × (pull + 1s), which at
    three seconds per pull is twelve minutes. It hit the workflow's step
    timeout and reported a hang, having done nothing wrong except take four
    times longer than its own name promised.

    Fixed one-second steps rather than a backoff: the waits are short, and a
    backoff would make the worst case unpredictable in a job that has a
    timeout. Fuel bounds the recursion so this is not `partial`, but the
    deadline is what stops it. -/
def waitFor {κ : Keys} (label : String) (root : System.FilePath) (bs : Backends)
    (done : World κ → Bool) (report : World κ → List String) : IO (List String) := do
  let start ← Data.Time.getCurrentTime
  let deadline := start.nanosSinceEpoch + settleSeconds * 1000000000
  let elapsed : IO Nat := do
    let now ← Data.Time.getCurrentTime
    return (now.nanosSinceEpoch - start.nanosSinceEpoch) / 1000000000
  -- Fuel bounds the recursion so this is not `partial` and the measure is
  -- real; the *deadline* is what actually stops it, and the fuel can only be
  -- reached if a pull returns instantly, which it cannot.
  let rec go (fuel : Nat) (lastBeat : Nat) : IO (List String) := do
    let w ← pull (κ := κ) root bs
    if done w then return []
    let secs ← elapsed
    let now ← Data.Time.getCurrentTime
    if now.nanosSinceEpoch ≥ deadline then return report w
    match fuel with
    | 0     => return report w
    | n + 1 =>
      -- A heartbeat roughly every fifteen seconds, naming what is still
      -- outstanding. Without it this loop is silent for minutes, which reads
      -- as a hang — and when it fails, *which* resource never appeared is the
      -- whole diagnosis. One slow namespace and nine missing resources are
      -- very different situations.
      let beat := secs / 15
      if beat > lastBeat then
        let outstanding := report w
        progress s!"[{label}] {secs}s of {settleSeconds}s — \
{outstanding.length} outstanding: {String.intercalate ", " (outstanding.take 3)}\
{if outstanding.length > 3 then s!" (+{outstanding.length - 3} more)" else ""}"
        IO.sleep 1000
        go n beat
      else
        IO.sleep 1000
        go n lastBeat
  go settleSeconds 0

/-- One declaration in a sequence, packed so a list can hold stages whose key
    families differ.

    They must differ: a stage that *drops* a resource has fewer keys than the
    one before it, so `Plan κ` is a different type at each step. Bundling the
    key family with everything derived from it is what lets the driver below
    iterate over them, and it is the same trick the ledger plays — the record
    of what is managed cannot be indexed by a key family that changes
    underneath it. -/
structure Stage where
  label   : String
  κ       : Keys
  plan    : Plan κ
  regions : Regions
  forgets : List (Released κ)
  /-- Every slot this stage declares, as `Engine.slotId` strings.

      Derived from the key family rather than written out, so it cannot
      disagree with the declaration: this is the list the account is checked
      against after the stage settles. -/
  declared : List String

/-- Pack a declaration, deriving `declared` from its own keys. -/
def stage {κ : Keys} (label : String) (plan : Plan κ) (regions : Regions)
    (forgets : List (Released κ)) : Stage where
  κ := κ
  label := label
  plan := plan
  regions := regions
  forgets := forgets
  declared :=
    (Finite.elems (α := ProviderId)).flatMap fun p =>
      (Finite.elems (α := Kind)).flatMap fun k =>
        (Finite.elems (α := κ.Key p k)).filterMap fun key =>
          match plan.assign p k key with
          | .present _ => some (Ledger.slotId p k (κ.name p k key))
          | _          => none

/-- Everything the ledger says is managed, as slot strings. -/
def ledgerSlots (rows : List Ledger.Row) : List String :=
  (Ledger.sorted rows).map Ledger.Row.slot

/-- Apply one stage, wait for it to settle, and check the account holds exactly
    what the stage declares — no more.

    "No more" is the whole point of the sequence. A stage that drops a resource
    must *destroy* it, and the only thing that knows the resource exists is the
    ledger, because its line is gone from the declaration. If membership were
    still read off the declaration, a dropped resource would be silently
    abandoned: this stage would pass, the next would find nothing to clean up,
    and the leak would show up on a bill. Comparing the ledger against
    `declared` after every stage is what catches that. -/
def runStage (name : String) (root : System.FilePath) (st : Stage) : IO Unit := do
  let (bs, _) ← Infra.Cli.liveFor st.κ st.regions
  let rows ← Ledger.load root
  progress s!"[{name}/{st.label}] applying ({st.declared.length} declared, \
{rows.length} managed)…"
  let entries ← observe (κ := st.κ) root bs
  let store : Store st.κ :=
    { root := some root, rows, forgets := st.forgets
      regionOf := fun p k nm => (st.regions.codeFor p k nm).getD "" }
  discard <| push bs st.plan (worldOf entries) { apply := true }
    (edges := st.plan) (store := store) (seen := some entries)

  -- Converged: a second apply would do nothing. Polled, because every cloud's
  -- list API is eventually consistent and a resource created a moment ago may
  -- simply not be visible yet — checking once tests the propagation delay
  -- rather than this library, which is what the first live run of this test
  -- actually did.
  let after ← Ledger.load root
  let outstanding ← waitFor s!"{name}/{st.label} converge" root bs
    (fun w => (plan st.plan w after st.forgets).isEmpty)
    (fun w => (plan st.plan w after st.forgets).map Action.render)
  unless outstanding.isEmpty do
    throw (IO.userError s!"[{name}/{st.label}] did not converge after \
{settleSeconds}s: {String.intercalate ", " outstanding}")

  -- And the ledger records exactly the declaration, which is what says the
  -- dropped resources were destroyed rather than forgotten about.
  let managed := ledgerSlots after
  let expected := (st.declared.mergeSort fun a b => compare a b != .gt)
  unless managed == expected do
    let extra := managed.filter (!expected.contains ·)
    let missing := expected.filter (!managed.contains ·)
    throw (IO.userError s!"[{name}/{st.label}] the ledger and the declaration \
disagree.\n  still managed but not declared: {String.intercalate ", " extra}\
\n  declared but not managed: {String.intercalate ", " missing}")
  progress s!"[{name}/{st.label}] converged; {managed.length} managed"

/-- The stages for one cloud, ending in a declaration that names nothing.

    That last stage is `apply` against an empty declaration, which is the same
    operation `destroy` performs — see `Plan.absent` — and is the half that had
    never run live. Everything the ledger holds becomes an orphan, and orphans
    are what get destroyed. -/
def stagesFor : String → Option (List Stage)
  | "aws" => some
    [ stage "full"    awsFull.plan      awsFull.regions      awsFull.forgets
    , stage "trimmed" awsTrimmed.plan   awsTrimmed.regions   awsTrimmed.forgets
    , stage "empty"   nothingAtAll.plan awsFull.regions      nothingAtAll.forgets ]
  | "scaleway" => some
    [ stage "full"    scalewayFull.plan    scalewayFull.regions    scalewayFull.forgets
    , stage "trimmed" scalewayTrimmed.plan scalewayTrimmed.regions scalewayTrimmed.forgets
    , stage "empty"   nothingAtAll.plan    scalewayFull.regions    nothingAtAll.forgets ]
  | "gcp" => some
    [ stage "full"    gcpFull.plan      gcpFull.regions      gcpFull.forgets
    , stage "trimmed" gcpTrimmed.plan   gcpTrimmed.regions   gcpTrimmed.forgets
    , stage "empty"   nothingAtAll.plan gcpFull.regions      nothingAtAll.forgets ]
  | _ => none

/-! ### The stages really are different declarations

  Checked offline, because the live legs cost money and a sequence whose stages
  happened to declare the same thing would pass every assertion while testing
  nothing. Each cloud must drop something, keep something, and add something —
  those are the three cases `runStage` distinguishes. -/

private def slotsOf (st : Stage) : List String := st.declared

private def dropped (a b : Stage) : List String :=
  (slotsOf a).filter (!(slotsOf b).contains ·)

private def added (a b : Stage) : List String :=
  (slotsOf b).filter (!(slotsOf a).contains ·)

/-- A stage by position, with an empty declaration as the fallback so a wrong
    index fails a guard rather than failing to compile. -/
private def at! (sts : List Stage) (i : Nat) : Stage :=
  (sts.drop i).headD (stage "missing" nothingAtAll.plan {} nothingAtAll.forgets)

private def awsStages := stagesFor "aws" |>.getD []
private def scwStages := stagesFor "scaleway" |>.getD []
private def gcpStages := stagesFor "gcp" |>.getD []

/- Three stages per cloud, and the last one declares nothing at all — which is
   what makes it `apply`-empty rather than a fourth mechanism. -/
#guard awsStages.length = 3
#guard scwStages.length = 3
#guard gcpStages.length = 3
#guard (at! awsStages 2).declared = []
#guard (at! scwStages 2).declared = []
#guard (at! gcpStages 2).declared = []

/- Stage 2 drops exactly what its comment says, on each cloud. These are the
   orphans: no key in stage 2 names them, so only the ledger can. -/
#guard dropped (at! awsStages 0) (at! awsStages 1)
     = ["aws/secrets/ci-tests-infra-b", "aws/security-group/ci-tests-infra-sg"]
#guard dropped (at! scwStages 0) (at! scwStages 1)
     = ["scaleway/secrets/ci-tests-infra-b", "scaleway/scaleway-container/ci-tests-infra-ctr"]
#guard dropped (at! gcpStages 0) (at! gcpStages 1)
     = ["gcp/compute/ci-tests-infra-run", "gcp/secrets/ci-tests-infra-b"]

/- And adds one, so the stage is not purely subtractive: a sequence that only
   ever removed things would never exercise a create after a delete. -/
#guard added (at! awsStages 0) (at! awsStages 1) = ["aws/secrets/ci-tests-infra-late"]
#guard added (at! scwStages 0) (at! scwStages 1) = ["scaleway/secrets/ci-tests-infra-late"]
#guard added (at! gcpStages 0) (at! gcpStages 1) = ["gcp/secrets/ci-tests-infra-late"]

/- Stage 3 drops everything stage 2 still held. -/
#guard dropped (at! awsStages 1) (at! awsStages 2) = (at! awsStages 1).declared
#guard added (at! awsStages 1) (at! awsStages 2) = []

/- The symmetric core is the same on all three clouds: same kinds, same names,
   same graph. Anything beyond it is a cloud that has something the others do
   not, and those are commented where they are declared. -/
private def coreSlots (cloud : String) : List String :=
  [ s!"{cloud}/queues/ci-tests-infra-queue"
  , s!"{cloud}/secrets/ci-tests-infra-secret", s!"{cloud}/secrets/ci-tests-infra-a"
  , s!"{cloud}/secrets/ci-tests-infra-b", s!"{cloud}/secrets/ci-tests-infra-sink"
  , s!"{cloud}/secrets/ci-tests-infra-tail" ]
#guard (coreSlots "aws").all (at! awsStages 0).declared.contains
#guard (coreSlots "scaleway").all (at! scwStages 0).declared.contains
#guard (coreSlots "gcp").all (at! gcpStages 0).declared.contains

/- Every resource any stage declares is named `ci-tests-infra-*`. This is a
   safety property, not a style rule: it is what lets a human find debris from
   a failed run, and what `ciPrefix` documents. A stage that declared something
   unprefixed could leave a resource nobody would recognise as a test's. -/
#guard (awsStages ++ scwStages ++ gcpStages).all fun st =>
  st.declared.all fun slot => (slot.splitOn ciPrefix).length > 1

/- The counts, read off the declarations rather than remembered. Eleven, eleven
   and ten resources, spanning seven kinds on AWS, eight on Scaleway and six on
   GCP. -/
#guard (at! awsStages 0).declared.length = 11
#guard (at! scwStages 0).declared.length = 11
#guard (at! gcpStages 0).declared.length = 10

/-- The teardown, on its own, for the workflow's backstop.

    It is the last stage of the sequence and nothing else, which is what makes
    it safe to re-run: the backstop used to re-run the *whole* command, on the
    reasoning that destroy is idempotent — but a full run is a create *and* a
    destroy, so a failed run was followed by a second create that failed the
    same way and could leave more behind than it cleaned up. That is what the
    first extended AWS run actually did.

    Because the empty stage destroys whatever the *ledger* holds rather than
    whatever some declaration names, it also cleans up after a run that failed
    partway through a different stage. -/
def liveTeardown (name : String) (regions : Regions) : IO Unit := do
  let root : System.FilePath := ".infra" / s!"live-{name}"
  runStage name root (stage "empty" nothingAtAll.plan regions nothingAtAll.forgets)
  let rows ← Ledger.load root
  unless rows.isEmpty do
    throw (IO.userError s!"[{name}] torn down, but the ledger still lists \
{rows.length} resource(s)")
  progress s!"[{name}] torn down, and the ledger is empty"

/-- Every stage in order, with the teardown guaranteed.

    The final stage *is* the teardown, so a clean run ends with nothing left.
    If any earlier stage fails, the teardown still runs, and both errors are
    reported: a teardown failure that swallowed the real error is how a CI job
    becomes a mystery and a bill. -/
def liveSequence (name : String) (stages : List Stage) (regions : Regions) :
    IO Unit := do
  let root : System.FilePath := ".infra" / s!"live-{name}"
  -- Stage by stage rather than `forM`, so that a failure knows *which* stage
  -- failed. That matters for one case: the last stage is itself the teardown,
  -- and re-running it as a fallback would issue the same request, fail the
  -- same way, and print everything twice. The first live run of this test did
  -- exactly that on all three clouds — the same shape as the workflow backstop
  -- that used to re-run a create after a failed create.
  let rec go : List Stage → IO Unit
    | [] => pure ()
    | st :: rest => do
      match ← (runStage name root st).toBaseIO with
      | .ok _ => go rest
      | .error e =>
        if st.declared.isEmpty then
          -- The teardown is what failed. There is nothing else to try, and
          -- resources are still standing: say so plainly rather than
          -- reporting one error twice.
          throw (IO.userError s!"{e}\n\
[{name}] the teardown stage itself failed, so resources are still standing. \
`lake test -- {name} destroy` retries it and nothing else")
        else
          match ← (liveTeardown name regions).toBaseIO with
          | .ok _     => throw e
          | .error e2 => throw (IO.userError s!"{e}\nand teardown also failed: {e2}")
  go stages
  -- The last stage already emptied it; this asserts that rather than assuming.
  let rows ← Ledger.load root
  unless rows.isEmpty do
    throw (IO.userError s!"[{name}] the sequence finished with \
{rows.length} resource(s) still managed")

def usage : String :=
  "usage: lake test [-- <aws|scaleway|gcp> [destroy]]\n\n\
  With no argument:     the offline checks. No cloud, no credentials, no cost.\n\
  With a provider:      runs three declarations in sequence against one\n\
                        ledger — the whole fleet, then a trimmed version, then\n\
                        one that declares nothing — and checks after each that\n\
                        the account holds exactly what that stage declares.\n\
                        Ten or eleven real resources, all named\n\
                        'ci-tests-infra-*'. The last stage destroys them.\n\
  …plus 'destroy':      runs only the last stage. Safe to re-run: it destroys\n\
                        whatever the *ledger* holds rather than whatever some\n\
                        declaration names, so it also cleans up after a run\n\
                        that died partway through. This is what CI's backstop\n\
                        runs after a failed leg — the full command is a create\n\
                        *and* a destroy, so re-running that to clean up would\n\
                        create again.\n\n\
  The middle stage is the one that earns the sequence: it drops two resources,\n\
  so their lines are gone from the declaration entirely, and only the ledger\n\
  knows they exist. If membership came from the declaration they would be\n\
  silently abandoned and every assertion would still pass.\n\n\
  The secret's value is read from the environment, never from the fleet: a\n\
  committed literal would not compile, which is what `secretsAreSound`\n\
  proves. Set " ++ secretValueVar ++ " before running a live leg."

/-- The placement to tear down with, per cloud. `liveTeardown` declares nothing,
    so it has no `in` clause of its own to take one from. -/
def regionsFor : String → Option Regions
  | "aws"      => some awsFull.regions
  | "scaleway" => some scalewayFull.regions
  | "gcp"      => some gcpFull.regions
  | _          => none

def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    -- The safe default, and what `lake test` runs in ordinary CI. The stage
    -- guards above have already run by now: they are `#guard`s, so they ran
    -- while this file elaborated.
    Infra.Cli.offlinePlan awsFull.plan "offline checks — no cloud contacted"
    IO.println "\nFor a live sequence: lake test -- <aws|scaleway|gcp>"
    return 0
  | [p] =>
    let some stages := stagesFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    let some regions := regionsFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    match ← (liveSequence p stages regions).toBaseIO with
    | .ok _    => progress s!"[{p}] ok — all {stages.length} stages"; return 0
    | .error e => IO.eprintln s!"error: {e}"; return 1
  | [p, "destroy"] =>
    let some regions := regionsFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    match ← (liveTeardown p regions).toBaseIO with
    | .ok _    => progress s!"[{p}] torn down"; return 0
    | .error e => IO.eprintln s!"error: {e}"; return 1
  | _ => IO.eprintln usage; return 2
