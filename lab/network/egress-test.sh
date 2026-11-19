#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C7: the chart's egress check. An HAProxy on the kind network stands in
# for server.egress.checkUrl, answering with the caller's address. The mta
# pods are placed on one node (nodeSelector), and kind sends a pod's traffic
# out from its node's address, so that's the address outbound mail leaves
# from. Each install leaves an event on the mta Deployment:
#
#   1. that node's address expected: Normal EgressAddress
#   2. only a documentation address expected: Warning EgressMismatch
#   3. a checkUrl that doesn't answer: Warning EgressUnknown, and the install
#      still succeeds
#
# Leaves the chart as it found it and removes HAProxy.
#
#   SERVER_TAG=kc6 WEBMAIL_TAG=kw3 lab/network/egress-test.sh
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.0-alpine}"
NODE="${NODE:-inbuxa-lab-worker3}"
fails=0

install() { # [helm args]: the lab's install, with the webmail and console
  helm --kube-context kind-inbuxa-lab -n inbuxa upgrade inbuxa "$CHART" \
    -f ../chart/values-lab.yaml -f ../chart/values-frontends.yaml --set server.image.tag="$SERVER_TAG" \
    "${EXTRA[@]}" "$@" --wait --timeout 10m >/dev/null
  for d in front mta; do "${K[@]}" rollout status deploy/inbuxa-$d --timeout 5m >/dev/null; done
}
cfg=$(mktemp)
cleanup() {
  rm -f "$cfg"
  docker rm -f inbuxa-lab-ipecho >/dev/null 2>&1 || true
  install >/dev/null 2>&1 || echo "!! couldn't put the chart back: run frontends-test.sh" >&2
}
trap cleanup EXIT

# The last event the check left: "<type> <reason>: <message>"
last_event() {
  "${K[@]}" get events --field-selector involvedObject.name=inbuxa-mta,source=inbuxa-egress-check \
    --sort-by=.lastTimestamp -o jsonpath='{range .items[*]}{.type} {.reason}: {.message}{"\n"}{end}' | tail -1
}
check() { # <name> <event> <type reason>
  case "$2" in
    "$3"*) echo "ok   $1: $2" ;;
    *) echo "FAIL $1: got \"$2\", want $3"; fails=$((fails + 1)) ;;
  esac
}

printf 'defaults\n  mode http\n  timeout connect 5s\n  timeout client 30s\n  timeout server 30s\nfrontend echo\n  bind :8080\n  http-request return status 200 content-type text/plain lf-string "%%[src]\\n"\n' >"$cfg"
chmod 644 "$cfg"
docker rm -f inbuxa-lab-ipecho >/dev/null 2>&1 || true
docker run -d --name inbuxa-lab-ipecho --network kind -v "$cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" "$HAPROXY_IMAGE" >/dev/null
ECHO=$(docker inspect inbuxa-lab-ipecho -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
NODE_IP=$("${K[@]}" get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "     address echo at $ECHO; mta pods on $NODE ($NODE_IP)"
PLACE=(--set-json "server.groups.mta.nodeSelector={\"kubernetes.io/hostname\":\"$NODE\"}"
  --set server.egress.checkUrl="http://$ECHO:8080/")

echo "== 1. the node's address expected"
install "${PLACE[@]}" --set-json "server.egress.expectedAddresses=[\"198.51.100.7\",\"$NODE_IP\"]"
check "as expected" "$(last_event)" "Normal EgressAddress"

echo "== 2. another address expected"
install "${PLACE[@]}" --set-json 'server.egress.expectedAddresses=["198.51.100.7"]'
check "mismatch" "$(last_event)" "Warning EgressMismatch"

echo "== 3. a checkUrl that doesn't answer"
install "${PLACE[@]}" --set-json "server.egress.expectedAddresses=[\"$NODE_IP\"]" \
  --set server.egress.checkUrl="http://$ECHO:9/"
check "unknown, install still fine" "$(last_event)" "Warning EgressUnknown"

echo
[ "$fails" = 0 ] && echo "== all pass" || { echo "== $fails failed"; exit 1; }
