#!/usr/bin/env bash
# A new store set up by the server's --seed, the way the chart will do it:
# wipes the lab's inbuxa database, then runs seed-job.yaml with seed.json.
#
#   IMAGE=inbuxa-lab/server:main lab/chart/seed-store.sh
#
# The administrator's and alice's passwords are generated here, put in
# Secret inbuxa-seed, and kept under $STATE (0600); never printed.
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab)
IMAGE="${IMAGE:-inbuxa-lab/server:main}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
mkdir -p "$STATE" && chmod 700 "$STATE"

new_password() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }
umask 077

echo "== stopping everything on the old store"
"${K[@]}" -n inbuxa scale deploy --all --replicas=0 >/dev/null 2>&1 || true
"${K[@]}" -n inbuxa wait --for=delete pod -l app.kubernetes.io/component=server --timeout=180s >/dev/null 2>&1 || true

echo "== a fresh database"
primary="$("${K[@]}" -n data get cluster inbuxa-pg -o jsonpath='{.status.currentPrimary}')"
"${K[@]}" -n data exec "$primary" -c postgres -- psql -q -v ON_ERROR_STOP=1 \
  -c 'DROP DATABASE IF EXISTS inbuxa WITH (FORCE)' -c 'CREATE DATABASE inbuxa OWNER inbuxa'

echo "== the seed and its secrets"
new_password > "$STATE/admin.password"
new_password > "$STATE/alice.password"
"${K[@]}" -n inbuxa get secret inbuxa-s3 -o jsonpath='{.data.access-key}' | base64 -d > "$STATE/s3-access-key"
"${K[@]}" -n inbuxa delete secret inbuxa-seed --ignore-not-found >/dev/null
"${K[@]}" -n inbuxa create secret generic inbuxa-seed \
  --from-file=admin-password="$STATE/admin.password" \
  --from-file=alice-password="$STATE/alice.password" \
  --from-file=s3-access-key="$STATE/s3-access-key" >/dev/null
rm -f "$STATE/s3-access-key"
"${K[@]}" -n inbuxa create configmap inbuxa-lab-seed --from-file=seed.json --dry-run=client -o yaml \
  | "${K[@]}" apply -f - >/dev/null

echo "== the seed run"
"${K[@]}" -n inbuxa delete job inbuxa-seed --ignore-not-found --wait >/dev/null
sed "s|image: IMAGE|image: $IMAGE|" seed-job.yaml | "${K[@]}" apply -f - >/dev/null
if ! "${K[@]}" -n inbuxa wait --for=condition=Complete job/inbuxa-seed --timeout=300s >/dev/null 2>&1; then
  "${K[@]}" -n inbuxa logs job/inbuxa-seed --tail=40 >&2 || true
  echo "!! the seed run failed" >&2
  exit 1
fi
"${K[@]}" -n inbuxa logs job/inbuxa-seed | grep -E "seed|store layout" | grep -v "^20..-" || true

echo "== done: admin@lab.test and alice@lab.test, passwords in $STATE"
