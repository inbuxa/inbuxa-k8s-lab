#!/usr/bin/env bash
# The chart's upgrade hook, on the lab's seeded install (seed-store.sh, then
# helm install with values-lab.yaml). Three cases, each against the image
# given as TAG (loaded into kind as inbuxa-lab/server:$TAG):
#
#   1. no layout change: the hook finds nothing to do, a rolling update
#   2. a layout change, not acknowledged: refused, nothing changed, the old
#      pods keep running
#   3. acknowledged: the server pods stopped, the store upgraded, rolled out,
#      mail works
#
# A layout change is simulated by setting the store's mark back to 2: the
# step from 2 isn't rolling-safe. Wipes nothing, but leaves the lab's store
# upgraded again at the end.
#
#   TAG=plan lab/chart/upgrade-test.sh
set -euo pipefail

cd "$(dirname "$0")"
TAG="${TAG:?the server image tag to upgrade to}"
K=(kubectl --context kind-inbuxa-lab)
H=(helm --kube-context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
fail() { echo "!! $*" >&2; exit 1; }

mark() { "${K[@]}" -n data exec inbuxa-pg-1 -c postgres -- psql -d inbuxa -At \
  -c "select encode(v,'hex') from \"_\" where k = 'Vs'::bytea"; }
set_mark() { "${K[@]}" -n data exec inbuxa-pg-1 -c postgres -- psql -d inbuxa -q \
  -c "update \"_\" set v = decode('$1','hex') where k = 'Vs'::bytea"; }
upgrade() { "${H[@]}" upgrade inbuxa "$CHART" -f values-lab.yaml --set server.image.tag="$TAG" \
  --wait --timeout 20m "$@"; }
server_pods() { "${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server --no-headers 2>/dev/null | wc -l; }
hook_log() { "${K[@]}" -n inbuxa logs job/inbuxa-upgrade 2>/dev/null | grep -v '^20..-' || true; }
mail() {
  local lb
  lb="$("${K[@]}" -n inbuxa get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" timeout 150 python3 mailtest.py "$lb"
}

[ "$(mark)" = 00000003 ] || fail "the store isn't at layout 3 to start with"

echo "== 1. no layout change"
start=$(date +%s)
upgrade >/dev/null
echo "   upgraded in $(( $(date +%s) - start ))s; hook said:"; hook_log | sed 's/^/   /'
[ "$(server_pods)" -ge 5 ] || fail "not every server pod is back"
mail

echo "== 2. a layout change, not acknowledged"
set_mark 00000002
before="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server -o name | sort)"
if upgrade >/dev/null 2>&1; then
  fail "the unacknowledged upgrade went through"
fi
echo "   refused; hook said:"; hook_log | sed 's/^/   /'
[ "$(mark)" = 00000002 ] || fail "the refused upgrade changed the store"
after="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server -o name | sort)"
[ "$before" = "$after" ] || fail "the refused upgrade replaced pods"

echo "== 3. acknowledged"
start=$(date +%s)
upgrade --set server.upgrade.acknowledgeLayout=3 >/dev/null
echo "   upgraded in $(( $(date +%s) - start ))s; hook said:"; hook_log | sed 's/^/   /'
[ "$(mark)" = 00000003 ] || fail "the store isn't at layout 3"
[ "$(server_pods)" -ge 5 ] || fail "not every server pod is back"
mail

echo "== all three cases passed"
