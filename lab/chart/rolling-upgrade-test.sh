#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L5, rolling: the published server images, release N-1 to release N,
# with mail flowing the whole way. On the lab's seeded install:
#
#   1. helm upgrade to FROM (ghcr.io, pinned by digest); mail works
#   2. mail starts flowing (mailflow.py: a message a second, retried like
#      an MTA would when a pod goes away)
#   3. helm upgrade to TO: the upgrade hook finds no layout change, so the
#      Deployments roll
#   4. every server pod runs TO's digest, mail still works, and every
#      message accepted during the roll arrived exactly once
#
#   FROM=27.1-rc.33 TO=27.1-rc.34 lab/chart/rolling-upgrade-test.sh
#
# Leaves the lab on TO. Needs docker (to read the digests) and the kind
# nodes to reach ghcr.io.
set -euo pipefail

cd "$(dirname "$0")"
FROM="${FROM:?the release to start from, e.g. 27.1-rc.33}"
TO="${TO:?the release to upgrade to, e.g. 27.1-rc.34}"
IMAGE=ghcr.io/inbuxa/inbuxa-server
K=(kubectl --context kind-inbuxa-lab)
H=(helm --kube-context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
WORK="$(mktemp -d)"
FLOW=""
trap '[ -n "$FLOW" ] && kill "$FLOW" 2>/dev/null; rm -rf "$WORK"' EXIT
fail() { echo "!! $*" >&2; exit 1; }

digest() { docker buildx imagetools inspect "$IMAGE:$1" --format '{{json .Manifest.Digest}}' | tr -d '"'; }
upgrade() {  # digest, then helm's own flags
  local d="$1"; shift
  "${H[@]}" upgrade inbuxa "$CHART" -f values-lab.yaml \
    --set server.image.repository="$IMAGE" --set server.image.pullPolicy=IfNotPresent \
    --set server.image.digest="$d" --wait --timeout 20m "$@"
}
# Every server pod is ready and runs exactly this digest, once the old ones
# have finished terminating (helm's --wait returns before they have)
on_digest() {
  local want="$1" got
  for _ in $(seq 1 60); do
    got="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}')"
    if [ "$(grep -c . <<<"$got")" -ge 5 ] && ! grep -qv "@$want true\$" <<<"$got"; then return 0; fi
    sleep 3
  done
  echo "$got"; return 1
}
hook_log() { "${K[@]}" -n inbuxa logs job/inbuxa-upgrade 2>/dev/null | grep -v '^20..-' || true; }
lb() { "${K[@]}" -n inbuxa get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }
mail() { ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" timeout 150 python3 mailtest.py "$(lb)"; }

from_d="$(digest "$FROM")"; to_d="$(digest "$TO")"
[[ "$from_d" =~ ^sha256: && "$to_d" =~ ^sha256: ]] || fail "couldn't read the digests of $FROM and $TO"
echo "$FROM = $from_d"
echo "$TO = $to_d"

echo "== 1. on $FROM"
start=$(date +%s)
upgrade "$from_d" >/dev/null
echo "   in $(( $(date +%s) - start ))s"
on_digest "$from_d" || fail "not every server pod runs $FROM"
mail

echo "== 2. mail flowing"
ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" STOP_FILE="$WORK/stop" \
  python3 mailflow.py "$(lb)" > "$WORK/flow.log" 2>&1 &
FLOW=$!
sleep 20

echo "== 3. rolling to $TO"
start=$(date +%s)
upgrade "$to_d" >/dev/null
echo "   in $(( $(date +%s) - start ))s; the hook said:"; hook_log | sed 's/^/   /'
sleep 20
touch "$WORK/stop"
flow=0; wait "$FLOW" || flow=$?; FLOW=""
sed 's/^/   /' "$WORK/flow.log"

echo "== 4. on $TO"
on_digest "$to_d" || fail "not every server pod runs $TO"
mail
[ "$flow" = 0 ] || fail "mail accepted during the roll was lost or doubled"
echo "== $FROM to $TO: rolled with mail flowing, nothing lost"
