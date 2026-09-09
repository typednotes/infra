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

/-- The handler a `scalewayFunction` deploys, and the smallest thing that can
    prove the kind works end to end.

    The file name inside the archive comes from `handler`, which is
    `handler.handle` in the fleets below, so this lands as `handler.py` and
    Scaleway calls `handle` in it. `Infra.Providers.Zip` builds the archive and
    `Compute.Functions.deployCode` uploads it.

    Inline in the declaration on purpose: the declaration then says what will
    run, which a path to a zip built somewhere else would not. That is why
    `ScalewayFunctionSpec.code` is source rather than a reference. -/
def helloHandler : String :=
  "def handle(event, context):\n" ++
  "    return {\"statusCode\": 200, \"body\": \"Hello, world!\"}\n"

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
    resource securityGroup "ci-tests-infra-sg" as awsSg
      { description := "created and destroyed by the infra live test" }
    -- The kind that used to be excluded, and the reason it can be included
    -- now: `imageId := "latest"` resolves the newest Amazon Linux 2023 image
    -- in this region at apply time, so there is no id in this file to rot.
    --
    -- It also carries the library's only *required* reference, so its creation
    -- order is forced rather than incidental: the group has to exist first,
    -- and teardown has to reverse that.
    --
    -- A `t3.nano`, destroyed within the run. It bills by the second.
    resource awsInstance "ci-tests-infra-vm"
      { imageId       := "latest"
      , instanceType  := InstanceType.of .t3 .nano
      , securityGroup := awsSg }
    resource iam "ci-tests-infra-user" {}

/-! ### Ramp up, then back down

  Same resources throughout: only mutable fields move. Every field changed here
  is on a `.mutable` row of its kind's divergence table, so each stage is an
  `update` rather than a replace, and the pair up-then-down exercises the path
  in both directions. Before this, one field on one kind had ever been updated
  against a real account. -/

fleet awsRampUp in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 120 }
    resource secrets "ci-tests-infra-secret" as awsBaseU
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as awsAU
      { valueFrom := composed expr!"a:{secretValueOf awsBaseU}" }
    resource secrets "ci-tests-infra-b" as awsBU
      { valueFrom := composed expr!"b:{secretValueOf awsBaseU}" }
    -- Fan-in of three, one edge of which is redundant.
    resource secrets "ci-tests-infra-sink" as awsSinkU
      { valueFrom := composed
          expr!"{secretValueOf awsAU}|{secretValueOf awsBU}|{secretValueOf awsBaseU}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf awsSinkU}" }
    resource imageRegistry "ci-tests-infra-images" { immutableTags := false }
    resource objectStore "ci-tests-infra-store-7c1f9a2e" { versioning := true }
    -- Both bucket kinds: they differ in Object Lock, which is creation-time
    -- only, so nothing short of a real create exercises it.
    resource s3Bucket "ci-tests-infra-lock-7c1f9a2e"
      { versioning := true, objectLock := true }
    resource securityGroup "ci-tests-infra-sg" as awsSgU
      { description := "created and destroyed by the infra live test" }
    -- The kind that used to be excluded, and the reason it can be included
    -- now: `imageId := "latest"` resolves the newest Amazon Linux 2023 image
    -- in this region at apply time, so there is no id in this file to rot.
    --
    -- It also carries the library's only *required* reference, so its creation
    -- order is forced rather than incidental: the group has to exist first,
    -- and teardown has to reverse that.
    --
    -- A `t3.nano`, destroyed within the run. It bills by the second.
    resource awsInstance "ci-tests-infra-vm"
      { imageId       := "latest"
      , instanceType  := InstanceType.of .t3 .nano
      , securityGroup := awsSgU }
    resource iam "ci-tests-infra-user" {}

fleet awsRampDown in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as awsBaseD
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as awsAD
      { valueFrom := composed expr!"a:{secretValueOf awsBaseD}" }
    resource secrets "ci-tests-infra-b" as awsBD
      { valueFrom := composed expr!"b:{secretValueOf awsBaseD}" }
    -- Fan-in of three, one edge of which is redundant.
    resource secrets "ci-tests-infra-sink" as awsSinkD
      { valueFrom := composed
          expr!"{secretValueOf awsAD}|{secretValueOf awsBD}|{secretValueOf awsBaseD}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf awsSinkD}" }
    resource imageRegistry "ci-tests-infra-images" { immutableTags := true }
    resource objectStore "ci-tests-infra-store-7c1f9a2e" { versioning := true }
    -- Both bucket kinds: they differ in Object Lock, which is creation-time
    -- only, so nothing short of a real create exercises it.
    resource s3Bucket "ci-tests-infra-lock-7c1f9a2e"
      { versioning := true, objectLock := true }
    resource securityGroup "ci-tests-infra-sg" as awsSgD
      { description := "created and destroyed by the infra live test" }
    -- The kind that used to be excluded, and the reason it can be included
    -- now: `imageId := "latest"` resolves the newest Amazon Linux 2023 image
    -- in this region at apply time, so there is no id in this file to rot.
    --
    -- It also carries the library's only *required* reference, so its creation
    -- order is forced rather than incidental: the group has to exist first,
    -- and teardown has to reverse that.
    --
    -- A `t3.nano`, destroyed within the run. It bills by the second.
    resource awsInstance "ci-tests-infra-vm"
      { imageId       := "latest"
      , instanceType  := InstanceType.of .t3 .nano
      , securityGroup := awsSgD }
    resource iam "ci-tests-infra-user" {}

/-! ### Stage 2: two resources dropped, one changed, one added

  `ci-tests-infra-b` and `ci-tests-infra-sg` are simply absent below, which
  also shortens the graph: with `b` gone, `sink` fans in on two instead of
  three. `queues`' visibility timeout goes from 30 to 60, which is a mutable
  field and so an `update` rather than a replace. And `ci-tests-infra-late`
  is new. -/

