import Infra.Core.Region

/-
  The four values a declaration produces, as one value.

  `Infra.Core.Fleet` (the structure below) is what `fleet myFleet where …`
  hands to `Infra.Cli.run`. It lives here rather than in `Infra/Core/Fleet.lean`
  with `Keys`, `Plan` and `Released` for one reason: it also carries `Regions`,
  and placement is defined downstream of all three.
-/

namespace Infra.Core

/-- The name a `fleet` declaration gets from its identifier: kebab-case, so
    that the Lean convention (`crossCloud`) becomes a valid marker value on
    every cloud (`cross-cloud`) — a GCP label value takes no capitals. A hump
    becomes a hyphen (`webTier` → `web-tier`, `myHTTPFleet` →
    `my-http-fleet`), a namespace dot becomes a hyphen, and everything is
    lowercased. `Boundary.fleetName` overrides the result. -/
def fleetNameOfIdent (ident : String) : String := Id.run do
  let cs := ident.toList.toArray
  let mut out : String := ""
  for i in [0:cs.size] do
    let c := cs[i]!
    if c == '.' then
      out := out.push '-'
    else if c.isUpper then
      let prev := if i == 0 then none else some cs[i-1]!
      let next := cs[i+1]?
      let hump := match prev with
        | some p => p.isLower || p.isDigit || (p.isUpper && (next.map Char.isLower).getD false)
        | none   => false
      if hump then out := out.push '-'
      out := out.push c.toLower
    else
      out := out.push c
  return out

#guard fleetNameOfIdent "typednotes" = "typednotes"
#guard fleetNameOfIdent "crossCloud" = "cross-cloud"
#guard fleetNameOfIdent "webTier" = "web-tier"
#guard fleetNameOfIdent "myHTTPFleet" = "my-http-fleet"
#guard fleetNameOfIdent "Prod.api" = "prod-api"
#guard fleetNameOfIdent "fleet2Eu" = "fleet2-eu"

/-- Everything a declaration says, in one value: what it manages, what it wants
    there, where that is, and what it has released.

    These four travelled separately, and every front end put them back together
    by hand — `Infra.Cli.run "x" x.plan (regions := x.regions) (forgets :=
    x.forgets)`. Three arguments naming the same declaration three times, which
    is noise; but also a hole, because only two of them are indexed by the key
    family. `Plan κ` and `Released κ` cannot be crossed between fleets;
    `Regions` deliberately is not indexed by anything (see `Regions.slot`), so
    a call that took fleet `a`'s plan and fleet `b`'s regions compiled, and
    built `a` wherever `b` said it lived. Passing one value is what closes
    that: there is no longer a second place to take the other half from.

    `forgets` has **no default**, and that is deliberate — the same reasoning
    that kept it non-defaulted on `Infra.Cli.run`. A fleet that declares
    `forget` and then does not hand the releases over destroys the very
    resource `forget` exists to protect. For a declared fleet the question is
    now settled at elaboration, because the `fleet` command fills the field;
    for a hand-written one the compiler still asks, and `Released κ`'s index
    means it cannot be answered with another fleet's list.

    `regions` does default: a fleet with no `in` clause takes each cloud's
    region from its credentials, which is what every fleet did before placement
    was expressible. -/
structure Fleet where
  /-- The fleet's name: the value of the ownership marker (`managed-by-infra`)
      on everything it creates, and the value it requires back before it
      changes or destroys anything. The `fleet` command sets it from the
      declaration's identifier, in kebab-case (`fleetNameOfIdent`:
      `fleet typednotes` is `"typednotes"`, `fleet crossCloud` is
      `"cross-cloud"`); `Boundary.fleetName` overrides it.

      **No default**, for `forgets`' reason below: every fleet has a name,
      because a fleet without one cannot tell its resources from another
      fleet's in the same account. Before 0.17.0 an unnamed fleet wrote the
      value `true`, which matched every fleet; that value is retired. -/
  name    : String
  /-- The key family: one finite key type per `(provider, kind)` pair. -/
  keys    : Keys
  /-- What this declaration wants to exist, at every key. -/
  plan    : Plan keys
  /-- Where it lives. Empty means "wherever the credentials say". -/
  regions : Regions := {}
  /-- The `forget` declarations: resources released from management without
      being destroyed. -/
  forgets : List (Released keys)

end Infra.Core
