#!/usr/bin/env bash
# The chart's webmail and console (K-C3) on the lab's seeded install:
# installs them (values-frontends.yaml), then
#
#   - signs in to the webmail starting on one replica and finishing on the
#     other, and uses the session on both (signin.py)
#   - signs in to the console as its browser would (console-signin.py)
#
#   SERVER_TAG=plan lab/chart/frontends-test.sh
#   SERVER_TAG=plan WEBMAIL_TAG=kw4 lab/chart/frontends-test.sh
#
# WEBMAIL_TAG picks another inbuxa-lab/webmail image than the one in
# values-frontends.yaml.
set -euo pipefail

cd "$(dirname "$0")"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
K=(kubectl --context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
forward() { # <local port> <target>
  "${K[@]}" port-forward "$2" "$1:8080" >/dev/null 2>&1 &
  PIDS+=($!)
}

echo "== install the webmail and the console"
helm --kube-context kind-inbuxa-lab -n inbuxa upgrade inbuxa "$CHART" \
  -f values-lab.yaml -f values-frontends.yaml --set server.image.tag="$SERVER_TAG" "${EXTRA[@]}" \
  --wait --timeout 10m >/dev/null
"${K[@]}" get pods -l 'app.kubernetes.io/component in (webmail,console)' --no-headers

# helm --wait returns before the old pods are gone: pick from the new ones
"${K[@]}" rollout status deployment/inbuxa-webmail --timeout 5m >/dev/null
sleep 5
mapfile -t webmail < <("${K[@]}" get pods -l app.kubernetes.io/component=webmail \
  --field-selector status.phase=Running -o name | sort)
[ "${#webmail[@]}" -ge 2 ] || { echo "!! fewer than two webmail pods"; exit 1; }
forward 18081 "${webmail[0]}"
forward 18082 "${webmail[1]}"
forward 18080 svc/inbuxa-http
forward 18083 svc/inbuxa-console
sleep 3

echo "== webmail: start on ${webmail[0]#pod/}, finish on ${webmail[1]#pod/}"
python3 signin.py http://127.0.0.1:18081 http://127.0.0.1:18082 http://127.0.0.1:18080 \
  alice@lab.test "$STATE/alice.password"

echo "== console"
python3 console-signin.py http://127.0.0.1:18083 http://127.0.0.1:18080 \
  https://admin.lab.test https://mail.lab.test admin@lab.test "$STATE/admin.password"

echo "== both pass"
