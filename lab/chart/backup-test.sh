#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C11 and K-L6: backup and restore. With server.backup and both store
# checks on:
#   1. mail for alice@lab.test, with attachments, and a digest of every
#      mailbox (count, and a hash over each message read whole over IMAP);
#   2. a run of the chart's backup CronJob, which exports the store to the
#      bucket inbuxa-backups in Garage;
#   3. a fresh cluster's stores: the server pods stopped, the database
#      dropped and made again, the blob bucket emptied;
#   4. the export imported, by a Job made from the CronJob's own pod (same
#      config, Secrets and keys), from s3://inbuxa-backups/lab: the newest
#      finished export;
#   5. the chart back up on the restored store: the digest must match, and
#      both store check CronJobs, run once each, must find nothing wrong.
#
# THIS WIPES THE LAB'S STORE AND PUTS THE EXPORT BACK: when step 4 fails,
# the store is empty, and fresh-store.sh sets up a new one. Secrets stay out
# of stdout: the backup key goes to a Secret and to files under $STATE.
#
#   SERVER_TAG=kc11 WEBMAIL_TAG=kw3 lab/chart/backup-test.sh
#
# RESTORE_ONLY=1 skips the mail and the backup, and restores the newest
# finished export into fresh stores (steps 3 to 5, printing the digest):
# the way back from a failed run.
set -euo pipefail

cd "$(dirname "$0")"
CTX=kind-inbuxa-lab
K=(kubectl --context "$CTX" -n inbuxa)
D=(kubectl --context "$CTX" -n data)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
BUCKET=inbuxa-backups
BLOBS=inbuxa-blobs
KEY=inbuxa-lab-backup
URL="s3://$BUCKET/lab"
S3_PORT=13900
fails=0
work=$(mktemp -d)
STAMP=$(date +%s)

check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}
g() { "${D[@]}" exec deploy/garage -- /garage "$@" 2>/dev/null; }
BACKUP=(
  --set server.backup.enabled=true --set server.backup.url="$URL"
  --set server.backup.endpoint=http://garage.data.svc:3900
  --set server.backup.region=garage --set server.backup.existingSecret="$KEY"
  --set server.storeCheck.quick.enabled=true --set server.storeCheck.full.enabled=true
)
install() { # [helm args]
  helm --kube-context "$CTX" -n inbuxa upgrade inbuxa "$CHART" \
    -f values-lab.yaml -f values-frontends.yaml --set server.image.tag="$SERVER_TAG" \
    "${EXTRA[@]}" "$@" --wait --timeout 15m >/dev/null
  for d in front mta core; do "${K[@]}" rollout status deploy/inbuxa-$d --timeout 5m >/dev/null; done
}
FORWARD_PID=""
STORE_EMPTY=""
cleanup() {
  [ -n "$FORWARD_PID" ] && kill "$FORWARD_PID" 2>/dev/null
  "${K[@]}" delete job -l lab.inbuxa.org/backup-test=true --ignore-not-found >/dev/null 2>&1 || true
  # Never start servers on the emptied store: their defaults would be data
  # an import refuses to go over
  if [ -n "$STORE_EMPTY" ]; then
    echo "!! the server pods are stopped and the store is empty: RESTORE_ONLY=1 $0 imports the newest export, or fresh-store.sh sets up a new store" >&2
  else
    install >/dev/null 2>&1 || echo "!! couldn't put the chart back: run frontends-test.sh" >&2
  fi
  rm -rf "$work"
}
trap cleanup EXIT

