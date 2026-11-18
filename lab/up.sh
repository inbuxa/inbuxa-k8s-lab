#!/usr/bin/env bash
# Bring up the lab: a kind cluster with the data layer inbuxa needs
# (PostgreSQL via CloudNativePG, NATS, Garage for S3), plus the Secrets the
# server reads, in namespace "inbuxa". Prints how long each part took.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
. "$here/versions.env"
t0=$SECONDS
step() { printf '\n== %s (%ss)\n' "$1" "$((SECONDS - t0))"; }
rand() { head -c 24 /dev/urandom | base64 | tr -d '/+=' ; }

step "kind cluster"
kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER" || kind create cluster --name "$KIND_CLUSTER" --config "$here/kind.yaml" --wait 120s
kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null
for ns in data inbuxa; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done

step "CloudNativePG operator"
helm upgrade --install cnpg cnpg/cloudnative-pg --version "$CNPG_CHART" -n cnpg-system --create-namespace --wait >/dev/null
kubectl -n data apply -f "$here/data-layer/postgres.yaml" >/dev/null

step "NATS"
kubectl -n data get secret nats-inbuxa >/dev/null 2>&1 || kubectl -n data create secret generic nats-inbuxa --from-literal=password="$(rand)" >/dev/null
helm upgrade --install nats nats/nats --version "$NATS_CHART" -n data -f "$here/data-layer/nats-values.yaml" >/dev/null

step "Garage"
kubectl -n data get secret garage-rpc >/dev/null 2>&1 || kubectl -n data create secret generic garage-rpc --from-literal=secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
sed "s|GARAGE_IMAGE|$GARAGE_IMAGE|" "$here/data-layer/garage.yaml" | kubectl -n data apply -f - >/dev/null
kubectl -n data rollout status deploy/garage --timeout=180s >/dev/null
g() { kubectl -n data exec deploy/garage -- /garage "$@"; }
if ! g bucket info inbuxa-blobs >/dev/null 2>&1; then
  node=$(g status 2>/dev/null | awk '/^[0-9a-f]{16}/{print $1; exit}')
  g layout assign -z lab -c 2G "$node" >/dev/null
  g layout apply --version 1 >/dev/null
  g bucket create inbuxa-blobs >/dev/null
  keyout=$(g key create inbuxa)
  g bucket allow --read --write --owner inbuxa-blobs --key inbuxa >/dev/null
  kid=$(awk -F': *' '/Key ID/{print $2; exit}' <<<"$keyout")
  ksec=$(awk -F': *' '/Secret key/{print $2; exit}' <<<"$keyout")
  kubectl -n inbuxa create secret generic inbuxa-s3 --from-literal=access-key="$kid" --from-literal=secret-key="$ksec" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

step "waiting for PostgreSQL and NATS"
kubectl -n data wait cluster.postgresql.cnpg.io/inbuxa-pg --for=condition=Ready --timeout=600s >/dev/null
kubectl -n data rollout status statefulset/nats --timeout=300s >/dev/null

step "Secrets for the server (namespace inbuxa)"
pgpw=$(kubectl -n data get secret inbuxa-pg-app -o jsonpath='{.data.password}' | base64 -d)
natspw=$(kubectl -n data get secret nats-inbuxa -o jsonpath='{.data.password}' | base64 -d)
kubectl -n inbuxa create secret generic inbuxa-data --from-literal=pg-password="$pgpw" --from-literal=nats-password="$natspw" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n inbuxa get secret inbuxa-recovery >/dev/null 2>&1 || kubectl -n inbuxa create secret generic inbuxa-recovery --from-literal=admin="admin:$(rand)" >/dev/null

step "done"
kubectl get nodes -o wide | awk '{print $1, $2, $5}' | column -t
kubectl -n data get pods -o wide | awk '{print $1, $3, $7}' | column -t