/-! The trimming stage drops `b` and the instance, and *keeps* the security
  group. Deliberately that way round: an instance holds a required reference to
  its group, so dropping the group while keeping the instance would not
  compile, and dropping both would make two orphans with a dependency between
  them — which is the one ordering case the ledger cannot express, since a row
  records a name and a region and not an edge. Dropping the dependent alone is
  the case it can. -/

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
    resource securityGroup "ci-tests-infra-sg"
      { description := "created and destroyed by the infra live test" }
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
    resource scalewayFunctionNamespace "ci-tests-infra-fns" as scwFns
      { description := "created and destroyed by the infra live test" }
    -- The other kind that used to be excluded, and the reason it can be
    -- included now: Serverless Functions deploys from an uploaded archive, so
    -- the source is in the declaration and the backend zips it
    -- (`Infra.Providers.Zip`) and uploads it. `handler.handle` means the
    -- archive holds `handler.py` and Scaleway calls `handle` in it.
    resource scalewayFunction "ci-tests-infra-fn"
      { runtime    := "python311"
      , namespace' := scwFns
      , code       := helloHandler
      , handler    := "handler.handle" }
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

fleet scalewayRampUp in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 120 }
    resource secrets "ci-tests-infra-secret" as scwBaseU
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as scwAU
      { valueFrom := composed expr!"a:{secretValueOf scwBaseU}" }
    resource secrets "ci-tests-infra-b" as scwBU
      { valueFrom := composed expr!"b:{secretValueOf scwBaseU}" }
    resource secrets "ci-tests-infra-sink" as scwSinkU
      { valueFrom := composed
          expr!"{secretValueOf scwAU}|{secretValueOf scwBU}|{secretValueOf scwBaseU}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf scwSinkU}" }
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
    resource scalewayFunctionNamespace "ci-tests-infra-fns" as scwFnsU
      { description := "created and destroyed by the infra live test" }
    -- The other kind that used to be excluded, and the reason it can be
    -- included now: Serverless Functions deploys from an uploaded archive, so
    -- the source is in the declaration and the backend zips it
    -- (`Infra.Providers.Zip`) and uploads it. `handler.handle` means the
    -- archive holds `handler.py` and Scaleway calls `handle` in it.
    resource scalewayFunction "ci-tests-infra-fn"
      { runtime    := "python311"
      , namespace' := scwFnsU
      , code       := helloHandler
      , handler    := "handler.handle" }
    resource scalewayContainerNamespace "ci-tests-infra-ctrs" as scwCtrsU
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
      { namespace' := scwCtrsU
      , image      := "docker.io/library/nginx:alpine"
      , port       := 80
      , minScale   := 1
      , maxScale   := 3
      , memoryMb   := 512
      , timeoutSec := 120
      , secretEnv  := [("BASE", scwBaseU)] }

fleet scalewayRampDown in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as scwBaseD
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as scwAD
      { valueFrom := composed expr!"a:{secretValueOf scwBaseD}" }
    resource secrets "ci-tests-infra-b" as scwBD
      { valueFrom := composed expr!"b:{secretValueOf scwBaseD}" }
    resource secrets "ci-tests-infra-sink" as scwSinkD
      { valueFrom := composed
          expr!"{secretValueOf scwAD}|{secretValueOf scwBD}|{secretValueOf scwBaseD}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf scwSinkD}" }
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
    resource scalewayFunctionNamespace "ci-tests-infra-fns" as scwFnsD
      { description := "created and destroyed by the infra live test" }
    -- The other kind that used to be excluded, and the reason it can be
    -- included now: Serverless Functions deploys from an uploaded archive, so
    -- the source is in the declaration and the backend zips it
    -- (`Infra.Providers.Zip`) and uploads it. `handler.handle` means the
    -- archive holds `handler.py` and Scaleway calls `handle` in it.
    resource scalewayFunction "ci-tests-infra-fn"
      { runtime    := "python311"
      , namespace' := scwFnsD
      , code       := helloHandler
      , handler    := "handler.handle" }
    resource scalewayContainerNamespace "ci-tests-infra-ctrs" as scwCtrsD
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
      { namespace' := scwCtrsD
      , image      := "docker.io/library/nginx:alpine"
      , port       := 80
      , minScale   := 0
      , maxScale   := 1
      , memoryMb   := 256
      , timeoutSec := 60
      , secretEnv  := [("BASE", scwBaseD)] }

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

fleet gcpRampUp in paris where
  provider gcp where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 120 }
    resource secrets "ci-tests-infra-secret" as gcpBaseU
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as gcpAU
      { valueFrom := composed expr!"a:{secretValueOf gcpBaseU}" }
    resource secrets "ci-tests-infra-b" as gcpBU
      { valueFrom := composed expr!"b:{secretValueOf gcpBaseU}" }
    resource secrets "ci-tests-infra-sink" as gcpSinkU
      { valueFrom := composed
          expr!"{secretValueOf gcpAU}|{secretValueOf gcpBU}|{secretValueOf gcpBaseU}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf gcpSinkU}" }
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
      , memoryMb   := 1024
      , timeoutSec := 120
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

fleet gcpRampDown in paris where
  provider gcp where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }
    resource secrets "ci-tests-infra-secret" as gcpBaseD
      { valueFrom := fromEnv "CI_TESTS_INFRA_SECRET" }
    resource secrets "ci-tests-infra-a" as gcpAD
      { valueFrom := composed expr!"a:{secretValueOf gcpBaseD}" }
    resource secrets "ci-tests-infra-b" as gcpBD
      { valueFrom := composed expr!"b:{secretValueOf gcpBaseD}" }
    resource secrets "ci-tests-infra-sink" as gcpSinkD
      { valueFrom := composed
          expr!"{secretValueOf gcpAD}|{secretValueOf gcpBD}|{secretValueOf gcpBaseD}" }
    resource secrets "ci-tests-infra-tail"
      { valueFrom := composed expr!"t:{secretValueOf gcpSinkD}" }
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

