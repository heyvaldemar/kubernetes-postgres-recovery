#!/usr/bin/env bash
# scripts/validate.sh [check ...] - the static checks, on what gets applied.
#
#   kubeconform  every manifest valid for Kubernetes 1.37, strictly; custom
#                resources against the CRDs the pinned charts install, so a
#                misspelled field fails instead of being ignored
#   images       every image by digest: in the manifests, and in what the
#                three charts render with values/*.yaml
#   database     what recovery depends on: three instances, a synchronous
#                standby that holds writes rather than lose them, WAL
#                archiving with a bound on its delay, a retention window, a
#                daily backup, restores that cannot write into the source's
#                backups, and Pod Security restricted where the data lives
#
# With no arguments every check runs. Exit status is the number that failed.
# Tools: helm, kubeconform, python3 with PyYAML (scripts/install-tools.sh).
# The check_* functions are called by name from the loop at the bottom.
# shellcheck disable=SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

KUBE_VERSION=1.37.0
CERT_MANAGER_CHART="$(sed -n 's/^CERT_MANAGER_CHART=//p' scripts/install.sh)"
CNPG_CHART="$(sed -n 's/^CNPG_CHART=//p' scripts/install.sh)"
BARMAN_PLUGIN_CHART="$(sed -n 's/^BARMAN_PLUGIN_CHART=//p' scripts/install.sh)"
# yannh/kubernetes-json-schema at a fixed commit: the built-in schemas cannot
# change under a green build.
default_schemas='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/817113f21a2643311cbc3e992bb44ffe1c416c54/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json'
K8S_SCHEMAS="${K8S_SCHEMAS:-$default_schemas}"

# The three charts, rendered with values/*.yaml into .cache/charts. Prints
# the directory.
render() {
  local out=.cache/charts
  mkdir -p "$out"
  if ! { helm template cert-manager cert-manager --repo https://charts.jetstack.io --version "$CERT_MANAGER_CHART" \
           -n cert-manager -f values/cert-manager.yaml >"$out/cert-manager.yaml" &&
         helm template cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version "$CNPG_CHART" \
           -n cnpg-system -f values/cloudnative-pg.yaml >"$out/cnpg.yaml" &&
         helm template plugin-barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts \
           --version "$BARMAN_PLUGIN_CHART" -n cnpg-system -f values/plugin-barman-cloud.yaml >"$out/plugin.yaml"; }; then
    echo "could not render the charts" >&2
    return 1
  fi
  echo "$out"
}

