#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L5, crossing: a store made and filled by a published 2026.x server, then
# upgraded by the chart to a 27.1 release, with the layout change the
# crossing brings:
#
#   1. a fresh store set up by OLD (fresh-store.sh), and OLD taking mail
#      through the chart's own mail Service, as one pod with the chart's
#      labels (OLD predates the chart: it runs as the lab's spike pods do)
#   2. the mailbox digests: every mailbox's count and a hash over its messages
#   3. helm upgrade to TO without acknowledging the layout change: refused,
#      the store untouched
#   4. acknowledged: the hook upgrades the store, the Deployments come up on
#      TO, and the digests are what OLD left
#
#   OLD=2026.11.18.3 TO=27.1-rc.34 lab/chart/crossing-test.sh
#
# WIPES the lab's inbuxa database, and leaves a store fresh-store.sh made.
# seed-store.sh and a helm upgrade put the lab back as the other tests want it.
set -euo pipefail

cd "$(dirname "$0")"
OLD="${OLD:?the 2026.x release to start from, e.g. 2026.11.18.3}"
TO="${TO:?the 27.1 release to cross to, e.g. 27.1-rc.34}"
MESSAGES="${MESSAGES:-15}"
IMAGE=ghcr.io/inbuxa/inbuxa-server
K=(kubectl --context kind-inbuxa-lab)
H=(helm --kube-context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
WORK="$(mktemp -d)"
trap '"${K[@]}" -n inbuxa delete pod inbuxa-old --ignore-not-found >/dev/null 2>&1; rm -rf "$WORK"' EXIT
fail() { echo "!! $*" >&2; exit 1; }

digest_of() { docker buildx imagetools inspect "$IMAGE:$1" --format '{{json .Manifest.Digest}}' | tr -d '"'; }
mark() { "${K[@]}" -n data exec inbuxa-pg-1 -c postgres -- psql -d inbuxa -At \
  -c "select encode(v,'hex') from \"_\" where k = 'Vs'::bytea"; }
lb() { "${K[@]}" -n inbuxa get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }
mailbox_digest() { ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" python3 mailbox-digest.py "$(lb)" "$@"; }
upgrade() {
  "${H[@]}" upgrade inbuxa "$CHART" -f values-lab.yaml --set server.seed.enabled=false \
    --set server.image.repository="$IMAGE" --set server.image.pullPolicy=IfNotPresent \
    --set server.image.digest="$to_d" --wait --timeout 20m "$@"
}
hook_log() { "${K[@]}" -n inbuxa logs job/inbuxa-upgrade 2>/dev/null | grep -v '^20..-' || true; }

old_d="$(digest_of "$OLD")"; to_d="$(digest_of "$TO")"
[[ "$old_d" =~ ^sha256: && "$to_d" =~ ^sha256: ]] || fail "couldn't read the digests of $OLD and $TO"
echo "$OLD = $old_d"
echo "$TO = $to_d"

echo "== 1. a store made by $OLD"
IMAGE="$IMAGE@$old_d" PULL=IfNotPresent ./fresh-store.sh
echo "   layout mark: $(mark)"
# OLD serving mail, behind the chart's Service and NetworkPolicies. The
# Service targets ports by name, so the pod names them as the chart's do.
PORTS="$("${K[@]}" -n inbuxa get deploy inbuxa-front -o jsonpath='{.spec.template.spec.containers[0].ports}')"
sed -n '/^  template:/,$p' ../spike/core.yaml | sed '1d' |
  sed -e "s|^    ||" \
      -e "s|metadata: {labels: {app: inbuxa-server, group: core}}|metadata: {name: inbuxa-old, namespace: inbuxa, labels: {app.kubernetes.io/name: inbuxa, app.kubernetes.io/instance: inbuxa, app.kubernetes.io/component: server, inbuxa.org/serves-mail: \"true\"}}|" \
      -e "s|image: inbuxa-lab/server:rc27|image: $IMAGE@$old_d|" \
      -e "s|imagePullPolicy: Never|imagePullPolicy: IfNotPresent\n      ports: $PORTS|" \
      -e '/topologySpreadConstraints:/,+1d' > "$WORK/old.yaml"
"${K[@]}" -n inbuxa delete pod inbuxa-old --ignore-not-found --wait >/dev/null
{ printf 'apiVersion: v1\nkind: Pod\n'; cat "$WORK/old.yaml"; } | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n inbuxa wait --for=condition=Ready pod/inbuxa-old --timeout=300s >/dev/null ||
  { "${K[@]}" -n inbuxa logs inbuxa-old | tail -20; fail "$OLD never got ready"; }

echo "== 2. mail into $OLD, and its digests"
for _ in $(seq 1 30); do timeout 5 bash -c "</dev/tcp/$(lb)/25" 2>/dev/null && break; sleep 2; done
mailbox_digest send "$MESSAGES" > "$WORK/before"
sed 's/^/   /' "$WORK/before"
grep -q . "$WORK/before" || fail "no mailboxes"
"${K[@]}" -n inbuxa delete pod inbuxa-old --wait >/dev/null
before_mark="$(mark)"

echo "== 3. to $TO, not acknowledged"
if upgrade >/dev/null 2>&1; then fail "the crossing went through unacknowledged"; fi
echo "   refused; the hook said:"; hook_log | sed 's/^/   /'
[ "$(mark)" = "$before_mark" ] || fail "the refused upgrade changed the store"

echo "== 4. acknowledged"
start=$(date +%s)
upgrade --set server.upgrade.acknowledgeLayout=3 >/dev/null
echo "   crossed in $(( $(date +%s) - start ))s; the hook said:"; hook_log | sed 's/^/   /'
[ "$(mark)" = 00000003 ] || fail "the store isn't at layout 3: $(mark)"
for _ in $(seq 1 60); do
  got="$("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}')"
  [ "$(grep -c . <<<"$got")" -ge 5 ] && ! grep -qv "@$to_d true\$" <<<"$got" && break
  sleep 3
done
grep -qv "@$to_d true\$" <<<"$got" && fail "not every server pod runs $TO"
mailbox_digest > "$WORK/after"
diff "$WORK/before" "$WORK/after" >/dev/null ||
  { diff "$WORK/before" "$WORK/after" | sed 's/^/   /'; fail "the mail isn't what $OLD left"; }
echo "   digests match"
ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" timeout 150 python3 mailtest.py "$(lb)"
echo "== $OLD to $TO: crossed, every message as it was"
