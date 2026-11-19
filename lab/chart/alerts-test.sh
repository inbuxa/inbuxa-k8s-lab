#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C10: the chart's alert rules, in a real Prometheus, quiet on a healthy
# install and firing when things break.
#
# Prometheus runs on its own in the monitoring namespace (no operator): it
# scrapes the server pods as the chart's ServiceMonitor does, and loads the
# rules from the chart's PrometheusRule, every `for` cut to 0s so a test
# doesn't wait out the hold times.
#
#   1. quiet: the lab as it is, with the chart's thresholds: nothing fires.
#   2. breakage, each checked for the alert it should raise:
#      - a server process stopped (SIGSTOP on its node): InbuxaServerDown
#      - a front pod cut off from Postgres: InbuxaClusterLeaseNotRenewed
#      - mail to a host that never answers (wait.lab.test, added to the
#        lab's CoreDNS for the test) waits in the queue:
#        InbuxaQueueLarge, InbuxaQueueMessageWaiting (thresholds lowered)
#      - mail to example.com (a null MX) bounces: InbuxaDeliveriesFailing
#      - a certificate that runs out in two days: InbuxaCertificateExpiring
#      - InbuxaDataStoreSlow with a threshold any store time crosses: the
#        expression reads real series.
# The kube-state-metrics alerts are left out: the lab doesn't run it.
#
# Puts everything back: the chart, CoreDNS, the network policy, the stopped
# process, the queued test mail, the certificate, and the monitoring
# namespace.
#
#   SERVER_TAG=kc10 WEBMAIL_TAG=kw3 lab/chart/alerts-test.sh
set -euo pipefail

cd "$(dirname "$0")"
CTX=kind-inbuxa-lab
K=(kubectl --context "$CTX" -n inbuxa)
M=(kubectl --context "$CTX" -n monitoring)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v3.5.0}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
PORT="${PORT:-28080}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
METRICS=(--set server.metrics.prometheus.enabled=true)
fails=0
work=$(mktemp -d)
stopped=""   # node and pid of a stopped server process
cut=""       # the pod cut off from Postgres
fwd=""
cert=""      # the test certificate's id
corefile=""  # CoreDNS's Corefile before the test's name was added
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

install() { # [helm args]
  helm --kube-context "$CTX" -n inbuxa upgrade inbuxa "$CHART" \
    -f values-lab.yaml -f values-frontends.yaml --set server.image.tag="$SERVER_TAG" \
    "${EXTRA[@]}" "$@" --wait --timeout 10m >/dev/null
  for d in front mta core; do "${K[@]}" rollout status deploy/inbuxa-$d --timeout 5m >/dev/null; done
}
cleanup() {
  [ -n "$corefile" ] && dns_restore
  [ -n "$stopped" ] && docker exec "${stopped% *}" kill -CONT "${stopped#* }" 2>/dev/null || true
  kubectl --context "$CTX" -n data delete networkpolicy lab-cut-off --ignore-not-found >/dev/null 2>&1 || true
  [ -n "$cut" ] && "${K[@]}" label pod "$cut" lab.inbuxa.org/cut-off- >/dev/null 2>&1 || true
  if [ -n "$fwd" ] || forward; then
    python3 queue-clean.py "http://127.0.0.1:$PORT" "$STATE/admin.password" alice@lab.test "$START" >/dev/null ||
      echo "!! couldn't remove the test mail from the queue" >&2
    [ -n "$cert" ] && { echo "[[\"x:Certificate/set\", {\"destroy\": [\"$cert\"]}, \"d\"]]" |
      admin_jmap >/dev/null || echo "!! couldn't remove the test certificate $cert" >&2; }
  fi
  [ -n "$fwd" ] && kill "$fwd" 2>/dev/null || true
  kubectl --context "$CTX" delete namespace monitoring --ignore-not-found --wait=false >/dev/null 2>&1 || true
  install >/dev/null 2>&1 || echo "!! couldn't put the chart back: run frontends-test.sh" >&2
  rm -rf "$work"
}
trap cleanup EXIT

