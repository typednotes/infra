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
"""
import glob
import re
import sys

EXEMPT = {"/runtimes", "/applications"}
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
            if "project_id" not in following and "organization_id" not in following:
                bad.append(f"{path}:{i + 1}: GET {collection} is not scoped to a project")

    if bad:
        print("error: unscoped Scaleway collection listing(s):", file=sys.stderr)
        for b in bad:
            print(f"  - {b}", file=sys.stderr)
        print("\n  Add: (query := [(\"project_id\", ← creds.requireProject)])", file=sys.stderr)
        print("  An unscoped listing sees every project in the organization, and", file=sys.stderr)
        print("  pullEntries matches by name — so a fleet can adopt, and destroy,", file=sys.stderr)
        print("  another project's resource.", file=sys.stderr)
        return 1

    print("scaleway listings: all project-scoped")
    return 0

if __name__ == "__main__":
    sys.exit(main())
