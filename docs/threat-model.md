# Threat model

What can lose or corrupt the data, what stands against each, and the check that shows it holds. A threat with no check is listed under residual risks rather than claimed.

## What is protected

The rows in the database, and the ability to get them back: to a moment before a mistake, after the loss of the primary, after the loss of the cluster.

## Threats, controls and evidence

| Threat | Control | Check |
|---|---|---|
| The primary dies with commits only it has | a synchronous standby (`ANY 1`) confirms every commit; `dataDurability: required` holds writes rather than acknowledge them alone | e2e 4: primary force-deleted under writes; every acknowledged write on the new primary. Static: `number >= 1`, `required` |
| A mistake in the data (DROP, DELETE without WHERE) | base backups and WAL in the bucket, 7-day recovery window | e2e 3: a restore to a second before a DROP has every row before it and none after |
| The cluster and its volumes are lost | the bucket outside the cluster; `archive_timeout: 60s` | e2e 5: cluster and volumes deleted, restore from the bucket alone; the last write's WAL archived within a minute with no forced switch |
| Backups stop and nobody notices | `ContinuousArchiving` condition; the daily drill | e2e 2 and 6: archiving reported working; a cluster that is Ready and does not archive is detected |
| A restore writes over the backups it reads | restore templates have no archiver; the plugin refuses a used path | static: a restore template with `plugins` fails; e2e 6: the refusal is observed |
| An image changes under its tag | every image by digest, in manifests and in the rendered charts | static `images`, with planted tags |
| A pod gets more than it needs | Pod Security `restricted` on the database and the bucket | static: both namespaces enforce it; the cluster runs under it in every e2e run |
| Backup credentials in Git | generated at install, kept only in the cluster | `scripts/install.sh`; nothing in the repository |

## Findings from the build

**Ready is not backed up.** A cluster created under the name of one whose archive is still in the bucket serves every query and reports Ready, while the plugin refuses to archive over the old path (`Expected empty archive`). Only the `ContinuousArchiving` condition says so. Monitoring that watches Ready would show green over a database with no backups. The drill's step 6 builds that cluster and requires all three: Ready, not archiving, the refusal in the log.

**A failover is only as short as the client's timeout.** The first measurement of the failover was 136 seconds without an acknowledged write. The database had moved on long before: the client had no connect timeout, and its connection to the killed primary's address waited out TCP's SYN retries. With `PGCONNECT_TIMEOUT=3` the measurement is the database's. An application without a connect timeout, or a pool without a health check, turns a seconds-long failover into minutes.

## Residual risks

- **One node.** The three instances share one kind node, so there is no zone to lose and the synchronous standby costs no network latency. On a real cluster: spread the instances across zones (CloudNativePG's affinity settings), and expect each commit to pay the round trip to the nearest standby.
- **The bucket is in the same cluster, and its keys can delete.** Retention needs delete rights, and anyone with the keys can remove every backup. A real setup puts the bucket in another account with object lock (S3 Object Lock, or the provider's equivalent) for at least the recovery window, and gives the database write access without delete where the provider allows a separate lifecycle rule to prune.
- **No alert.** A failed archive is visible in the cluster's status and found by the next daily drill, up to a day later. CloudNativePG exports metrics for a Prometheus alert on archive failures and on time since the last successful archive; this repository does not deploy one yet.
- **Backups are as private as the store.** WAL and base backups are compressed and not encrypted here. On a cloud bucket, set the `ObjectStore`'s `encryption` (`AES256` or `aws:kms`, for data and for WAL) so the store encrypts every file, with a KMS key the database's role cannot schedule for deletion.
- **Major versions.** Upgrades from one PostgreSQL major version to the next are not exercised.

## How to explain this to a customer

We do not trust a backup we have not restored, so we restore three ways every day: to a second before a mistake, onto a standby when the main server dies mid-write, and from cloud storage alone when everything else is gone. Each one is checked by reading the data back. The open items are the ones that need a real cloud account: storage that even an administrator cannot delete during the retention window, and servers in different zones.
