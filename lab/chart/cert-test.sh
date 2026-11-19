#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C8: certificates from a TLS Secret, renewed in place. Plays cert-manager's
# part: makes a TLS Secret for mx.lab.test, has the chart mount it
# (server.certificates.secrets), and checks IMAPS on the mail Service serves
# it; then replaces the Secret's certificate, as a renewal does, and checks
# every connection gets the new one within five minutes, with no pod
# restarted.
#
# Leaves the chart as it found it and deletes the Secret.
#
#   SERVER_TAG=kc8 WEBMAIL_TAG=kw3 lab/chart/cert-test.sh
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
SECRET=inbuxa-lab-mail-tls
NAME=mx.lab.test
fails=0

install() { # [helm args]: the lab's install, with the webmail and console
  helm --kube-context kind-inbuxa-lab -n inbuxa upgrade inbuxa "$CHART" \
    -f values-lab.yaml -f values-frontends.yaml --set server.image.tag="$SERVER_TAG" \
    "${EXTRA[@]}" "$@" --wait --timeout 10m >/dev/null
  for d in front mta; do "${K[@]}" rollout status deploy/inbuxa-$d --timeout 5m >/dev/null; done
}
work=$(mktemp -d)
cleanup() {
  install >/dev/null 2>&1 || echo "!! couldn't put the chart back: run frontends-test.sh" >&2
  "${K[@]}" delete secret "$SECRET" --ignore-not-found >/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

make_cert() { # <name>: a self-signed certificate for $NAME in $work/<name>.{crt,key}
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj "/CN=$NAME" -addext "subjectAltName=DNS:$NAME" \
    -keyout "$work/$1.key" -out "$work/$1.crt" 2>/dev/null
  openssl x509 -in "$work/$1.crt" -noout -fingerprint -sha256 | cut -d= -f2
}
put_secret() { # <name>
  "${K[@]}" create secret tls "$SECRET" --cert "$work/$1.crt" --key "$work/$1.key" \
    --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
}
served() { # the fingerprint IMAPS on the mail Service shows for $NAME
  openssl s_client -connect "$LB:993" -servername "$NAME" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}
pods() { # the server pods not on their way out, with their restart counts
  "${K[@]}" get pods -l app.kubernetes.io/component=server \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {.metadata.deletionTimestamp}{"\n"}{end}' |
    awk 'NF == 1 { printf "%s ", $1 }'
}
settle() { # until the last rollout's old pods are gone
  for _ in $(seq 60); do
    [ -z "$("${K[@]}" get pods -l app.kubernetes.io/component=server -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}')" ] && return
    sleep 3
  done
}
check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}

LB=$("${K[@]}" get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
FIRST=$(make_cert first)
NEXT=$(make_cert next)

echo "== 1. the Secret's certificate is served"
put_secret first
install --set-json "server.certificates.secrets=[\"$SECRET\"]"
settle
got=""
for _ in $(seq 20); do got=$(served); [ -n "$got" ] && break; sleep 3; done
check "IMAPS serves the Secret's certificate" "$got" "$FIRST"
before=$(pods)

echo "== 2. renewed in place"
put_secret next
start=$(date +%s); streak=0
while [ $(($(date +%s) - start)) -lt 300 ] && [ "$streak" -lt 8 ]; do
  if [ "$(served)" = "$NEXT" ]; then streak=$((streak + 1)); else streak=0; sleep 5; fi
done
check "every connection gets the renewed certificate ($(($(date +%s) - start))s)" "$streak" 8
check "no pod restarted or replaced" "$(pods)" "$before"

echo
[ "$fails" = 0 ] && echo "== all pass" || { echo "== $fails failed"; exit 1; }