/-! ### The last stage: nothing at all

  A declaration that declares no resources — `Plan.absent` over the cloud's
  *own* key family. Everything the ledger records becomes an orphan, and
  orphans are what get destroyed. This is `apply` reaching the same place
  `destroy` does.

  Over the full key family, and not over an empty `fleet` of its own, which is
  what it used to be. `liveFor` authenticates exactly `κ.providers`, so a key
  family that names no cloud gets no credentials, and every backend it hands
  back is `Infra.Providers.placeholderBackend` — whose `delete` returns `()`.
  A teardown built that way deleted nothing, emptied the ledger, and satisfied
  `runStage`'s check because `[] == []`. Two clouds reported five green stages
  on 2026-09-08 with their whole estate still standing. `Plan.absent κ` says
  the same thing about the resources while keeping the providers, and `push`
  now refuses the substitution besides — see `docs/internals.md`, "Which clouds
  get authenticated, and the hole that leaves". -/

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
#guard awsFull.keys.count .aws .awsInstance = 1
#guard awsFull.keys.count .aws .iam = 1

#guard scalewayFull.keys.count .scaleway .queues = 1
#guard scalewayFull.keys.count .scaleway .secrets = 5
#guard scalewayFull.keys.count .scaleway .imageRegistry = 1
#guard scalewayFull.keys.count .scaleway .objectStore = 1
#guard scalewayFull.keys.count .scaleway .scalewayFunctionNamespace = 1
#guard scalewayFull.keys.count .scaleway .scalewayContainerNamespace = 1
#guard scalewayFull.keys.count .scaleway .scalewayContainer = 1
#guard scalewayFull.keys.count .scaleway .scalewayFunction = 1
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

/- The one kind no live fleet contains, and the assertion is the zero: a
   Postgres instance takes five to fifteen minutes to create and as long to
   delete, which is longer than the workflow step it would run in. Everything
   else is covered — see the thirteen-of-fourteen guard further down. -/
#guard awsFull.keys.count .aws .postgres = 0
#guard scalewayFull.keys.count .scaleway .postgres = 0
#guard gcpFull.keys.count .gcp .postgres = 0

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

/-- Pack a declaration, deriving `declared` from its own keys.

    Takes the whole fleet rather than the three pieces of it the driver used to
    unpack by hand, for the reason `Infra.Cli.run` does: `regions` carries no
    key family, so a stage assembled from two declarations was a typo away and
    would have run one fleet's plan in another's regions. -/
def stage (label : String) (F : Fleet) : Stage where
  κ := F.keys
  label := label
  plan := F.plan
  regions := F.regions
  forgets := F.forgets
  declared :=
    (Finite.elems (α := ProviderId)).flatMap fun p =>
      (Finite.elems (α := Kind)).flatMap fun k =>
        (Finite.elems (α := F.keys.Key p k)).filterMap fun key =>
          match F.plan.assign p k key with
          | .present _ => some (Ledger.slotId p k (F.keys.name p k key))
          | _          => none

/-- The teardown stage: declare nothing, over the key family that names the
    cloud.

    `Plan.absent κ` and an empty `fleet` say the same thing about resources and
    different things about *providers*, and the difference is not cosmetic —
    `liveFor` authenticates `κ.providers`, so the empty family authenticates
    nothing and tears down through placeholder backends that delete nothing.
    Nothing is forgotten in a teardown either: a `Released` key is one the
    ledger drops without deleting, which is the opposite of what this stage is
    for. -/
def emptyStage (F : Fleet) : Stage :=
  stage "empty" { keys := F.keys, plan := Plan.absent F.keys
                  regions := F.regions, forgets := [] }

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
\n  declared but not managed: {String.intercalate ", " missing}\
\n  A resource on the second list exists and matches, or the stage would not have \
converged, so it was refused rather than missed: look for `push`'s warning about the \
'{markerKey}' tag just above. Debris from an earlier run predates the marker, is not \
adopted, and is therefore not destroyed by the teardown either — \
`lake test -- {name} sweep` is what removes it.")
  progress s!"[{name}/{st.label}] converged; {managed.length} managed"

/-- The stages for one cloud, ending in a declaration that names nothing.

    That last stage is `apply` against an empty declaration, which is the same
    operation `destroy` performs — see `Plan.absent` — and is the half that had
    never run live. Everything the ledger holds becomes an orphan, and orphans
    are what get destroyed. -/
def stagesFor : String → Option (List Stage)
  | "aws" => some
    [ stage "full" awsFull
    , stage "ramp-up" awsRampUp
    , stage "ramp-down" awsRampDown
    , stage "trimmed" awsTrimmed
    , emptyStage awsFull ]
  | "scaleway" => some
    [ stage "full" scalewayFull
    , stage "ramp-up" scalewayRampUp
    , stage "ramp-down" scalewayRampDown
    , stage "trimmed" scalewayTrimmed
    , emptyStage scalewayFull ]
  | "gcp" => some
    [ stage "full" gcpFull
    , stage "ramp-up" gcpRampUp
    , stage "ramp-down" gcpRampDown
    , stage "trimmed" gcpTrimmed
    , emptyStage gcpFull ]
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
  (sts.drop i).headD { emptyStage awsFull.keys {} with label := "missing" }

private def awsStages := stagesFor "aws" |>.getD []
private def scwStages := stagesFor "scaleway" |>.getD []
private def gcpStages := stagesFor "gcp" |>.getD []

/- Five stages per cloud, and the last one declares nothing at all — which is
   what makes it `apply`-empty rather than a sixth mechanism. -/
#guard awsStages.length = 5
#guard scwStages.length = 5
#guard gcpStages.length = 5
#guard (at! awsStages 4).declared = []
#guard (at! scwStages 4).declared = []
#guard (at! gcpStages 4).declared = []

/- And the teardown stage still names its cloud. This is the guard the false
   green of 2026-09-08 needed: the stage declared nothing *and* its key family
   named no provider, so `liveFor` loaded no credentials, every backend was a
   placeholder, and the teardown deleted nothing while reporting success.
   `declared = []` above cannot see that; `providers` can. -/
