#!/usr/bin/env bash
# A fresh, set-up store for the chart smoke test, in place of whatever the
# lab's database held: first boot (bootstrap-mode pod), then the blob store,
# coordinator and role groups, and one mail account (recovery-mode pod).
#
#   IMAGE=inbuxa-lab/server:main lab/chart/fresh-store.sh
#
# This wipes the lab's inbuxa database. Secrets stay out of stdout: the
# administrator and the test account's password go to files under $STATE
# (0600). The steps the chart can't do yet (first boot and the registry
# setup) are here, by hand, until it can.
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab)
IMAGE="${IMAGE:-inbuxa-lab/server:main}"
# Never for an image loaded into kind; IfNotPresent for a published one
PULL="${PULL:-Never}"
PORTS="${PORTS:-pop3s=off}"
DOMAIN="${DOMAIN:-lab.test}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
mkdir -p "$STATE" && chmod 700 "$STATE"

secret() { "${K[@]}" -n inbuxa get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }

# A one-off server pod from ../spike, on this image and these listener ports.
# It carries the chart's server labels, so the chart's deny-all and server
# NetworkPolicies cover it, as the lab's Kyverno policy requires.
LABELS='app.kubernetes.io/name: inbuxa, app.kubernetes.io/instance: inbuxa, app.kubernetes.io/component: server'

run_pod() {
  local file="$1" name="$2"
  "${K[@]}" -n inbuxa delete pod "$name" --ignore-not-found --wait >/dev/null
  sed -e "s|image: inbuxa-lab/server:rc27|image: $IMAGE|" \
      -e "s|imagePullPolicy: Never|imagePullPolicy: $PULL|" \
      -e "s|^  name: $name\$|  name: $name\n  labels: {$LABELS}|" -e '/^  labels: {app: inbuxa-setup}$/d' \
      -e "s|        - {name: INBUXA_HOSTNAME, value: $name}|        - {name: INBUXA_HOSTNAME, value: $name}\n        - {name: INBUXA_LISTENER_PORTS, value: \"$PORTS\"}|" \
      "../spike/$file" | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" -n inbuxa wait --for=condition=Ready "pod/$name" --timeout=180s >/dev/null
}

# Port-forward 18080 to a pod's 8080 until stop_forward; waits for it to
# answer. The port-forward is started again if it exits, as it does when
# the one before it hasn't let go of 18080 yet.
FORWARD_PID=""
forward() {
  for _ in $(seq 1 60); do
    if [ -z "$FORWARD_PID" ] || ! kill -0 "$FORWARD_PID" 2>/dev/null; then
      "${K[@]}" -n inbuxa port-forward "pod/$1" 18080:8080 >/dev/null 2>&1 &
      FORWARD_PID=$!
    fi
    curl -fsS -o /dev/null http://127.0.0.1:18080/healthz/live 2>/dev/null && return 0
    sleep 1
  done
  echo "!! $1 never answered on 8080" >&2
  return 1
}
stop_forward() {
  [ -n "$FORWARD_PID" ] || return 0
  kill "$FORWARD_PID" 2>/dev/null
  wait "$FORWARD_PID" 2>/dev/null || true
  FORWARD_PID=""
}
trap stop_forward EXIT

# The one-off pods' config.json (the chart's own pods have theirs)
"${K[@]}" apply -f ../spike/server-common.yaml >/dev/null

echo "== stopping everything on the old store"
"${K[@]}" -n inbuxa scale deploy --all --replicas=0 >/dev/null 2>&1 || true
"${K[@]}" -n inbuxa wait --for=delete pod -l app.kubernetes.io/component=server --timeout=180s >/dev/null 2>&1 || true
"${K[@]}" -n inbuxa wait --for=delete pod -l app=inbuxa-server --timeout=180s >/dev/null 2>&1 || true

echo "== a fresh database"
primary="$("${K[@]}" -n data get cluster inbuxa-pg -o jsonpath='{.status.currentPrimary}')"
"${K[@]}" -n data exec "$primary" -c postgres -- psql -q -v ON_ERROR_STOP=1 \
  -c 'DROP DATABASE IF EXISTS inbuxa WITH (FORCE)' -c 'CREATE DATABASE inbuxa OWNER inbuxa'

echo "== first boot"
run_pod bootstrap-pod.yaml inbuxa-bootstrap
forward inbuxa-bootstrap
BOOTSTRAP_ADMIN="$(secret inbuxa-recovery admin)" ADMIN_OUT="$STATE/admin.json" \
  python3 ../spike/bootstrap.py http://127.0.0.1:18080 "mail.$DOMAIN" "$DOMAIN"
stop_forward
"${K[@]}" -n inbuxa delete pod inbuxa-bootstrap --wait >/dev/null

echo "== blob store, coordinator, role groups, a mail account"
run_pod setup-pod.yaml inbuxa-setup
forward inbuxa-setup
RECOVERY_ADMIN="$(secret inbuxa-recovery admin)" S3_ACCESS_KEY="$(secret inbuxa-s3 access-key)" \
  python3 ../spike/setup-registry.py http://127.0.0.1:18080 all >"$STATE/setup.log" \
  || { cat "$STATE/setup.log" >&2; exit 1; }
grep -E " OK$" "$STATE/setup.log"
RECOVERY_ADMIN="$(secret inbuxa-recovery admin)" PASSWORD_FILE="$STATE/alice.password" \
  python3 accounts.py http://127.0.0.1:18080 "$DOMAIN" alice
stop_forward
"${K[@]}" -n inbuxa delete pod inbuxa-setup --wait >/dev/null

echo "== done: alice@$DOMAIN, password in $STATE/alice.password"
