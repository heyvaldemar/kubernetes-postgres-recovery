#!/usr/bin/env bash
# run.sh - the recovery drill, against the cluster `make up` builds.
#
#   1. the cluster: three instances, and a standby confirming every commit
#   2. backups: WAL archiving works, and a base backup is in the bucket
#   3. point in time: rows, a target time, a row after it, then DROP TABLE.
#      A cluster restored from the bucket to the target has every row before
#      it, none after, and the table
#   4. failover: the primary is killed under a steady stream of writes. A
#      standby takes over, and every write the client was told committed is
#      on it
#   5. disaster: the cluster and its volumes are deleted. A cluster restored
#      from the bucket alone has what archive_timeout guarantees
#   6. Ready is not backed up: a cluster created again under the old name
#      reports Ready, and refuses to archive over the old backups
#
# Destructive: step 5 deletes the cluster. `make up` builds it again.
# Prints what it measured: the time each restore took, the write gap of the
# failover. Needs kubectl and python3.
#
# `check && pass || fail` below is safe: pass only prints and cannot fail.
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
NS=database
failed=0
results=()
measured=()
pass() { results+=("PASS  $1"); printf '  ok    %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }
measure() { measured+=("$1"); printf '  ..    %s\n' "$1"; }

k() { kubectl -n "$NS" "$@"; }
primary() { k get cluster "${1:-pg}" -o jsonpath='{.status.currentPrimary}'; }
# sql <pod> <statement>: run as postgres over the pod's local socket, in app.
sql() { k exec "$1" -c postgres -- psql -d app -v ON_ERROR_STOP=1 -qtAc "$2" 2>&1; }
cond() { k get cluster "$1" -o jsonpath="{.status.conditions[?(@.type==\"$2\")].status}"; }

# Waits until the WAL holding everything committed so far is in the bucket:
# switch to a new segment, then watch the archiver pass the old one.
archived_now() {
  local pod="$1" seg
  seg="$(sql "$pod" "select pg_walfile_name(pg_current_wal_lsn())")"
  sql "$pod" "select pg_switch_wal()" >/dev/null
  for _ in $(seq 1 60); do
    [ "$(sql "$pod" "select coalesce(last_archived_wal, '') >= '$seg' from pg_stat_archiver")" = t ] && return 0
    sleep 2
  done
  return 1
}

# restore <template> <name> [target]: applies a restore and waits for it.
# Prints the seconds it took to be ready, or nothing.
restore() {
  local t0=$SECONDS out i
  # The operator's admission webhook can drop a request while it is busy;
  # that is no answer about the manifest, so ask again.
  for i in 1 2 3 4 5; do
    out="$(sed -e "s#NAME#$2#" -e "s#TARGET_TIME#${3:-}#" "$ROOT/manifests/recovery/$1" | kubectl apply -f - 2>&1)" && break
    grep -q 'failed calling webhook' <<<"$out" && [ "$i" -lt 5 ] || { echo "$out" >&2; return 1; }
    sleep 5
  done
  k wait --for=condition=Ready "cluster/$2" --timeout=900s >/dev/null 2>&1 || return 1
  echo $((SECONDS - t0))
}

# --- 1 -------------------------------------------------------------------------
step "1. the cluster"
P="$(primary)"
ready="$(k get cluster pg -o jsonpath='{.status.readyInstances}')"
[ "$ready" = 3 ] && pass "three instances ready, $P the primary" || fail "ready instances: ${ready:-none}"
streaming="$(sql "$P" "select count(*) from pg_stat_replication where state = 'streaming'")"
quorum="$(sql "$P" "select count(*) from pg_stat_replication where sync_state in ('sync', 'quorum')")"
names="$(sql "$P" "show synchronous_standby_names")"
if [ "$streaming" = 2 ] && [ "$quorum" -ge 1 ] 2>/dev/null && [[ "$names" == "ANY 1 "* ]]; then
  pass "two standbys streaming; a commit waits for one of them ($names)"
else
  fail "replication: $streaming streaming, $quorum synchronous, synchronous_standby_names '$names'"
fi

# --- 2 -------------------------------------------------------------------------
step "2. backups"
[ "$(cond pg ContinuousArchiving)" = True ] && pass "continuous WAL archiving to the bucket" \
  || fail "ContinuousArchiving is '$(cond pg ContinuousArchiving)'"
done_backup=""
for _ in $(seq 1 60); do
  done_backup="$(k get backups.postgresql.cnpg.io -o jsonpath='{range .items[?(@.status.phase=="completed")]}{.metadata.name}{"\n"}{end}' | head -1)"
  [ -n "$done_backup" ] && break
  sleep 5
done
[ -n "$done_backup" ] && pass "base backup $done_backup completed" || fail "no base backup completed within five minutes"
listing="$(kubectl -n object-store exec deploy/seaweedfs -- sh -c 'echo "fs.ls /buckets/backups/pg" | weed shell -master=localhost:9333 -filer=localhost:8888' 2>/dev/null)"
if grep -qx base <<<"$listing" && grep -qx wals <<<"$listing"; then
  pass "the bucket holds base backups and WAL for pg"
else
  fail "the bucket's pg/ holds: $(tr '\n' ' ' <<<"$listing")"
fi

# --- 3 -------------------------------------------------------------------------
step "3. point in time"
P="$(primary)"
sql "$P" "create table ledger (id int primary key, note text not null, at timestamptz not null default clock_timestamp());
          insert into ledger (id, note) select g, 'before the target' from generate_series(1, 100) g" >/dev/null
sleep 1
target="$(sql "$P" "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")"
sleep 1
sql "$P" "insert into ledger (id, note) values (101, 'after the target')" >/dev/null
sleep 1
sql "$P" "drop table ledger" >/dev/null
echo "  target $target; row 101 after it; then DROP TABLE"
if archived_now "$P"; then
  pass "the WAL up to the DROP is in the bucket"
else
  fail "the WAL up to the DROP did not reach the bucket in two minutes"
fi
if secs="$(restore point-in-time.yaml pg-pitr "$target")" && [ -n "$secs" ]; then
  measure "point-in-time restore: ready in ${secs}s"
  R="$(primary pg-pitr)"
  got="$(sql "$R" "select count(*) filter (where id <= 100), count(*) filter (where id = 101) from ledger")"
  if [ "$got" = "100|0" ]; then
    pass "restored to the target: the 100 rows before it, not row 101, and the table the DROP removed"
  else
    fail "restored cluster has (before|after) = '$got', expected '100|0'"
  fi
else
  fail "the point-in-time restore did not become ready: $(k get cluster pg-pitr -o jsonpath='{.status.phase}' 2>&1)"
fi
k delete cluster pg-pitr --wait=false >/dev/null 2>&1

# --- 4 -------------------------------------------------------------------------
step "4. failover under writes"
P="$(primary)"
# The client writes as the application's user, so the table is that user's.
sql "$P" "create table heartbeat (id int primary key, at timestamptz not null default clock_timestamp());
          alter table heartbeat owner to app" >/dev/null
IMAGE="$(k get cluster pg -o jsonpath='{.spec.imageName}')"
# A client with the application's credentials, through the read-write service:
# one insert every 200 ms, each logged as ok or err with the time.
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 26
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: writer
      image: $IMAGE
      env:
        - name: URI
          valueFrom: {secretKeyRef: {name: pg-app, key: uri}}
        # Without it, a connect to the killed primary's address waits out
        # TCP's SYN retries, about two minutes, long after the failover.
        - name: PGCONNECT_TIMEOUT
          value: "3"
      command: [bash, -c]
      args:
        - |
          i=0
          while :; do
            i=\$((i + 1))
            if out="\$(psql "\$URI" -qtAc "insert into heartbeat (id) values (\$i)" 2>&1)"; then
              echo "ok \$i \$(date +%s.%N)"
            else
              echo "err \$i \$(date +%s.%N) \$(head -1 <<<"\$out" | cut -c1-160)"
            fi
            sleep 0.2
          done
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 128Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
EOF
k wait --for=condition=Ready pod/writer --timeout=120s >/dev/null 2>&1
oks() { k logs writer 2>/dev/null | grep -c '^ok '; }
for _ in $(seq 1 60); do [ "$(oks)" -ge 25 ] && break; sleep 1; done
before="$(oks)"
k delete pod "$P" --grace-period=0 --force >/dev/null 2>&1
echo "  killed $P with $before writes acknowledged"
new=""
for _ in $(seq 1 90); do
  new="$(primary)"
  [ -n "$new" ] && [ "$new" != "$P" ] && [ "$(oks)" -gt "$before" ] && break
  sleep 2
done
sleep 10
log="$(k logs writer 2>/dev/null || true)"
k delete pod writer --wait=false >/dev/null 2>&1 || true
if [ -n "$new" ] && [ "$new" != "$P" ]; then
  pass "$new took over from $P"
else
  fail "no new primary after $P was killed"
fi
# Every id the client was told committed has to be on the new primary.
acked="$(grep '^ok ' <<<"$log" | awk '{print $2}' | sort -n | tr '\n' ',' | sed 's/,$//')"
if [ -n "$acked" ]; then
  missing="$(sql "$new" "select count(*) from unnest(array[$acked]) a(id) where not exists (select 1 from heartbeat h where h.id = a.id)")"
  total="$(grep -c '^ok ' <<<"$log")"
  [ "$missing" = 0 ] && pass "all $total acknowledged writes are on the new primary" \
    || fail "$missing of $total acknowledged writes are missing on the new primary"
else
  fail "the writer logged no acknowledged writes; its first error: $(grep -m1 '^err ' <<<"$log" | cut -d' ' -f4-)"
fi
# The longest stretch between two acknowledged writes, on the client's own
# clock: the outage, whatever the host's clock says.
gap="$(LOG="$log" python3 - <<'PY'
import os
t = [float(l.split()[2]) for l in os.environ["LOG"].splitlines() if l.startswith("ok ")]
print("%.1f" % max(b - a for a, b in zip(t, t[1:])) if len(t) > 1 else "")
PY
)"
[ -n "$gap" ] && measure "failover: the longest stretch without an acknowledged write was ${gap}s"
for _ in $(seq 1 90); do [ "$(k get cluster pg -o jsonpath='{.status.readyInstances}')" = 3 ] && break; sleep 2; done
[ "$(k get cluster pg -o jsonpath='{.status.readyInstances}')" = 3 ] && pass "$P came back as a standby; three instances ready" \
  || fail "the cluster did not return to three ready instances"

