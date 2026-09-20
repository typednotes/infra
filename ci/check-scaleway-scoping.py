#!/usr/bin/env python3
"""Every Scaleway collection listing must be scoped to a project.

An unscoped `GET .../secrets` (and the same for namespaces, containers,
functions, instances) is evaluated against the whole **organization**, not the
credential's project. Two consequences, and the second is the dangerous one:

1. A project-scoped credential is refused outright — `403 permissions_denied`,
   with no hint that the *scope* rather than the permission is wrong.

2. The listing returns other projects' resources. `Infra.Core.pullEntries`
   matches a listed resource to a fleet key **by name**, so a fleet could adopt
   a same-named resource belonging to a different project — and then diff it,
   and then `destroy` it.

Measured, not theorised: at the time this was written, the organization had two
container-registry namespaces, both in the `Typednotes` project. A fleet in the
`default` project listing unscoped saw both.

Deliberate exceptions:
  - `/runtimes` is a catalogue of available runtimes, not a resource collection.
  - IAM `/applications` is organization-scoped by nature; there is no project.

And one conditional exception, which is a different shape and is why it is not
simply added to the list above. IAM `/rules` is the sub-collection of a *single
policy*: `policy_id` is required by the API (it is a non-pointer field in
Scaleway's generated SDK, where optional ones are pointers), so the listing is
bounded by a parent rather than by an account. Neither consequence at the top
of this file applies — the parent id is a UUID this code only ever obtains from
an already-scoped `/policies` listing, and rules are not a fleet kind, so
`pullEntries` never name-matches one.

It is exempted only *when that parent scope is actually present*, rather than
by name. A bare `GET /rules` is still an error here, which is the point: an
exemption that stopped checking anything would be indistinguishable from
deleting the rule for that collection.
"""
import glob
import re
import sys

EXEMPT = {"/runtimes", "/applications"}

# Collections scoped by a parent resource rather than by a project: the
# collection path, and the query parameter that must bound it. See the module
# docstring for why this is conditional rather than a second EXEMPT set.
PARENT_SCOPED = {"/rules": "policy_id"}
CALL = re.compile(r'Scaleway\.call creds "GET" \((?:pfx|prefix\'[^)]*)\s*\+\+ "(/[a-z-]+)"\)\s*$')

def main() -> int:
    bad = []
    for path in sorted(glob.glob("Infra/Providers/**/*.lean", recursive=True)):
        lines = open(path).read().split("\n")
        for i, line in enumerate(lines):
            m = CALL.search(line)
            if not m:
                continue
            collection = m.group(1)
            if collection in EXEMPT:
                continue
            following = lines[i + 1] if i + 1 < len(lines) else ""
            parent = PARENT_SCOPED.get(collection)
            if parent is not None:
                if parent not in following:
                    bad.append(f"{path}:{i + 1}: GET {collection} is not scoped "
                               f"by its parent '{parent}'")
                continue
            if "project_id" not in following and "organization_id" not in following:
                bad.append(f"{path}:{i + 1}: GET {collection} is not scoped to a project")

    if bad:
        print("error: unscoped Scaleway collection listing(s):", file=sys.stderr)
        for b in bad:
            print(f"  - {b}", file=sys.stderr)
        # Two failures, two remedies. Telling someone to add `project_id` to a
        # collection that has no project — `/rules` belongs to a policy — sends
        # them to try something the API will reject, which is worse than saying
        # nothing.
        if any("parent" in b for b in bad):
            print("\n  For a collection that belongs to a parent resource, pass the", file=sys.stderr)
            print("  parent's id: (query := [(\"policy_id\", some id)]). The id must", file=sys.stderr)
            print("  itself come from a listing that is scoped.", file=sys.stderr)
        if any("project" in b for b in bad):
            print("\n  Add: (query := [(\"project_id\", ← creds.requireProject)])", file=sys.stderr)
            print("  An unscoped listing sees every project in the organization, and", file=sys.stderr)
            print("  pullEntries matches by name — so a fleet can adopt, and destroy,", file=sys.stderr)
            print("  another project's resource.", file=sys.stderr)
        return 1

    print("scaleway listings: all project-scoped")
    return 0

if __name__ == "__main__":
    sys.exit(main())
