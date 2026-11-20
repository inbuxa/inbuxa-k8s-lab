#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L7: the soak. Steady load for SOAK_DAYS days (7) on the lab's seeded
# install, one chaos scenario a day, a report at the end of each day and
# one for the whole run.
#
#   lab/soak/soak.sh start     checks the install, then runs in the
#                              background (a systemd user unit)
#   lab/soak/soak.sh status    where it's up to, and today's numbers so far
#   lab/soak/soak.sh stop
#   lab/soak/soak.sh report    the reports written so far
#
# The load (soak-load.py) comes from this host through the load balancer:
# mail in, mail out to the sink, IMAP IDLE. The webmail tabs
# (chart/webmail-tabs.py) run in a pod, as there's no ingress. Chaos is
# chart/chaos-test.sh with one scenario a day, CHAOS_AFTER seconds into the
# day (2 h). Reports and state go to SOAK_DIR; a run is resumed, not
# restarted, by `start` after a stop or a reboot, until it's done.
#
# A shorter run, to try the harness: SOAK_DAY=1800 SOAK_DAYS=2 CHAOS_AFTER=300
#
# The unit stops when its user logs out unless lingering is on
# (`loginctl enable-linger`), which is the machine owner's call.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../versions.env"
export KCTX="${KCTX:-kind-$KIND_CLUSTER}"
K=(kubectl --context "$KCTX")
LAB_STATE="${LAB_STATE:-$HOME/.cache/inbuxa-lab}"
export STATE="${SOAK_DIR:-$LAB_STATE/soak}"
export SOAK_DAY="${SOAK_DAY:-86400}"
SOAK_DAYS="${SOAK_DAYS:-7}"
CHAOS_AFTER="${CHAOS_AFTER:-7200}"
SCENARIOS=(pod-kill drain pg-failover nats-restart s3-outage pod-kill drain)
UNIT=inbuxa-soak
fail() { echo "!! $*" >&2; exit 1; }
lb() { "${K[@]}" -n inbuxa get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }

tabs_pod() {
  "${K[@]}" create namespace lab-soak --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" label namespace lab-soak pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
  "${K[@]}" -n lab-soak create configmap soak-tabs --from-file="$HERE/../chart/webmail-tabs.py" \
    --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" -n lab-soak create secret generic soak-tabs --from-file=password="$LAB_STATE/alice.password" \
    --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" -n lab-soak apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: soak-tabs}
spec:
  replicas: 1
  selector: {matchLabels: {app: soak-tabs}}
  template:
    metadata: {labels: {app: soak-tabs}}
    spec:
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
            - {name: INTERVAL, value: "5"}
            - {name: SUMMARY_EVERY, value: "60"}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 128Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: tabs, mountPath: /tabs}
            - {name: secret, mountPath: /secret}
      volumes:
        - {name: tabs, configMap: {name: soak-tabs}}
        - {name: secret, secret: {secretName: soak-tabs, defaultMode: 0440}}
EOF
  "${K[@]}" -n lab-soak rollout status deploy/soak-tabs --timeout=180s >/dev/null
}

start() {
  systemctl --user is-active --quiet "$UNIT" && fail "already running: $0 status"
  mkdir -p "$STATE"
  if [ -f "$STATE/started" ] && [ -f "$STATE/report.md" ]; then
    fail "the run in $STATE is finished; move it away to start another"
  fi
  if [ ! -f "$STATE/started" ]; then
    echo "== every client check first (it also routes sink.test to the sink)"
    PORTS="${PORTS:-18080}" STATE="$LAB_STATE" "$HERE/../chart/mailcheck.sh" >"$STATE/mailcheck.log" 2>&1 \
      || { tail -20 "$STATE/mailcheck.log"; fail "the install isn't healthy; not starting"; }
    date +%s >"$STATE/started"
  fi
  echo "== the webmail tabs"
  tabs_pod
  systemd-run --user --unit "$UNIT" --collect --quiet \
    --setenv=KCTX="$KCTX" --setenv=SOAK_DIR="$STATE" --setenv=SOAK_DAY="$SOAK_DAY" \
    --setenv=SOAK_DAYS="$SOAK_DAYS" --setenv=CHAOS_AFTER="$CHAOS_AFTER" --setenv=LAB_STATE="$LAB_STATE" \
    --setenv=PATH="$PATH" --setenv=HOME="$HOME" \
    bash "$HERE/soak.sh" run
  echo "== running: $SOAK_DAYS day(s) of ${SOAK_DAY}s; $0 status"
}

