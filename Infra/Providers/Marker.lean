import Infra.Core.Ownership

/-
  Taking the ownership marker back off — the pure half of `Backend.release`.

  Two shapes, matching the two rungs of `Ownership`'s ladder that can be
  rewritten:

    * a key/value tag set (AWS tags, GCP labels): drop the one pair
      `(markerKey, fleet)` and keep every other pair in its place;
    * a free-text field (the description rung): the exact inverse of what
      `create` wrote there, which is `encodeMarkerText fleet` and nothing else.

  Scaleway's flat `[]string` tags are the third shape and live beside their
  encoding, as `Scaleway.dropTag`.

  Both functions answer "nothing of ours" rather than a rewritten value when
  the marker is absent **or carries another fleet's name**, so a caller can
  skip the write entirely. That is the defence in depth `release` asks for:
  the engine only asks for a release of a resource it has just seen carrying
  this fleet's marker, but the check is repeated at the moment of the write,
  against a fresh read, so another fleet's marker is never stripped.

  Only this module's imports are `Infra.Core`: both GCP and Scaleway use the
  description helper, and neither client may depend on the other.
-/

namespace Infra.Providers.Marker

open Infra.Core

/-- The tag set with this fleet's marker removed, or `none` when it does not
    carry this fleet's marker (absent, or somebody else's value). Order and
    every other pair are preserved. -/
def releaseTags (fleet : String) (tags : List (String × String)) :
    Option (List (String × String)) :=
  if tags.contains (markerKey, fleet) then some (tags.filter (· != (markerKey, fleet)))
  else none

#guard releaseTags "me" [(markerKey, "me"), ("team", "infra")] = some [("team", "infra")]
#guard releaseTags "me" [(markerKey, "me")] = some []
-- Another fleet's marker is left alone — the whole point of checking the value.
#guard releaseTags "me" [(markerKey, "other"), ("team", "infra")] = none
#guard releaseTags "me" [("team", "infra")] = none
#guard releaseTags "me" [] = none

/-- A description with this fleet's marker taken back out.

    The exact inverse of the description rung's write: every `create`/
    `putMarker` on that rung (`ImageRegistry.Scw`, `Gcp.Iam`) sets the whole
    field to `encodeMarkerText fleet`, since no spec field competes for it —
    so what was there before the marker is the empty description, and that is
    what comes back. Anything else is returned unchanged: a human's own text,
    another fleet's marker, or a marker with words added after it, all of
    which `decodeMarkerText` also reads as *not this fleet's*. -/
def stripMarkerText (fleet : String) (description : String) : String :=
  if description == encodeMarkerText fleet then "" else description

/- Round trip: what create wrote, stripped, is the description as it was
   before the marker went in — empty. -/
#guard stripMarkerText "my-fleet" (encodeMarkerText "my-fleet") = ""
/- A description without this fleet's marker is unchanged. -/
#guard stripMarkerText "my-fleet" "the CI deploy identity" = "the CI deploy identity"
#guard stripMarkerText "my-fleet" "" = ""
#guard stripMarkerText "my-fleet" (encodeMarkerText "other-fleet") = encodeMarkerText "other-fleet"
#guard stripMarkerText "my-fleet" (encodeMarkerText "my-fleet" ++ " and notes")
     = encodeMarkerText "my-fleet" ++ " and notes"
/- And it agrees with the read side: it strips exactly when the decoded
   description carries this fleet's marker, so a release acts on precisely the
   resources `ownershipInfo` reported as ours. -/
#guard [encodeMarkerText "my-fleet", encodeMarkerText "other", "notes", "", "a=b"].all fun d =>
  (stripMarkerText "my-fleet" d != d) == (decodeMarkerText d).contains (markerKey, "my-fleet")

end Infra.Providers.Marker
