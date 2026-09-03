import Infra

/-!
  # Example: declare and push a single Scaleway queue

  The counterpart to `example/ScalewayPull.lean`. That one lists whatever
  Scaleway already has; this one declares a target — one `.queues` resource —
  and pushes it, going through the same `Keys`/`Plan`/`push` path
  `Infra.Core.pull` and `Main.lean` are built around, rather than a raw
  `Backend.list`. `Infra.Demo.demoKeys` is the pattern this borrows, cut down
  to the smallest fleet that still needs the machinery: exactly one key, in
  one cloud, of one kind.

  Scaleway-only, same as `ScalewayPull.lean`: the AWS backend is a
  placeholder, so no AWS credentials are read or required, and `.aws .queues`
  is `Nothing` in this fleet's key family — this plan cannot mention it even
  by mistake.

  Run with:

      lake exe scaleway-queue            -- prints the plan, changes nothing
      lake exe scaleway-queue --apply    -- actually creates the queue
-/

open Infra.Core
open Infra.Specs

/-- The one resource this fleet manages. -/
inductive ExampleQueue | infraExample
  deriving Repr, DecidableEq

instance : Finite ExampleQueue where
  elems := [.infraExample]
  complete := by intro a; cases a <;> simp
  nodup := by decide

/-- Every other `(provider, kind)` pair is `Nothing`, so this fleet cannot
    declare, plan, or push anything but this one queue. -/
@[reducible] def exampleKey : ProviderId → Kind → Type
  | .scaleway, .queues => ExampleQueue
  | _,         _        => Nothing

def exampleKeys : Keys where
  Key    := exampleKey
  finite p k := by cases p <;> cases k <;> exact inferInstance
  decEq  p k := by cases p <;> cases k <;> exact inferInstance
  name   _ _ _ := "infra-example"

def exampleQueueSpec {K : ProviderId → Kind → Type} : QueuesSpec K Partial (Expr K) where
  name                 := "infra-example"
  visibilityTimeoutSec := 30

def examplePlan : Plan exampleKeys where
  assign
    | .scaleway, .queues, .infraExample => .present exampleQueueSpec
    | _,         _,        _            => .unmanaged
  outside := .unmanaged

/-- Own cache root, gitignored the same way as `.infra/` — a separate
    directory because this fleet's key family is not `Infra.Demo.demoKeys`'s,
    and the two must never be read as if they were the same shape. -/
def cacheRoot : System.FilePath := ".infra" / "example-queue"

def main (args : List String) : IO UInt32 := do
  IO.println "authenticating to Scaleway..."
  let creds ← Credentials.load .scaleway
  IO.println s!"authenticated (region {creds.region})"

  let bs : Backends := { backend := fun
    | .aws      => Infra.Providers.placeholderBackend "aws"
    | .scaleway => Infra.Providers.liveBackend .scaleway creds }

  let world ← pull (κ := exampleKeys) cacheRoot bs
  let apply := args == ["--apply"]
  if args != [] && !apply then
    IO.eprintln s!"usage: scaleway-queue [--apply]"
    return 1
  for line in ← push bs examplePlan world { apply } do
    IO.println line
  return 0
