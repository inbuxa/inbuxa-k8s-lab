#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# The singleton roles on two core pods (server #437): every core pod has the
# taskScheduler and metricsCalculate roles, and one at a time holds each
# role's lease in the store and does its work. Checks that:
#   - each role has exactly one holder among the core pods;
#   - when the holder dies without giving the lease up (killed, no grace
#     period), another core pod takes both roles over within two lease
#     periods (6 minutes; about 4 is expected);
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

victim=$(awk '$1 == "taskScheduler" {print $2}' <<<"$out")
victim_roles=$(awk -v p="$victim" '$2 == p {print $1}' <<<"$out" | tr '\n' ' ')
echo "== killing $victim (holds: $victim_roles) with no grace period"
"${K[@]}" delete pod "$victim" --grace-period=0 --force >/dev/null 2>&1
t=$SECONDS

echo "== another core pod takes its roles over"
taken=""
while (( SECONDS - t < TAKEOVER_LIMIT )); do
  out=$(holders | grep -v " $victim\$" || true)
  taken=1
  for r in $victim_roles; do grep -q "^$r " <<<"$out" || taken=""; done
  [ -n "$taken" ] && break
  sleep 5
done
if [ -n "$taken" ]; then
  echo "ok   taken over in $(( SECONDS - t ))s (limit ${TAKEOVER_LIMIT}s):"
  sed 's/^/       /' <<<"$out"
else
  echo "FAIL not taken over in ${TAKEOVER_LIMIT}s; holders now:"; sed 's/^/     /' <<<"${out:-(none)}"
  fails=$((fails + 1))
fi

echo "== the replacement pod is up, and still one holder for each role"
"${K[@]}" rollout status deploy/inbuxa-core --timeout=300s >/dev/null
if out=$(one_holder_each 150); then
  sed 's/^/ok   /' <<<"$out"
else
  echo "FAIL not exactly one holder for each role:"; sed 's/^/     /' <<<"${out:-(none)}"
  fails=$((fails + 1))
fi

[ "$fails" = 0 ] && echo "== PASSED" || { echo "== FAILED ($fails)"; exit 1; }
