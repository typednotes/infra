import Lake
open System Lake DSL

/-
  Build configuration.

  This was `lakefile.toml` until `infra` started using Linen's FFI-backed
  features (`System.Keychain` for credentials, and OpenSSL-backed TLS/SigV4 for
  the provider clients). Lake does **not** propagate a dependency's
  `moreLinkArgs` to a dependent's executable: `liblinenffi.a` is on the link
  line, but the flags its members need are not, so `keychain.o` fails to link
  with undefined `SecItemCopyMatching`/`CFRelease`. TOML has no way to express
  the platform-conditional flags that fixes, hence Lean.

  Only the flags for the FFI `infra` actually reaches are declared. A static
  archive contributes only the members whose symbols are referenced, so there
  is no need for Linen's libpq or DuckDB flags here.

  Resolution happens at lakefile-elaboration time on the build machine, so
  nothing is hardcoded to one developer's paths.
-/

/-- Ask `pkg-config` for a package's flags, degrading to `#[]` when it or the
    package is missing — matching how Linen treats optional native
    dependencies. -/
def pkgConfigFlags (args : Array String) : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "pkg-config", args }
    if out.exitCode != 0 then return #[]
    return (out.stdout.trimAscii.copy.splitOn " ").toArray.map (·.trimAscii.copy)
      |>.filter (· != "")
  catch _ => return #[]

/-- Link flags for a `pkg-config` package, including an explicit `-L` so a
    keg-only Homebrew prefix resolves. -/
def pkgLinkFlags (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #["--libs", pkg]
  let libdir ← pkgConfigFlags #["--variable=libdir", pkg]
  return (libdir.filter (· != "")).map ("-L" ++ ·) ++ libs

/-- The active macOS SDK's framework and library search paths. Lean ships its
    own `lld`, which has no default framework path, so these are required for
    `-framework` to resolve. `#[]` off macOS. -/
def macSdkArgs : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "xcrun", args := #["--show-sdk-path"] }
    if out.exitCode != 0 then return #[]
    let sdk := out.stdout.trimAscii.copy
    if sdk.isEmpty then return #[]
    return #["-F", sdk ++ "/System/Library/Frameworks", "-L", sdk ++ "/usr/lib"]
  catch _ => return #[]

open Lean Elab Command in
run_cmd do
  let mkDef (n : Name) (flags : Array String) : CommandElabM Unit := do
    let lits : Array (TSyntax `term) := flags.map (fun s => quote s)
    elabCommand (← `(def $(mkIdent n) : Array String := #[$lits,*]))
  -- `System.Keychain`: Security.framework on macOS, libsecret on Linux.
  let keychain : Array String ←
    if System.Platform.isOSX then
      (macSdkArgs).map (· ++ #["-framework", "Security", "-framework", "CoreFoundation"])
    else if System.Platform.isWindows then
      pure #["-ladvapi32", "-lcredui"]
    else
      pkgLinkFlags "libsecret-1"
  -- TLS and the SHA-256/HMAC behind SigV4 are OpenSSL-backed. Linking the
  -- *right* OpenSSL matters on macOS: without an explicit `-L`, dyld can bind
  -- these to the system's incompatible `libboringssl`, which crashes on the
  -- first TLS call rather than failing to link.
  let ssl ← pkgLinkFlags "openssl"
  mkDef `nativeLinkArgs (keychain ++ ssl)

package infra where
  version := v!"0.1.0"
  moreLinkArgs := nativeLinkArgs

require linen from git "https://github.com/typednotes/linen" @ "main"

@[default_target]
lean_lib Infra

@[default_target]
lean_exe infra where
  root := `Main