# --- 5 -------------------------------------------------------------------------
step "5. disaster"
P="$(primary)"
sql "$P" "create table survivors as select g as id from generate_series(1, 50) g" >/dev/null
written="$(date +%s)"
# No forced switch here: archive_timeout has to close the segment by itself.
seg="$(sql "$P" "select pg_walfile_name(pg_current_wal_lsn())")"
for _ in $(seq 1 45); do
  [ "$(sql "$P" "select coalesce(last_archived_wal, '') >= '$seg' from pg_stat_archiver")" = t ] && break
  sleep 2
done
waited=$(( $(date +%s) - written ))
if [ "$(sql "$P" "select coalesce(last_archived_wal, '') >= '$seg' from pg_stat_archiver")" = t ]; then
  pass "archive_timeout shipped the last write's WAL within ${waited}s, without a forced switch"
else
  fail "the last write's WAL was not archived within ${waited}s; archive_timeout is 60s"
fi
k delete cluster pg --wait=true --timeout=300s >/dev/null 2>&1
# The volumes go by garbage collection, after the cluster object.
for _ in $(seq 1 60); do
  left="$(k get pvc -l cnpg.io/cluster=pg -o name 2>/dev/null | wc -l | tr -d ' ')"
  [ "$left" = 0 ] && break
  sleep 2