check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}
prom() { # <path>: GET from Prometheus
  "${M[@]}" exec deploy/prometheus -- wget -qO- "http://localhost:9090$1"
}
firing() { # the Inbuxa alerts firing, sorted, one per line
  prom /api/v1/alerts | python3 -c '
import json, sys
names = {a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"]
         if a["state"] == "firing" and a["labels"]["alertname"].startswith("Inbuxa")}
if names:
    print("\n".join(sorted(names)))'
}
wait_for() { # <alert> <seconds>: until it fires
  local t=0
  while [ "$t" -lt "$2" ]; do
    firing | grep -qx "$1" && { echo "ok   $1 fired (${t}s)"; return; }
    sleep 5; t=$((t + 5))
  done
  echo "FAIL $1 didn't fire in $2s"; fails=$((fails + 1))
}
rules() { # [helm args]: the chart's rules as a Prometheus rules file, every for 0s
  helm template inbuxa "$CHART" -n inbuxa -f values-lab.yaml --set server.image.tag="$SERVER_TAG" \
    "${METRICS[@]}" --set server.metrics.prometheus.serviceMonitor.enabled=true \
    --set server.metrics.prometheus.rules.enabled=true \
    --set server.metrics.prometheus.rules.kubeStateMetrics=false "$@" \
    --show-only templates/server/metrics.yaml | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc["kind"] == "PrometheusRule":
        for group in doc["spec"]["groups"]:
            for rule in group["rules"]:
                rule["for"] = "0s"
        print(yaml.safe_dump({"groups": doc["spec"]["groups"]}, sort_keys=False))'
}
load_rules() { # [helm args]: new rules into Prometheus, reloaded
  rules "$@" >"$work/rules.yml"
  "${M[@]}" create configmap prometheus-rules --from-file=rules.yml="$work/rules.yml" \
    --dry-run=client -o yaml | "${M[@]}" apply -f - >/dev/null
  # The kubelet takes up to a minute to update the mounted file
  for _ in $(seq 40); do
    "${M[@]}" exec deploy/prometheus -- cat /etc/prometheus/rules/rules.yml 2>/dev/null |
      cmp -s - "$work/rules.yml" && break
    sleep 3
  done
  "${M[@]}" exec deploy/prometheus -- wget -qO- --post-data= http://localhost:9090/-/reload >/dev/null
}
forward() {
  "${K[@]}" port-forward svc/inbuxa-http "$PORT:8080" >/dev/null 2>&1 &
  fwd=$!
  for _ in $(seq 20); do curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz/live" && return 0; sleep 1; done
  return 1
}
# wait.lab.test, for mail that has to wait: an address in TEST-NET-2 that
# nothing answers, so delivery fails for now and is retried. Added to the
# lab's CoreDNS for the test (its reload plugin picks it up, which can
# take a couple of minutes) and taken out
# after.
dns_add() {
  corefile=$(kubectl --context "$CTX" -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
  printf '%s' "$corefile" >"$work/Corefile.orig"
  python3 - "$work/Corefile.orig" >"$work/Corefile" <<'EOF2'
import sys
s = open(sys.argv[1]).read()
anchor = "    forward . /etc/resolv.conf"
assert anchor in s
print(s.replace(anchor, "    hosts {\n       198.51.100.1 wait.lab.test\n       fallthrough\n    }\n" + anchor, 1), end="")
EOF2
  kubectl --context "$CTX" -n kube-system create configmap coredns --from-file=Corefile="$work/Corefile" \
    --dry-run=client -o yaml | kubectl --context "$CTX" -n kube-system apply -f - >/dev/null 2>&1
}
dns_restore() {
  kubectl --context "$CTX" -n kube-system create configmap coredns --from-file=Corefile="$work/Corefile.orig" \
    --dry-run=client -o yaml | kubectl --context "$CTX" -n kube-system apply -f - >/dev/null 2>&1 ||
    echo "!! couldn't restore CoreDNS's Corefile: it's in $work/Corefile.orig" >&2
}
dns_resolves() { # whether a server pod resolves wait.lab.test yet
  "${K[@]}" exec deploy/inbuxa-core -c server -- sh -c 'getent hosts wait.lab.test || curl -s -m 2 -o /dev/null http://wait.lab.test; [ $? -ne 6 ]' >/dev/null 2>&1
}
admin_jmap() { # JMAP calls on stdin, as admin@lab.test
  python3 admin-jmap.py "http://127.0.0.1:$PORT" "$STATE/admin.password"
}
send() { # <count> <recipient>: messages from alice, over submissions
  LB="$LB" PASSWORD_FILE="$STATE/alice.password" python3 - "$@" <<'EOF'
import os, smtplib, ssl, sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
tls = ssl.create_default_context(); tls.check_hostname = False; tls.verify_mode = ssl.CERT_NONE
password = open(os.environ["PASSWORD_FILE"]).read().strip()
with smtplib.SMTP_SSL(os.environ["LB"], 465, context=tls, timeout=30) as s:
    s.login("alice@lab.test", password)
    for i in range(int(sys.argv[1])):
        m = EmailMessage()
        m["From"] = "alice@lab.test"; m["To"] = sys.argv[2]
        m["Subject"] = f"alerts-test {i}"; m["Date"] = formatdate()
        m["Message-ID"] = make_msgid(domain="lab.test")
        m.set_content("Sent by the inbuxa-k8s-lab alerts test.\n")
        s.send_message(m)
EOF
}

echo "== the chart, with scraping on"
install "${METRICS[@]}"
LB=$("${K[@]}" get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "== Prometheus"
kubectl --context "$CTX" create namespace monitoring --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
"${M[@]}" create secret generic inbuxa-scrape \
  --from-literal=password="$("${K[@]}" get secret inbuxa-metrics -o jsonpath='{.data.password}' | base64 -d)" \
  --dry-run=client -o yaml | "${M[@]}" apply -f - >/dev/null
rules >"$work/rules.yml"
"${M[@]}" create configmap prometheus-rules --from-file=rules.yml="$work/rules.yml" \
  --dry-run=client -o yaml | "${M[@]}" apply -f - >/dev/null
kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: prometheus, namespace: monitoring}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: lab-prometheus, namespace: inbuxa}
rules:
  - apiGroups: [""]
    resources: [services, pods, endpoints]
    verbs: [get, list, watch]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: lab-prometheus, namespace: inbuxa}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: lab-prometheus}
