#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C5: the server pods' pre-flight check (inbuxa --check, the chart's
# init container) names the part of the data layer it can't use, and why, in
# the pod's status. Each case runs a pod shaped like the chart's server pod,
# in a scratch namespace under Pod Security "restricted", with the lab's
# config.json and secrets, one of them broken on purpose:
#
#   nothing broken                 the pod starts
#   wrong PostgreSQL password      data store: credentials refused (77)
#   wrong S3 secret key            blob store: credentials refused (77)
#   wrong NATS password            coordinator: credentials refused (77)
#   NATS not reachable             coordinator: unreachable (69)
#   S3 not reachable               blob store: unreachable (69)
#
# Needs a server image with --check (27.1-rc.32): SERVER_TAG, or what the
# lab's server pods run.
#
#   lab/chart/check-test.sh
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab)
NS=check-test
IMAGE="${SERVER_TAG:+inbuxa-lab/server:$SERVER_TAG}"
IMAGE="${IMAGE:-$("${K[@]}" -n inbuxa get deploy inbuxa-front -o jsonpath='{.spec.template.spec.containers[0].image}')}"
fails=0

"${K[@]}" create namespace "$NS" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" label --overwrite namespace "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null
"${K[@]}" -n inbuxa get configmap inbuxa-server -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "server"}, "data": d["data"]}))' |
  "${K[@]}" -n "$NS" apply -f - >/dev/null

# secrets [key=wrong]...: the lab's secrets, as the pods see them, with any
# key named replaced by a wrong value. Nothing is printed.
secrets() {
  { "${K[@]}" -n inbuxa get secret inbuxa-data -o json; "${K[@]}" -n inbuxa get secret inbuxa-s3 -o json; } |
    python3 -c '
import base64, json, sys
docs, text = [], sys.stdin.read()
dec = json.JSONDecoder(); i = 0
while i < len(text):
    if text[i].isspace(): i += 1; continue
    d, i = dec.raw_decode(text, i); docs.append(d)
files = {"pg-password": docs[0]["data"]["pg-password"], "nats-password": docs[0]["data"]["nats-password"],
         "s3-secret-key": docs[1]["data"]["secret-key"]}
for name in sys.argv[1:]:
    files[name] = base64.b64encode(b"wrong-on-purpose").decode()
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "secrets"}, "data": files}))' "$@" |
    "${K[@]}" -n "$NS" apply -f - >/dev/null
}

# block nats|s3: that service refuses this namespace and no other. It's
# done on the service's side, with a policy in "data": the lab's CNI
# (kindnet) enforces ingress rules, not egress ones.
block() {
  local selector
  case $1 in
    nats) selector='{"matchLabels":{"app.kubernetes.io/name":"nats","app.kubernetes.io/component":"nats"}}' ;;
    s3) selector='{"matchLabels":{"app":"garage"}}' ;;
  esac
  echo "{\"apiVersion\":\"networking.k8s.io/v1\",\"kind\":\"NetworkPolicy\",
    \"metadata\":{\"name\":\"check-test-block\",\"namespace\":\"data\"},
    \"spec\":{\"podSelector\":$selector,\"policyTypes\":[\"Ingress\"],\"ingress\":[{\"from\":[{\"namespaceSelector\":
      {\"matchExpressions\":[{\"key\":\"kubernetes.io/metadata.name\",\"operator\":\"NotIn\",\"values\":[\"$NS\"]}]}}]}]}}" |
    "${K[@]}" apply -f - >/dev/null
  # The CNI takes a moment to enforce a new policy
  sleep 10
}
unblock() { "${K[@]}" -n data delete networkpolicy check-test-block --ignore-not-found >/dev/null; }
trap 'unblock; "${K[@]}" delete namespace "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

pod() { # <name>: the chart's server pod, cut down to the check and a stand-in
  cat <<EOF | "${K[@]}" -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 2000, runAsGroup: 2000, fsGroup: 2000, seccompProfile: {type: RuntimeDefault}}
  initContainers:
    - name: check
      image: $IMAGE
      imagePullPolicy: Never
      args: ["--config", "/etc/inbuxa/config.json", "--check"]
      terminationMessagePolicy: FallbackToLogsOnError
      env: [{name: INBUXA_HOSTNAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts:
        - {name: config, mountPath: /etc/inbuxa/config.json, subPath: config.json, readOnly: true}
        - {name: secrets, mountPath: /etc/inbuxa/secrets, readOnly: true}
        - {name: tmp, mountPath: /tmp}
  containers:
    - name: server
      image: $IMAGE
      imagePullPolicy: Never
      command: ["sh", "-c", "exit 0"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
  volumes:
    - {name: config, configMap: {name: server}}
    - {name: secrets, secret: {secretName: secrets, defaultMode: 0440}}
    - {name: tmp, emptyDir: {}}
EOF
}

# case_ <name> <exit code> <words> [secrets args] [-- nats|s3]
case_() {
  local name=$1 want=$2 words=$3; shift 3
  local keys=() blocked=""
  while [ $# -gt 0 ] && [ "$1" != -- ]; do keys+=("$1"); shift; done
  [ "${1:-}" = -- ] && blocked=$2
  secrets "${keys[@]}"
  unblock
  [ -z "$blocked" ] || block "$blocked"
  local p="check-$RANDOM"
  pod "$p"
  local code="" status=""
  for _ in $(seq 120); do
    code=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}')
    [ -n "$code" ] && break
    sleep 2
  done
  sleep 1
  status=$("${K[@]}" -n "$NS" get pod "$p" --no-headers -o custom-columns=S:.status.phase,R:.status.initContainerStatuses[0].state.terminated.reason)
  local message
  message=$("${K[@]}" -n "$NS" get pod "$p" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.message}')
  # A check that passed leaves no message, only its log
  [ "$code" = 0 ] && message=$("${K[@]}" -n "$NS" logs "$p" -c check)
  if [ "$code" = "$want" ] && grep -q "$words" <<<"$message"; then
    echo "ok   $name: exit $code, $(grep -m1 "$words" <<<"$message" | cut -c1-110)"
  else
    echo "FAIL $name: exit ${code:-none} (want $want), status $status"
    sed 's/^/     /' <<<"$message"
    fails=$((fails + 1))
  fi
  "${K[@]}" -n "$NS" delete pod "$p" --wait=false >/dev/null
}

echo "== $IMAGE"
case_ "nothing broken" 0 "ok    coordinator: NATS"
case_ "wrong PostgreSQL password" 77 "data store: credentials refused" pg-password
case_ "wrong S3 secret key" 77 "blob store: credentials refused" s3-secret-key
case_ "wrong NATS password" 77 "coordinator: credentials refused" nats-password
case_ "NATS refuses this namespace" 69 "coordinator: unreachable" -- nats
case_ "S3 refuses this namespace" 69 "blob store: unreachable" -- s3

echo
[ "$fails" = 0 ] && echo "== all pass" || { echo "== $fails failed"; exit 1; }
