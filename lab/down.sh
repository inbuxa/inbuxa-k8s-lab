#!/usr/bin/env bash
# Remove the lab cluster and everything in it.
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/versions.env"
kind delete cluster --name "$KIND_CLUSTER"