#guard (at! awsStages 4).κ.providers = [.aws]
#guard (at! scwStages 4).κ.providers = [.scaleway]
#guard (at! gcpStages 4).κ.providers = [.gcp]

/- The two ramp stages declare *exactly* what stage 1 does: same resources,
   same names, same graph. Only mutable fields move. If a ramp accidentally
   added or dropped a resource it would be testing the wrong thing, and the
   assertion in `runStage` would pass anyway because it only compares sets. -/
#guard (at! awsStages 1).declared = (at! awsStages 0).declared
#guard (at! awsStages 2).declared = (at! awsStages 0).declared
#guard (at! scwStages 1).declared = (at! scwStages 0).declared
#guard (at! scwStages 2).declared = (at! scwStages 0).declared
#guard (at! gcpStages 1).declared = (at! gcpStages 0).declared
#guard (at! gcpStages 2).declared = (at! gcpStages 0).declared

/- And every ramp stage declares something, so none is mistaken for a teardown
   by the brake in `push`. A ramp whose numbers matched stage 1 would converge
   instantly and assert nothing, which is how this test would rot unnoticed;
   the numbers themselves are in the declarations a few hundred lines up. -/
#guard awsRampUp.plan.declaresAnything && awsRampDown.plan.declaresAnything
#guard scalewayRampUp.plan.declaresAnything && scalewayRampDown.plan.declaresAnything
#guard gcpRampUp.plan.declaresAnything && gcpRampDown.plan.declaresAnything

/- The trimming stage drops exactly what its comment says, on each cloud.
   These are the orphans: no key in that stage names them, so only the ledger
   can. -/
#guard dropped (at! awsStages 0) (at! awsStages 3)
     = ["aws/secrets/ci-tests-infra-b", "aws/aws-instance/ci-tests-infra-vm"]
-- Three orphans here, and each one's namespace is *still declared*, which is
-- what keeps them orderable: the ledger records a name and a region, not an
-- edge, so an orphan whose dependency is also an orphan is the case it cannot
-- sequence.
#guard dropped (at! scwStages 0) (at! scwStages 3)
     = [ "scaleway/secrets/ci-tests-infra-b"
       , "scaleway/scaleway-function/ci-tests-infra-fn"
       , "scaleway/scaleway-container/ci-tests-infra-ctr" ]
#guard dropped (at! gcpStages 0) (at! gcpStages 3)
     = ["gcp/compute/ci-tests-infra-run", "gcp/secrets/ci-tests-infra-b"]

/- And adds one, so the stage is not purely subtractive: a sequence that only
   ever removed things would never exercise a create after a delete. -/
#guard added (at! awsStages 0) (at! awsStages 3) = ["aws/secrets/ci-tests-infra-late"]
#guard added (at! scwStages 0) (at! scwStages 3) = ["scaleway/secrets/ci-tests-infra-late"]
#guard added (at! gcpStages 0) (at! gcpStages 3) = ["gcp/secrets/ci-tests-infra-late"]

/- Stage 3 drops everything stage 2 still held. -/
#guard dropped (at! awsStages 3) (at! awsStages 4) = (at! awsStages 3).declared
#guard added (at! awsStages 3) (at! awsStages 4) = []

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

/- The counts, read off the declarations rather than remembered: twelve, twelve
   and ten resources, spanning 22 `(cloud, kind)` pairs and *thirteen of the
   fourteen kinds*. Only `postgres` is left out, because it takes longer to
   create than a workflow step allows. -/
-- And after the trim: two dropped and one added on AWS and GCP, three dropped
-- and one added on Scaleway. Quoted by `docs/internals.md`'s sequence diagram,
-- so a fleet that grows has one place to correct.
#guard (at! awsStages 3).declared.length = 11
#guard (at! scwStages 3).declared.length = 10
#guard (at! gcpStages 3).declared.length = 9

#guard (at! awsStages 0).declared.length = 12
#guard (at! scwStages 0).declared.length = 12
#guard (at! gcpStages 0).declared.length = 10

private def kindsOf (st : Stage) : List String :=
  (st.declared.map fun (sl : String) => ((sl.splitOn "/").drop 1).headD "?").eraseDups

#guard (kindsOf (at! awsStages 0)).length + (kindsOf (at! scwStages 0)).length
     + (kindsOf (at! gcpStages 0)).length = 22
#guard ((((at! awsStages 0).declared ++ (at! scwStages 0).declared
          ++ (at! gcpStages 0).declared).map fun (sl : String) =>
          ((sl.splitOn "/").drop 1).headD "?").eraseDups).length = 13
#guard card Kind = 14

/-! ## Sweeping an account, without a ledger to go on

  `destroy` tears down what the *ledger* records, which is the right thing
  inside a run and useless between them: the ledger lives under `.infra/`,
  which is gitignored and does not survive a CI job. So a fresh job asked to
  clean up finds an empty ledger and deletes nothing, however much debris is
  standing.

  A sweep answers a different question — *what in this account looks like this
  test's?* — and answers it from the account rather than from local state.
  Every resource this test creates is named `ci-tests-infra-*`; that naming
  rule is guarded above precisely so it can be relied on here.

  It is the operation `docs/coverage.md` has been telling humans to do by hand
  ("look for 'ci-tests-infra-*' in the account") ever since the first failed
  live run left something behind. -/

/-- Whether a name is this sweep's to delete.

    The single safety property of the whole sweep, so it is one function and it
    is used nowhere else: a sweep must never touch a resource it did not
    create. Anything without the prefix belongs to somebody.

    The prefix is an argument rather than `ciPrefix` directly, and that is the
    difference between "delete this test's debris" and "delete every CI-looking
    thing in the account". One account can hold more than one project's test
    resources — a fork, a second checkout, somebody's branch — and a sweep that
    hard-codes the prefix reaches all of them. `ciPrefix` is still the default
    everywhere, so nothing changes for a caller that does not care; a caller
    that shares an account can narrow it (`--prefix`). Deliberately no empty
    check here: an empty prefix matches everything, and `main` refuses it. -/
