# Point-in-time recovery

Someone ran a `DELETE` without a `WHERE`, or a migration dropped the wrong table. The cluster is healthy and serving; the data is wrong. This puts a copy of the database, as it was a second before the mistake, next to the running one, and then moves the application to it or copies the rows back.

The drill runs these steps every day (`tests/e2e/run.sh`, step 3).

## 1. Find the second before the mistake

PostgreSQL's log has the statement and its time when `log_statement` covers it; the application's log usually has the request. Take a time just before it, in PostgreSQL's format, and write the zone. The operator accepts a time without one and reads it as UTC: an incident at 14:05 on a clock five hours behind UTC, typed as `14:05:00`, restores to five hours before it (the drill keeps a plant for this, `tests/e2e/plants/restore-target-without-a-zone.yaml`). In UTC:

```bash
kubectl -n database exec pg-1 -c postgres -- psql -d app -qtAc \
  "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'"
```

The recovery window is 7 days (`retentionPolicy` in `manifests/database/objectstore.yaml`). A time older than that is gone.

## 2. Make sure the WAL past that second is in the bucket

The WAL that holds the mistake has to be archived, or recovery stops short of the target and the cluster does not start. With `archive_timeout: 60s` it is there a minute after the mistake; to not wait, switch segments and check the archiver:

```bash
kubectl -n database exec pg-1 -c postgres -- psql -d app -qtAc "select pg_switch_wal()"
kubectl -n database exec pg-1 -c postgres -- psql -d app -qtAc \
  "select last_archived_wal, last_archived_time, last_failed_wal from pg_stat_archiver"
```

Run these on the primary (`kubectl -n database get cluster pg -o jsonpath='{.status.currentPrimary}'`).

## 3. Restore next to the running cluster

```bash
sed -e 's#NAME#pg-restore#' -e 's#TARGET_TIME#2026-10-14 16:50:01.000000+00#' \
  manifests/recovery/point-in-time.yaml | kubectl apply -f -
kubectl -n database wait --for=condition=Ready cluster/pg-restore --timeout=30m
```

`pg-restore` reads `pg`'s backups and writes none of its own (ADR 4). The damaged cluster keeps serving the whole time.

## 4. Check what came back

```bash
kubectl -n database exec pg-restore-1 -c postgres -- psql -d app -c "select count(*) from the_table"
```

Compare with what the application expects. If the target was off, delete `pg-restore` and restore again with another time: the backups are untouched.

## 5. Use it

Either copy the lost rows back into `pg` (`pg_dump --table` from `pg-restore`, restore into `pg`), which keeps everything written since the mistake; or move the application to `pg-restore` and give it the archiver (`plugins` from `manifests/database/cluster.yaml`), which loses everything written since. Most incidents want the first.

Then delete `pg-restore`.
