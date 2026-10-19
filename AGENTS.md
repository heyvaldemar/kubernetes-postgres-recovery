# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Every line of the README's "What is proven, and how" table is a check in `tests/e2e/run.sh`, the drill on a fresh kind cluster, or in `scripts/validate.sh`. A claim with no check is not written: a threat with no check goes under residual risks in `docs/threat-model.md`. Every restore is judged by reading the data back, never by the restored cluster reporting Ready. It is a reference architecture that runs on kind at no cloud cost, with SeaweedFS standing in for S3, and nothing says otherwise: no wording about live deployments or certification (the fleet's conformance check refuses it).

## Before changing anything

- Read the decision record that covers it, under `docs/decisions/`. A change that alters a decision amends that record or adds one in the same format, with a row in `docs/decisions/README.md`, ending with how the choice is explained to a customer. The synchronous standby is ADR 2, the archive bound ADR 3, restores with no archiver ADR 4.
- A change to what an operator types is a change to `docs/runbooks/` too. The `NAME` and `TARGET_TIME` placeholders in `manifests/recovery/` are filled by `sed` in `tests/e2e/run.sh`, `scripts/validate.sh` and both runbooks.
- `make check` runs the static checks (`scripts/validate.sh`: `kubeconform`, `images`, `database`) and shows each one its planted violation (`tests/static/plant_violations.py` over `tests/static/plants.tsv`). It must end with every plant caught, none missed, none stale.
- Both namespaces enforce Pod Security `restricted`. A pod the drill adds is written to pass it, as the step 4 writer is.

## A check is trusted only after it has failed

A new or changed check ships with the violation it exists for:

- a static check: a row in `tests/static/plants.tsv` (the file, the text it breaks, its replacement, the check that must fail, what it plants; each field JSON-encoded);
- a restore the operator must refuse at apply: a manifest in `tests/e2e/plants/` whose `# expect:` line holds the refusal text, or `admitted`. `restore-to-a-time.yaml` is the control and stays admitted, or every refusal could be the operator refusing everything;
- a drill check in `tests/e2e/run.sh`: a deliberate sabotage run whose failing output is recorded in the commit message.

A plant quotes the text it breaks, so an edit to that text (a digest bump, a renamed field) updates the row in the same commit, or `make check` reports it stale. A check that has never been seen to fail proves nothing.

## Proving a risky change

A change to `manifests/`, `values/`, `scripts/install.sh` or `tests/e2e/run.sh`, or a chart or image bump, runs the drill on a branch before it reaches main:

```bash
gh workflow run e2e.yml --ref <branch>
```

`status.yml` and `scripts/status.py` read main only, so a branch run never reaches the badges. A second run on the same ref cancels the first. When a run fails, read its "What the cluster looked like" step (clusters, backups, events, operator and plugin logs) before changing the drill. `make test` runs the same drill locally and is destructive: its last step deletes the cluster, so `make down up` before another run.

## Pins

Everything is pinned by digest, hash or commit:

- chart versions: `CERT_MANAGER_CHART`, `CNPG_CHART` and `BARMAN_PLUGIN_CHART` in `scripts/install.sh`, which `scripts/validate.sh` reads;
- chart images: `values/*.yaml`;
- the PostgreSQL image: `manifests/database/cluster.yaml`, both restore templates, the five e2e plants and the first row of `tests/static/plants.tsv`, moved together;
- SeaweedFS in `manifests/object-store/seaweedfs.yaml`, the kind node in `kind/cluster.yaml`;
- tools by version and sha256 per platform in `tools.lock`, CI images in `ci-images.pins`, actions by commit SHA in the workflows (the SLSA generator stays on a tag: it refuses a SHA), Kubernetes schemas at a fixed commit in `scripts/validate.sh`.

Dependabot reads only the actions. `scripts/check-freshness.py`, weekly in the verify workflow, reports every other pin that fell behind and changes nothing. Those bumps are by hand, with the new hash checked against the publisher's, and pass the same checks as any change.

## Numbers

The README's measured table names its commit and its three runs, and every figure there is what the drill printed in those runs. A new figure names its commit and runs the same way; a run's `e2e-results` artifact holds what it printed for 30 days. The badges are written by `scripts/status.py` from the latest run on main. The text before `: ` in a `measure` line names its badge file on the `status` branch, so renaming one breaks a README badge unless the README changes with it.

When runs differ, find what changed before calling it noise: the first failover measurement, 136 s, was a client with no connect timeout, not the database. A bound lives in its decision record and changes only with it. ADR 3 holds the archive bound: `archive_timeout: 60s`, 90 s for the drill to see the WAL in the bucket with no forced switch, more than five minutes refused by the static check.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` in the same commit as the change.
- Tag only a commit whose drill is green on main, or a docs-only commit right after one, and say which in the release notes: what is new, what was found while building it, how it was checked. v1.0.0 is the second kind: CHANGELOG and README only, right after `6e58a4e`, the commit the numbers were measured on.
- Publishing a release runs `release-assets.yml`: a `git archive` of the tag, a keyless cosign signature and SLSA provenance. After publishing, verify them the way a stranger would, with `cosign verify-blob` and `slsa-verifier verify-artifact --source-tag <tag>`, as the workflow's header shows.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, commits and files. Commit subjects follow the log: `feat:`, `fix(status):`, `test(e2e):`, `ci:`, `docs:`, `chore(release):`. Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines.

## Never

- Print a secret or credential, put one in a file or a log, or pass one as a command-line argument. The S3 keys are made by `scripts/install.sh`, reach `kubectl` on stdin and live only in the cluster; CloudNativePG makes the database's passwords there. Do not read them back out of their Secrets.
- Turn off or weaken a check, a test or a gate to get a run green, or the settings they guard: three instances, `dataDurability: required`, `archive_timeout`, the retention window.
- Touch anything outside this repository's own CI to test a change: no cloud resources, no outside services, no real bucket. SeaweedFS inside kind is the bucket.
- Call a backup good until a restore from it has been read back, or call a cluster backed up because it is Ready: only `ContinuousArchiving` True says it archives (ADR 4).
- Give a restore template in `manifests/recovery/` an archiver. A restore never writes into the backups it reads.
- Claim a failover or restore time changed from a handful of runs, or present the restore times as a figure for a large database: they are a 1 GiB volume and a few hundred rows.
- Edit the `status` branch by hand, or `docs/demo/drill.cast` beyond cutting waits.
