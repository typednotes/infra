import Lake
open System Lake DSL

package infra where
  version := v!"0.24.3"
  -- Metadata Reservoir (the Lake package index) surfaces on the package page.
  -- Reservoir indexes public Lean repos automatically — no submission — but it
  -- only shows what is declared here, and the repo link is all it can infer.
  description := "Terraform-style infrastructure as code in Lean 4: \
dependently-typed target and observed cloud state, so an unrealisable \
target is a compile error"
  keywords := #["devtool", "cloud", "infrastructure", "devops", "dsl"]
  homepage := "https://typednotes.github.io/infra/"
  license := "Apache-2.0"
  -- Strict elaboration: every variable is bound explicitly. CI also builds
  -- with `--wfail`, so a warning (including `sorry`) fails the build.

require linen from git "https://github.com/typednotes/linen" @ "v4.1.0"

@[default_target]
lean_lib Infra

@[default_target]
lean_exe infra where
  root := `Main

/-- `example/ScalewayPull.lean`: authenticate to Scaleway alone, pull, and
    export what came back to `out/scaleway/` as JSON and as Lean. Compiled by
    `lake build` like everything else, but only touches a network when run. -/
@[default_target]
lean_exe «scaleway-pull» where
  srcDir := "example"
  root := `ScalewayPull

/-- `example/ScalewayQueue.lean`: declare and push a single Scaleway queue,
    the `Keys`/`Plan`/`push` counterpart to `scaleway-pull`'s raw
    `Backend.list`. -/
@[default_target]
lean_exe «scaleway-queue» where
  srcDir := "example"
  root := `ScalewayQueue

/-- `example/ParisInstances.lean`: two EC2 instances behind one security
    group, demonstrating the library's only *required* cross-resource
    reference — an instance with no security group is not representable.
    Placeholder-backed, so it costs nothing to run. -/
@[default_target]
lean_exe «paris-instances» where
  srcDir := "example"
  root := `ParisInstances

/-- `example/CrossCloud.lean`: one fleet spanning both clouds, with a
    reference crossing between them. Unlike the two above it runs against the
    placeholder backends, so it needs no credentials and touches no network —
    it is there to be read and compiled, not to provision anything. -/
@[default_target]
lean_exe «cross-cloud» where
  srcDir := "example"
  root := `CrossCloud

/-- The test driver, which `lake test` runs.

    Offline with no arguments — that is what ordinary CI runs, and it needs no
    credentials and costs nothing. `lake test -- aws` (or `scaleway`, `gcp`)
    creates one real queue, checks the fleet converged, and deletes it again,
    with the teardown guaranteed by a `finally`. See `test/Live.lean`. -/
@[test_driver]
lean_exe «live-test» where
  srcDir := "test"
  root := `Live

/-- `example/ServerlessSqlIam.lean`: an IAM application, an API key minted
    into a secret, and a Serverless SQL Database that only IAM can open —
    the fleet `SecretSource.apiKeyFor` exists for. Placeholder-backed on a
    bare invocation, so it needs no credentials. -/
@[default_target]
lean_exe «serverless-sql-iam» where
  srcDir := "example"
  root := `ServerlessSqlIam

/-- `example/MultiRegion.lean`: one fleet in four regions, placed with nested
    `provider`/`in` blocks. Placeholder-backed like `cross-cloud`, so a bare
    invocation needs no credentials. -/
@[default_target]
lean_exe «multi-region» where
  srcDir := "example"
  root := `MultiRegion

/-- `example/PostgresMigrations.lean`: a database, the two identities and
    URL secrets that gate it, a declared migration history, and a container
    whose rollout waits on it — the `postgresMigrations` kind's whole
    story in one fleet. Placeholder-backed, so a bare invocation needs no
    credentials and touches no network: it is there to be read and
    compiled, and the ordering of its plan is what it proves. -/
@[default_target]
lean_exe «postgres-migrations» where
  srcDir := "example"
  root := `PostgresMigrations

/-- `example/KubernetesPostgres.lean`: a managed cluster, and a Postgres
    StatefulSet behind a Service inside it — the `kubernetesCluster` and
    `kubernetesObject` kinds' story in one fleet. Placeholder-backed, so a
    bare invocation needs no credentials; the ordering of its plan and the
    refusals of its broken siblings are what it proves. -/
@[default_target]
lean_exe «kubernetes-postgres» where
  srcDir := "example"
  root := `KubernetesPostgres

@[default_target]
lean_exe «private-services» where
  srcDir := "example"
  root := `PrivateServices