def isDebris (debrisPrefix : String) (name : String) : Bool :=
  debrisPrefix.isPrefixOf name

/-- A `--prefix` value, refused when empty.

    The one input this program must never accept: `isDebris ""` is true of
    every name in the account, so an empty prefix turns a scoped cleanup into
    "delete everything the credentials can see". A typo like `--prefix ""` in a
    workflow file is exactly how that would arrive. -/
def checkedPrefix (value : String) : Option String :=
  if value.isEmpty then none else some value

/-- Walk every prefixed resource one cloud's credentials can see, doing `f` to
    each.

    A sweep and the account audit below cover exactly the same ground — every
    kind, every region the fleet uses, every name carrying the prefix — and
    differ only in what they do on finding one. One walk and two callers, so a
    kind or a region that one of them can see is never one the other cannot.

    Listing happens per region the fleet uses, through `Backends.listers`, and
    `f` is handed the listing's own backend — so a resource is acted on
    against the endpoint that reported it, with no region to resolve. -/
def forEachDebris {α : Type} (bs : Backends) (p : ProviderId) (debrisPrefix : String)
    (f : Backend → (k : Kind) → Handle k → String → IO α) : IO (List α) := do
  let mut out : List α := []
  for k in Finite.elems (α := Kind) do
    for (b, _) in bs.listers p k do
      -- A kind the cloud does not implement lists nothing, so this is safe to
      -- ask for every kind rather than only the declared ones — which is the
      -- point: debris from a *previous* version of the fleet is still debris.
      let observed ← match ← (b.list k).toBaseIO with
        | .ok os   => pure os
        | .error _ => pure []   -- an unreadable kind is not a reason to stop
      for o in observed do
        let h := observedHandle k o
        if isDebris debrisPrefix h.raw then
          out := (← f b k h (Ledger.slotId p k h.raw)) :: out
  return out.reverse

/-- One pass: delete every prefixed resource the credentials can see.

    Returns what went and what refused. A refusal is usually a dependency —
    a container before its namespace, an instance before its security group —
    and is not reported as an error here, because the caller retries. Nothing
    knows the dependency graph: a sweep has no declaration to read edges from,
    which is why it converges by repetition instead of by ordering. `push` now
    answers the same question the same way for orphan deletions, which have no
    edges either. -/
def sweepPass (bs : Backends) (p : ProviderId) (debrisPrefix : String := ciPrefix) :
    IO (List String × List String) := do
  let outcomes ← forEachDebris bs p debrisPrefix fun b k h slot => do
    match ← (b.delete k h).toBaseIO with
    | .ok _    => return Except.ok slot
    | .error e => return Except.error s!"{slot}: {e}"
  return (outcomes.filterMap fun (o : Except String String) =>
            match o with | .ok slot => some slot | .error _ => none,
          outcomes.filterMap fun (o : Except String String) =>
            match o with | .ok _ => none | .error e => some e)

/-- Sweep until a pass deletes nothing.

    Bounded by a fuel counter so this is not `partial` and the measure is real.
    Each round either deletes something — strictly reducing what is left — or
    stops, so the bound is only reached if a cloud keeps producing new
    prefixed resources, which nothing does. -/
def sweepUntilQuiet (bs : Backends) (p : ProviderId)
    (label : String) (fuel : Nat) (deleted : Nat)
    (debrisPrefix : String := ciPrefix) : IO Nat := do
  match fuel with
  | 0 =>
    progress s!"[{label}] gave up sweeping with resources still standing"
    return deleted
  | fuel + 1 =>
    let (gone, stuck) ← sweepPass bs p debrisPrefix
    for slot in gone do
      progress s!"[{label}] deleted {slot}"
    if gone.isEmpty then
      -- Nothing went this round, so nothing will next round either: every
      -- remaining refusal is permanent as far as this tool can tell.
      unless stuck.isEmpty do
        progress s!"[{label}] {stuck.length} resource(s) would not delete:"
        for line in stuck do progress s!"[{label}]   {line}"
        throw (IO.userError s!"[{label}] swept {deleted} resource(s), but \
{stuck.length} would not delete — the first is: {stuck.headD "?"}")
      return deleted
    else
      -- Something went, so a refusal may have been a dependency that is now
      -- satisfied. Go round again.
      sweepUntilQuiet bs p label fuel (deleted + gone.length) debrisPrefix

/-- Delete every `ci-tests-infra-*` resource one cloud's credentials can see.

    Independent of any declaration and of any local state, which is what makes
    it the right thing for a scheduled cleanup: it needs no ledger, no cache
    and no knowledge of which fleet created what. It also clears debris from a
    *previous* version of the fleet, which `destroy` cannot, because the
    ledger only ever knew what the current declaration named. -/
def liveSweep (name : String) (κ : Keys) (p : ProviderId) (regions : Regions)
    (debrisPrefix : String := ciPrefix) : IO Unit := do
  let (bs, _) ← Infra.Cli.liveFor κ regions
  progress s!"[{name}] sweeping for '{debrisPrefix}*'…"
  -- Fuel of eight: the deepest dependency chain this test can build is four
  -- (base → a → sink → tail), and a sweep needs one round per level plus a
  -- final round that finds nothing. Eight is that with room.
  let n ← sweepUntilQuiet bs p name 8 0 debrisPrefix
  if n == 0 then
    progress s!"[{name}] nothing to sweep — the account is clean"
  else
    progress s!"[{name}] swept {n} resource(s)"
  -- The ledger may name things that are now gone, so clear it rather than
  -- leave it claiming resources that do not exist.
  Ledger.save (".infra" / s!"live-{name}") []

/-! ## Asking the account, not the ledger

  A teardown empties the ledger, and the check that a run ends clean used to
  compare the ledger against the declaration — so *anything* that empties the
  ledger without deleting satisfied it. That is not hypothetical: `liveFor`
  used to substitute a placeholder for a cloud it loaded no credentials for,
  a placeholder's `delete` returns `()`, and two clouds reported a clean
  teardown with their whole estate standing.

  So a run now finishes by asking the cloud's own listings the question the
  ledger cannot answer. It is the sweep's walk without the deletes. -/

