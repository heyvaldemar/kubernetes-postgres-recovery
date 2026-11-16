# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `AGENTS.md` (and a `CLAUDE.md` that imports it): the rules an AI agent working on this repository is held to: claims only as checks in the drill or the static checks, a check trusted only after it has failed, risky changes proved on a branch, where each pin lives, measured numbers only from named runs, how a release is cut and verified, and no backup called good until a restore from it has been read back.
- A weekly check of every pin against upstream: `scripts/check-freshness.py`, run by the verify workflow on its schedule and by hand. It compares the charts the scripts install with their repository's index, every image pinned by digest with what its tag resolves to now, the tools in `tools.lock` with their newest releases, and the CI images. Dependabot here watched the workflows' actions and nothing else, so a chart, an image or a tool could fall behind without a sound. Its first run found helm one patch behind.
- Live status: every e2e run uploads its checks and measurements (`E2E_RESULTS`), and `.github/workflows/status.yml` rewrites the `status` branch after each run with the last 30 days on main: green days, the streak, the latest checks (`scripts/status.py`). The README's second row of badges reads it.

### Changed

- `scripts/check-freshness.py` is the fleet's one copy of the freshness check, fleet-ops `templates/check-freshness.py`, and what this repository pins is listed in `freshness.json`. A release younger than three days is now a warning that names the moment it becomes a failure: the release-age rule keeps such a version off main anyway, and every upstream release used to turn the check red for three days nobody was allowed to act on. A release whose date cannot be read still fails, and so does a tag that moved to a new digest.
- The status workflow hands its push credential to git through git's environment, not its command line, which any process on the runner can read.
- helm v4.3.1 in `tools.lock`, its hashes checked against helm's own checksum files.

### Security

- **A run by hand never replaces a signature a release already carries.** `.github/workflows/release-assets.yml`, started by hand, now refuses a release that already has its signature, or one it cannot read. Replacing the files would have made the signature name `main` instead of the tag, and a check pinned to the tag's identity would then refuse the release. To replace them on purpose, delete the three files first.
- **A release is verified for its exact signer** (69cbbd8). `.github/workflows/release-assets.yml` checks the signature against this repository's `release-assets.yml` on the ref the run ran on; before, any workflow of the repository on any branch passed. A changed archive must now be refused in the tool's own words, so Sigstore out of reach or a missing tool fails the job instead of passing it. A run started by hand runs only from `main`.

## [1.0.0] - 2026-10-14

### Added

- PostgreSQL 18.6 on CloudNativePG 1.30.1, three instances with a synchronous standby required, WAL and daily base backups through the Barman Cloud plugin 0.15.1 to an S3 bucket (SeaweedFS on kind), a one-minute archive ceiling and a 7-day recovery window. Every image by digest; Pod Security restricted.
- The recovery drill (`tests/e2e/run.sh`), daily on a fresh kind cluster: a restore to a second before a `DROP TABLE`, a failover under writes with every acknowledged write checked on the new primary, a restore from the bucket alone after the cluster and its volumes are deleted, and a cluster that is Ready while it refuses to archive over a used path.
- Five planted restore manifests the drill dry-runs against the operator first: a target that is not a time, two targets and an undeclared source are refused at apply; a well-formed restore is admitted, and so is a target time with no zone, which the operator reads as UTC.
- A recording of the drill (`docs/demo/drill.cast`, rendered to `docs/demo/drill.gif`).
- Static checks with 11 planted violations, each caught: images by digest in the manifests and the rendered charts, every manifest against the CRDs the pinned charts install, and the properties recovery depends on.
- Runbooks for point-in-time recovery and disaster recovery, four decision records, a threat model.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-postgres-recovery/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/kubernetes-postgres-recovery/releases/tag/v1.0.0