subjects: [{kind: ServiceAccount, name: prometheus, namespace: monitoring}]
---
apiVersion: v1
kind: ConfigMap
metadata: {name: prometheus-config, namespace: monitoring}
data:
  prometheus.yml: |
    global: {scrape_interval: 5s, scrape_timeout: 4s, evaluation_interval: 5s}
    rule_files: [/etc/prometheus/rules/rules.yml]
    scrape_configs:
      # What the chart's ServiceMonitor asks the operator for
      - job_name: inbuxa
        metrics_path: /metrics/prometheus
        basic_auth: {username: prometheus, password_file: /etc/prometheus/scrape/password}
        kubernetes_sd_configs: [{role: endpointslice, namespaces: {names: [inbuxa]}}]
        relabel_configs:
          - {source_labels: [__meta_kubernetes_service_label_inbuxa_org_metrics], regex: "true", action: keep}
          - {source_labels: [__meta_kubernetes_endpointslice_port_name], regex: http, action: keep}
          - {source_labels: [__meta_kubernetes_service_name], target_label: job}
          - {source_labels: [__meta_kubernetes_namespace], target_label: namespace}
          - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
          - {source_labels: [__meta_kubernetes_pod_label_inbuxa_org_group], target_label: inbuxa_org_group}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: prometheus, namespace: monitoring}
spec:
  replicas: 1
  selector: {matchLabels: {app: prometheus}}
  template:
    metadata: {labels: {app: prometheus}}
    spec:
      serviceAccountName: prometheus
      securityContext: {runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: prometheus
          image: $PROM_IMAGE
          imagePullPolicy: Never
          args: [--config.file=/etc/prometheus/prometheus.yml, --storage.tsdb.path=/prometheus, --web.enable-lifecycle]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus/prometheus.yml, subPath: prometheus.yml}
            - {name: rules, mountPath: /etc/prometheus/rules}
            - {name: scrape, mountPath: /etc/prometheus/scrape}
            - {name: data, mountPath: /prometheus}
      volumes:
        - {name: config, configMap: {name: prometheus-config}}
        - {name: rules, configMap: {name: prometheus-rules}}
        - {name: scrape, secret: {secretName: inbuxa-scrape}}
        - {name: data, emptyDir: {}}
