#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# The lab end to end, from nothing (K-L1, S7): the kind cluster and data
# layer (up.sh), then the chart with the released images the next chart
# release names (inbuxa-charts release/suite.yaml), seeded, then
#
#   every client check, chart/mailcheck.sh: SMTP in, submission, IMAP,
#   JMAP, SMTP out to an outside server, CalDAV, CardDAV, the webmail across
#   both replicas and the console
#
# and how long each part took. CI runs this on a fresh runner; on the bench
# it builds the lab from scratch too, so take the lab down first
# (lab/down.sh) unless you mean to reuse it.
#
#   lab/e2e.sh                      # chart in ../inbuxa-charts
#   CHART_REPO=path lab/e2e.sh
#   KIND_NODE_IMAGE=kindest/node:v1.35.8 lab/e2e.sh   # lab/kubernetes.json lists the three CI runs
#
# Prints a summary, also to $GITHUB_STEP_SUMMARY when it's set, and on a
# failure what the pods and events were.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/versions.env"
CHART_REPO="${CHART_REPO:-$here/../../inbuxa-charts}"
CHART="$CHART_REPO/charts/inbuxa"
SUITE="$CHART_REPO/release/suite.yaml"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
K=(kubectl --context "kind-$KIND_CLUSTER" -n inbuxa)
P="${PORTS:-18080}"
t0=$SECONDS
SUMMARY=()
lap() { SUMMARY+=("| $1 | $(( SECONDS - ${2:-$t0} ))s |"); }
report() {
  { echo "| Part | Took |"; echo "|---|---|"; printf '%s\n' "${SUMMARY[@]}"; } > "$STATE/e2e-summary.md"
  cat "$STATE/e2e-summary.md"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && { echo "### inbuxa lab, ${E2E_LABEL:-$(uname -m)}"; cat "$STATE/e2e-summary.md"; } >> "$GITHUB_STEP_SUMMARY"
  return 0
}
on_exit() {
  rc=$?
  if [ "$rc" != 0 ]; then
    SUMMARY+=("| **failed** | after $(( SECONDS - t0 ))s |")
    echo "== failed: pods and events"
    kubectl --context "kind-$KIND_CLUSTER" get pods -A -o wide 2>/dev/null || true
    "${K[@]}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true
    "${K[@]}" logs -l app.kubernetes.io/component=server --tail=30 --prefix 2>/dev/null | grep -v '^\s*$' | tail -60 || true
  fi
  report
  exit "$rc"
}
trap on_exit EXIT
pin() { awk -v k="$1:" '$1 == k {print $2}' "$SUITE"; }
SERVER="$(pin server)"; WEBMAIL="$(pin webmail)"; CONSOLE="$(pin console)"
[ -n "$SERVER" ] && [ -n "$WEBMAIL" ] && [ -n "$CONSOLE" ] || { echo "!! no images in $SUITE" >&2; exit 1; }
echo "== images: server $SERVER, webmail $WEBMAIL, console $CONSOLE"
mkdir -p "$STATE" && chmod 700 "$STATE"

echo "== the cluster and the data layer"
s=$SECONDS
"$here/up.sh"
lap "kind, Kyverno, MetalLB, CloudNativePG, NATS, Garage" "$s"

echo "== the seed's passwords and setup"
umask 077
new_password() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }
new_password > "$STATE/admin.password"
new_password > "$STATE/alice.password"
"${K[@]}" get secret inbuxa-s3 -o jsonpath='{.data.access-key}' | base64 -d > "$STATE/s3-access-key"
"${K[@]}" create secret generic inbuxa-seed \
  --from-file=admin-password="$STATE/admin.password" \
  --from-file=alice-password="$STATE/alice.password" \
  --from-file=s3-access-key="$STATE/s3-access-key" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
rm -f "$STATE/s3-access-key"
"${K[@]}" create configmap inbuxa-lab-seed --from-file="$here/chart/seed.json" --dry-run=client -o yaml \
  | "${K[@]}" apply -f - >/dev/null
umask 022

echo "== the chart: seeded, two replicas of everything"
s=$SECONDS
helm --kube-context "kind-$KIND_CLUSTER" -n inbuxa upgrade --install inbuxa "$CHART" \
  -f "$here/chart/values-lab.yaml" -f "$here/chart/values-frontends.yaml" \
  --set server.image.repository=ghcr.io/inbuxa/inbuxa-server --set server.image.tag="$SERVER" \
  --set server.image.pullPolicy=IfNotPresent \
  --set webmail.image.repository=ghcr.io/inbuxa/inbuxa-webmail --set webmail.image.tag="$WEBMAIL" \
  --set webmail.image.pullPolicy=IfNotPresent \
  --set console.image.repository=ghcr.io/inbuxa/inbuxa-admin --set console.image.tag="$CONSOLE" \
  --set console.image.pullPolicy=IfNotPresent \
  --wait --timeout 15m >/dev/null
"${K[@]}" get pods --no-headers -o wide | awk '{print "   " $1, $3, $7}'
lap "chart install (seed, server, webmail, console)" "$s"

echo "== the client checks (chart/mailcheck.sh)"
s=$SECONDS
PORTS="$P" STATE="$STATE" "$here/chart/mailcheck.sh"
lap "mail (SMTP in, submission, IMAP, JMAP, SMTP out), CalDAV, CardDAV, webmail, console" "$s"

lap "**total**"
echo "== passed in $(( SECONDS - t0 ))s"
