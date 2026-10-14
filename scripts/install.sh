#!/usr/bin/env bash
# install.sh - what the database needs, into the current cluster: cert-manager,
# the CloudNativePG operator and its Barman Cloud plugin, and SeaweedFS as the
# S3 store backups go to. Chart versions are pinned below, every image by
# digest in platform/*.yaml. Safe to run again.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_MANAGER_CHART=v1.21.2
CNPG_CHART=0.29.1
BARMAN_PLUGIN_CHART=0.8.1
say() { printf '\n== %s\n' "$*"; }

say "cert-manager $CERT_MANAGER_CHART"
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io --version "$CERT_MANAGER_CHART" \
  --namespace cert-manager --create-namespace --wait --timeout 10m -f "$ROOT/platform/cert-manager.yaml"

say "CloudNativePG, chart $CNPG_CHART"
helm upgrade --install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version "$CNPG_CHART" \
  --namespace cnpg-system --create-namespace --wait --timeout 10m -f "$ROOT/platform/cloudnative-pg.yaml"

# The plugin goes in the operator's namespace; the operator finds it there.
say "Barman Cloud plugin, chart $BARMAN_PLUGIN_CHART"
helm upgrade --install plugin-barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts \
  --version "$BARMAN_PLUGIN_CHART" --namespace cnpg-system --wait --timeout 10m -f "$ROOT/platform/plugin-barman-cloud.yaml"
kubectl -n cnpg-system rollout status deployment/plugin-barman-cloud --timeout=300s

kubectl apply -f "$ROOT/manifests/namespaces.yaml" >/dev/null

say "S3 keys for SeaweedFS and the database (generated here, kept only in the cluster)"
if ! kubectl -n object-store get secret object-store-s3 >/dev/null 2>&1; then
  # A finite read: `tr </dev/urandom | head` dies of SIGPIPE under pipefail.
  access="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Z0-9' | cut -c1-20)"
  secret="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40)"
  [ "${#access}" -eq 20 ] && [ "${#secret}" -eq 40 ] || { echo "could not generate S3 keys" >&2; exit 1; }
  printf '{"identities":[{"name":"database","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$access" "$secret" |
    kubectl -n object-store create secret generic object-store-s3 --from-file=s3.json=/dev/stdin >/dev/null
  # The keys reach kubectl on stdin: no file, no argv, and printf rather than a
  # here-string, which would append a newline to the value.
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: backup-s3\n  namespace: database\ntype: Opaque\ndata:\n  ACCESS_KEY_ID: %s\n  ACCESS_SECRET_KEY: %s\n' \
    "$(printf '%s' "$access" | base64)" "$(printf '%s' "$secret" | base64)" | kubectl apply -f - >/dev/null
  unset access secret
  echo "created"
else
  echo "already present"
fi

say "SeaweedFS and the backups bucket"
kubectl apply -f "$ROOT/manifests/object-store/" >/dev/null
kubectl -n object-store rollout status deployment/seaweedfs --timeout=300s
kubectl -n object-store wait --for=condition=complete job/create-backups-bucket --timeout=300s