/-- Every prefixed resource one cloud's credentials can see, as slot ids, and
    nothing deleted. -/
def debrisStanding (bs : Backends) (p : ProviderId) (debrisPrefix : String := ciPrefix) :
    IO (List String) := do
  return (← forEachDebris bs p debrisPrefix fun _ _ _ slot => pure slot).eraseDups

/-- `debrisStanding`, polled until it comes back empty or the settle window
    runs out.

    The same reason `waitFor` exists: a delete a cloud has accepted can still
    be listed for a while — Scaleway's namespaces take tens of seconds to go —
    so a single read straight after a teardown measures propagation delay
    rather than correctness. A clean account answers on the first read and
    costs nothing.

    Fuel bounds the recursion so this is not `partial`; the deadline is what
    actually stops it. -/
def debrisAfterSettling (name : String) (bs : Backends) (p : ProviderId) :
    IO (List String) := do
  let start ← Data.Time.getCurrentTime
  let deadline := start.nanosSinceEpoch + settleSeconds * 1000000000
  let rec go (fuel : Nat) : IO (List String) := do
    let standing ← debrisStanding bs p
    if standing.isEmpty then return []
    let now ← Data.Time.getCurrentTime
    if now.nanosSinceEpoch ≥ deadline then return standing
    match fuel with
    | 0     => return standing
    | n + 1 =>
      progress s!"[{name}] {standing.length} resource(s) still listed; waiting…"
      IO.sleep 5000
      go n
  go settleSeconds

/-- Fail unless the account itself reports no debris.

    This is the assertion a green run is worth something for: the ledger being
    empty says only that local state is empty. -/
def assertAccountClean (name : String) (κ : Keys) (p : ProviderId) (regions : Regions) :
    IO Unit := do
  let (bs, _) ← Infra.Cli.liveFor κ regions
  let standing ← debrisAfterSettling name bs p
  unless standing.isEmpty do
    throw (IO.userError s!"[{name}] the ledger is empty but the account is not: {standing.length} resource(s) named '{ciPrefix}*' are still standing — {String.intercalate ", " standing}. `lake test -- {name} sweep` removes them")
  progress s!"[{name}] the account reports no '{ciPrefix}*' resource"

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
def liveTeardown (name : String) (κ : Keys) (p : ProviderId) (regions : Regions) :
    IO Unit := do
  let root : System.FilePath := ".infra" / s!"live-{name}"
  runStage name root (emptyStage κ regions)
  let rows ← Ledger.load root
  unless rows.isEmpty do
    throw (IO.userError s!"[{name}] torn down, but the ledger still lists \
{rows.length} resource(s)")
  progress s!"[{name}] torn down, and the ledger is empty"
  -- And the account agrees, which the ledger on its own cannot say.
  assertAccountClean name κ p regions

/-- Every stage in order, with the teardown guaranteed.

    The final stage *is* the teardown, so a clean run ends with nothing left.
    If any earlier stage fails, the teardown still runs, and both errors are
    reported: a teardown failure that swallowed the real error is how a CI job
    becomes a mystery and a bill. -/
def liveSequence (name : String) (κ : Keys) (p : ProviderId) (stages : List Stage)
    (regions : Regions) : IO Unit := do
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
          match ← (liveTeardown name κ p regions).toBaseIO with
          | .ok _     => throw e
          | .error e2 => throw (IO.userError s!"{e}\nand teardown also failed: {e2}")
  go stages
  -- The last stage already emptied it; this asserts that rather than assuming.
  let rows ← Ledger.load root
  unless rows.isEmpty do
    throw (IO.userError s!"[{name}] the sequence finished with \
{rows.length} resource(s) still managed")
  -- The ledger is empty; now ask the cloud, because an empty ledger is what a
  -- teardown produces whether or not it deleted anything.
  assertAccountClean name κ p regions

def usage : String :=
  "usage: lake test [-- <aws|scaleway|gcp|all> [sweep [--prefix <p>]|destroy]]\n\n\
  With no argument:     the offline checks. No cloud, no credentials, no cost.\n\
  With a provider:      runs five declarations in sequence against one\n\
                        ledger: the whole fleet, the same fleet scaled up,\n\
                        the same scaled back down, a trimmed version, then\n\
                        one that declares nothing. After each it checks that\n\
                        the account holds exactly what that stage declares.\n\
                        Ten or eleven real resources, all named\n\
                        'ci-tests-infra-*'. The last stage destroys them.\n\
  …plus 'sweep':        deletes every resource in the account named\n\
                        'ci-tests-infra-*', whatever created it. Needs no\n\
                        ledger, so unlike 'destroy' it works in a fresh\n\
                        checkout and clears debris from an older version of\n\
                        the fleet. `lake test -- all sweep` does all three\n\
                        clouds. This is the scheduled cleanup.\n\
  …with '--prefix <p>': narrows what counts as debris, for an account shared\n\
                        with another project or checkout whose resources also\n\
                        look like a test's. Defaults to 'ci-tests-infra-'.\n\
                        An empty prefix is refused: it would match every\n\
                        resource the credentials can see.\n\
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

/-- The sweep deletes debris and nothing else.

    The one assertion that matters about a sweep, and it runs offline on every
    push, because getting it wrong means deleting somebody's resource and no
    live test would be a safe place to discover that.

    The backend below lists four buckets: two carrying the CI prefix, one
    belonging to production and one whose name merely *contains* the prefix
    rather than starting with it. Only the first two may go. -/
