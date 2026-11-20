#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L10: the chart under a GitOps controller, after it installed it
# (INSTALL_WITH=TOOL lab/e2e.sh does both). TOOL is argocd or flux.
#
#   1. steady: the app stays in sync across refreshes; nothing is re-applied
#      and no Secret changes (a chart that renders differently each time
#      never settles under Argo CD)
#   2. self-heal: the webmail scaled down by hand comes back to two
#   3. an upgrade, 27.1.0-lab.1 to -lab.2 with every image pinned by digest
#      as a chart release pins them: everything rolls, the upgrade hook
#      runs, and webmail tabs open across it are never signed out
#   4. after it: the same Secrets, mail works, and steady again
#
#   lab/gitops/gitops-test.sh TOOL
#
# Wants SERVER, WEBMAIL and CONSOLE, the tags the install used. Leaves the
# app on -lab.2 with the digests, and prints them as KEY=value lines on fd 3
# when it's open (e2e.sh passes them to the crossing).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/../versions.env"
TOOL="${1:?argocd or flux}"
K=(kubectl --context "kind-$KIND_CLUSTER")
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
G=("$here/gitops.sh")
: "${SERVER:?}" "${WEBMAIL:?}" "${CONSOLE:?}"
WORK="$(mktemp -d)"
trap '"${K[@]}" -n lab-sink delete pod gitops-tabs --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
fail() { echo "!! $*" >&2; exit 1; }

# Every Secret in the namespace by name, uid and a hash of its data; Helm's
# own release records change on every upgrade by design, so they're left out
secrets() {
  "${K[@]}" -n inbuxa get secrets -o json | python3 -c '
import hashlib, json, sys
for s in sorted(json.load(sys.stdin)["items"], key=lambda s: s["metadata"]["name"]):
    if s.get("type") == "helm.sh/release.v1":
        continue
    h = hashlib.sha256(json.dumps(s.get("data", {}), sort_keys=True).encode()).hexdigest()[:16]
    print(s["metadata"]["name"], s["metadata"]["uid"], h)'
}
refresh() {
  if [ "$TOOL" = argocd ]; then
    "${K[@]}" -n argocd annotate application inbuxa argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  else
    "${K[@]}" -n flux-system annotate helmrelease inbuxa reconcile.fluxcd.io/requestedAt="$(date +%s%N)" --overwrite >/dev/null
  fi
}
steady() {
  local before after
  before="$("${G[@]}" deployed "$TOOL")"
  for i in 1 2 3; do
    refresh
    sleep 30
    "${G[@]}" state "$TOOL" > "$WORK/state"
    python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["ok"] else 1)' "$WORK/state" \
      || { cat "$WORK/state" >&2; fail "out of sync or unhealthy on refresh $i"; }
  done
  after="$("${G[@]}" deployed "$TOOL")"
  [ "$before" = "$after" ] || fail "$TOOL applied the chart again with nothing changed ($before, then $after)"
  secrets > "$WORK/secrets.now"
  diff "$WORK/secrets" "$WORK/secrets.now" >/dev/null ||
    { diff "$WORK/secrets" "$WORK/secrets.now" | sed 's/^/   /'; fail "a Secret changed"; }
}
digest_of() { docker buildx imagetools inspect "ghcr.io/inbuxa/$1:$2" --format '{{json .Manifest.Digest}}' | tr -d '"'; }
lb() { "${K[@]}" -n inbuxa get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }

"${G[@]}" wait "$TOOL" "" 600 >/dev/null
secrets > "$WORK/secrets"
grep -q '^inbuxa-webmail' "$WORK/secrets" || fail "no webmail Secret"
echo "   $(wc -l < "$WORK/secrets") Secrets: $(awk '{print $1}' "$WORK/secrets" | tr '\n' ' ')"

echo "== 1. steady: three refreshes"
steady
echo "   in sync each time; nothing re-applied; every Secret as it was"

echo "== 2. self-heal: the webmail scaled to 1 by hand"
"${K[@]}" -n inbuxa scale deploy/inbuxa-webmail --replicas=1 >/dev/null
for _ in $(seq 1 60); do
  [ "$("${K[@]}" -n inbuxa get deploy inbuxa-webmail -o jsonpath='{.spec.replicas}')" = 2 ] && break
  sleep 5
