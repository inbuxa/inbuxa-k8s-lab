#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L4: faults with mail flowing. For each scenario, mailflow.py sends a
# message a second over SMTP (retrying like an MTA when refused), the fault
# happens, the lab recovers, and every message the server accepted has to
# arrive exactly once:
#
#   pod-kill      an mta pod and a front pod killed outright (no grace)
#   drain         a worker with server pods drained, then uncordoned
#   pg-failover   the PostgreSQL primary deleted: CloudNativePG promotes the
#                 replica
#   nats-restart  NATS restarted, one pod at a time
#   s3-outage     Garage frozen for 60 s (SIGSTOP; requests hang, as a
#                 stuck S3 does), then thawed
#
#   lab/chart/chaos-test.sh
#   SCENARIOS="pg-failover s3-outage" lab/chart/chaos-test.sh
#
# On the lab's seeded install; ends with chart/mailcheck.sh, so everything
# still works after the lot. The drain skips the nodes with the PostgreSQL
# primary and Garage (whose data is an emptyDir in the lab, so it can't
# move); a node it cordons, and a frozen Garage, are put back on any exit.
set -euo pipefail

cd "$(dirname "$0")"
. ../versions.env
KCTX="kind-$KIND_CLUSTER"
K=(kubectl --context "$KCTX")
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
SCENARIOS="${SCENARIOS:-pod-kill drain pg-failover nats-restart s3-outage}"
WORK="$(mktemp -d)"
FLOW="" CORDONED="" FROZEN=""
cleanup() {
  [ -n "$FLOW" ] && kill "$FLOW" 2>/dev/null || true
  [ -n "$CORDONED" ] && "${K[@]}" uncordon "$CORDONED" >/dev/null 2>&1 || true
  [ -n "$FROZEN" ] && docker exec "$FROZEN" sh -c 'kill -CONT $(pgrep -x garage)' 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "!! $*" >&2; exit 1; }

lb() { "${K[@]}" -n inbuxa get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }
# The server back to full strength: every Deployment rolled out and ready
healthy() {
  for d in front mta core; do
    "${K[@]}" -n inbuxa rollout status "deploy/inbuxa-$d" --timeout=300s >/dev/null
  done
}
data_ready() {
  "${K[@]}" -n data wait cluster.postgresql.cnpg.io/inbuxa-pg --for=condition=Ready --timeout=600s >/dev/null
  "${K[@]}" -n data rollout status statefulset/nats --timeout=300s >/dev/null
  "${K[@]}" -n data rollout status deploy/garage --timeout=120s >/dev/null
}
node_of() { "${K[@]}" -n "$1" get pod "$2" -o jsonpath='{.spec.nodeName}'; }
primary() { "${K[@]}" -n data get cluster inbuxa-pg -o jsonpath='{.status.currentPrimary}'; }
garage_node() { "${K[@]}" -n data get pod -l app=garage -o jsonpath='{.items[0].spec.nodeName}'; }

pod_kill() {
  local mta front
  mta="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server,app.kubernetes.io/instance=inbuxa -o name | grep -m1 inbuxa-mta)"
  front="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server,app.kubernetes.io/instance=inbuxa -o name | grep -m1 inbuxa-front)"
  echo "   killing ${mta#pod/} and ${front#pod/}"
  "${K[@]}" -n inbuxa delete "$mta" "$front" --grace-period=0 --force --wait=false >/dev/null 2>&1
  sleep 5
  healthy
}

drain() {
  local avoid node
  avoid="$(node_of data "$(primary)") $(garage_node)"
  node="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | sort | uniq -c | sort -rn | awk '{print $2}' | grep -vxF -f <(tr ' ' '\n' <<<"$avoid") | head -1 || true)"
  [ -n "$node" ] || { echo "   no node to drain without the PostgreSQL primary or Garage; skipped"; return 0; }
  echo "   draining $node (not $avoid)"
  CORDONED="$node"
  "${K[@]}" drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=300s >/dev/null 2>"$WORK/drain.err" \
    || { cat "$WORK/drain.err" >&2; return 1; }
  healthy
  "${K[@]}" uncordon "$node" >/dev/null
  CORDONED=""
  data_ready
}

pg_failover() {
  local old new=""
  old="$(primary)"
  echo "   deleting the primary, $old"
  "${K[@]}" -n data delete pod "$old" --wait=false >/dev/null
  for _ in $(seq 1 100); do
    new="$(primary)"
    [ -n "$new" ] && [ "$new" != "$old" ] && break
    sleep 3
  done
  [ "$new" != "$old" ] || { echo "   no new primary"; return 1; }
  echo "   new primary $new"
  data_ready
  healthy
}

nats_restart() {
  "${K[@]}" -n data rollout restart statefulset/nats >/dev/null
  "${K[@]}" -n data rollout status statefulset/nats --timeout=300s >/dev/null
  healthy
}

s3_outage() {
  local node
  node="$(garage_node)"
  echo "   freezing Garage on $node for 60 s"
  FROZEN="$node"
  docker exec "$node" sh -c 'kill -STOP $(pgrep -x garage)'
  sleep 60
  docker exec "$node" sh -c 'kill -CONT $(pgrep -x garage)'
  FROZEN=""
  echo "   thawed"
  healthy
}

declare -A RESULT TOOK
for sc in $SCENARIOS; do
  fn="${sc//-/_}"
  declare -F "$fn" >/dev/null || fail "no scenario $sc"
  echo "== $sc"
  start=$(date +%s)
  rm -f "$WORK/stop"
  ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" STOP_FILE="$WORK/stop" WAIT=420 \
    python3 mailflow.py "$(lb)" > "$WORK/$sc.log" 2>&1 &
  FLOW=$!
  sleep 15
  fault=0
  "$fn" || fault=$?
  sleep 20
  touch "$WORK/stop"
  flow=0; wait "$FLOW" || flow=$?; FLOW=""
  # The retries too: why each send was refused says what the fault did
  sed 's/^/   /' "$WORK/$sc.log"
  TOOK[$sc]=$(( $(date +%s) - start ))
  # A message missing: what the server's logs say about it, by its queue id
  # (delivered late, deferred and why, or nothing at all)
  for id in $(sed -n 's/^  queue id [0-9]*: \([0-9][0-9]*\)$/\1/p' "$WORK/$sc.log"); do
    echo "   -- the server's logs on queue id $id"
    "${K[@]}" -n inbuxa logs -l app.kubernetes.io/component=server --prefix --tail=-1 --since=30m 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' | grep -wF -- "$id" | tail -20 | cut -c1-400 | sed 's/^/      /' || true
  done
  if [ "$fault" != 0 ]; then RESULT[$sc]="FAIL (the fault or the recovery)"
  elif [ "$flow" != 0 ]; then RESULT[$sc]="FAIL (mail lost or doubled)"
  else RESULT[$sc]="ok"; fi
done

echo "== after it all: every client check"
after=0
PORTS="${PORTS:-18080}" STATE="$STATE" ./mailcheck.sh >"$WORK/after.log" 2>&1 || after=$?
grep -E '^  (ok|FAIL)|^== every' "$WORK/after.log" || tail -20 "$WORK/after.log"

echo "== chaos"
bad=0
for sc in $SCENARIOS; do
  printf '   %-13s %-34s %ss\n' "$sc" "${RESULT[$sc]}" "${TOOK[$sc]}"
  [ "${RESULT[$sc]}" = ok ] || bad=1
done
[ "$after" = 0 ] || { echo "   the client checks failed afterwards"; bad=1; }
exit "$bad"
