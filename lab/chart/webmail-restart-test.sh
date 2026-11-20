#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-W5: the webmail restarted under open tabs. webmail-tabs.py runs in a
# pod in the cluster (namespace lab-sink, the CloudNativePG image's Python)
# and goes through the webmail Service: three tabs holding live-update
# streams, and a JMAP request every 200 ms. Meanwhile the webmail
# Deployment is restarted, one pod at a time.
#
# Passes when no request failed and every stream that ended, ended cleanly
# and came back: what a browser shows no error for.
#
#   lab/chart/webmail-restart-test.sh
#   WEBMAIL_IMAGE=inbuxa-lab/webmail:kw5 lab/chart/webmail-restart-test.sh
#
# WEBMAIL_IMAGE (a local image loaded into kind) installs that webmail
# first, with values-frontends.yaml; otherwise the installed one is tested.
#
# RESTART names the Deployments restarted under the tabs, one after
# another (default inbuxa-webmail), so the same check covers the server's
# groups the webmail talks to:
#
#   RESTART="inbuxa-front inbuxa-core" lab/chart/webmail-restart-test.sh
set -euo pipefail

cd "$(dirname "$0")"
. ../versions.env
KCTX="kind-$KIND_CLUSTER"
K=(kubectl --context "$KCTX")
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
fail() { echo "!! $*" >&2; exit 1; }
trap '"${K[@]}" -n lab-sink delete pod webmail-tabs --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

if [ -n "${WEBMAIL_IMAGE:-}" ]; then
  echo "== installing the webmail $WEBMAIL_IMAGE"
  helm --kube-context "$KCTX" -n inbuxa upgrade inbuxa "$CHART" --reuse-values \
    --set webmail.image.repository="${WEBMAIL_IMAGE%:*}" --set webmail.image.tag="${WEBMAIL_IMAGE##*:}" \
    --set webmail.image.digest= --set webmail.image.pullPolicy=Never --wait --timeout 10m >/dev/null
  "${K[@]}" -n inbuxa rollout status deploy/inbuxa-webmail --timeout=5m >/dev/null
fi

echo "== the tabs, inside the cluster"
"${K[@]}" create namespace lab-sink --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n lab-sink create configmap webmail-tabs --from-file=webmail-tabs.py --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n lab-sink create secret generic webmail-tabs --from-file=password="$STATE/alice.password" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n lab-sink delete pod webmail-tabs --ignore-not-found --wait >/dev/null
"${K[@]}" -n lab-sink apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: webmail-tabs}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 2000, runAsGroup: 2000, fsGroup: 2000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: tabs
      image: $PG_IMAGE
      imagePullPolicy: IfNotPresent
      command: [python3, -u, /tabs/webmail-tabs.py, "http://inbuxa-webmail.inbuxa.svc:8080", "http://inbuxa-http.inbuxa.svc:8080"]
      env:
        - {name: ACCOUNT, value: alice@lab.test}
        - {name: PASSWORD_FILE, value: /secret/password}
        - {name: STOP_FILE, value: /tmp/stop}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts:
        - {name: tabs, mountPath: /tabs}
        - {name: secret, mountPath: /secret}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tabs, configMap: {name: webmail-tabs}}
    - {name: secret, secret: {secretName: webmail-tabs, defaultMode: 0440}}
    - {name: tmp, emptyDir: {}}
EOF
"${K[@]}" -n lab-sink wait --for=condition=Ready pod/webmail-tabs --timeout=120s >/dev/null
sleep 15
if [ "$("${K[@]}" -n lab-sink get pod webmail-tabs -o jsonpath='{.status.phase}')" != Running ]; then
  "${K[@]}" -n lab-sink logs webmail-tabs | tail -20 >&2
  fail "the tabs stopped before the restart"
fi

for d in ${RESTART:-inbuxa-webmail}; do
  image="$("${K[@]}" -n inbuxa get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "== restarting $d ($image) under them"
  "${K[@]}" -n inbuxa rollout restart "deploy/$d" >/dev/null
  "${K[@]}" -n inbuxa rollout status "deploy/$d" --timeout=5m >/dev/null
  # rollout status returns before the old pods have finished going
  sleep 20
done

"${K[@]}" -n lab-sink exec webmail-tabs -- touch /tmp/stop
"${K[@]}" -n lab-sink wait --for=jsonpath='{.status.phase}'=Succeeded pod/webmail-tabs --timeout=120s >/dev/null \
  || fail "the tabs didn't finish"
out="$("${K[@]}" -n lab-sink logs webmail-tabs | tail -1)"
python3 - "$out" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
print(f"   requests: {r['requests']} made, {r['failed']} failed")
for i, t in enumerate(r["tabs"]):
    print(f"   tab {i}: {t['streams']} streams, {t['clean_ends']} ended cleanly, {t['cut_off']} cut off, "
          f"longest wait for an event {t['longest_gap_s']} s")
for e in r["errors"]:
    print(f"   {e}")
bad = r["failed"] > 0 or any(t["cut_off"] > 0 or t["streams"] < 2 for t in r["tabs"])
print("== " + ("FAIL: a tab would have shown an error" if bad else "no request failed; every stream ended cleanly and came back"))
sys.exit(1 if bad else 0)
PY
