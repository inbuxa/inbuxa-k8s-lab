#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Every client check against an installed chart, in one command (K-L2):
#
#   mailcheck.py   SMTP in on 25, submission on 465, IMAPS, JMAP, SMTP out
#                  to an outside server (mail-sink.yaml), CalDAV, CardDAV
#   signin.py      the webmail: signing in starting on one replica and
#                  finishing on the other
#   console-signin.py  the console: signing in as its browser would
#
#   lab/chart/mailcheck.sh
#
# Wants the lab's seeded install with the webmail and the console
# (values-frontends.yaml), and the passwords seed-store.sh or e2e.sh left
# under $STATE. Sets up the sink (namespace lab-sink) if it isn't there.
# PORTS picks four free local ports in a row (default from 18080).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/../versions.env"
KCTX="kind-$KIND_CLUSTER"
K=(kubectl --context "$KCTX" -n inbuxa)
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
P="${PORTS:-18080}"
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done' EXIT
fail() { echo "!! $*" >&2; exit 1; }

echo "== the outside mail server"
sed "s|image: IMAGE|image: $PG_IMAGE|" "$here/mail-sink.yaml" | kubectl --context "$KCTX" apply -f - >/dev/null
kubectl --context "$KCTX" -n lab-sink rollout status deploy/sink --timeout=180s >/dev/null

lb=""
for _ in $(seq 1 30); do
  lb="$("${K[@]}" get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [ -n "$lb" ] && break
  sleep 2
done
[ -n "$lb" ] || fail "the mail Service has no address"

forward() { # <local port> <target>
  # Something else on the port would answer in the forward's place
  if ss -ltn "sport = :$1" | grep -q LISTEN; then
    fail "port $1 is in use: PORTS=<first of four free ports> $0"
  fi
  "${K[@]}" port-forward "$2" "$1:8080" >/dev/null 2>&1 &
  PIDS+=($!)
}
mapfile -t webmail < <("${K[@]}" get pods -l app.kubernetes.io/component=webmail \
  --field-selector status.phase=Running -o name | sort)
[ "${#webmail[@]}" -ge 2 ] || fail "fewer than two webmail pods (values-frontends.yaml?)"
forward "$P" svc/inbuxa-http
forward $((P + 1)) "${webmail[0]}"
forward $((P + 2)) "${webmail[1]}"
forward $((P + 3)) svc/inbuxa-console
sleep 3

echo "== mail, calendars and contacts, as alice@lab.test"
KCTX="$KCTX" python3 "$here/mailcheck.py" "$lb" "http://127.0.0.1:$P" \
  "$STATE/alice.password" "$STATE/admin.password"

echo "== webmail: start on ${webmail[0]#pod/}, finish on ${webmail[1]#pod/}"
python3 "$here/signin.py" "http://127.0.0.1:$((P + 1))" "http://127.0.0.1:$((P + 2))" \
  "http://127.0.0.1:$P" alice@lab.test "$STATE/alice.password"

echo "== console"
python3 "$here/console-signin.py" "http://127.0.0.1:$((P + 3))" "http://127.0.0.1:$P" \
  https://admin.lab.test https://mail.lab.test admin@lab.test "$STATE/admin.password"

echo "== every check passed"