def checkSweepTouchesOnlyDebris : IO Unit := do
  let seen ← IO.mkRef ([] : List String)
  let listed : List (ObservedOf .objectStore) :=
    [ { handle := ⟨"ci-tests-infra-store-1"⟩, url := "" }
    , { handle := ⟨"ci-tests-infra-store-2"⟩, url := "" }
    , { handle := ⟨"production-billing-exports"⟩, url := "" }
      -- Contains the prefix but does not start with it. `isPrefixOf`, not a
      -- substring test, is what makes this survive — and a substring test is
      -- the obvious way to write this wrong.
    , { handle := ⟨"archive-of-ci-tests-infra-store-0"⟩, url := "" } ]
  let b : Backend :=
    { Infra.Providers.placeholderBackend "sweep-test" with
      list := fun k => match k with
        | .objectStore => pure listed
        | _            => pure []
      delete := fun k h => seen.modify (Ledger.slotId .aws k h.raw :: ·) }
  let bs : Backends := { backend := fun _ => b }
  let (gone, stuck) ← sweepPass bs .aws ciPrefix
  unless stuck.isEmpty do
    throw (IO.userError s!"a sweep against a compliant backend reported failures: {stuck}")
  let deleted := (← seen.get).reverse
  let expected := ["aws/object-store/ci-tests-infra-store-1",
                   "aws/object-store/ci-tests-infra-store-2"]
  unless deleted == expected do
    throw (IO.userError s!"a sweep deleted the wrong things.\n  \
deleted: {deleted}\n  expected: {expected}")
  unless gone == expected do
    throw (IO.userError s!"a sweep reported the wrong things: {gone}")
  IO.println "sweep: ok (deletes every 'ci-tests-infra-*' and nothing else)"

/-- The account audit lists debris and deletes nothing.

    Its whole value is being a *check* — the thing a green run is worth
    something for — so a version of it that deleted, or that scoped like a
    substring test, would be worse than not having it. Same four buckets as
    above: two are debris, and neither of the other two may be reported. -/
def checkAuditListsWithoutDeleting : IO Unit := do
  let deletes ← IO.mkRef (0 : Nat)
  let listed : List (ObservedOf .objectStore) :=
    [ { handle := ⟨"ci-tests-infra-store-1"⟩, url := "" }
    , { handle := ⟨"production-billing-exports"⟩, url := "" }
    , { handle := ⟨"archive-of-ci-tests-infra-store-0"⟩, url := "" } ]
  let b : Backend :=
    { Infra.Providers.placeholderBackend "audit-test" with
      list := fun k => match k with
        | .objectStore => pure listed
        | _            => pure []
      delete := fun _ _ => deletes.modify (· + 1) }
  let standing ← debrisStanding { backend := fun _ => b } .aws ciPrefix
  unless standing == ["aws/object-store/ci-tests-infra-store-1"] do
    throw (IO.userError s!"the audit reported the wrong resources: {standing}")
  unless (← deletes.get) == 0 do
    throw (IO.userError "the audit deleted something; it is a check, not a sweep")
  -- And an account with no debris in it reports clean, which is the answer
  -- every green run gets and therefore the one that must not be a false
  -- negative in either direction.
  let clean ← debrisStanding
    { backend := fun _ => { Infra.Providers.placeholderBackend "audit-test" with
                              list := fun _ => pure [] } } .aws ciPrefix
  unless clean.isEmpty do
    throw (IO.userError s!"an empty account did not report clean: {clean}")
  IO.println "audit: ok (lists this test's debris, deletes nothing)"

/-- A narrowed prefix scopes the sweep to one project's debris.

    The case `--prefix` exists for: one account, two checkouts, and both of
    their test resources looking like a test's. With the default prefix a
    sweep from either one deletes both — which is not a hypothetical, it is
    what a fork or a second branch running the live tests would do to the run
    it was racing.

    Asserted in both directions, because a prefix that scoped *nothing* would
    pass a test that only checked the survivor. -/
def checkSweepPrefixScopes : IO Unit := do
  let seen ← IO.mkRef ([] : List String)
  let listed : List (ObservedOf .objectStore) :=
    [ { handle := ⟨"ci-tests-infra-a-store"⟩, url := "" }
    , { handle := ⟨"ci-tests-infra-b-store"⟩, url := "" } ]
  let b : Backend :=
    { Infra.Providers.placeholderBackend "sweep-test" with
      list := fun k => match k with
        | .objectStore => pure listed
        | _            => pure []
      delete := fun k h => seen.modify (Ledger.slotId .aws k h.raw :: ·) }
  let bs : Backends := { backend := fun _ => b }
  let (gone, _) ← sweepPass bs .aws "ci-tests-infra-a-"
  unless gone == ["aws/object-store/ci-tests-infra-a-store"] do
    throw (IO.userError s!"a narrowed sweep did not scope to its own prefix: {gone}")
  unless (← seen.get) == ["aws/object-store/ci-tests-infra-a-store"] do
    throw (IO.userError s!"a narrowed sweep deleted the wrong things: {← seen.get}")
  -- The default still takes both, so the narrowing is the caller's choice and
  -- not a change to what a plain sweep does.
  let (both, _) ← sweepPass bs .aws ciPrefix
  unless both.length == 2 do
    throw (IO.userError s!"the default prefix stopped covering both projects: {both}")
  -- An empty prefix would match every name in the account. `main` refuses it;
  -- this is the assertion that the refusal is not the only thing standing in
  -- the way of noticing.
  unless (checkedPrefix "").isNone && (checkedPrefix "x").isSome do
    throw (IO.userError "an empty --prefix was accepted")
  IO.println "sweep: ok (a narrowed prefix scopes to one project; empty is refused)"

/-- A sweep keeps going while it makes progress, because it has no dependency
    graph to order by.

    The backend here refuses the namespace until the container is gone, which
    is the real Scaleway ordering constraint, and it is the reason a sweep
    converges by repetition rather than by sorting. One pass would leave the
    namespace standing and report a failure. -/
