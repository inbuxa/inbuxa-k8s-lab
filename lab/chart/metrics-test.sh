#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C10: metrics. Installs with server.metrics.prometheus and .otlp on, then
# checks, for every server pod:
#   - /metrics/prometheus refuses no password and a wrong one, and answers
#     the chart's password with the gauges the alerts read;
#   - its cluster lease was renewed in the last two and a half minutes;
#   - the headless metrics Service lists it;
#   - it pushes OTLP to a collector, with the header from the Secret (the
#     collector sees the nodes' addresses, so this counts pushes).
# The collector is HAProxy on the kind network, answering 200 and logging
# each request with its Authorization header.
#
# Leaves the chart as it found it, and removes the collector and the Secret.
#
#   SERVER_TAG=kc10 WEBMAIL_TAG=kw3 lab/chart/metrics-test.sh
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.0-alpine}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
SINK=inbuxa-lab-otlp
HEADERS=inbuxa-lab-otlp
TOKEN="Bearer lab-otlp-$RANDOM$RANDOM"
fails=0

install() { # [helm args]: the lab's install, with the webmail and console
  helm --kube-context kind-inbuxa-lab -n inbuxa upgrade inbuxa "$CHART" \
    -f values-lab.yaml -f values-frontends.yaml --set server.image.tag="$SERVER_TAG" \
    "${EXTRA[@]}" "$@" --wait --timeout 10m >/dev/null
  for d in front mta core; do "${K[@]}" rollout status deploy/inbuxa-$d --timeout 5m >/dev/null; done
}
work=$(mktemp -d)
cleanup() {
  install >/dev/null 2>&1 || echo "!! couldn't put the chart back: run frontends-test.sh" >&2
  "${K[@]}" delete secret "$HEADERS" --ignore-not-found >/dev/null
  docker rm -f "$SINK" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

settle() { # until the last rollout's old pods are gone
  for _ in $(seq 60); do
    [ -z "$("${K[@]}" get pods -l app.kubernetes.io/component=server -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}')" ] && return
    sleep 3
  done
}
check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}
scrape() { # <pod ip> [curl args]: the status code, the body in $work/body
  "${K[@]}" exec deploy/inbuxa-core -c server -- \
    curl -s -m 10 -o /dev/stdout -w '\n%{http_code}' "${@:2}" "http://$1:8080/metrics/prometheus" >"$work/out" || true
  sed '$d' "$work/out" >"$work/body"
  tail -n1 "$work/out"
}
gauge() { # <name>: its value in $work/body, as an integer
  awk -v n="$1" '$1 == n { printf "%d", $2 }' "$work/body"
}

echo "== the collector"
cat >"$work/haproxy.cfg" <<'EOF'
global
  log stdout format raw local0
defaults
  mode http
  log global
  timeout client 30s
  timeout server 30s
  timeout connect 5s
frontend otlp
  bind :4318
  http-request capture req.hdr(authorization) len 64
  log-format "%ci %HM %HP %hr"
  http-request return status 200
EOF
docker rm -f "$SINK" >/dev/null 2>&1 || true
docker run -d --name "$SINK" --network kind -v "$work/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" "$HAPROXY_IMAGE" >/dev/null
SINK_IP=$(docker inspect "$SINK" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
[ -n "$SINK_IP" ] || { docker logs "$SINK" >&2; echo "!! the collector didn't start" >&2; exit 1; }
printf 'authorization=%s\n' "$TOKEN" >"$work/headers"
"${K[@]}" create secret generic "$HEADERS" --from-file=headers="$work/headers" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null

echo "== install with metrics on"
install --set server.metrics.prometheus.enabled=true \
  --set server.metrics.otlp.enabled=true \
  --set server.metrics.otlp.endpoint="http://$SINK_IP:4318" \
  --set server.metrics.otlp.intervalSeconds=5 \
  --set server.metrics.otlp.headersSecret="$HEADERS"
settle
PW=$("${K[@]}" get secret inbuxa-metrics -o jsonpath='{.data.password}' | base64 -d)
USER=$("${K[@]}" get secret inbuxa-metrics -o jsonpath='{.data.username}' | base64 -d)
mapfile -t PODS < <("${K[@]}" get pods -l app.kubernetes.io/component=server \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}')
check "five server pods" "${#PODS[@]}" 5

echo "== the metrics Service lists every pod"
listed=$("${K[@]}" get endpointslices -l kubernetes.io/service-name=inbuxa-metrics \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' | sort -u | wc -l)
check "inbuxa-metrics endpoints" "$listed" 5

echo "== scraping"
first_ip=$(echo "${PODS[0]}" | cut -d' ' -f2)
check "no password: refused" "$(scrape "$first_ip")" 401
check "wrong password: refused" "$(scrape "$first_ip" -u "$USER:not-it")" 401
now=$(date +%s)
for p in "${PODS[@]}"; do
  name=${p% *}; ip=${p#* }
  check "$name: the chart's password" "$(scrape "$ip" -u "$USER:$PW")" 200
  for m in queue_count queue_oldest_message cluster_lease_renewed tls_earliest_expiry server_memory; do
    grep -q "^$m " "$work/body" || { echo "FAIL $name: no $m"; fails=$((fails + 1)); }
  done
  renewed=$(gauge cluster_lease_renewed)
  age=$((now - renewed))
  if [ "$renewed" -gt 0 ] && [ "$age" -le 150 ]; then
    echo "ok   $name: lease renewed ${age}s ago"
  else
    echo "FAIL $name: lease renewed at $renewed (${age}s ago)"; fails=$((fails + 1))
  fi
done

echo "== OTLP pushes, with the header"
sleep 20
docker logs "$SINK" 2>/dev/null | grep " POST /v1/metrics " >"$work/pushes" || true
# Pods reach the kind network through their node's address, so the
# collector sees one address per node with server pods, and every pod's
# pushes, about one per pod per interval
nodes=$("${K[@]}" get pods -l app.kubernetes.io/component=server -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
pushers=$(awk '{print $1}' "$work/pushes" | sort -u | wc -l)
check "nodes the pushes came from" "$pushers" "$nodes"
count=$(wc -l <"$work/pushes")
if [ "$count" -ge 15 ]; then echo "ok   $count pushes in the first 20s or so"; else echo "FAIL only $count pushes"; fails=$((fails + 1)); fi
bad=$(grep -vcF "{$TOKEN}" "$work/pushes" || true)
check "pushes without the token" "$bad" 0

echo
if [ "$fails" -eq 0 ]; then echo "metrics-test: all passed"; else echo "metrics-test: $fails failed"; exit 1; fi
