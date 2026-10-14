# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- PostgreSQL 18.6 on CloudNativePG 1.30.1, three instances with a synchronous standby required, WAL and daily base backups through the Barman Cloud plugin 0.15.1 to an S3 bucket (SeaweedFS on kind), a one-minute archive ceiling and a 7-day recovery window. Every image by digest; Pod Security restricted.
- The recovery drill (`tests/e2e/run.sh`), daily on a fresh kind cluster: a restore to a second before a `DROP TABLE`, a failover under writes with every acknowledged write checked on the new primary, a restore from the bucket alone after the cluster and its volumes are deleted, and a cluster that is Ready while it refuses to archive over a used path.
- Static checks with 11 planted violations, each caught: images by digest in the manifests and the rendered charts, every manifest against the CRDs the pinned charts install, and the properties recovery depends on.
- Runbooks for point-in-time recovery and disaster recovery, four decision records, a threat model.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-postgres-recovery/commits/main
