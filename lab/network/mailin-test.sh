#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-C6: mail from outside keeps the client's address, in both of the chart's
# modes. Each message goes to alice@lab.test from the bench, and the address
# the server put in its Received header is checked:
#
#   1. Local: straight to the mail Service (externalTrafficPolicy Local):
#      the bench's own address on the kind network
#   2. PROXY: the chart with server.services.mail.proxyProtocol on, trusting
#      an HAProxy on the kind network (the stand-in for a cloud load
#      balancer), which sends PROXY v2: the bench's address, not HAProxy's
#   3. a PROXY header from someone the server doesn't trust (the bench,
#      straight to the Service) claiming 203.0.113.66: not believed
#
# Leaves the chart as it found it (PROXY off) and removes HAProxy.
#
#   SERVER_TAG=kc6 WEBMAIL_TAG=kw3 lab/network/mailin-test.sh
set -euo pipefail

cd "$(dirname "$0")"
K=(kubectl --context kind-inbuxa-lab -n inbuxa)
CHART="${CHART:-../../../inbuxa-charts/charts/inbuxa}"
STATE="${STATE:-$HOME/.cache/inbuxa-lab}"
SERVER_TAG="${SERVER_TAG:?the server image tag in kind}"
EXTRA=()
[ -n "${WEBMAIL_TAG:-}" ] && EXTRA+=(--set webmail.image.tag="$WEBMAIL_TAG")
HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.0-alpine}"
fails=0

install() { # [helm args]: the lab's install, with the webmail and console
  helm --kube-context kind-inbuxa-lab -n inbuxa upgrade inbuxa "$CHART" \
    -f ../chart/values-lab.yaml -f ../chart/values-frontends.yaml --set server.image.tag="$SERVER_TAG" \
    "${EXTRA[@]}" "$@" --wait --timeout 10m >/dev/null
  for d in front mta; do "${K[@]}" rollout status deploy/inbuxa-$d --timeout 5m >/dev/null; done
}
cleanup() {
  docker rm -f inbuxa-lab-haproxy >/dev/null 2>&1 || true
  install >/dev/null 2>&1 || echo "!! couldn't put the chart back: run frontends-test.sh" >&2
}
trap cleanup EXIT

LB=$("${K[@]}" get svc inbuxa-mail -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
BENCH=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -m1 '\.')
[ -n "$LB" ] && [ -n "$BENCH" ] || { echo "!! no mail Service address, or no bench address on the kind network"; exit 1; }

# send <host> <port> [proxy-claim]: one message to alice, then the address
# in the first Received header the server wrote
send() {
  ACCOUNT=alice@lab.test PASSWORD_FILE="$STATE/alice.password" LB="$LB" python3 - "$@" <<'EOF'
import imaplib, os, smtplib, socket, ssl, struct, sys, time, uuid, re, ipaddress
host, port = sys.argv[1], int(sys.argv[2])
claim = sys.argv[3] if len(sys.argv) > 3 else None
token = uuid.uuid4().hex
msg = (f"From: lab-sender@sender.test\r\nTo: alice@lab.test\r\nSubject: mail-in {token}\r\n"
       f"Message-ID: <{token}@sender.test>\r\n\r\nK-C6\r\n")
class Smtp(smtplib.SMTP):
    # Writes a PROXY v2 header claiming another client before SMTP starts
    def _get_socket(self, host, port, timeout):
        s = socket.create_connection((host, port), timeout)
        if claim:
            src = ipaddress.IPv4Address(claim).packed; dst = ipaddress.IPv4Address(os.environ["LB"]).packed
            body = src + dst + struct.pack("!HH", 40000, 25)
            s.sendall(b"\r\n\r\n\x00\r\nQUIT\n" + bytes([0x21, 0x11]) + struct.pack("!H", len(body)) + body)
        return s
try:
    with Smtp(host, port, timeout=30) as smtp:
        smtp.ehlo("lab-client.sender.test")
        smtp.sendmail("lab-sender@sender.test", ["alice@lab.test"], msg)
except (smtplib.SMTPException, OSError) as err:
    print(f"refused ({type(err).__name__})"); sys.exit(0)
tls = ssl.create_default_context(); tls.check_hostname = False; tls.verify_mode = ssl.CERT_NONE
deadline = time.time() + 90
while time.time() < deadline:
    with imaplib.IMAP4_SSL(os.environ["LB"], 993, ssl_context=tls, timeout=30) as imap:
        imap.login(os.environ["ACCOUNT"], open(os.environ["PASSWORD_FILE"]).read().strip())
        for folder in ("INBOX", "Junk Mail", "Junk"):
            if imap.select(f'"{folder}"', readonly=True)[0] != "OK": continue
            _, found = imap.search(None, "SUBJECT", f'"{token}"')
            if found[0].split():
                _, data = imap.fetch(found[0].split()[-1], "(BODY.PEEK[HEADER.FIELDS (RECEIVED)])")
                received = data[0][1].decode(errors="replace")
                m = re.search(r"\[([0-9a-fA-F.:]+)\]", received)
                print(m.group(1) if m else "no address in: " + received.strip()[:200]); sys.exit(0)
    time.sleep(3)
print("never arrived")
EOF
}
check() { # <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); fi
}

echo "== 1. Local: straight to the mail Service at $LB"
install
check "client address" "$(send "$LB" 25)" "$BENCH"

echo "== 2. PROXY: through HAProxy, the only address trusted"
docker rm -f inbuxa-lab-haproxy >/dev/null 2>&1 || true
cfg=$(mktemp); trap 'rm -f "$cfg"; cleanup' EXIT
printf 'defaults\n  mode tcp\n  timeout connect 5s\n  timeout client 60s\n  timeout server 60s\nfrontend smtp\n  bind :25\n  default_backend inbuxa\nbackend inbuxa\n  server lb %s:25 send-proxy-v2\n' "$LB" >"$cfg"
chmod 644 "$cfg"
# On 25, as a cloud load balancer would be: the server tells mail from the
# internet by port 25, which it reads from the PROXY header's destination
docker run -d --name inbuxa-lab-haproxy --network kind --sysctl net.ipv4.ip_unprivileged_port_start=25 -v "$cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" "$HAPROXY_IMAGE" >/dev/null
HAPROXY=$(docker inspect inbuxa-lab-haproxy -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
install --set server.services.mail.proxyProtocol.enabled=true \
  --set-json "server.services.mail.proxyProtocol.trustedNetworks=[\"$HAPROXY\"]"
echo "     HAProxy at $HAPROXY"
check "client address through HAProxy" "$(send "$HAPROXY" 25)" "$BENCH"

echo "== 3. a PROXY header from someone not trusted"
got=$(send "$LB" 25 203.0.113.66)
if [ "$got" = 203.0.113.66 ]; then
  echo "FAIL forged PROXY header believed: $got"; fails=$((fails + 1))
else
  echo "ok   forged PROXY header not believed: $got"
fi

echo
[ "$fails" = 0 ] && echo "== all pass" || { echo "== $fails failed"; exit 1; }