EOF
"${M[@]}" rollout status deploy/prometheus --timeout 3m >/dev/null
for _ in $(seq 40); do prom /-/ready >/dev/null 2>&1 && break; sleep 3; done
for _ in $(seq 30); do
  up=$(prom '/api/v1/query?query=sum(up%7Bjob%3D%22inbuxa-metrics%22%7D)' 2>/dev/null | python3 -c '
import json, sys
try: r = json.load(sys.stdin)["data"]["result"]
except Exception: r = []
print(int(float(r[0]["value"][1])) if r else 0)')
  [ "$up" = 5 ] && break
  sleep 3
done
check "Prometheus scrapes the five server pods" "$up" 5
rules_loaded=$(prom /api/v1/rules | python3 -c 'import json, sys; print(sum(len(g["rules"]) for g in json.load(sys.stdin)["data"]["groups"]))')
check "rules loaded" "$rules_loaded" 7

echo "== 1. quiet while nothing is wrong"
sleep 60
check "alerts firing on a healthy install" "$(firing | paste -sd " ")" ""

echo "== 2. breakage"
forward || { echo "!! no port-forward to the server" >&2; exit 1; }

echo "-- a certificate that runs out in two days"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
  -subj "/CN=alerts.lab.test" -addext "subjectAltName=DNS:alerts.lab.test" \
  -keyout "$work/cert.key" -out "$work/cert.crt" 2>/dev/null
cert=$(python3 - "$work/cert.crt" "$work/cert.key" <<'EOF2' | admin_jmap | python3 -c '
import json, sys; r = json.load(sys.stdin)[0][1]; print(r.get("created", {}).get("c", {}).get("id", ""))'
import json, sys
print(json.dumps([["x:Certificate/set", {"create": {"c": {
    "certificate": {"@type": "Text", "value": open(sys.argv[1]).read()},
    "privateKey": {"@type": "Text", "secret": open(sys.argv[2]).read()}}}}, "s"]]))
EOF2
)
[ -n "$cert" ] || { echo "FAIL couldn't store the test certificate"; fails=$((fails + 1)); }
wait_for InbuxaCertificateExpiring 90
# Lower thresholds: two queued messages, a minute's wait, any store time,
# two bounces
load_rules --set server.metrics.prometheus.rules.queueMessages=1 \
  --set-json server.metrics.prometheus.rules.queueOldestHours=0.015 \
  --set-json server.metrics.prometheus.rules.storeLatencyMs=0.001 \
  --set-json server.metrics.prometheus.rules.deliveryFailureRatio=0.01 \
  --set server.metrics.prometheus.rules.deliveryFailureMinimum=2

echo "-- a server process stopped"
victim=$("${K[@]}" get pods -l inbuxa.org/group=mta -o jsonpath='{.items[0].metadata.name}')
node=$("${K[@]}" get pod "$victim" -o jsonpath='{.spec.nodeName}')
cid=$("${K[@]}" get pod "$victim" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|.*://||')
pid=$(docker exec "$node" crictl inspect --output go-template --template '{{.info.pid}}' "$cid")
docker exec "$node" kill -STOP "$pid"
stopped="$node $pid"
wait_for InbuxaServerDown 45
docker exec "$node" kill -CONT "$pid"
stopped=""

echo "-- mail that waits, and mail that bounces"
dns_add
for _ in $(seq 60); do dns_resolves && break; sleep 3; done
dns_resolves || { echo "FAIL wait.lab.test doesn't resolve"; fails=$((fails + 1)); }
# The stopped pod is back in a moment; a connection that lands on it
# before then is tried again
for attempt in 1 2 3 4 5 6; do
  # wait.lab.test never answers, which is retried; example.com publishes a
  # null MX (RFC 7505), which bounces at once
  send 3 "lab-wait@wait.lab.test" 2>/dev/null && send 3 "lab-bounce@example.com" 2>/dev/null && break
  [ "$attempt" = 6 ] && { echo "FAIL couldn't send the test mail"; fails=$((fails + 1)); }
  sleep 10
done

echo "-- a front pod cut off from Postgres"
cut=$("${K[@]}" get pods -l inbuxa.org/group=front -o jsonpath='{.items[0].metadata.name}')
cut_ip=$("${K[@]}" get pod "$cut" -o jsonpath='{.status.podIP}')
"${K[@]}" label pod "$cut" lab.inbuxa.org/cut-off=true >/dev/null
kubectl --context "$CTX" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: lab-cut-off, namespace: data}
spec:
  podSelector: {matchLabels: {cnpg.io/cluster: inbuxa-pg}}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: cnpg-system}}
        - podSelector: {matchLabels: {cnpg.io/cluster: inbuxa-pg}}
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: inbuxa}}
          podSelector:
            matchExpressions: [{key: lab.inbuxa.org/cut-off, operator: DoesNotExist}]
EOF
# The policy stops new connections; end the ones the pod holds
sleep 5
kubectl --context "$CTX" -n data exec inbuxa-pg-1 -c postgres -- psql -qtA -U postgres -c \
  "select count(pg_terminate_backend(pid)) from pg_stat_activity where client_addr = '$cut_ip'" >/dev/null


# The lease alert needs five minutes without a renewal, the queue gauges
# the core's next count (every five minutes)
wait_for InbuxaDataStoreSlow 60
wait_for InbuxaDeliveriesFailing 180
wait_for InbuxaQueueLarge 360
wait_for InbuxaQueueMessageWaiting 360
wait_for InbuxaClusterLeaseNotRenewed 420

echo "-- back to normal"
kubectl --context "$CTX" -n data delete networkpolicy lab-cut-off >/dev/null
"${K[@]}" label pod "$cut" lab.inbuxa.org/cut-off- >/dev/null
cut=""

echo
if [ "$fails" -eq 0 ]; then echo "alerts-test: all passed"; else echo "alerts-test: $fails failed"; exit 1; fi