done
[ "$left" = 0 ] && pass "pg and its volumes are gone" || fail "$left of pg's volumes are still there"
if secs="$(restore latest.yaml pg-dr)" && [ -n "$secs" ]; then
  measure "restore from the bucket alone: ready in ${secs}s"
  R="$(primary pg-dr)"
  got="$(sql "$R" "select count(*) from survivors")"
  [ "$got" = 50 ] && pass "the restored cluster has the 50 rows written before the loss" \
    || fail "the restored cluster has '$got' of the 50 rows"
else
  fail "the restore from the bucket did not become ready: $(k get cluster pg-dr -o jsonpath='{.status.phase}' 2>&1)"
fi

# --- 6 -------------------------------------------------------------------------
step "6. Ready is not backed up"
# The same name means the same path in the bucket, which holds the lost
# cluster's archive. The plugin refuses to archive over it; the cluster is
# Ready all the same. Only the ContinuousArchiving condition says so.
kubectl apply -f "$ROOT/manifests/database/cluster.yaml" >/dev/null 2>&1
k wait --for=condition=Ready cluster/pg --timeout=600s >/dev/null 2>&1
state=""
for _ in $(seq 1 45); do
  state="$(cond pg ContinuousArchiving)"
  [ "$state" = False ] && break
  sleep 4
done
msg="$(k get cluster pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}')"
expected="$(k logs pg-1 -c plugin-barman-cloud --tail=400 2>/dev/null | grep -c 'Expected empty archive')"
if [ "$(cond pg Ready)" = True ] && [ "$state" = False ] && [ "$expected" -gt 0 ]; then
  pass "pg, created again over the old path, is Ready and does not archive: 'Expected empty archive'"
else
  fail "a cluster over a used path: Ready '$(cond pg Ready)', archiving '$state' ($msg), refusals logged: $expected"
fi

# --- summary -------------------------------------------------------------------
printf '\n'
printf '%s\n' "${results[@]}" "" "${measured[@]}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### PostgreSQL recovery drill"; echo; echo '```'; printf '%s\n' "${results[@]}" "" "${measured[@]}"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