def checkSweepRetriesUntilQuiet : IO Unit := do
  -- A deleted resource stops being listed, as a real cloud's would. Without
  -- that the double is not a cloud at all: the sweep would keep finding the
  -- namespace and keep deleting it.
  let containerGone ← IO.mkRef false
  let nsGone ← IO.mkRef false
  let b : Backend :=
    { Infra.Providers.placeholderBackend "sweep-order" with
      list := fun k => match k with
        | .scalewayContainerNamespace => do
          if ← nsGone.get then pure []
          else pure [{ handle := ⟨"ci-tests-infra-ctrs"⟩, namespaceId := ""
                       registryEndpoint := "" }]
        | .scalewayContainer => do
          if ← containerGone.get then pure []
          else pure [{ handle := ⟨"ci-tests-infra-ctr"⟩, url := "" }]
        | _ => pure []
      delete := fun k _ => do
        match k with
        | .scalewayContainer => containerGone.set true
        | .scalewayContainerNamespace =>
          -- What Scaleway actually does while a container is still in it, and
          -- the reason a sweep cannot simply delete in one pass.
          if ← containerGone.get then nsGone.set true
          else throw (IO.userError "namespace is not empty")
        | _ => pure () }
  let bs : Backends := { backend := fun _ => b }
  let n ← sweepUntilQuiet bs .scaleway "sweep-order" 8 0 ciPrefix
  unless n == 2 do
    throw (IO.userError s!"a sweep with a dependency swept {n} of 2 resources; \
one pass is not enough and the retry is what makes it converge")
  IO.println "sweep: ok (retries past a dependency, with no graph to go on)"

/-- The placement to tear down or sweep with. Neither declares anything, so
    neither has an `in` clause of its own to take one from. -/
def regionsFor : String → Option Regions
  | "aws"      => some awsFull.regions
  | "scaleway" => some scalewayFull.regions
  | "gcp"      => some gcpFull.regions
  | _          => none

/-- The key family to authenticate with, per cloud.

    Which cloud gets authenticated falls out of this and not out of any `if`:
    `liveFor` authenticates exactly the providers a key family declares
    resources in, so sweeping AWS never reads Scaleway's credentials. That is
    `Keys.providers`, and it is why a sweep can be handed one cloud's key
    family and be trusted to touch only that cloud. -/
def keysFor : String → Option (Keys × ProviderId)
  | "aws"      => some (awsFull.keys, .aws)
  | "scaleway" => some (scalewayFull.keys, .scaleway)
  | "gcp"      => some (gcpFull.keys, .gcp)
  | _          => none

/-- The clouds a sweep covers when asked for all of them. -/
def allClouds : List String := ["aws", "scaleway", "gcp"]

/-- Sweep every cloud, reporting at the end rather than stopping at the first
    one that will not come clean: a cleanup that abandons two accounts because
    the first had a problem is the opposite of useful. -/
def sweepAllClouds (debrisPrefix : String) : IO UInt32 := do
  let mut failures : List String := []
  for cloud in allClouds do
    let some (κ, pid) := keysFor cloud | continue
    let some regions := regionsFor cloud | continue
    match ← (liveSweep cloud κ pid regions debrisPrefix).toBaseIO with
    | .ok _    => pure ()
    | .error e =>
      IO.eprintln s!"error: [{cloud}] {e}"
      failures := cloud :: failures
  if failures.isEmpty then
    progress "swept every cloud"
    return 0
  else
    IO.eprintln s!"error: {failures.reverse} did not come clean"
    return 1

/-- Sweep one cloud. -/
def sweepOneCloud (p : String) (debrisPrefix : String) : IO UInt32 := do
  let some (κ, pid) := keysFor p
    | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
  let some regions := regionsFor p
    | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
  match ← (liveSweep p κ pid regions debrisPrefix).toBaseIO with
  | .ok _    => return 0
  | .error e => IO.eprintln s!"error: {e}"; return 1

def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    -- The safe default, and what `lake test` runs in ordinary CI. The stage
    -- guards above have already run by now: they are `#guard`s, so they ran
    -- while this file elaborated.
    Infra.Cli.offlinePlan awsFull.plan "offline checks — no cloud contacted"
    checkSweepTouchesOnlyDebris
    checkSweepPrefixScopes
    checkSweepRetriesUntilQuiet
    checkAuditListsWithoutDeleting
    IO.println "\nFor a live sequence: lake test -- <aws|scaleway|gcp>"
    return 0
  | [p] =>
    let some stages := stagesFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    let some regions := regionsFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    let some (κ, pid) := keysFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    match ← (liveSequence p κ pid stages regions).toBaseIO with
    | .ok _    => progress s!"[{p}] ok — all {stages.length} stages"; return 0
    | .error e => IO.eprintln s!"error: {e}"; return 1
  | [p, "destroy"] =>
    let some regions := regionsFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    let some (κ, pid) := keysFor p
      | do IO.eprintln s!"error: unknown provider '{p}'\n\n{usage}"; return 1
    match ← (liveTeardown p κ pid regions).toBaseIO with
    | .ok _    => progress s!"[{p}] torn down"; return 0
    | .error e => IO.eprintln s!"error: {e}"; return 1
  -- `sweep all` keeps going after a failure and reports at the end, rather
  -- than stopping at the first cloud that will not come clean. A cleanup that
  -- abandons two accounts because the first one had a problem is the opposite
  -- of useful.
  | ["all", "sweep"] => sweepAllClouds ciPrefix
  | [p, "sweep"] => sweepOneCloud p ciPrefix
  -- `--prefix` narrows what counts as debris, for an account that holds more
  -- than one project's test resources. Spelled out per verb rather than
  -- stripped from the argument list first, so it cannot be silently accepted
  -- and ignored by a verb that does not take it.
  | ["all", "sweep", "--prefix", value] =>
    let some pre := checkedPrefix value
      | do IO.eprintln "error: --prefix may not be empty: it would match \
every resource in the account"; return 1
    sweepAllClouds pre
  | [p, "sweep", "--prefix", value] =>
    let some pre := checkedPrefix value
      | do IO.eprintln "error: --prefix may not be empty: it would match \
every resource in the account"; return 1
    sweepOneCloud p pre
  | _ => IO.eprintln usage; return 2
