import Infra

/-!
  # The test driver: offline by default, live on request

  `lake test` runs the offline checks and touches no cloud. `lake test -- aws`
  (or `scaleway`, or `gcp`) creates a real resource, checks it converged,
  and deletes it again.

  ## Why a queue

  Every live fleet here declares exactly one `queues` resource. Queues are the
  right shape for this: their names are scoped to a region rather than
  globally unique, so two accounts running this concurrently do not collide,
  they cost approximately nothing, and they create and delete in seconds. An
  S3 bucket would be the obvious choice and is the wrong one — bucket names
  are globally unique across all of AWS, and a fleet's resource names are
  fixed at compile time, so the test would be one name away from being
  permanently unrunnable by anyone else.

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

fleet awsLive in ireland where
  provider aws where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }

fleet scalewayLive in paris where
  provider scaleway where
    resource queues "ci-tests-infra-queue" { visibilityTimeoutSec := 30 }

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

-- Every live fleet names exactly one resource, and it carries the prefix.
#guard awsLive.keys.count .aws .queues = 1
#guard scalewayLive.keys.count .scaleway .queues = 1
#guard gcpLive.keys.count .gcp .queues = 1
#guard awsLive.names.aws.queues.all (ciPrefix.isPrefixOf ·)
#guard scalewayLive.names.scaleway.queues.all (ciPrefix.isPrefixOf ·)
#guard gcpLive.names.gcp.queues.all (ciPrefix.isPrefixOf ·)

-- Each fleet is single-cloud, so a run for one provider never authenticates
-- another — which is what lets the workflow pass one set of secrets.
#guard awsLive.keys.providers = [.aws]
#guard scalewayLive.keys.providers = [.scaleway]
#guard gcpLive.keys.providers = [.gcp]

/-- How long to let a cloud's listing catch up before calling it a failure. -/
def settleSeconds : Nat := 60

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
  With a provider:  creates a real queue named 'ci-tests-infra-queue',\n\
                    checks it converged, and deletes it again."

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
