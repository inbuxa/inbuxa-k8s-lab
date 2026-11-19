#!/usr/bin/env bash
# Sign-in limits with several replicas (K-W3), on the lab's install with the
# webmail (frontends-test.sh first):
#
#   1. the webmail's own limit counts per replica: one replica refuses, the
#      other still starts a sign-in
#   2. the webmail counts the browser its proxy names, not the proxy: with
#      one client refused, another through the same replica still gets in
#   3. the server counts failed sign-ins across its pods, and bans the
#      address after about 100 (the default), whichever pod they reached
#   4. through a proxy, the server counts each client, not the proxy: 110
#      failures for 110 clients ban nobody, the proxy least of all
#
# That the webmail passes that address on to the server as X-Forwarded-For
# is its own test (inbuxa-webmail server/src/clientcontext.test.ts); step 4's
# proxy is a pod on the network the webmail's are on, which the server
# believes.
#
# Addresses the test gets banned are unblocked at the end.
#
#   lab/chart/ratelimit-test.sh
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab)
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
PROBE_IMAGE="${PROBE_IMAGE:-$("${K[@]}" -n inbuxa get deploy inbuxa-webmail -o jsonpath='{.spec.template.spec.containers[0].image}')}"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
fail() { echo "!! $*" >&2; exit 1; }
forward() { # <local port> <target> <remote port>
  "${K[@]}" -n inbuxa port-forward "$2" "$1:$3" >/dev/null 2>&1 &
  PIDS+=($!)
}
blocked() { python3 blocked-ips.py http://127.0.0.1:18090 "$STATE/admin.password" list | sort; }
probe() { # <mode> <n> <targets...>: from a pod in "data", outside the chart's pods
  "${K[@]}" -n data run "kw3-probe-$RANDOM" --rm -i --quiet --restart=Never --image="$PROBE_IMAGE" \
    --image-pull-policy=IfNotPresent --env="RUN=$RUN" --env="PACE_MS=${PACE_MS:-700}" --command -- node -e "$(cat probe.js)" "$@"
}

mapfile -t webmail < <("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=webmail \
  --field-selector status.phase=Running -o name | sort)
mapfile -t front < <("${K[@]}" -n inbuxa get pods -l app.kubernetes.io/component=server,inbuxa.org/group=front \
  --field-selector status.phase=Running -o jsonpath='{range .items[*]}{.status.podIP}:8080{"\n"}{end}')
[ "${#webmail[@]}" -ge 2 ] && [ "${#front[@]}" -ge 2 ] || fail "needs two webmail and two front pods"
forward 18090 svc/inbuxa-http 8080
forward 18081 "${webmail[0]}" 8080
forward 18082 "${webmail[1]}" 8080
for port in 18090 18081 18082; do
  for _ in $(seq 30); do curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/" && break; sleep 1; done
done
before=$(blocked)
# The server's counts last a day: a new account name each run
RUN=$(date +%s)
unblock_new() { # what's been banned since $before
  local new
  new=$(comm -13 <(echo "$before") <(blocked) | awk '{print $1}')
  [ -z "$new" ] || python3 blocked-ips.py http://127.0.0.1:18090 "$STATE/admin.password" unblock $new >/dev/null
}

echo "== 1. the webmail's limit counts per replica"
RUN=$RUN python3 - <<'EOF'
import http.client, os, sys
# One client for this run, as an ingress would name it, so the lab's own
# address keeps its allowance for the other tests
client = f"192.0.2.{int(os.environ['RUN']) % 250 + 1}"
# A refusal sends the browser back with signin_error=rate_limited; a start
# sends it to the server's page
def start(port, who=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("GET", "/api/auth/oauth/start?username=alice%40lab.test", headers={"x-forwarded-for": who or client})
    r = c.getresponse(); r.read(); c.close()
    return r.getheader("location") or f"status {r.status}"
def started(where):
    return "rate_limited" not in where and "/login" in where
for i in range(1, 400):
    if "rate_limited" in start(18081):
        break
else:
    sys.exit("!! replica A never refused")
if i < 150:
    sys.exit(f"!! replica A refused {client} at {i}: counted with other clients (the proxy?)")
print(f"replica A: {client}'s sign-in {i} refused (rate_limited)")
if not started(where := start(18082)):
    sys.exit(f"!! replica B: {where}, expected it to start the sign-in")
print(f"replica B: still starts {client}'s sign-in, to the server's page")
other = f"192.0.2.{(int(os.environ['RUN']) + 1) % 250 + 1}"
if not started(where := start(18081, other)):
    sys.exit(f"!! replica A refused {other} too ({where}): it counted the proxy, not the browser")
print(f"== 2. the webmail counts the browser its proxy names\nreplica A: still starts {other}'s sign-in")
EOF

echo "== 3. the server counts failed sign-ins across its pods"
out=$(probe password 110 "${front[@]}")
echo "$out" | sed 's/^/   /'
first=$(grep -m1 ': 403' <<<"$out" | sed 's/^#\([0-9]*\)-.*/\1/')
# Counted per pod, the ban would take about 200; at or under the limit of
# 100 means the pods share one count (fewer if kind reused an address that
# already had failures today)
[ -n "$first" ] && [ "$first" -le 105 ] \
  || fail "expected the ban by about 100 failures across both pods, got: ${first:-none}"
echo "banned after $first failures split across ${#front[@]} pods"
unblock_new

echo "== 4. through a proxy, each client counts, not the proxy"
mid=$(blocked)
out=$(probe password-xff 110 "${front[@]}")
echo "$out" | sed 's/^/   /'
grep -q ': 403' <<<"$out" && fail "a proxy was banned for its clients' failures"
[ "$(blocked)" = "$mid" ] || fail "something new was banned: $(comm -13 <(echo "$mid") <(blocked))"
echo "110 failures for 110 clients: nobody banned"

unblock_new
echo "== all pass"
