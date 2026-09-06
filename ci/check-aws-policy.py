#!/usr/bin/env python3
"""Validate `ci/aws-permissions-policy.json` against IAM's policy grammar.

This exists because the file shipped with a top-level `"Comment"` key. IAM's
grammar allows only `Version`, `Id` and `Statement`, so `aws iam create-policy`
rejected it — and the failure surfaced one command later, as

    NoSuchEntity: Policy arn:aws:iam::…:policy/infra-ci-live-tests
    does not exist or is not attachable

from the *attach* step, which names neither the real problem nor the file. JSON
has no comments and IAM has no comment field, so prose about the policy belongs
in `ci/README.md`; this check is what stops it drifting back into the document.

It is a grammar check, not an authorisation review. For the latter:

    aws accessanalyzer validate-policy \\
      --policy-document file://ci/aws-permissions-policy.json \\
      --policy-type IDENTITY_POLICY
"""
import json
import re
import sys

PATH = "ci/aws-permissions-policy.json"
TOP = {"Version", "Id", "Statement"}
STMT = {"Sid", "Effect", "Action", "NotAction", "Resource", "NotResource",
        "Condition", "Principal", "NotPrincipal"}

def main() -> int:
    try:
        doc = json.load(open(PATH))
    except json.JSONDecodeError as e:
        print(f"error: {PATH} is not valid JSON: {e}", file=sys.stderr)
        return 1

    bad = []
    extra = set(doc) - TOP
    if extra:
        bad.append(f"top-level key(s) IAM does not accept: {sorted(extra)} "
                   f"(only {sorted(TOP)} are allowed — a comment cannot go here)")

    if doc.get("Version") != "2012-10-17":
        bad.append(f"Version should be \"2012-10-17\", found {doc.get('Version')!r}")

    statements = doc.get("Statement")
    if not isinstance(statements, list) or not statements:
        bad.append("Statement must be a non-empty list")
        statements = []

    seen = set()
    for i, st in enumerate(statements):
        where = st.get("Sid") or f"statement {i}"
        unknown = set(st) - STMT
        if unknown:
            bad.append(f"{where}: key(s) IAM does not accept: {sorted(unknown)}")
        if st.get("Effect") not in ("Allow", "Deny"):
            bad.append(f"{where}: Effect must be Allow or Deny")
        if "Action" not in st and "NotAction" not in st:
            bad.append(f"{where}: needs Action or NotAction")
        if "Resource" not in st and "NotResource" not in st:
            bad.append(f"{where}: needs Resource or NotResource")
        sid = st.get("Sid")
        if sid is not None:
            if not re.fullmatch(r"[A-Za-z0-9]+", sid):
                bad.append(f"{where}: Sid must be alphanumeric, found {sid!r}")
            if sid in seen:
                bad.append(f"{where}: duplicate Sid")
            seen.add(sid)
        for action in ([st["Action"]] if isinstance(st.get("Action"), str)
                       else st.get("Action", [])):
            if not re.fullmatch(r"[a-z0-9-]+:[A-Za-z0-9*]+", action):
                bad.append(f"{where}: {action!r} is not a service:Action pair")

    if bad:
        print(f"error: {PATH} would be rejected by IAM:", file=sys.stderr)
        for b in bad:
            print(f"  - {b}", file=sys.stderr)
        return 1

    print(f"{PATH}: conforms to IAM's policy grammar "
          f"({len(statements)} statements)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
