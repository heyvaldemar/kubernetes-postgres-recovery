# PostgreSQL on Kubernetes with recovery proven, on kind: CloudNativePG, WAL
# and base backups to an S3 bucket, and a drill that restores to a point in
# time, fails over under writes, and rebuilds from the bucket alone.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
BIN := $(CURDIR)/.cache/bin
export PATH := $(BIN):$(PATH)

.PHONY: tools up test check down

tools:
	@./scripts/install-tools.sh >/dev/null

up: tools
	kind create cluster --config kind/cluster.yaml --wait 120s
	./scripts/install.sh
	kubectl apply -f manifests/database/
	kubectl -n database wait --for=condition=Ready cluster/pg --timeout=900s

# Destructive: the last step deletes the cluster. `make down up` for another run.
test: tools
	./tests/e2e/run.sh

check: tools
	./scripts/validate.sh
	python3 tests/static/plant_violations.py

down: tools
	kind delete cluster --name postgres-recovery
