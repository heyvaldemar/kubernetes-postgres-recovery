# Disaster recovery

The cluster is gone: its namespace was deleted, the nodes and their volumes with it, or the Kubernetes cluster itself. What is left is the bucket. This builds a new cluster from it and makes that the production database.

The drill runs the restore every day (`tests/e2e/run.sh`, step 5), after deleting the cluster and its volumes.

## 1. What will come back

Everything committed up to the last WAL segment that reached the bucket. With `archive_timeout: 60s`, that is everything but the last minute or so before the loss. Look before restoring:

```bash
kubectl -n object-store exec deploy/seaweedfs -- sh -c \
  'echo "fs.ls -l /buckets/backups/pg/wals" | weed shell -master=localhost:9333 -filer=localhost:8888'
```

On a cloud bucket, list the same prefix with the provider's tools.

## 2. Restore from the bucket

The operator, the plugin and the `ObjectStore` with its credentials have to exist first: `scripts/install.sh`, then `kubectl apply -f manifests/database/objectstore.yaml` (not the cluster).

```bash
sed -e 's#NAME#pg-dr#' manifests/recovery/latest.yaml | kubectl apply -f -
kubectl -n database wait --for=condition=Ready cluster/pg-dr --timeout=30m
```

## 3. Check what came back

```bash
kubectl -n database exec pg-dr-1 -c postgres -- psql -d app -c "select max(created_at) from the_busiest_table"
```

The newest row tells you where recovery stopped, which is the data loss to report.

## 4. Make it the production cluster

- Give `pg-dr` the archiver: add the `plugins` section of `manifests/database/cluster.yaml`. It archives under `pg-dr`, its own name, next to `pg`'s backups. Do not name a new cluster `pg`: the bucket's `pg/` path holds the lost cluster's archive, and the plugin refuses to archive over it while the cluster reports Ready (ADR 4; the drill's step 6 shows it).
- Scale it to three instances, with the synchronous standby: the rest of `manifests/database/cluster.yaml`'s spec.
- Check `ContinuousArchiving` is True, not only Ready:

  ```bash
  kubectl -n database get cluster pg-dr -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'
  ```

- Take a base backup now (`kubectl cnpg backup -n database pg-dr --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io`, or a `Backup` resource with `method: plugin`), and point the `ScheduledBackup` at `pg-dr`.
- Point the application at `pg-dr-rw`.
