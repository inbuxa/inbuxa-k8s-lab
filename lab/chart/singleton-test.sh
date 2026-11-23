#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# The singleton roles on two core pods (server #437): every core pod has the
# taskScheduler and metricsCalculate roles, and one at a time holds each
# role's lease in the store and does its work. Checks that:
#   - each role has exactly one holder among the core pods;
#   - a crash: the holder's server process killed (SIGKILL, from its kind
#     node), so it gives nothing up, and its roles taken over within two
#     lease periods (6 minutes; about 4 is expected);
#   - a clean stop: the holder deleted as a rollout or a drain would, its
#     leases given up and taken at the next round (2 minutes at most);
#   - each role again has exactly one holder.
# Reads the pods' logs for cluster.singleton-lease-taken and -lost. Leaves
# two ready core pods behind.
#
#   lab/chart/singleton-test.sh
set -euo pipefail

K=(kubectl --context "kind-${KIND_CLUSTER:-inbuxa-lab}" -n inbuxa)
SEL=app.kubernetes.io/component=server,inbuxa.org/group=core
ROLES=(taskScheduler metricsCalculate)
TAKEOVER_LIMIT=360
fails=0

# What the core pods say about the leases and the coordinator, on a failure
explain() {
  for p in $(core_pods); do
    echo "     -- $p: $("${K[@]}" logs "$p" --tail=-1 2>/dev/null | wc -l) log lines; on leases and the coordinator:"
    "${K[@]}" logs "$p" --tail=-1 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -iE 'singleton|coordinator|cluster\.' | tail -8 | cut -c1-300 | sed 's/^/        /' || true
  done
}

core_pods() { "${K[@]}" get pods -l "$SEL" --field-selector=status.phase=Running -o name | sed 's|^pod/||'; }

# The roles a pod holds now: for each role, its last taken/lost line decides
holds() {
  "${K[@]}" logs "$1" --tail=-1 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -E '\(cluster\.singleton-lease-(taken|lost)\)' \
    | awk -v roles="${ROLES[*]}" '
        BEGIN { n = split(roles, r, " ") }
        { for (i = 1; i <= n; i++) if (index($0, "\"" r[i] "\"")) last[r[i]] = (index($0, "lease-taken") ? 1 : 0) }
        END { for (i = 1; i <= n; i++) if (last[r[i]]) print r[i] }'
}

# "role pod" for every role held, across the core pods
holders() { for p in $(core_pods); do holds "$p" | sed "s|\$| $p|"; done; }

# Waits until each role has exactly one holder; prints "role pod" lines
one_holder_each() {
  local limit=$1 start=$SECONDS out
  while (( SECONDS - start < limit )); do
    out=$(holders)
    local ok=1
    for r in "${ROLES[@]}"; do
      [ "$(grep -c "^$r " <<<"$out" || true)" = 1 ] || ok=0
    done
    if (( ok )); then echo "$out"; return 0; fi
    sleep 5
  done
  echo "$out"
  return 1
}

echo "== two core pods"
"${K[@]}" rollout status deploy/inbuxa-core --timeout=300s >/dev/null
pods=$(core_pods)
if [ "$(wc -w <<<"$pods")" != 2 ]; then
  echo "FAIL expected 2 core pods, found: $pods"
  exit 1
fi
echo "ok   $(tr '\n' ' ' <<<"$pods")"

echo "== one holder for each role"
# A pod tries for the leases each minute: give both a round and a half
if out=$(one_holder_each 150); then
  sed 's/^/ok   /' <<<"$out"
else
  echo "FAIL not exactly one holder for each role:"; sed 's/^/     /' <<<"${out:-(none)}"
  explain
  exit 1
fi

