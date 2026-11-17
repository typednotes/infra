#!/usr/bin/env bash
# The Helm interop, checked through the real `helm` (offline: no cluster).
#
# `Infra.Interop.HelmChart` writes Go templates, and Go's template engine is
# Helm's, not infra's — so the claim "the chart installs what
# `render --chart-defaults` prints" can only be checked by running Helm. This
# is that check, on `example/KubernetesPostgres.lean`:
#
#   1. `render --chart` writes a chart, and `helm lint --strict` accepts it;
#   2. `helm template` with the default values renders the same objects as
#      `render --chart-defaults` (compared as YAML, in any order — Helm sorts
#      objects by kind);
#   3. values.schema.json refuses a negative replica count, and a Secret
#      override reaches the `secretKeyRef`;
#   4. `infra import kubernetes` reads `render` output back as the typed
#      declarations, and `infra import helm` reads the chart back.
#
# Needs `helm` and Python 3 with PyYAML, and the `infra` and
# `kubernetes-postgres` executables built (`lake build`).
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

example=./.lake/build/bin/kubernetes-postgres
infra=./.lake/build/bin/infra

"$example" render --chart "$tmp/chart" --version 0.1.0
helm lint --strict "$tmp/chart"

# 2. helm template ≡ render --chart-defaults.
helm template rel "$tmp/chart" > "$tmp/helm.yaml"
"$example" render --chart-defaults > "$tmp/defaults.yaml"
python3 - "$tmp/helm.yaml" "$tmp/defaults.yaml" <<'EOF'
import sys, yaml

def objects(path):
    with open(path) as f:
        docs = [d for d in yaml.safe_load_all(f) if d is not None]
    key = lambda d: (d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"])
    return {key(d): d for d in docs}, len(docs)

helm, n_helm = objects(sys.argv[1])
ours, n_ours = objects(sys.argv[2])
if n_helm != n_ours or helm != ours:
    print("helm template and render --chart-defaults disagree", file=sys.stderr)
    for k in sorted(set(helm) | set(ours)):
        if helm.get(k) != ours.get(k):
            print(f"  {k}:\n    helm: {helm.get(k)}\n    ours: {ours.get(k)}", file=sys.stderr)
    sys.exit(1)
print(f"helm template and render --chart-defaults agree on {n_ours} objects")
EOF

# 3. The schema refuses a value of the wrong shape; an override reaches its field.
if helm template rel "$tmp/chart" \
    --set-json 'objects={"default/statefulset.apps/postgres":{"image":"postgres:17","replicas":-1}}' \
    > /dev/null 2>&1; then
  echo "values.schema.json accepted replicas = -1" >&2
  exit 1
fi
helm template rel "$tmp/chart" \
  --set-json 'secrets={"db-password":{"name":"pg-credentials","key":"password"}}' \
  | grep -q 'name: "pg-credentials"' \
  || { echo "a secrets override did not reach the secretKeyRef" >&2; exit 1; }

# 4. Imports: render output reads back typed; the chart reads back.
"$example" render > "$tmp/render.yaml"
"$infra" import kubernetes "$tmp/render.yaml" > "$tmp/imported.lean"
grep -q 'shape := statefulSet (image := "postgres:17") (ports := \[5432\]) (env := \[.lit "POSTGRES_USER" "dbadmin", .lit "PGDATA" "/var/lib/postgresql/data/pg", .secret "POSTGRES_PASSWORD" "db-password"\]) (storage := some { sizeGb := 20, storageClass := "scw-bssd", mountPath := "/var/lib/postgresql/data" })' "$tmp/imported.lean" \
  || { echo "render → import did not give back the typed StatefulSet:" >&2; cat "$tmp/imported.lean" >&2; exit 1; }
grep -q 'shape := service 5432 }' "$tmp/imported.lean" \
  || { echo "render → import did not give back the typed Service" >&2; exit 1; }
"$infra" import helm "$tmp/chart" --objects-only > "$tmp/from-helm.lean"
grep -q 'resource kubernetesObject "main/default/statefulset.apps/postgres"' "$tmp/from-helm.lean" \
  || { echo "import helm did not declare the StatefulSet:" >&2; cat "$tmp/from-helm.lean" >&2; exit 1; }
echo "imports read render output and the chart back"
