# 4. Restores never archive into their source

- Status: accepted
- Date: 2026-10-14

## Context

A restored cluster starts a new timeline from the old one's backups. If it archived its own WAL into the same path, it would mix with the source's, and a later restore of the source could replay the wrong history. The Barman Cloud plugin refuses to archive into a path that already holds an archive (`WAL archive check failed for server pg: Expected empty archive`). The cluster still reports Ready: only its `ContinuousArchiving` condition, False, says that nothing is being backed up. The drill's sixth step creates exactly that cluster and requires all three.

## Decision

The restore templates in `manifests/recovery/` read the source's backups through `externalClusters` and have no `plugins` section, so they archive nothing. Making a restore the new production cluster means adding the archiver back, under the restored cluster's own name, next to the old path. The static check fails on a restore template that archives.

## Consequences

- A point-in-time restore can run next to the damaged cluster, which keeps serving, with no risk to its backups.
- After a disaster recovery there is a step to remember: enable archiving on the new cluster, under a name the bucket has not seen. The runbook has it.
- Anything that watches the database has to watch `ContinuousArchiving`, not Ready. A cluster can serve every query and back up nothing.

## Alternatives

- **Restore with archiving to the same path.** Refused by the plugin; and if it were not, the two histories would share one place.
- **Restore in place.** Not how CloudNativePG works: a restore is always a new cluster.

## How to explain this to a customer

A restore never touches the backups it comes from. We can restore to yesterday next to the live database, look, and throw it away, and the backups are exactly as they were. When a restore becomes the real database, it starts its own backups in their own place.