# The unit's body: never exits on a hiccup, only when the run is done
run() {
  set +e
  mkdir -p "$STATE"
  local started load_pid="" day now since
  started="$(cat "$STATE/started")"
  stop_load() { [ -n "$load_pid" ] && kill "$load_pid" 2>/dev/null; wait "$load_pid" 2>/dev/null; }
  trap 'stop_load; exit 0' TERM INT
  while :; do
    if [ -z "$load_pid" ] || ! kill -0 "$load_pid" 2>/dev/null; then
      ACCOUNT=alice@lab.test PASSWORD_FILE="$LAB_STATE/alice.password" \
        python3 "$HERE/soak-load.py" "$(lb)" >>"$STATE/load.log" 2>&1 &
      load_pid=$!
    fi
    python3 "$HERE/soak-watch.py" collect >>"$STATE/watch.log" 2>&1

    now=$(date +%s)
    day=$(( (now - started) / SOAK_DAY + 1 ))
    since=$(( (now - started) % SOAK_DAY ))
    # Yesterday's report, once
    if [ "$day" -gt 1 ] && [ ! -f "$STATE/day-$((day - 1)).md" ]; then
      python3 "$HERE/soak-watch.py" report "$((day - 1))" >/dev/null 2>>"$STATE/watch.log"
    fi
    if [ "$day" -gt "$SOAK_DAYS" ]; then
      python3 "$HERE/soak-watch.py" final >/dev/null 2>>"$STATE/watch.log"
      stop_load
      "${K[@]}" -n lab-soak scale deploy/soak-tabs --replicas=0 >/dev/null 2>&1
      exit 0
    fi
    # Today's chaos, once
    if [ "$since" -ge "$CHAOS_AFTER" ] && [ ! -f "$STATE/chaos-day-$day.log" ]; then
      local sc="${SCENARIOS[$(( (day - 1) % ${#SCENARIOS[@]} ))]}" t0 rc
      t0=$(date +%s)
      printf '{"day": %d, "scenario": "%s", "start": %d}\n' "$day" "$sc" "$t0" >>"$STATE/chaos.jsonl"
      SCENARIOS="$sc" STATE="$LAB_STATE" PORTS=18180 "$HERE/../chart/chaos-test.sh" >"$STATE/chaos-day-$day.log" 2>&1
      rc=$?
      python3 - "$STATE/chaos.jsonl" "$day" "$rc" "$(date +%s)" <<'PY'
import json, sys
path, day, rc, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rows = [json.loads(l) for l in open(path) if l.strip()]
for r in rows:
    if r["day"] == day and "end" not in r:
        r["end"], r["result"] = end, "ok" if rc == 0 else f"FAILED (exit {rc}, see chaos-day-{day}.log)"
open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
    fi
    sleep 60
  done
}

status() {
  if systemctl --user is-active --quiet "$UNIT"; then echo "== running"; else echo "== not running"; fi
  [ -f "$STATE/started" ] || { echo "   no run in $STATE"; return 0; }
  local started now; started="$(cat "$STATE/started")"; now=$(date +%s)
  echo "   day $(( (now - started) / SOAK_DAY + 1 )) of $SOAK_DAYS, $(( (now - started) % SOAK_DAY / 60 )) min in"
  python3 - "$STATE" <<'PY'
import json, os, sys
d = sys.argv[1]
L = json.load(open(os.path.join(d, "load.json")))
W = json.load(open(os.path.join(d, "watch.json"))) if os.path.exists(os.path.join(d, "watch.json")) else {"out": {}, "tabs": {}}
i, o, idle = L["inbound"], L["outbound"], L["idle"]
print(f"   in: {i['sent']} sent, {i['arrived']} arrived, {len(L['pending'])} pending, {i['twice']} twice")
print(f"   out: {o['sent']} sent, {len(W['out'])} at the sink")
print(f"   idle: {idle['notices']} notices, {idle['drops']} drops")
t = list(W["tabs"].values())
print(f"   webmail: {sum(x.get('requests', 0) for x in t)} requests, {sum(x.get('failed', 0) for x in t)} failed")
PY
  ls "$STATE"/day-*.md 2>/dev/null | sed 's/^/   /' || true
}

case "${1:-}" in
  start) start ;;
  run) run ;;
  status) status ;;
  stop) systemctl --user stop "$UNIT" 2>/dev/null || true; echo "== stopped (start resumes it)" ;;
  report) cat "$STATE"/day-*.md "$STATE"/report.md 2>/dev/null || echo "no reports yet" ;;
  *) sed -n '4,25p' "$0"; exit 2 ;;
esac
