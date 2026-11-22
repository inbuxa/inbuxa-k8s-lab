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

step "Helm repositories"
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update >/dev/null
helm repo add metallb https://metallb.github.io/metallb --force-update >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo update >/dev/null

step "kind cluster"
# KIND_NODE_IMAGE picks the Kubernetes version (CI's matrix); unset, kind's own
kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER" ||
  kind create cluster --name "$KIND_CLUSTER" --config "$here/kind.yaml" --wait 120s \
    ${KIND_NODE_IMAGE:+--image "$KIND_NODE_IMAGE"}
kubectl config use-context "kind-$KIND_CLUSTER" >/dev/null
for ns in data inbuxa; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done

step "Docker Hub images: pulled once, loaded into the nodes"
# Docker Hub limits anonymous pulls per address, and four nodes each pulling
# NATS and Garage could run out on a shared CI address (NATS stuck in
# ImagePullBackOff). Pulled here once each, retried, then loaded into every
# node; one that still won't pull is left to the nodes, as before.
hub_images() {
  helm template nats nats/nats --version "$NATS_CHART" -n data -f "$here/data-layer/nats-values.yaml" \
    | awk '$1 == "image:" {print $2}' | tr -d '"'
  echo "$GARAGE_IMAGE"
}
case "$(docker info -f '{{.Architecture}}')" in
  aarch64|arm64) platform=linux/arm64 ;;
  *) platform=linux/amd64 ;;
esac
archive="$(mktemp)"
for image in $(hub_images | sed -E 's|^docker\.io/||' | grep -vE '^[^/]+\.[^/]+/' | sort -u); do
  pulled=""
  for wait in 0 20 60 120; do
    sleep "$wait"
    docker pull -q --platform "$platform" "$image" >/dev/null 2>&1 && { pulled=1; break; }
  done
  if [ -n "$pulled" ] && docker save --platform "$platform" -o "$archive" "$image" \
    && kind load image-archive "$archive" --name "$KIND_CLUSTER" >/dev/null 2>&1; then
    echo "   $image"
  else
    echo "   $image: not loaded, the nodes pull it themselves" >&2
  fi
done
rm -f "$archive"
# inbuxa's pods run under Pod Security "restricted", enforced (K-C4), and
# the lab's own policies (policy/defaults.yaml, K-L3)
kubectl label --overwrite namespace inbuxa inbuxa.org/policy=enforce \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted >/dev/null

step "MetalLB"
# LoadBalancer addresses from the top of kind's Docker network, which the
# host reaches: computed, since that network's subnet differs by machine
helm upgrade --install metallb metallb/metallb --version "$METALLB_CHART" -n metallb-system --create-namespace --wait >/dev/null
subnet=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
pool=$(python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); print(f"{n.broadcast_address-55}-{n.broadcast_address-5}")' "$subnet")
sed "s|172.19.255.200-172.19.255.250|$pool|" "$here/network/metallb-pool.yaml" | kubectl apply -f - >/dev/null
echo "   LoadBalancer pool $pool ($subnet)"

step "Kyverno"
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART" -n kyverno --create-namespace \
  --set cleanupController.enabled=false --set reportsController.enabled=false --wait >/dev/null
# Helm's --wait returns before the webhook answers on a new cluster
for i in $(seq 1 30); do
  kubectl apply -f "$here/policy/defaults.yaml" >/dev/null 2>"$here/.policy-apply.err" && break
  [ "$i" = 30 ] && { cat "$here/.policy-apply.err" >&2; rm -f "$here/.policy-apply.err"; exit 1; }
  sleep 3
done
rm -f "$here/.policy-apply.err"

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
  # Ready to Kubernetes isn't ready to answer: wait for Garage to list itself
  node=""
  for _ in $(seq 1 30); do
    node=$( (g status 2>/dev/null || true) | awk '/^[0-9a-f]{16}/{print $1; exit}')
    [ -n "$node" ] && break
    sleep 2
  done
  [ -n "$node" ] || { echo "!! Garage never listed its node" >&2; exit 1; }
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
