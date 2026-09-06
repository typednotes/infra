import Infra.Core.Kind

/-
  Scaffolding a declaration repository.

  `lake exe infra new my-infra` produces a project that builds, commits and
  deploys — the canonical structure, a commented example fleet, a `.gitignore`
  that excludes the two things that must never be committed, and CI for both
  GitHub and GitLab.

  ## Two modes

  `new <dir>` makes a project in a new directory; `init [dir]` sets up a
  directory that already exists, defaulting to `.`. Same output, and the same
  distinction Lake draws between its own `new` and `init`.

  `init` exists because `new` alone was the wrong shape for the commonest
  start: someone with a repository already, or with nothing in it but a `git
  init` and a README. `new` refused any non-empty directory, so the only route
  was to scaffold a *second* project elsewhere and move files across by hand
  — a workflow nobody would choose, and stricter than `lake init` itself,
  which has never minded a non-empty directory.

  ## Why it wraps `lake init`

  Rather than write a `lean-toolchain` and a git repository from scratch, this
  runs Lake's own `lake init` first and then adds what an infra project needs.
  Lake is the authority on how a Lean project starts, and pinning the toolchain
  is exactly the kind of thing that should not be reimplemented here and left
  to drift.

  ## Why the lakefile is replaced rather than patched

  `lake init` writes a minimal lakefile; an infra project needs a much longer
  one, because **Lake does not propagate a dependency's `moreLinkArgs` to a
  dependent's executable**. `liblinenffi.a` lands on the link line but the
  flags its members need do not, so linking fails with undefined
  `SecItemCopyMatching`. Every consumer therefore has to carry the same
  platform-conditional block that `infra`'s own lakefile has — which is the
  single most annoying thing about starting one of these by hand, and the main
  reason this command exists.

  That block is duplicated, and duplication is a liability: if `infra`'s own
  link flags change, this copy has to change with them. `AGENTS.md` records the
  obligation.
-/

namespace Infra.Cli.New

/-- The platform-conditional native link flags every consumer needs.

    Kept byte-for-byte in step with `infra`'s own `lakefile.lean`, for the
    reason in the module comment. -/
private def linkFlags : String :=
"-- ── Native link flags ──
--
-- Lake does NOT propagate a dependency's `moreLinkArgs` to a dependent's
-- executable: `liblinenffi.a` is on the link line, but the flags its members
-- need are not, so `keychain.o` fails to link with undefined
-- `SecItemCopyMatching`/`CFRelease`. This block is the fix, and it is why this
-- file is `.lean` rather than `.toml` — TOML cannot express a conditional.
--
-- This is a VERBATIM copy of the same block in `infra`'s own lakefile, kept
-- identical by `ci/check-lakefile-sync.sh`. Do not \"simplify\" it: every
-- branch below is load-bearing on some platform, and the two that look most
-- redundant (dropping `-L`, and omitting OpenSSL) are the two whose absence
-- breaks the Linux link outright.
-- ⟪native-link-flags:begin⟫ — mirrored verbatim into `Infra/Cli/New.lean`.
-- `ci/check-lakefile-sync.sh` fails the build if the two ever differ.
/-- Ask `pkg-config` for a package's flags, degrading to `#[]` when it or the
    package is missing — matching how Linen treats optional native
    dependencies. -/
