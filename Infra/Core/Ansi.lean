import Infra.Core.Finite

/-
  Colour for the terminal, and — more importantly — the rule for when not to
  use it.

  A plan is read far more often than it is applied, and the interesting part of
  it is the verb: `CREATE` and `DELETE` deserve to be distinguishable at a
  glance rather than by reading. But escape codes are corrupting noise
  everywhere except an actual terminal, and two places in this project pipe
  plan output somewhere else:

    * CI writes it into `$GITHUB_STEP_SUMMARY` through `tee`, where escape
      codes would appear literally in the rendered markdown.
    * `infra check` matches rendered lines as plain text
      (`startsWith "would CREATE"`), so a coloured string would fail a check
      about ordering for reasons having nothing to do with ordering.

  Hence: **off unless something says otherwise.** `PushOptions.colour`
  defaults to `false`, so every existing caller keeps getting plain strings and
  only the CLI, which knows whether it is talking to a terminal, turns it on.
-/

namespace Infra.Core.Ansi

/-- End all attributes. -/
def reset : String := "\x1b[0m"

def red     : String := "31"
def green   : String := "32"
def yellow  : String := "33"
def magenta : String := "35"
def dim     : String := "2"
def bold    : String := "1"

/-- Wrap `s` in an SGR code, or return it untouched when styling is off.

    Taking the flag as a parameter rather than reading the environment means
    this is pure, so a rendered plan is still a value and still testable. -/
def style (on : Bool) (code : String) (s : String) : String :=
  if on then s!"\x1b[{code}m{s}{reset}" else s

/-- Whether output should be coloured, by the conventions people expect.

    In order: `NO_COLOR` set to anything non-empty wins outright (the
    `no-color.org` convention); then `FORCE_COLOR`, for a terminal-emulating
    CI that renders escape codes; then whether stdout is actually a terminal.
    A pipe or a redirect therefore gets none, which is what keeps CI's
    `plan | tee "$GITHUB_STEP_SUMMARY"` free of them without CI having to
    know that colour exists. -/
def wanted : IO Bool := do
  let nonEmpty (v : Option String) := (v.getD "").trimAscii.isEmpty == false
  if nonEmpty (← IO.getEnv "NO_COLOR") then return false
  if nonEmpty (← IO.getEnv "FORCE_COLOR") then return true
  (← IO.getStdout).isTty

end Infra.Core.Ansi
