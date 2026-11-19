#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L3: the chart as the lab installs it passes Pod Security "restricted" and
# the policies in defaults.yaml, and what breaks a default is refused. Runs
# against a scratch namespace with server-side dry runs, so it changes
# nothing but that namespace's NetworkPolicies, and removes it after.
#
#   lab/policy/policy-test.sh
set -euo pipefail

cd "$(dirname "$0")"
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
NS=policy-test
K=(kubectl --context kind-inbuxa-lab)
H=(helm --kube-context kind-inbuxa-lab)
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

"${K[@]}" apply -f defaults.yaml 2>&1 | grep -v '^Warning: <nil>' >/dev/null
"${K[@]}" create namespace "$NS" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${K[@]}" label --overwrite namespace "$NS" inbuxa.org/policy=enforce \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted >/dev/null
trap '"${K[@]}" delete namespace "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

# render <release> [helm args]: the chart as the lab installs it
render() {
  local release=$1; shift
  "${H[@]}" template "$release" "$CHART" -n "$NS" -f ../chart/values-lab.yaml -f ../chart/values-frontends.yaml \
    --set server.upgrade.acknowledgeLayout=3 "$@"
}
# pick <kinds> [patch]: those documents only, optionally changed by a Python
# expression on each one (d)
pick() {
  python3 -c '
import sys, yaml
kinds, patch = sys.argv[1].split(","), (sys.argv[2] if len(sys.argv) > 2 else "")
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] in kinds]
for d in docs:
    if patch: exec(patch)
print(yaml.safe_dump_all(docs))' "$@"
}
dry_run() { "${K[@]}" apply -n "$NS" --dry-run=server -f - 2>&1 || true; }

echo "== the chart as the lab installs it"
render pt | pick NetworkPolicy | "${K[@]}" apply -n "$NS" -f - >/dev/null
out=$(render pt | pick Deployment,Job | dry_run)
if grep -q 'denied\|violate PodSecurity' <<<"$out"; then fail "refused:"; echo "$out"; else pass "every Deployment and Job admitted"; fi
# Until the chart's server image is 27.1-rc.32 (inbuxa-charts#19)
grep -q 'secrets are mounted as files' <<<"$out" && echo "     (warned: a secret in the server's environment, until rc.32)"

echo "== bad values"
out=$(render pt2 --set networkPolicy.enabled=false | pick Deployment | dry_run)
grep -q 'deny-all NetworkPolicy' <<<"$out" && pass "networkPolicy.enabled=false is refused" || { fail "networkPolicy.enabled=false got through"; echo "$out"; }

out=$(render pt --set-json 'webmail.extraEnv=[{"name":"LEAK","valueFrom":{"secretKeyRef":{"name":"inbuxa-data","key":"pg-password"}}}]' \
  --show-only templates/webmail.yaml | pick Deployment | dry_run)
grep -q 'secrets are mounted as files' <<<"$out" && pass "a secret in webmail.extraEnv is flagged (warn until rc.32, then refused)" \
  || { fail "a secret in webmail.extraEnv got through"; echo "$out"; }

if render pt --set-json 'webmail.securityContext={"readOnlyRootFilesystem":false}' >/dev/null 2>&1; then
  fail "the schema took webmail.securityContext"
else
  pass "no value turns the security context off: the schema refuses webmail.securityContext"
fi

echo "== what the chart can't render, if someone edits a manifest"
out=$(render pt | pick Deployment 'd["spec"]["template"]["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"] = False' | dry_run)
grep -q 'read-only root filesystem' <<<"$out" && pass "a writable root is refused" || { fail "a writable root got through"; echo "$out"; }

out=$(render pt | pick Deployment 'd["spec"]["template"]["spec"]["automountServiceAccountToken"] = True' | dry_run)
grep -q 'service-account token' <<<"$out" && pass "a service-account token is refused" || { fail "a service-account token got through"; echo "$out"; }

out=$(render pt | pick Deployment 'd["spec"]["template"]["spec"]["containers"][0]["securityContext"]["capabilities"] = {"add": ["NET_ADMIN"]}' | dry_run)
grep -q 'violate PodSecurity' <<<"$out" && pass "an added capability is refused (Pod Security restricted)" || { fail "an added capability got through"; echo "$out"; }

echo
[ "$fails" = 0 ] && echo "== all pass" || { echo "== $fails failed"; exit 1; }