def pkgConfigFlags (args : Array String) : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := \"pkg-config\", args }
    if out.exitCode != 0 then return #[]
    return (out.stdout.trimAscii.copy.splitOn \" \").toArray.map (·.trimAscii.copy)
      |>.filter (· != \"\")
  catch _ => return #[]

/-- Link flags naming each library file outright, rather than adding its
    directory to the search path.

    On Linux, `pkg-config --variable=libdir` is typically
    `/usr/lib/x86_64-linux-gnu`, which holds the *system* `libc.so` alongside
    everything else. Passing that as `-L` makes `ld.lld` prefer the system
    glibc over the one Lean bundles, and Lean's own `Scrt1.o` references
    `__libc_csu_init` — removed in glibc 2.34. The result is a link that fails
    with an undefined symbol in the C runtime, nowhere near anything this
    package wrote.

    Linen has the same `-L` and never hits this, because only `lean_lib Linen`
    is a default target there: `lake build` never links an executable. `infra`
    does.

    Naming `<libdir>/libfoo.so` directly links exactly the intended file and
    shadows nothing. Falls back to `-lfoo` if the file is absent, so a distro
    with a different layout still gets a chance. -/
def pkgAbsoluteLibs (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #[\"--libs\", pkg]
  let libdirs ← pkgConfigFlags #[\"--variable=libdir\", pkg]
  let libdir : Option String := (libdirs.filter (· != \"\"))[0]?
  let mut out : Array String := #[]
  for tok in libs do
    if tok.startsWith \"-L\" then
      continue                                  -- deliberately dropped
    else if tok.startsWith \"-l\" then
      let name := (tok.drop 2).toString
      match libdir with
      | some d =>
        let candidate : FilePath := (d : FilePath) / s!\"lib{name}.so\"
        if ← candidate.pathExists then
          out := out.push candidate.toString
        else
          out := out.push tok
      | none => out := out.push tok
    else
      out := out.push tok
  return out

/-- The active macOS SDK's framework and library search paths. Lean ships its
    own `lld`, which has no default framework path, so these are required for
    `-framework` to resolve. `#[]` off macOS. -/
def macSdkArgs : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := \"xcrun\", args := #[\"--show-sdk-path\"] }
    if out.exitCode != 0 then return #[]
    let sdk := out.stdout.trimAscii.copy
    if sdk.isEmpty then return #[]
    return #[\"-F\", sdk ++ \"/System/Library/Frameworks\", \"-L\", sdk ++ \"/usr/lib\"]
  catch _ => return #[]

open Lean Elab Command in
run_cmd do
  let mkDef (n : Name) (flags : Array String) : CommandElabM Unit := do
    let lits : Array (TSyntax `term) := flags.map (fun s => quote s)
    elabCommand (← `(def $(mkIdent n) : Array String := #[$lits,*]))
  -- `System.Keychain`: Security.framework on macOS, libsecret on Linux.
  let keychain : Array String ←
    if System.Platform.isOSX then
      (macSdkArgs).map (· ++ #[\"-framework\", \"Security\", \"-framework\", \"CoreFoundation\"])
    else if System.Platform.isWindows then
      pure #[\"-ladvapi32\", \"-lcredui\"]
    else
      pkgAbsoluteLibs \"libsecret-1\"
  -- OpenSSL is deliberately absent, though `jose.o` and `tls.o` both reference
  -- it. Lean already ends every executable link with its own
  -- `LEANC_INTERNAL_LINKER_FLAGS`:
  --
  --     -L <toolchain>/lib … -lgmp -luv -lssl -lcrypto
  --
  -- which resolves against the *static* `libssl.a`/`libcrypto.a` the release
  -- toolchain bundles (`script/prepare-llvm-linux.sh`: `cp $OPENSSL/lib/libssl.a
  -- $OPENSSL/lib/libcrypto.a stage1/lib/`). Those archives are already the
  -- last thing on the line, which is exactly where an archive has to sit to
  -- satisfy `liblinenffi.a` above it.
  --
  -- Naming the system OpenSSL as well is not merely redundant on Linux, it is
  -- fatal. A current distro's `libssl.so`/`libcrypto.so` need
  -- `stat@GLIBC_2.33`, `dlopen@GLIBC_2.34` and `__isoc23_strtol@GLIBC_2.38`,
  -- while the glibc Lean bundles under `lib/glibc` predates all three — it
  -- still has the `__libc_csu_init` that glibc 2.34 removed. Under lld's
  -- default `--no-allow-shlib-undefined` that is an immediate link failure on
  -- eighteen symbols no code here can reach.
  --
  -- Dropping it retires the macOS hazard too: the reason to point at
  -- Homebrew's OpenSSL was that dyld could otherwise bind to the system's
  -- incompatible `libboringssl` and crash on the first TLS call. A static
  -- archive cannot be re-bound at runtime, so the failure mode is gone rather
  -- than merely avoided.
  --
  -- The Linux CI still installs `libssl-dev`, for the *headers* Linen's
  -- `jose.c`/`tls.c` compile against. Only the link flags are unnecessary.
  mkDef `nativeLinkArgs keychain
-- ⟪native-link-flags:end⟫
"

private def fleetLean (name : String) : String :=
"import Infra

/-!
  # The declared fleet: everything this project manages

  A fleet is an ordinary Lean value. You do not write steps — you write the
  destination, and `infra` works out the route: observe what exists, diff it
  against this file, and reconcile.

  Two things to internalise before editing:

  1. **Removing a `resource` line does not delete anything.** It removes the
     key, and an unkeyed resource is *unmanaged* — it keeps running and keeps
     billing. Deletion is `destroy`.
  2. **Only what is named here is managed.** Everything else in your accounts
     is left alone, unconditionally. There is no import step and no drift
     scan over resources you did not declare.

  See `docs/tutorial.md` in the `infra` repository for the guided version.
-/

open Infra.Core
open Infra.Specs

-- `in paris` places every cloud this fleet uses: AWS reads `eu-west-3`,
-- Scaleway `fr-par`, GCP `europe-west9`. One word, resolved per cloud.
--
-- You can also name a cloud's own code (`in aws \"eu-west-1\"`), and you can
-- place individual resources with nested blocks:
--
--     provider aws where
--       resource objectStore \"eu-assets\" { versioning := true }
--       in nVirginia where
--         resource objectStore \"us-assets\" { versioning := true }
--
-- A place a cloud is not in — `in warsaw` on a fleet using AWS — does not
-- compile.
fleet " ++ name ++ " in paris where
  provider scaleway where

    -- The simplest resource: a bucket. Fields you do not mention are not
    -- \"defaulted and enforced\" — they are simply not spoken about, and
    -- whatever the cloud has stays.
    resource objectStore \"" ++ name ++ "-assets\"
      { versioning := true
      , tags       := [(\"project\", \"" ++ name ++ "\")] }

    -- A secret names where its value comes from. It never holds one, and
    -- `secretsAreSound` below checks that at compile time.
    resource secrets \"" ++ name ++ "-db-password\" as dbPassword
      { valueFrom := fromEnv \"DB_PASSWORD\" }

    -- `masterPasswordSecret` names the secret above by name; the reference
    -- below (`dbPassword`) is the typed one. Both are ordering edges, so one
    -- apply creates the password first.
    resource postgres \"" ++ name ++ "-db\" as mainDb
      { masterUsername       := \"dbadmin\"
      , masterPasswordSecret := \"" ++ name ++ "-db-password\"
      , minCapacity          := 1
      , maxCapacity          := 4 }

    -- A value that cannot exist until the database does. `composed` holds the
    -- *function*, so ONE apply creates all three in the right order — no
    -- second run, no operator pasting a connection string in between.
    resource secrets \"" ++ name ++ "-db-url\"
      { valueFrom := composed
          expr!\"postgres://dbadmin:{secretValueOf dbPassword}@{endpointOf mainDb}/main\" }

-- ── Checks that run at build time ──

-- No plaintext secret is committed. Decidable, so this is checked by the
-- compiler rather than trusted.
#guard " ++ name ++ ".plan.secretsAreSound

-- Single-cloud, so no other cloud's credentials are read or required.
#guard " ++ name ++ ".keys.providers = [.scaleway]

-- Four resources, one apply.
#guard (actions " ++ name ++ ".plan (worldOf [])).length = 4
"

private def mainLean (name : String) : String :=
"import Fleet

open Infra.Core

/-- Which accounts this fleet is for.

    Checked before any live command touches anything, because being
    authenticated is not the same as being pointed at the right place. A stale
    keychain entry, an exported `AWS_PROFILE`, or a CI secret aimed elsewhere
    all look identical at the point of use.

    Neither value is a secret — an AWS account id appears in every ARN — and
    they belong in the repo that declares the fleet. Fill these in, or delete
    the argument below to skip the check. -/
def accounts : Infra.Cli.Accounts where
  expect
    | .aws      => none   -- e.g. some \"123456789012\"
    | .scaleway => none   -- e.g. some \"your-org-uuid\"
    | .gcp      => none   -- e.g. some \"your-gcp-project\"

/-- The dispatch lives in `infra`; this repo declares. -/
def main (args : List String) : IO UInt32 :=
  Infra.Cli.run \"" ++ name ++ "\" " ++ name ++ ".plan
    (accounts := accounts) (regions := " ++ name ++ ".regions)
    -- Without this, a `forget` in the declaration compiles and then the
    -- resource is destroyed anyway, which is the one thing `forget` exists to
    -- prevent.
    (forgets := " ++ name ++ ".forgets) (args := args)
"

private def gitignore : String :=
"/.lake

# Observed-state cache and the local membership ledger. Regenerated by
# `refresh` and rewritten by `apply`; never commit either.
.infra/

.DS_Store
"

private def githubPlan (name : String) : String :=
"name: Plan

# On a pull request: show what would change. Reads the account, changes
# nothing. The offline half runs for everyone; the live half needs secrets and
# is skipped on forks, where they are not available.
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Install native dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libpq-dev libssl-dev libsecret-1-dev pkg-config
      - uses: leanprover/lean-action@v1

      # Lean's toolchain bundles a static OpenSSL whose compile-time trust-store
      # path does not exist on a runner, so every live call fails with
      # `certificate verify failed` until OpenSSL is pointed at the real
      # bundle. Costs nothing when it is already correct.
      - name: Point OpenSSL at the runner's CA bundle
        run: |
          for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
            if [ -f \"$f\" ]; then echo \"SSL_CERT_FILE=$f\" >> \"$GITHUB_ENV\"; break; fi
          done
          echo \"SSL_CERT_DIR=/etc/ssl/certs\" >> \"$GITHUB_ENV\"


      # Compiles the fleet and runs every `#guard` in it — including that no
      # plaintext secret is committed. No credentials needed.
      - name: Offline checks
        run: lake exe " ++ name ++ " check

      - name: Plan
        if: github.event.pull_request.head.repo.full_name == github.repository || github.event_name != 'pull_request'
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ secrets.SCW_DEFAULT_PROJECT_ID }}
        run: |
          {
            echo '### Plan'
            echo '```'
            lake exe " ++ name ++ " plan 2>&1
            echo '```'
          } >> \"$GITHUB_STEP_SUMMARY\"
"

private def githubApply (name : String) : String :=
"name: Apply

# Manual only. A job that changes infrastructure should be started by a person
# who meant to, and `environment: production` is where you add required
# reviewers — a gate this file cannot enforce for itself.
on:
  workflow_dispatch:

concurrency:
  group: apply
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v5
      - name: Install native dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libpq-dev libssl-dev libsecret-1-dev pkg-config
      - uses: leanprover/lean-action@v1

      # Lean's toolchain bundles a static OpenSSL whose compile-time trust-store
      # path does not exist on a runner, so every live call fails with
      # `certificate verify failed` until OpenSSL is pointed at the real
      # bundle. Costs nothing when it is already correct.
      - name: Point OpenSSL at the runner's CA bundle
        run: |
          for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
            if [ -f \"$f\" ]; then echo \"SSL_CERT_FILE=$f\" >> \"$GITHUB_ENV\"; break; fi
          done
          echo \"SSL_CERT_DIR=/etc/ssl/certs\" >> \"$GITHUB_ENV\"


      - name: Check the required secrets are present
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ secrets.SCW_DEFAULT_PROJECT_ID }}
          DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
        run: |
          # An unset GitHub secret arrives as the empty string, not as absent.
          # Checking here names the missing one instead of failing later as an
          # opaque provider error — or, worse, half way through an apply.
          missing=\"\"
          for v in SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID DB_PASSWORD; do
            [ -n \"${!v}\" ] || missing=\"$missing $v\"
          done
          if [ -n \"$missing\" ]; then
            echo \"::error::missing repository secret(s):$missing\"
            exit 1
          fi

      - name: Plan
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ secrets.SCW_DEFAULT_PROJECT_ID }}
        run: lake exe " ++ name ++ " plan

      - name: Apply
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ secrets.SCW_DEFAULT_PROJECT_ID }}
          DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
        run: lake exe " ++ name ++ " apply

      # A clean apply leaves nothing outstanding. If this prints actions, the
      # fleet did not converge and something is wrong.
      - name: Verify convergence
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ secrets.SCW_DEFAULT_PROJECT_ID }}
        run: lake exe " ++ name ++ " plan
"

private def gitlabCi (name : String) : String :=
"# GitLab CI, the same shape as the GitHub workflows: plan on every push,
# apply only when a human starts it.
#
# Set SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_PROJECT_ID and DB_PASSWORD
# as *masked, protected* CI/CD variables in Settings -> CI/CD -> Variables.

stages: [check, plan, apply]

default:
  image: ubuntu:24.04
  before_script:
    - apt-get update -qq
    - apt-get install -y -qq curl git build-essential libpq-dev libssl-dev libsecret-1-dev pkg-config
    - curl -sSfL https://github.com/leanprover/elan/releases/latest/download/elan-x86_64-unknown-linux-gnu.tar.gz | tar xz
    - ./elan-init -y --default-toolchain none
    - export PATH=\"$HOME/.elan/bin:$PATH\"
    # Lean's toolchain bundles a static OpenSSL whose compile-time trust-store
    # path does not exist in a bare container: without this, every live call
    # fails with `certificate verify failed`.
    - export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    - export SSL_CERT_DIR=/etc/ssl/certs
  cache:
    key: lake-$CI_COMMIT_REF_SLUG
    paths: [.lake/]

# Compiles the fleet and runs every `#guard`, including that no plaintext
# secret is committed. Needs no credentials.
check:
  stage: check
  script:
    - export PATH=\"$HOME/.elan/bin:$PATH\"
    - lake exe " ++ name ++ " check

plan:
  stage: plan
  script:
    - export PATH=\"$HOME/.elan/bin:$PATH\"
    - lake exe " ++ name ++ " plan

# Manual, and protected: `when: manual` means a person presses the button.
apply:
  stage: apply
  when: manual
  allow_failure: false
  environment:
    name: production
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  resource_group: apply      # never two applies at once
  script:
    - export PATH=\"$HOME/.elan/bin:$PATH\"
    - lake exe " ++ name ++ " plan
    - lake exe " ++ name ++ " apply
    - lake exe " ++ name ++ " plan   # must be empty: a clean apply converges
"

/-- CircleCI. -/
private def circleCi (name : String) : String :=
"# CircleCI: plan on every push, apply only when a person approves it.
#
# Set SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_PROJECT_ID and DB_PASSWORD
# in a context (Organization Settings -> Contexts) rather than as plain project
# variables, so the apply job can require the context and the plan job need not
# have it.

version: 2.1

commands:
  setup:
    steps:
      - checkout
      - run:
          name: Install Lean and native dependencies
          command: |
            sudo apt-get update -qq
            sudo apt-get install -y -qq libpq-dev libssl-dev libsecret-1-dev pkg-config
            curl -sSfL https://github.com/leanprover/elan/releases/latest/download/elan-x86_64-unknown-linux-gnu.tar.gz | tar xz
            ./elan-init -y --default-toolchain none
            echo 'export PATH=\"$HOME/.elan/bin:$PATH\"' >> \"$BASH_ENV\"
            # Lean's toolchain bundles a static OpenSSL whose compile-time
            # trust-store path does not exist here: without this every live
            # call fails with `certificate verify failed`.
            echo 'export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' >> \"$BASH_ENV\"
            echo 'export SSL_CERT_DIR=/etc/ssl/certs' >> \"$BASH_ENV\"
      - run: lake build

jobs:
  # Compiles the fleet and runs every `#guard`, including that no plaintext
  # secret is committed. Needs no credentials.
  check:
    machine: { image: ubuntu-2404:current }
    steps:
      - setup
      - run: lake exe " ++ name ++ " check

  plan:
    machine: { image: ubuntu-2404:current }
    steps:
      - setup
      - run: lake exe " ++ name ++ " plan

  apply:
    machine: { image: ubuntu-2404:current }
    steps:
      - setup
      - run: lake exe " ++ name ++ " plan
      - run: lake exe " ++ name ++ " apply
      # Must be empty: a clean apply converges.
      - run: lake exe " ++ name ++ " plan

workflows:
  infra:
    jobs:
      - check
      - plan:
          requires: [check]
      # `type: approval` is the button. The apply reads the context; the plan
      # above deliberately does not.
      - hold:
          type: approval
          requires: [plan]
          filters: { branches: { only: [main] } }
      - apply:
          requires: [hold]
          context: [infra-apply]
          filters: { branches: { only: [main] } }
"

/-- Azure Pipelines. -/
private def azurePipelines (name : String) : String :=
"# Azure Pipelines: plan on every push, apply behind a manual approval.
#
# Put SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_PROJECT_ID and DB_PASSWORD in
# a variable group named `infra-secrets` (Pipelines -> Library), marked secret.
# The apply stage targets an *environment*, which is where approvals live —
# create one called `production` and add yourself as an approver, or the apply
# runs unattended.

trigger:
  branches: { include: [main] }

pool:
  vmImage: ubuntu-24.04

variables:
  - group: infra-secrets
  # Lean's toolchain bundles a static OpenSSL whose compile-time trust-store
  # path does not exist on the hosted image.
  - name: SSL_CERT_FILE
    value: /etc/ssl/certs/ca-certificates.crt
  - name: SSL_CERT_DIR
    value: /etc/ssl/certs

stages:
  - stage: check
    jobs:
      - job: check
        steps:
          - template: .azure/setup.yml
          # Compiles the fleet and runs every `#guard`. No credentials needed.
          - script: lake exe " ++ name ++ " check
            displayName: Offline checks

  - stage: plan
    dependsOn: check
    jobs:
      - job: plan
        steps:
          - template: .azure/setup.yml
          - script: lake exe " ++ name ++ " plan
            displayName: Plan

  - stage: apply
    dependsOn: plan
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      # A deployment job, not a plain job: that is what makes the environment's
      # approval apply to it.
      - deployment: apply
        environment: production
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self
                - template: .azure/setup.yml
                - script: lake exe " ++ name ++ " plan
                  displayName: Plan
                - script: lake exe " ++ name ++ " apply
                  displayName: Apply
                - script: lake exe " ++ name ++ " plan
                  displayName: Re-plan (must be empty)
"

/-- The setup steps Azure's stages share. -/
private def azureSetup : String :=
"# Shared by every stage in azure-pipelines.yml. Kept separate because Azure
# re-clones and re-provisions per stage, so this runs three times and should
# only be written once.
steps:
  - script: |
      set -e
      sudo apt-get update -qq
      sudo apt-get install -y -qq libpq-dev libssl-dev libsecret-1-dev pkg-config
      curl -sSfL https://github.com/leanprover/elan/releases/latest/download/elan-x86_64-unknown-linux-gnu.tar.gz | tar xz
      ./elan-init -y --default-toolchain none
      echo \"##vso[task.prependpath]$HOME/.elan/bin\"
    displayName: Install Lean and native dependencies
  - task: Cache@2
    inputs:
      key: 'lake | \"$(Agent.OS)\" | lake-manifest.json'
      path: .lake
    displayName: Cache .lake
  - script: lake build
    displayName: Build
"

/-- Jenkins, declarative pipeline. -/
private def jenkinsfile (name : String) : String :=
"// Jenkins declarative pipeline: plan on every build, apply behind an input
// step that a person has to answer.
//
// Credentials come from the Jenkins credential store by id — add four secret
// texts named scw-access-key, scw-secret-key, scw-project-id and db-password.
// Nothing secret belongs in this file.

pipeline {
  agent { label 'linux' }

  environment {
    // Lean's toolchain bundles a static OpenSSL whose compile-time trust-store
    // path does not exist on most agents: without this every live call fails
    // with `certificate verify failed`.
    SSL_CERT_FILE = '/etc/ssl/certs/ca-certificates.crt'
    SSL_CERT_DIR  = '/etc/ssl/certs'
    PATH          = \"$HOME/.elan/bin:$PATH\"
  }

  options {
    // Never two applies at once against the same account.
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
  }

  stages {
    stage('Install') {
      steps {
        sh 'command -v lake >/dev/null || (curl -sSfL https://github.com/leanprover/elan/releases/latest/download/elan-x86_64-unknown-linux-gnu.tar.gz | tar xz && ./elan-init -y --default-toolchain none)'
      }
    }

    stage('Build') { steps { sh 'lake build' } }

    // Compiles the fleet and runs every `#guard`, including that no plaintext
    // secret is committed. Needs no credentials.
    stage('Check') { steps { sh 'lake exe " ++ name ++ " check' } }

    stage('Plan') {
      steps {
        withCredentials([
          string(credentialsId: 'scw-access-key', variable: 'SCW_ACCESS_KEY'),
          string(credentialsId: 'scw-secret-key', variable: 'SCW_SECRET_KEY'),
          string(credentialsId: 'scw-project-id', variable: 'SCW_DEFAULT_PROJECT_ID'),
          string(credentialsId: 'db-password',    variable: 'DB_PASSWORD')
        ]) {
          sh 'lake exe " ++ name ++ " plan'
        }
      }
    }

    stage('Approve') {
      when { branch 'main' }
      steps {
        // The button. Times out rather than holding an executor for ever.
        timeout(time: 60, unit: 'MINUTES') {
          input message: 'Apply this plan to production?', ok: 'Apply'
        }
      }
    }

    stage('Apply') {
      when { branch 'main' }
      steps {
        withCredentials([
          string(credentialsId: 'scw-access-key', variable: 'SCW_ACCESS_KEY'),
          string(credentialsId: 'scw-secret-key', variable: 'SCW_SECRET_KEY'),
          string(credentialsId: 'scw-project-id', variable: 'SCW_DEFAULT_PROJECT_ID'),
          string(credentialsId: 'db-password',    variable: 'DB_PASSWORD')
        ]) {
          sh 'lake exe " ++ name ++ " plan'
          sh 'lake exe " ++ name ++ " apply'
          // Must be empty: a clean apply converges.
          sh 'lake exe " ++ name ++ " plan'
        }
      }
    }
  }
}
"

private def readme (name : String) : String :=
"# " ++ name ++ "

Infrastructure as code, declared in Lean with
[`infra`](https://github.com/typednotes/infra).

`Fleet.lean` is the whole declaration. `Main.lean` is a five-line entry point.
Everything else is build and CI plumbing.

## Commands

```sh
lake exe " ++ name ++ "                # check — offline, free, no credentials
lake exe " ++ name ++ " refresh        # observe the accounts and cache what is there
lake exe " ++ name ++ " plan           # what would change; reads, changes nothing
lake exe " ++ name ++ " apply          # actually reconcile
lake exe " ++ name ++ " plan --destroy # what tearing it down would delete
lake exe " ++ name ++ " destroy        # delete everything this fleet declares
```

A bare invocation is offline and free of charge: it plans against placeholder
backends. You have to ask for the real thing.

## Credentials

Three sources, first hit wins: the cloud CLIs' own config files, then the OS
keychain, then environment variables.

```sh
export SCW_ACCESS_KEY=…  SCW_SECRET_KEY=…  SCW_DEFAULT_PROJECT_ID=…
```

You do **not** need a region variable — `Fleet.lean` declares where it is.

`DB_PASSWORD` is read at apply time for the secret declared in `Fleet.lean`;
it never enters the repository, the plan output or the state cache.

## Before the first apply

- **Fill in `accounts` in `Main.lean`.** Until you do, nothing stops this
  being applied into the wrong account. The ids are not secrets.
- **Rename the resources** in `Fleet.lean`. Some names are globally unique
  per cloud.
- **`.infra/` is gitignored** and must stay that way.

## Two things that surprise people

- Removing a `resource` line does **not** delete anything. It un-manages it —
  the resource keeps running and keeps billing. Deletion is `destroy`.
- Only what is named in `Fleet.lean` is managed. Everything else in your
  accounts is left alone, unconditionally.
"

/-- Write a file, creating its directory. Returns whether it wrote.

    `keep := true` leaves an existing file alone. That is the difference
    between `new` and `init`: scaffolding into a directory someone is already
    working in must not be able to destroy what is there, and a lakefile or a
    `Main.lean` they wrote is exactly what would go. -/
private def put (root : System.FilePath) (rel : String) (contents : String)
    (keep : Bool := false) : IO Bool := do
  let path := root / rel
  if keep && (← path.pathExists) then
    IO.println s!"  {rel} (kept — already there)"
    return false
  if let some dir := path.parent then IO.FS.createDirAll dir
  IO.FS.writeFile path contents
  IO.println s!"  {rel}"
  return true

/-- The lakefile: Lake's own, plus the link flags and the dependency. -/
private def lakefile (name : String) : String :=
"import Lake
open System Lake DSL

/-
  Build configuration for an `infra` declaration repository.

  Generated by `infra new`. The long block below is not optional — see its
  comment — and is the reason this is `.lean` rather than `.toml`.
-/

" ++ linkFlags ++ "

package «" ++ name ++ "» where
  version := v!\"0.1.0\"
  moreLinkArgs := nativeLinkArgs

require infra from git \"https://github.com/typednotes/infra\" @ \"main\"

@[default_target]
lean_lib Fleet

-- Compiled, never applied: it is the reference catalogue, and compiling it is
-- what keeps its examples from rotting. Delete the file and this line together.
@[default_target]
lean_lib Catalogue

@[default_target]
lean_exe «" ++ name ++ "» where
  root := `Main
"

/-- The reference catalogue: every resource kind, declared. -/
private def catalogueLean (name : String) : String :=
"import Infra

/-!
  # Catalogue: every kind, declared once

  A reference to copy from. This file is **compiled and never applied** —
  `Main.lean` runs `Fleet.plan` and nothing else, so nothing here is ever
  created, read or billed.

  Compiled, though, and that is the point. Commented-out examples rot: they
  drift from the API and nobody notices, because nothing checks them. These are
  type-checked by your own `lake build`, against the version of `infra` you
  actually depend on. If an example here stops compiling after an upgrade, that
  is real information, and it is the same information the release notes would
  have had to tell you.

  Delete this file whenever it stops being useful. Nothing imports it.

  Fields you do not mention are not defaulted-and-enforced — they are not
  spoken about, and whatever the cloud has stays. So the shortest declaration
  that names a resource is a valid one.
-/

open Infra.Core
open Infra.Specs

-- One place for three clouds: AWS reads `eu-west-3`, Scaleway `fr-par`, GCP
-- `europe-west9`. Naming a place a cloud is not in does not compile.
fleet catalogue in paris where

  -- ── Portable kinds: the same declaration on any cloud ──
  provider aws where

    -- Object storage. `objectStore` is the portable spelling; `s3Bucket`
    -- below is the AWS-local one with Object Lock.
    resource objectStore \"" ++ name ++ "-portable-bucket\"
      { versioning := true
      , tags       := [(\"owner\", \"platform\"), (\"env\", \"prod\")] }

    -- An IAM role, by name, with policies attached by ARN.
    resource iam \"" ++ name ++ "-task-role\"
      { policies := [\"arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess\"] }

    -- A container image repository.
    resource imageRegistry \"" ++ name ++ "-images\"
      { immutableTags := true }

    -- A queue. On AWS and Scaleway this is SQS; on GCP it is a Pub/Sub topic,
    -- where `visibilityTimeoutSec` belongs to a subscription and is therefore
    -- not reported — see the GCP block below.
    resource queues \"" ++ name ++ "-jobs\"
      { visibilityTimeoutSec := 60 }

    -- A secret names *where its value comes from*. It never holds one, and
    -- `secretsAreSound` proves that at compile time.
    resource secrets \"" ++ name ++ "-api-key\" as apiKey
      { valueFrom := fromEnv \"API_KEY\" }

    -- Serverless compute. `image` is required; the rest differ by cloud, and
    -- a field the cloud has no concept of is simply left unsaid.
    resource compute \"" ++ name ++ "-worker\"
      { image         := \"" ++ name ++ "-images:latest\"
      , memoryMb      := 512
      , timeoutSec    := 30
      , env           := [(\"QUEUE\", \"" ++ name ++ "-jobs\")] }

    -- Postgres. Every capacity argument is required: an autoscaling range you
    -- did not choose is a bill you did not choose.
    resource secrets \"" ++ name ++ "-db-password\" as dbPassword
      { valueFrom := fromEnv \"DB_PASSWORD\" }
    resource postgres \"" ++ name ++ "-db\" as db
      { masterUsername       := \"dbadmin\"
      , masterPasswordSecret := \"" ++ name ++ "-db-password\"
      , minCapacity          := 1
      , maxCapacity          := 4
      , storageGb            := 20 }

    -- A value that cannot exist until the database does. `composed` holds the
    -- *function*, so one apply creates password, database and URL in order —
    -- no second run, nobody pasting a connection string in between.
    resource secrets \"" ++ name ++ "-db-url\"
      { valueFrom := composed
          expr!\"postgres://dbadmin:{secretValueOf dbPassword}@{endpointOf db}/main\" }

    -- ── AWS-local kinds ──

    -- `s3Bucket` over `objectStore` when you need Object Lock, which is
    -- creation-time only and so shows up as a `replace` if you change it.
    resource s3Bucket \"" ++ name ++ "-archive\"
      { versioning := true
      , objectLock := true }

    -- A security group, and an instance that requires one. The reference is
    -- typed: delete the group and the instance stops compiling.
    resource securityGroup \"" ++ name ++ "-web\" as web
      { description := \"http from anywhere\"
      -- The annotation is needed, and it is not ceremony: a bare `80` has no
      -- determined type until something fixes it, and the coercion into the
      -- field cannot fire while it is still open. Without it the error names
      -- a metavariable rather than this line.
      , ingress     := ([(80, \"0.0.0.0/0\"), (443, \"0.0.0.0/0\")] : List (Nat × String)) }

    -- `InstanceType.of` is a checked pair: `.of .t3 .nano` compiles,
    -- `.of .t3 .metal` does not, because there is no `t3.metal`.
    resource awsInstance \"" ++ name ++ "-api\"
      { imageId       := \"ami-0abcdef1234567890\"
      , instanceType  := InstanceType.of .t3 .small
      , securityGroup := web
      , keyName       := \"my-keypair\" }

  provider scaleway where

    resource objectStore \"" ++ name ++ "-scw-assets\" { versioning := true }
    resource queues \"" ++ name ++ "-scw-jobs\" { visibilityTimeoutSec := 30 }
    resource secrets \"" ++ name ++ "-scw-token\" as scwToken
      { valueFrom := fromEnv \"SCW_TOKEN\" }

    -- ── Scaleway-local kinds ──

    -- Functions and containers live in a namespace, and the namespace is a
    -- resource. The reference is typed, so the namespace is created first.
    resource scalewayFunctionNamespace \"" ++ name ++ "-fns\" as fns
      { description := \"functions for " ++ name ++ "\" }
    resource scalewayFunction \"" ++ name ++ "-resize\"
      { runtime    := \"node22\"
      , namespace' := fns }

    resource scalewayContainerNamespace \"" ++ name ++ "-ctrs\" as ctrs
      { description := \"containers for " ++ name ++ "\" }
    resource scalewayContainer \"" ++ name ++ "-api\"
      { namespace' := ctrs
      , image      := \"rg.fr-par.scw.cloud/" ++ name ++ "/api:latest\"
      , port       := 8080
      , minScale   := 0
      , maxScale   := 3
      , memoryMb   := 512
      , timeoutSec := 60
      , env        := [(\"LOG_LEVEL\", \"info\")]
      -- Secrets are passed by *reference*, not by value: the plaintext is
      -- never in this file and never in the plan.
      , secretEnv  := [(\"TOKEN\", scwToken)] }

  provider gcp where

    -- `queues` on GCP is a Pub/Sub topic and is live. The other kinds here
    -- declare, place, diff and export to HCL, but an apply raises — see
    -- `docs/coverage.md` in the infra repository for what is implemented.
    -- An empty block is legal and means \"manage this, say nothing about it\":
    -- every field is then left as the cloud has it.
    resource queues \"" ++ name ++ "-gcp-jobs\" {}

    resource objectStore \"" ++ name ++ "-gcp-assets\" { versioning := true }

-- ── Checks the compiler runs on all of it ──

-- No plaintext secret anywhere in the catalogue. Decidable, so this is proved
-- rather than reviewed.
#guard catalogue.plan.secretsAreSound

-- All three clouds appear.
#guard catalogue.keys.providers = [.aws, .scaleway, .gcp]
"

/-! ## Converting `lakefile.toml`

  The flow this exists for is the one a Terraform user would expect:

      lake init my-infra
      cd my-infra
      # add infra to lakefile.toml
      lake update
      lake exe infra init

  and the obstacle is the first line. `lake init` writes **`lakefile.toml`**,
  and TOML cannot express what this needs: the native link flags are computed
  on the build machine by running `pkg-config`, so the lakefile has to be a
  program. Telling someone to port it by hand is the friction the last command
  is supposed to remove — so it is converted instead.

  Only the subset `lake init` and `lake new` actually emit is understood, plus
  the `require` forms someone would add by hand. Anything else refuses the
  conversion rather than guessing: a lakefile is the one file where a
  well-meaning rewrite that drops a line is worse than doing nothing. The
  original is renamed, never deleted. -/

/-- A `[table]` or `[[table]]` and the `key = value` lines under it. -/
private structure TomlSection where
  header : String
  kvs    : List (String × String) := []

/-- Split into sections. Comments and blank lines are dropped; a line that is
    neither a header nor a `key = value` is kept as an unnamed key so the
    caller can refuse rather than silently ignore it. -/
private def tomlSections (contents : String) : List TomlSection :=
  let step : (List TomlSection) → String → (List TomlSection) := fun acc raw =>
    let line := raw.trimAscii.copy
    if line.isEmpty || line.startsWith "#" then acc
    else if line.startsWith "[" then
      { header := line, kvs := [] } :: acc
    else
      match line.splitOn "=" with
      | k :: rest =>
        let kv := (k.trimAscii.copy, (String.intercalate "=" rest).trimAscii.copy)
        match acc with
        | s :: tl => { s with kvs := s.kvs ++ [kv] } :: tl
        | []      => [{ header := "", kvs := [kv] }]
      | [] => acc
  let sections := ((contents.splitOn "\n").foldl step [{ header := "", kvs := [] }]).reverse
  sections

/-- A TOML string literal's contents. -/
private def tomlStr (v : String) : Option String :=
  let t := v.trimAscii.copy
  if t.length ≥ 2 && t.startsWith "\"" && t.endsWith "\"" then
    some ((t.drop 1).dropEnd 1).copy
  else none

/-- What a converted lakefile needs to reproduce. -/
private structure Ported where
  name     : String := ""
  version  : String := "0.1.0"
  libs     : List String := []
  exes     : List (String × String) := []
  requires : List String := []
  deriving Inhabited

private def lookup (s : TomlSection) (k : String) : Option String :=
  (s.kvs.find? (·.1 == k)).bind fun kv => tomlStr kv.2

/-- Render one `[[require]]` as Lake's Lean syntax, or refuse.

    Refusing matters more than covering every form. A `require` that is
    silently dropped turns into a missing-import error a long way from here,
    and one that is rendered wrongly is worse still. -/
private def portRequire (s : TomlSection) : Except String String := do
  let some name := lookup s "name"
    | throw "a [[require]] with no name"
  match lookup s "git", lookup s "rev", lookup s "path", lookup s "version" with
  | some git, rev, _, _ =>
    let pin := match rev with | some r => s!" @ \"{r}\"" | none => ""
    return s!"require «{name}» from git \"{git}\"{pin}"
  | none, _, some path, _ =>
    return s!"require «{name}» from \"{path}\""
  | none, _, none, some v =>
    return s!"require «{name}» @ \"{v}\""
  | none, _, none, none =>
    return s!"require «{name}»"

/-- Read a `lakefile.toml` into the pieces a Lean one has to restate. -/
private def portToml (contents : String) : Except String Ported := do
  let mut p : Ported := {}
  for s in tomlSections contents do
    let h := s.header
    if h.isEmpty then
      if let some n := lookup s "name" then p := { p with name := n }
      if let some v := lookup s "version" then p := { p with version := v }
      -- `defaultTargets` is re-derived: the targets change, because a Fleet
      -- library is being added and the executable now runs it.
      for (k, _) in s.kvs do
        unless ["name", "version", "defaultTargets", "testDriver", "lintDriver",
                "leanOptions", "buildType", "precompileModules", "platformIndependent",
                "moreLinkArgs", "moreLeanArgs", "moreServerArgs", "srcDir",
                "packagesDir", "keywords", "description", "homepage", "license",
                "licenseFiles", "readmeFile", "reservoir", "defaultFacets",
                "weakLeanArgs", "weakLinkArgs", "moreLeancArgs", "weakLeancArgs",
                "restoreAllPackages", "version_tags"].contains k do
          throw s!"a package field this does not understand: '{k}'"
    else if h == "[[lean_lib]]" then
      let some n := lookup s "name" | throw "a [[lean_lib]] with no name"
      p := { p with libs := p.libs ++ [n] }
    else if h == "[[lean_exe]]" then
      let some n := lookup s "name" | throw "a [[lean_exe]] with no name"
      p := { p with exes := p.exes ++ [(n, (lookup s "root").getD "Main")] }
    else if h == "[[require]]" then
      p := { p with requires := p.requires ++ [← portRequire s] }
    else
      throw s!"a table this does not understand: {h}"
  if p.name.isEmpty then throw "no package name"
  return p

/-- A lakefile.lean equivalent to the TOML one, plus what `infra` adds.

    Their libraries and executables are preserved rather than replaced: this is
    a conversion, and a project that had a `MyInfra` library still has one
    afterwards. What is added is the `Fleet` library, the link flags, and
    `infra` itself if it was not already required. -/
private def lakefileFromToml (p : Ported) : String :=
  let hasInfra := p.requires.any fun r => (r.splitOn "«infra»").length > 1
  let requires :=
    if hasInfra then p.requires
    else p.requires ++ ["require infra from git \"https://github.com/typednotes/infra\" @ \"main\""]
  let libs := (p.libs ++ ["Fleet", "Catalogue"]).eraseDups
  let exes := if p.exes.isEmpty then [(p.name, "Main")] else p.exes
  "import Lake\nopen System Lake DSL\n\n" ++
"/-\n  Build configuration for an `infra` declaration repository.\n\n\
  Converted from `lakefile.toml` by `infra init`, which had to: the link-flag\n\
  block below is computed by running `pkg-config` on the build machine, and\n\
  TOML has no way to express that. The original is kept as\n\
  `lakefile.toml.replaced-by-infra`.\n-/\n\n" ++
  linkFlags ++ "\n\npackage «" ++ p.name ++ "» where\n  version := v!\"" ++ p.version ++
  "\"\n  moreLinkArgs := nativeLinkArgs\n\n" ++
  String.intercalate "\n" requires ++ "\n\n" ++
  String.intercalate "\n\n" (libs.map fun l => "@[default_target]\nlean_lib " ++ l) ++ "\n\n" ++
  String.intercalate "\n\n" (exes.map fun (n, r) =>
    "@[default_target]\nlean_exe «" ++ n ++ "» where\n  root := `" ++ r) ++ "\n"

/-- Is this `Main.lean` the stub `lake init` writes?

    It matters because transforming a project means replacing its entry point,
    and replacing code someone wrote would be unforgivable. Lake's stub prints
    a greeting and nothing else, so it is recognisable and safe to overwrite;
    anything else is kept, with the five lines to add printed instead. -/
private def isLakeStubMain (contents : String) : Bool :=
  (contents.splitOn "Hello,").length > 1 && contents.length < 400

/-- Scaffold a project into `dir`.

    Two modes, mirroring Lake's own pair, because they answer two different
    questions and conflating them was a mistake:

    - `new dir` — make me a project. Refuses a non-empty directory.
    - `init dir` — set *this* directory up. Keeps whatever is already there.

    Only `new` existed at first, and it refused any directory with anything in
    it — including one holding nothing but a `git init` and a README, which is
    where most people start. So the answer to "I already have a directory, add
    infra to it" was to create a *second* project somewhere else and move the
    files across by hand. `lake init`, which this wraps, has never had that
    restriction; the wrapper was stricter than the thing it wrapped for no
    reason anyone could have defended.

    `init` writes only files that are absent and says which it kept. If it
    keeps the lakefile — an existing Lean project — it prints the block that
    has to go in by hand, because the link flags are not optional and Lake
    will not propagate them from a dependency. -/
def scaffold (dir : String) (inPlace : Bool := false) : IO UInt32 := do
  let root : System.FilePath := dir
  if ← root.pathExists then
    let entries ← root.readDir
    unless inPlace || entries.isEmpty do
      IO.eprintln s!"error: {dir} exists and is not empty"
      IO.eprintln s!"  to set up the directory you are already in, use: \
lake exe infra init {dir}"
      return 1
  IO.FS.createDirAll root

  -- The Lean identifier the fleet is named after: `my-infra` is not one, and
  -- neither is `.` — which is the usual spelling of "here", so it has to
  -- resolve to the directory's real name rather than to an underscore.
  let resolved ← try IO.FS.realPath root catch _ => pure root
  let base := (resolved.fileName.getD dir)
  let cleaned := base.map fun c => if c.isAlphanum then c else '_'
  -- A leading digit is not a Lean identifier either, and `2026-infra` is a
  -- plausible directory name.
  let ident := if cleaned.front.isDigit then "_" ++ cleaned else cleaned

  -- What was here *before this command ran*. That is the set to protect, and
  -- it is not the same as "what exists when we come to write it": `lake init`
  -- below creates a lakefile, a `Main.lean` and a README of its own moments
  -- from now, and keeping *those* would mean keeping Lake's minimal lakefile
  -- instead of the one with the link flags in it — the single thing this
  -- command exists to provide.
  let mut preexisting : List String := []
  if inPlace then
    for f in [ "lakefile.lean", "Fleet.lean", "Main.lean", ".gitignore", "README.md"
             , ".github/workflows/plan.yml", ".github/workflows/apply.yml"
             , ".gitlab-ci.yml", ".circleci/config.yml", "azure-pipelines.yml"
             , ".azure/setup.yml", "Jenkinsfile", "Catalogue.lean" ] do
      if ← (root / f).pathExists then preexisting := f :: preexisting

  -- `lake new` writes `lakefile.toml`, and with both present Lake announces
  -- "using lakefile.lean" and ignores the TOML one *entirely* — including any
  -- dependency declared in it. Writing ours next to theirs would therefore
  -- silently discard their configuration while appearing to work, which is
  -- worse than doing nothing. So a TOML lakefile counts as a lakefile.
  let hasToml ← (root / "lakefile.toml").pathExists

  IO.println s!"{if inPlace then "Setting up" else "Creating"} {dir}…\n"

  -- Lake first: it owns how a Lean project starts, including the toolchain
  -- pin, and reimplementing that here would only let it drift. Skipped when
  -- there is already a lakefile, because then Lake's work is done and running
  -- it again would only fail.
  let hasLakefile ← ((root / "lakefile.lean").pathExists <||> (root / "lakefile.toml").pathExists)
  unless hasLakefile do
    let init ← try
        IO.Process.output { cmd := "lake", args := #["init", ident, "exe.lean"], cwd := root }
      catch _ =>
        IO.eprintln "error: `lake` is not on PATH — install elan first"
        return 1
    unless init.exitCode == 0 do
      IO.eprintln s!"error: lake init failed:\n{init.stderr}"
      return 1

  let keep (rel : String) : Bool := preexisting.contains rel
  -- Not `keep`: that only declines to *overwrite*, and here the file to leave
  -- alone is `lakefile.toml` while the one we would create — `lakefile.lean` —
  -- does not exist yet. So this is a conversion, not a no-clobber.
  -- One name, used for the fleet's namespace, the executable, the CI scripts
  -- and `Main.lean`'s reference to the fleet. It defaults to the directory,
  -- but a converted project already *has* a name — its package's — and using
  -- the directory there produced a `Fleet.lean` declaring `fleet flow` beside
  -- a `Main.lean` calling `my_infra.plan`. It compiled in neither direction.
  let mut exeName := ident
  let wroteLakefile ←
    if inPlace && hasToml then do
      let contents ← IO.FS.readFile (root / "lakefile.toml")
      match portToml contents with
      | .ok p =>
        IO.FS.writeFile (root / "lakefile.lean") (lakefileFromToml p)
        -- Renamed, not removed. Lake ignores `lakefile.toml` once a Lean one
        -- exists, so leaving it in place would be a trap for the next reader;
        -- deleting it would be taking a decision that is not this command's
        -- to take.
        IO.FS.rename (root / "lakefile.toml") (root / "lakefile.toml.replaced-by-infra")
        if let some (n, _) := p.exes[0]? then exeName := n
        IO.println "  lakefile.lean (converted from lakefile.toml)"
        IO.println "  lakefile.toml → lakefile.toml.replaced-by-infra"
        pure true
      | .error e =>
        IO.println s!"  lakefile.lean (NOT written — {e})"
        pure false
    else put root "lakefile.lean" (lakefile ident) (keep "lakefile.lean")
  discard <| put root "Fleet.lean"                 (fleetLean exeName) (keep "Fleet.lean")
  discard <| put root "Catalogue.lean"             (catalogueLean exeName) (keep "Catalogue.lean")
  -- Transforming a project means replacing its entry point, and Lake's stub
  -- prints a greeting and nothing else — recognisable, and no loss to
  -- overwrite. Anything else is someone's code and is kept.
  let keepMain ←
    if keep "Main.lean" then
      pure !(isLakeStubMain (← IO.FS.readFile (root / "Main.lean")))
    else pure false
  let wroteMain ← put root "Main.lean" (mainLean exeName) keepMain
  discard <| put root ".gitignore"                 gitignore (keep ".gitignore")
  discard <| put root "README.md"                  (readme exeName) (keep "README.md")
  discard <| put root ".github/workflows/plan.yml" (githubPlan exeName)
    (keep ".github/workflows/plan.yml")
  discard <| put root ".github/workflows/apply.yml" (githubApply exeName)
    (keep ".github/workflows/apply.yml")
  discard <| put root ".gitlab-ci.yml"             (gitlabCi exeName) (keep ".gitlab-ci.yml")
  discard <| put root ".circleci/config.yml"       (circleCi exeName)
    (keep ".circleci/config.yml")
  discard <| put root "azure-pipelines.yml"        (azurePipelines exeName)
    (keep "azure-pipelines.yml")
  discard <| put root ".azure/setup.yml"           azureSetup (keep ".azure/setup.yml")
  discard <| put root "Jenkinsfile"                (jenkinsfile exeName) (keep "Jenkinsfile")

  -- Written line by line rather than as one escaped literal: the indentation
  -- is part of the message, and a string gap would eat it.
  IO.println ""
  -- Keeping someone's lakefile is the one case where the result does not yet
  -- build, and saying "Done" would be a lie. The flags are the whole reason
  -- this command exists.
  unless wroteLakefile do
    if hasToml then
      IO.println "Your lakefile.toml was left exactly as it was, because this"
      IO.println "could not convert it safely — the reason is on the line above."
      IO.println ""
      IO.println "It has to become a lakefile.lean either way: the native link"
      IO.println "flags are computed by running `pkg-config` on the build machine,"
      IO.println "and TOML cannot express that. They are not optional, because"
      IO.println "Lake does not propagate them from a dependency."
      IO.println ""
      IO.println "Port it by hand and re-run this, and it will fill in the rest."
      IO.println "For a reference lakefile.lean to copy the block from:"
      IO.println ""
      IO.println "  infra new /tmp/reference && cat /tmp/reference/lakefile.lean"
      IO.println ""
    else
    IO.println "Your lakefile was kept, so the dependency and the native link"
    IO.println "flags are NOT in it yet. Both are required — Lake does not"
    IO.println "propagate link flags from a dependency. Add to lakefile.lean:"
    IO.println ""
    IO.println "  require infra from git \"https://github.com/typednotes/infra\" @ \"main\""
    IO.println ""
    IO.println "  -- and the `moreLinkArgs` block from this project's own"
    IO.println "  -- lakefile.lean, which `lake exe infra new` writes in full:"
    IO.println "  --   lake exe infra new /tmp/reference && cat /tmp/reference/lakefile.lean"
    IO.println ""
  IO.println "Next:"
  IO.println ""
  unless inPlace do IO.println s!"  cd {dir}"
  IO.println  "  lake update                # fetch infra"
  IO.println s!"  lake exe {exeName}           # offline plan — no credentials, no charges"
  IO.println ""
  unless wroteMain do
    IO.println "Your Main.lean was kept, so it does not run the fleet yet. It needs:"
    IO.println ""
    IO.println "  import Fleet"
    IO.println "  def main (args : List String) : IO UInt32 :="
    IO.println s!"    Infra.Cli.run \"{exeName}\" Fleet.plan (accounts := accounts)"
    IO.println   "      (regions := Fleet.regions) (forgets := Fleet.forgets) (args := args)"
    IO.println ""
    IO.println "See the Main.lean that `infra new` writes for the whole file."
    IO.println ""
  IO.println "Then edit Fleet.lean, fill in `accounts` in Main.lean, and commit."
  IO.println "CI for GitHub and GitLab is already there; add your secrets and it runs."
  return 0

end Infra.Cli.New
