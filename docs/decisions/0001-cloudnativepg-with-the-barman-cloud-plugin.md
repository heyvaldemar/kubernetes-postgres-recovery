# 1. CloudNativePG with the Barman Cloud plugin

- Status: accepted
- Date: 2026-10-14

## Context

PostgreSQL on Kubernetes needs something to do what a DBA would: start the primary and standbys, promote a standby when the primary dies, ship WAL, take base backups, restore. A StatefulSet does none of it. The choice is which operator, and how backups attach to it.

## Decision

CloudNativePG 1.30, which manages the instances directly rather than through a StatefulSet and promotes a standby itself, with backups through its Barman Cloud plugin (0.15). Since CloudNativePG 1.26 object-store backups are a plugin rather than built in; the plugin adds a sidecar to every instance that ships WAL and takes base backups, and an `ObjectStore` resource that holds the bucket, the credentials and the retention window.

## Consequences

- One resource (`Cluster`) declares the database, its replication and where its WAL goes; restores are a `Cluster` with a `bootstrap.recovery` section.
- The plugin needs cert-manager, for the certificates between it and the operator: one more component to install and upgrade.
- The operator's admission webhook sits in front of every `Cluster` change; the drill retries an apply when the webhook drops a request, which it did once on a loaded laptop.

## Alternatives

- **The built-in `barmanObjectStore`.** Deprecated since 1.26 in favour of the plugin; new work goes to the plugin.
- **A StatefulSet and scripts.** Failover and point-in-time recovery become this repository's code, with its bugs.
- **A managed database (RDS, Cloud SQL).** The right answer for many teams; this repository is for the ones who keep the database next to the application, and it shows what that costs to do properly.

## How to explain this to a customer

The database runs under an operator that does what an on-call DBA would: it notices a dead primary and promotes a replica, ships every change to a bucket, and can rebuild the database from that bucket to any second in the last week. We chose the most widely used open-source one, and we restore with it every day so we know it works.
