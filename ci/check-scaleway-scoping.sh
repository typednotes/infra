#!/usr/bin/env bash
# Every Scaleway collection listing must be scoped to a project.
#
# An unscoped `GET .../secrets` (and the same for namespaces, containers,
# functions, instances) is evaluated against the whole **organization**, not
# the credential's project. Two consequences, and the second is the dangerous
# one:
#
#   1. A project-scoped credential is refused outright — `403
#      permissions_denied`, with no hint that the *scope* rather than the
#      permission is wrong.
#
#   2. The listing returns other projects' resources. `Infra.Core.pullEntries`
#      matches a listed resource to a fleet key **by name**, so a fleet could
#      adopt a same-named resource belonging to a different project — and then
#      diff it, and then `destroy` it.
#
# Measured, not theorised: at the time this was written, the organization had
# two container-registry namespaces, both in the `Typednotes` project. A fleet
# in the `default` project listing unscoped saw both.
#
# Deliberate exceptions:
#   - `/runtimes` is a catalogue of available runtimes, not a resource
#     collection.
#   - IAM `/applications` is organization-scoped by nature; there is no
#     project.
#
# And one conditional exception, which is a different shape and is why it is
# not simply added to the list above. IAM `/rules` is the sub-collection of a
# *single policy*: `policy_id` is required by the API (it is a non-pointer
# field in Scaleway's generated SDK, where optional ones are pointers), so the
# listing is bounded by a parent rather than by an account. Neither consequence
# above applies — the parent id is a UUID this code only ever obtains from an
# already-scoped `/policies` listing, and rules are not a fleet kind, so
# `pullEntries` never name-matches one.
#
# It is exempted only *when that parent scope is actually present*, rather than
# by name. A bare `GET /rules` is still an error here, which is the point: an
# exemption that stopped checking anything would be indistinguishable from
# deleting the rule for that collection.
#
# Bash rather than Python: `ci/` is one language, so that reading a check does
# not mean switching dialects. This one needs no JSON, so it needs no jq
# either — `grep -n` finds the call sites and `sed -n` reads the line after
# each, which is the whole algorithm.
set -euo pipefail
cd "$(dirname "$0")/.."

# Collections that are not project-scoped by nature.
exempt() {
  case "$1" in
    /runtimes|/applications) return 0 ;;
    *) return 1 ;;
  esac
}

# Collections scoped by a parent resource rather than by a project: echoes the
# query parameter that must bound the listing, or nothing.
parent_of() {
  case "$1" in
    /rules) echo "policy_id" ;;
    *) echo "" ;;
  esac
}

# The call shape, anchored to end-of-line so that a listing whose query is on
# the same line is not a candidate in the first place. `prefix'` takes
# arguments and `pfx` does not, hence the alternation.
call_re='Scaleway\.call creds "GET" \((pfx|prefix'"'"'[^)]*) \+\+ "(/[a-z-]+)"\)[[:space:]]*$'

bad=()
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"

  # The collection is the quoted path on the matched line.
  collection=$(sed -n "${line}p" "$file" \
    | sed -E 's|.*\+\+ "(/[a-z-]+)"\).*|\1|')
  exempt "$collection" && continue

  following=$(sed -n "$((line + 1))p" "$file")
  parent=$(parent_of "$collection")
  if [ -n "$parent" ]; then
    case "$following" in
      *"$parent"*) ;;
      *) bad+=("$file:$line: GET $collection is not scoped by its parent '$parent'") ;;
    esac
    continue
  fi
  case "$following" in
    *project_id*|*organization_id*) ;;
    *) bad+=("$file:$line: GET $collection is not scoped to a project") ;;
  esac
# Sorted by path, then by line *numerically*: a plain `sort` puts line 196
# before line 67, which makes a multi-finding report read as though the file
# were being walked at random.
done < <(grep -rnE "$call_re" Infra/Providers --include='*.lean' \
         | sort -t: -k1,1 -k2,2n || true)

if [ ${#bad[@]} -ne 0 ]; then
  echo "error: unscoped Scaleway collection listing(s):" >&2
  printf '  - %s\n' "${bad[@]}" >&2
  # Two failures, two remedies. Telling someone to add `project_id` to a
  # collection that has no project — `/rules` belongs to a policy — sends them
  # to try something the API will reject, which is worse than saying nothing.
  if printf '%s\n' "${bad[@]}" | grep -q "parent"; then
    {
      echo ""
      echo "  For a collection that belongs to a parent resource, pass the"
      echo "  parent's id: (query := [(\"policy_id\", some id)]). The id must"
      echo "  itself come from a listing that is scoped."
    } >&2
  fi
  if printf '%s\n' "${bad[@]}" | grep -q "scoped to a project"; then
    {
      echo ""
      echo "  Add: (query := [(\"project_id\", ← creds.requireProject)])"
      echo "  An unscoped listing sees every project in the organization, and"
      echo "  pullEntries matches by name — so a fleet can adopt, and destroy,"
      echo "  another project's resource."
    } >&2
  fi
  exit 1
fi

echo "scaleway listings: all project-scoped"