# The restore templates with their placeholders filled, as tests/e2e/run.sh does.
recovery_rendered() {
  mkdir -p .cache/recovery
  for f in manifests/recovery/*.yaml; do
    sed -e 's#NAME#pg-check#' -e 's#TARGET_TIME#2026-10-14 16:50:01.123456+00#' "$f" >".cache/recovery/$(basename "$f")"
  done
}

check_kubeconform() {
  local charts
  charts="$(render)" || return 1
  rm -rf .cache/schemas
  python3 scripts/crd-schemas.py "$charts" .cache/schemas || return 1
  recovery_rendered
  mkdir -p .cache/kubeconform
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" \
    -schema-location '.cache/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    manifests/namespaces.yaml manifests/object-store manifests/database .cache/recovery tests/e2e/plants
}

check_images() {
  local charts bad
  charts="$(render)" || return 1
  bad="$( { grep -rnE '^\s*(image|imageName):' manifests tests/e2e/plants | grep -v '@sha256:';
            grep -hoE '(image|value|SIDECAR_IMAGE): "?[a-z0-9.-]+\.(io|com)/[^" ]+' "$charts"/*.yaml \
              | sed -E 's/^[A-Z_a-z]+: "?//' | sort -u | grep -v '@sha256:'; } || true)"
  if [ -n "$bad" ]; then echo "images without a digest:"; echo "$bad"; return 1; fi
  echo "every image is referenced by digest, in the manifests and in the rendered charts"
}

check_database() {
  python3 - <<'PY'
import glob, re, sys, yaml

def load(path):
    return [d for d in yaml.safe_load_all(open(path)) if d]

bad = []
cluster = load("manifests/database/cluster.yaml")[0]["spec"]
store = load("manifests/database/objectstore.yaml")[0]
sched = load("manifests/database/scheduled-backup.yaml")[0]["spec"]

if cluster.get("instances", 1) < 3:
    bad.append("fewer than three instances: losing one leaves no standby to fail over to")
sync = cluster.get("postgresql", {}).get("synchronous", {})
if sync.get("number", 0) < 1:
    bad.append("no synchronous standby: the primary's loss can take acknowledged commits with it")
if sync.get("dataDurability", "required") != "required":
    bad.append("dataDurability is not required: with no standby to confirm, commits would be acknowledged anyway")
timeout = cluster.get("postgresql", {}).get("parameters", {}).get("archive_timeout", "")
m = re.fullmatch(r"(\d+)(s|min)?", str(timeout))
seconds = int(m.group(1)) * (60 if m and m.group(2) == "min" else 1) if m else 0
if not 0 < seconds <= 300:
    bad.append(f"archive_timeout is '{timeout}': a quiet database would leave its last writes out of the bucket for an unbounded time")
if cluster.get("enablePDB") is False:
    bad.append("enablePDB is false: a node drain could take the primary and a standby at once")
archivers = [p for p in cluster.get("plugins", []) if p.get("name") == "barman-cloud.cloudnative-pg.io" and p.get("isWALArchiver")]
if not archivers:
    bad.append("no WAL archiver: base backups alone cannot restore to a point in time")
elif archivers[0].get("parameters", {}).get("barmanObjectName") != store["metadata"]["name"]:
    bad.append("the WAL archiver names an ObjectStore that is not manifests/database/objectstore.yaml")

if not store["spec"].get("retentionPolicy"):
    bad.append("the ObjectStore has no retentionPolicy: backups are never pruned, and nothing states the recovery window")
creds = store["spec"]["configuration"].get("s3Credentials", {})
for key in ("accessKeyId", "secretAccessKey"):
    if not isinstance(creds.get(key), dict) or "name" not in creds[key]:
        bad.append(f"s3Credentials.{key} is not a Secret reference")

if sched.get("method") != "plugin" or sched.get("pluginConfiguration", {}).get("name") != "barman-cloud.cloudnative-pg.io":
    bad.append("the scheduled backup does not go through the Barman Cloud plugin")
if sched.get("cluster", {}).get("name") != "pg":
    bad.append("the scheduled backup is not for the cluster pg")
if not sched.get("schedule"):
    bad.append("the scheduled backup has no schedule")

for path in sorted(glob.glob("manifests/recovery/*.yaml")):
    spec = load(path)[0]["spec"]
    if spec.get("plugins"):
        bad.append(f"{path} archives: a restore must not write into the backups it reads")
    sources = [c for c in spec.get("externalClusters", []) if c.get("name") == spec.get("bootstrap", {}).get("recovery", {}).get("source")]
    if not sources or sources[0].get("plugin", {}).get("parameters", {}).get("serverName") != "pg":
        bad.append(f"{path} does not restore from pg's backups")

for ns in load("manifests/namespaces.yaml"):
    labels = ns["metadata"].get("labels", {})
    if labels.get("pod-security.kubernetes.io/enforce") != "restricted":
        bad.append(f"namespace {ns['metadata']['name']} does not enforce Pod Security restricted")

for b in bad:
    print("database: " + b)
print("three instances, a synchronous standby, bounded archiving, restores that cannot write back" if not bad else f"{len(bad)} problem(s)")
sys.exit(1 if bad else 0)
PY
}

checks=("$@")
[ ${#checks[@]} -gt 0 ] || checks=(kubeconform images database)
failed=0
for c in "${checks[@]}"; do
  printf '\n== %s\n' "$c"
  if "check_$c"; then echo "-- $c: ok"; else echo "-- $c: FAILED"; failed=$((failed + 1)); fi
done
printf '\n%d of %d checks failed\n' "$failed" "${#checks[@]}"
exit "$failed"