s3() { # <command> <bucket> [arg]: lab/chart/s3.py as the backup key
  S3_ENDPOINT="http://127.0.0.1:$S3_PORT" S3_REGION=garage \
    S3_ACCESS_KEY_FILE="$STATE/backup-s3.access" S3_SECRET_KEY_FILE="$STATE/backup-s3.secret" \
    python3 s3.py "$@"
}
run_job() { # <cronjob> <job> [--import URL]: a Job from the CronJob's template; waits; log in $work/<job>.log
  local cron="$1" job="$2"; shift 2
  "${K[@]}" get cronjob "$cron" -o json | python3 -c '
import json, sys
cron = json.load(sys.stdin); job, extra = sys.argv[1], sys.argv[2:]
spec = cron["spec"]["jobTemplate"]["spec"]
spec["backoffLimit"] = 0
if extra:
    spec["template"]["spec"]["containers"][0]["args"] = extra + ["--config", "/etc/inbuxa/config.json"]
labels = dict(cron["spec"]["jobTemplate"]["metadata"].get("labels", {}), **{"lab.inbuxa.org/backup-test": "true"})
print(json.dumps({"apiVersion": "batch/v1", "kind": "Job",
                  "metadata": {"name": job, "labels": labels}, "spec": spec}))
' "$job" "$@" | "${K[@]}" apply -f - >/dev/null
  local status=""
  for _ in $(seq 400); do
    status=$("${K[@]}" get job "$job" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{end}')
    case "$status" in *Complete*|*Failed*) break ;; esac
    sleep 3
  done
  "${K[@]}" logs "job/$job" --all-containers >"$work/$job.log" 2>&1 || true
  case "$status" in *Complete*) return 0 ;; *) return 1 ;; esac
}
digest() { ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" python3 mailbox-digest.py "$LB" "$@"; }

echo "== the backup bucket and its key"
g bucket info "$BUCKET" >/dev/null || g bucket create "$BUCKET" >/dev/null
g key info "$KEY" >/dev/null || g key create "$KEY" >/dev/null
g bucket allow --read --write --owner "$BUCKET" --key "$KEY" >/dev/null
# The test empties the blob bucket for the fresh store, as this key
g bucket allow --read --write "$BLOBS" --key "$KEY" >/dev/null
umask 077
g key info --show-secret "$KEY" | awk -F': *' '/^Key ID/{print $2}' | tr -d '\r\n' >"$STATE/backup-s3.access"
g key info --show-secret "$KEY" | awk -F': *' '/^Secret key/{print $2}' | tr -d '\r\n' >"$STATE/backup-s3.secret"
umask 022
[ -s "$STATE/backup-s3.access" ] && [ -s "$STATE/backup-s3.secret" ] || { echo "!! couldn't read the key from Garage" >&2; exit 1; }
"${K[@]}" create secret generic "$KEY" --from-file=access-key="$STATE/backup-s3.access" \
  --from-file=secret-key="$STATE/backup-s3.secret" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
"${D[@]}" port-forward svc/garage "$S3_PORT:3900" >/dev/null 2>&1 &
FORWARD_PID=$!
for _ in $(seq 30); do s3 ls "$BUCKET" x >/dev/null 2>&1 && break; sleep 1; done

echo "== the chart, with the backup and store checks on"
install "${BACKUP[@]}"
LB=$("${K[@]}" get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
check "CronJobs" "$("${K[@]}" get cronjob -l app.kubernetes.io/instance=inbuxa -o name | sort | tr '\n' ' ')" \
  "cronjob.batch/inbuxa-backup cronjob.batch/inbuxa-store-check-full cronjob.batch/inbuxa-store-check-quick "

if [ -z "${RESTORE_ONLY:-}" ]; then
echo "== 1. mail, and its digest"
digest send 5 >"$work/before"
cat "$work/before" | sed 's/^/     /'
held=$(awk -F'\t' '{n += $2} END {print n + 0}' "$work/before")
[ "$held" -ge 5 ] && echo "ok   alice's mailboxes hold $held messages" || { echo "FAIL alice's mailboxes hold $held"; fails=$((fails + 1)); }

echo "== 2. the backup CronJob, once"
if run_job inbuxa-backup "lab-backup-$STAMP"; then echo "ok   the export finished"; else echo "FAIL the export: $(tail -3 "$work/lab-backup-$STAMP.log")"; exit 1; fi
where=$(sed -nE 's/^Exported .* to (s3:\/\/[^ ]+)\.$/\1/p' "$work/lab-backup-$STAMP.log" | tail -1)
name=${where##*/}
echo "     $(grep '^Exported' "$work/lab-backup-$STAMP.log")"
s3 get "$BUCKET" "lab/$name/export.json" >"$work/manifest.json"
check "export.json lists the files in the bucket" \
  "$(python3 -c 'import json,sys; print(sorted(f["name"] for f in json.load(open(sys.argv[1]))["files"]))' "$work/manifest.json")" \
  "$(s3 ls "$BUCKET" "lab/$name/" | sed "s|^lab/$name/||" | grep -v '^export.json$' | python3 -c 'import sys; print(sorted(l.strip() for l in sys.stdin))')"
# The blobs' subspace is t (116)
grep -q '"subspace": 116' "$work/manifest.json" && echo "ok   the export holds the blobs" || { echo "FAIL no blobs in the export"; fails=$((fails + 1)); }
fi

echo "== 3. a fresh cluster's stores"
for d in front mta core; do "${K[@]}" scale deploy/inbuxa-$d --replicas=0 >/dev/null; done
"${K[@]}" wait --for=delete pod -l app.kubernetes.io/component=server --timeout=300s >/dev/null 2>&1 || true
STORE_EMPTY=1
primary=$("${D[@]}" get cluster inbuxa-pg -o jsonpath='{.status.currentPrimary}')
"${D[@]}" exec "$primary" -c postgres -- psql -q -v ON_ERROR_STOP=1 \
  -c 'DROP DATABASE IF EXISTS inbuxa WITH (FORCE)' -c 'CREATE DATABASE inbuxa OWNER inbuxa' >/dev/null
echo "     database dropped and made again; $(s3 empty "$BLOBS") blobs deleted from $BLOBS"
check "blobs left in $BLOBS" "$(s3 ls "$BLOBS" | wc -l)" 0

echo "== 4. the import, from the newest finished export"
if run_job inbuxa-backup "lab-restore-$STAMP" --import "$URL"; then
  echo "ok   the import finished"
else
  echo "FAIL the import: $(tail -5 "$work/lab-restore-$STAMP.log")"
  echo "!! the lab's store is empty: fresh-store.sh sets up a new one" >&2
  exit 1
fi
STORE_EMPTY=""
if [ -z "${RESTORE_ONLY:-}" ]; then
grep -q "Importing the newest finished export, s3://$BUCKET/lab/$name" "$work/lab-restore-$STAMP.log" &&
  echo "ok   it chose $name" || { echo "FAIL it didn't choose $name"; fails=$((fails + 1)); }
else
  echo "     $(grep 'Importing the newest' "$work/lab-restore-$STAMP.log")"
fi
grep -q "into the blob store the export's settings name" "$work/lab-restore-$STAMP.log" &&
  echo "ok   blobs went to the blob store the settings name" || { echo "FAIL blobs went elsewhere"; fails=$((fails + 1)); }
echo "     $BLOBS holds $(s3 ls "$BLOBS" | wc -l) blobs again"

echo "== 5. the chart on the restored store"
install "${BACKUP[@]}"
for _ in $(seq 30); do digest >"$work/after" 2>/dev/null && break; sleep 5; done
if [ -n "${RESTORE_ONLY:-}" ]; then
  sed 's/^/     /' "$work/after"
elif diff -q "$work/before" "$work/after" >/dev/null; then
  echo "ok   every mailbox's count and digest match"
else
  echo "FAIL the mail differs:"; diff "$work/before" "$work/after" | sed 's/^/     /'; fails=$((fails + 1))
fi
for mode in quick full; do
  if run_job "inbuxa-store-check-$mode" "lab-check-$mode-$STAMP"; then
    echo "ok   store check $mode: $(tail -1 "$work/lab-check-$mode-$STAMP.log")"
  else
    echo "FAIL store check $mode: $(tail -2 "$work/lab-check-$mode-$STAMP.log")"; fails=$((fails + 1))
  fi
done

echo
if [ "$fails" -eq 0 ]; then echo "backup-test: all passed"; else echo "backup-test: $fails failed"; exit 1; fi