# Waits until every role in $2 has a holder that isn't pod $1 (or any
# pod, with $1 empty); prints "role pod" lines, or fails after $3 seconds
taken_over() {
  local gone=$1 roles=$2 limit=$3 start=$SECONDS out ok
  while (( SECONDS - start < limit )); do
    out=$(holders | { if [ -n "$gone" ]; then grep -v " $gone\$"; else cat; fi; } || true)
    ok=1
    for r in $roles; do [ "$(grep -c "^$r " <<<"$out" || true)" = 1 ] || ok=""; done
    if [ -n "$ok" ]; then echo "$out"; return 0; fi
    sleep 5
  done
  echo "$out"
  return 1
}

holder_of() { awk -v r="$1" '$1 == r {print $2}' <<<"$2"; }
roles_of() { awk -v p="$1" '$2 == p {print $1}' <<<"$2" | tr '\n' ' '; }

# 1. A crash: the holder's server process killed (SIGKILL, from its kind
# node), so it gives nothing up. Its container restarts in the same pod,
# with a new lease token; whichever core pod is first after the lease runs
# out takes the roles. The old process's log goes with it, so until then
# no pod's current log says it holds them.
victim=$(holder_of taskScheduler "$out")
victim_roles=$(roles_of "$victim" "$out")
node=$("${K[@]}" get pod "$victim" -o jsonpath='{.spec.nodeName}')
sandbox=$(docker exec "$node" crictl pods --name "$victim" -q | head -1)
cid=$(docker exec "$node" crictl ps --pod "$sandbox" --name server -q | head -1)
pid=$(docker exec "$node" crictl inspect --output go-template --template '{{.info.pid}}' "$cid")
restarts() { "${K[@]}" get pod "$victim" -o jsonpath='{.status.containerStatuses[?(@.name=="server")].restartCount}'; }
before=$(restarts)
echo "== a crash: the server in $victim (holds: $victim_roles) killed, pid $pid on $node"
docker exec "$node" sh -c "kill -KILL $pid"
t=$SECONDS
# Its log is the new container's only once that has started
for _ in $(seq 1 60); do [ "$(restarts)" -gt "$before" ] && break; sleep 1; done
if out=$(taken_over "" "$victim_roles" "$TAKEOVER_LIMIT"); then
  echo "ok   taken over in $(( SECONDS - t ))s, once the lease ran out (limit ${TAKEOVER_LIMIT}s):"
  sed 's/^/       /' <<<"$out"
else
  echo "FAIL not taken over in ${TAKEOVER_LIMIT}s; holders now:"; sed 's/^/     /' <<<"${out:-(none)}"
  explain
  fails=$((fails + 1))
fi
"${K[@]}" rollout status deploy/inbuxa-core --timeout=300s >/dev/null

# 2. A clean stop, as in a rollout or a drain: the holder gives its leases
# up as it stops, and another core pod takes them at its next round, a
# minute at most
out=$(holders)
victim=$(holder_of taskScheduler "$out")
victim_roles=$(roles_of "$victim" "$out")
if [ -n "$victim" ]; then
  echo "== a clean stop: $victim (holds: $victim_roles) deleted"
  "${K[@]}" delete pod "$victim" --wait=false >/dev/null
  t=$SECONDS
  if out=$(taken_over "$victim" "$victim_roles" 120); then
    echo "ok   handed over in $(( SECONDS - t ))s (limit 120s):"
    sed 's/^/       /' <<<"$out"
  else
    echo "FAIL not handed over in 120s; holders now:"; sed 's/^/     /' <<<"${out:-(none)}"
    explain
    fails=$((fails + 1))
  fi
else
  echo "FAIL no taskScheduler holder before the clean stop"
  fails=$((fails + 1))
fi

echo "== both core pods up, and one holder for each role"
"${K[@]}" rollout status deploy/inbuxa-core --timeout=300s >/dev/null
if out=$(one_holder_each 150); then
  sed 's/^/ok   /' <<<"$out"
else
  echo "FAIL not exactly one holder for each role:"; sed 's/^/     /' <<<"${out:-(none)}"
  explain
  fails=$((fails + 1))
fi

[ "$fails" = 0 ] && echo "== PASSED" || { echo "== FAILED ($fails)"; exit 1; }