done
[ "$("${K[@]}" -n inbuxa get deploy inbuxa-webmail -o jsonpath='{.spec.replicas}')" = 2 ] || fail "$TOOL didn't put the webmail back"
"${K[@]}" -n inbuxa rollout status deploy/inbuxa-webmail --timeout=180s >/dev/null
"${G[@]}" wait "$TOOL" "" 300 >/dev/null
echo "   back to 2"

echo "== 3. upgrade to 27.1.0-lab.2, every image by digest, under open webmail tabs"
S_D="$(digest_of inbuxa-server "$SERVER")"; W_D="$(digest_of inbuxa-webmail "$WEBMAIL")"; C_D="$(digest_of inbuxa-admin "$CONSOLE")"
for d in "$S_D" "$W_D" "$C_D"; do [[ "$d" =~ ^sha256: ]] || fail "couldn't read a digest: $d"; done
"${K[@]}" create namespace lab-sink --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n lab-sink create configmap webmail-tabs --from-file="$here/../chart/webmail-tabs.py" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n lab-sink create secret generic webmail-tabs --from-file=password="$STATE/alice.password" \
  --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" -n lab-sink delete pod gitops-tabs --ignore-not-found --wait >/dev/null
"${K[@]}" -n lab-sink apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: gitops-tabs}
spec:
  restartPolicy: Never
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
        - {name: STOP_FILE, value: /tmp/stop}
        - {name: INTERVAL, value: "1"}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts:
        - {name: tabs, mountPath: /tabs}
        - {name: secret, mountPath: /secret}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tabs, configMap: {name: webmail-tabs}}
    - {name: secret, secret: {secretName: webmail-tabs, defaultMode: 0440}}
    - {name: tmp, emptyDir: {}}
EOF
"${K[@]}" -n lab-sink wait --for=condition=Ready pod/gitops-tabs --timeout=120s >/dev/null
sleep 10
[ "$("${K[@]}" -n lab-sink get pod gitops-tabs -o jsonpath='{.status.phase}')" = Running ] ||
  { "${K[@]}" -n lab-sink logs gitops-tabs | tail -20 >&2; fail "the tabs stopped before the upgrade"; }

since="$("${G[@]}" op "$TOOL")"
start=$SECONDS
CHART_VERSION=27.1.0-lab.2 SERVER="$S_D" WEBMAIL="$W_D" CONSOLE="$C_D" "${G[@]}" apply "$TOOL" | sed 's/^/   /'
"${G[@]}" wait "$TOOL" "$since" 1500 > "$WORK/state"
for d in front mta core webmail console; do
  "${K[@]}" -n inbuxa rollout status "deploy/inbuxa-$d" --timeout=600s >/dev/null
done
echo "   in after $(( SECONDS - start ))s: $(cat "$WORK/state")"
images="$("${K[@]}" -n inbuxa get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}')"
grep -qv '@sha256:' <<<"$images" && { echo "$images" >&2; fail "a Deployment isn't on a digest"; }
sleep 20

"${K[@]}" -n lab-sink exec gitops-tabs -- touch /tmp/stop
"${K[@]}" -n lab-sink wait --for=jsonpath='{.status.phase}'=Succeeded pod/gitops-tabs --timeout=120s >/dev/null \
  || fail "the tabs didn't finish"
python3 - "$("${K[@]}" -n lab-sink logs gitops-tabs | tail -1)" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
print(f"   tabs: {r['requests']} requests, {r['failed']} failed, signed in {r['signins']} time(s)")
for e in r["errors"][:10]:
    print(f"   {e}")
if r["signins"] != 1:
    print("!! the upgrade signed the tabs out", file=sys.stderr)
    sys.exit(1)
PY

echo "== 4. after the upgrade"
secrets > "$WORK/secrets.now"
diff "$WORK/secrets" "$WORK/secrets.now" >/dev/null ||
  { diff "$WORK/secrets" "$WORK/secrets.now" | sed 's/^/   /'; fail "the upgrade changed a Secret"; }
echo "   every Secret as it was"
ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" timeout 150 python3 "$here/../chart/mailtest.py" "$(lb)"
steady
echo "   steady again"
if { true >&3; } 2>/dev/null; then
  printf 'CHART_VERSION=27.1.0-lab.2\nWEBMAIL=%s\nCONSOLE=%s\n' "$W_D" "$C_D" >&3
fi
echo "== $TOOL: installed, steady, self-healed and upgraded; no Secret changed, nobody signed out"
