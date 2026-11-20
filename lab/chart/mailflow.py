#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Mail flowing through an upgrade (K-L5): sends one message a second over
SMTP (25), each from its own sender domain, until STOP_FILE appears, as a sending MTA would, so a refused or
dropped connection is retried rather than lost. Then waits for every
message the server accepted to show up over IMAPS (993) and checks each
arrived exactly once.

  ACCOUNT=user@domain PASSWORD_FILE=... STOP_FILE=... mailflow.py LB

Prints a summary line and exits 1 if anything accepted was lost or came
twice. The lab's certificate is self-signed, so TLS isn't verified.
"""
import imaplib, os, re, smtplib, ssl, sys, time, uuid
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

lb = sys.argv[1]
account = os.environ["ACCOUNT"]
password = open(os.environ["PASSWORD_FILE"]).read().strip()
stop = os.environ["STOP_FILE"]
run = uuid.uuid4().hex[:8]
tls = ssl.create_default_context()
tls.check_hostname = False
tls.verify_mode = ssl.CERT_NONE


def send(n):
    msg = EmailMessage()
    # A sender domain per message: the server's default throttle allows 25
    # an hour from one sender domain to one recipient
    msg["From"] = f"lab-sender@m{n}.{run}.sender.test"
    msg["To"] = account
    msg["Subject"] = f"mailflow {run} {n}"
    msg["Date"] = formatdate()
    msg["Message-ID"] = make_msgid(domain=f"{run}.sender.test")
    msg.set_content(f"mailflow {run} message {n}\n")
    with smtplib.SMTP(lb, 25, timeout=20) as s:
        s.send_message(msg)


accepted, retries, started = 0, 0, time.time()
while not os.path.exists(stop):
    n = accepted + 1
    try:
        send(n)
        accepted = n
    except (OSError, smtplib.SMTPException) as e:
        # Refused, reset or a 4xx: a real MTA tries again later
        retries += 1
        print(f"  retry {n}: {type(e).__name__}: {e}"[:160], flush=True)
        time.sleep(2)
        continue
    time.sleep(1)
sent_for = time.time() - started


def count():
    """How many times each message number of this run is in the account."""
    seen = {}
    m = imaplib.IMAP4_SSL(lb, 993, ssl_context=tls, timeout=30)
    try:
        m.login(account, password)
        _, boxes = m.list()
        for line in boxes:
            name = line.decode().rsplit(' "/" ', 1)[-1].strip()
            if m.select(name, readonly=True)[0] != "OK":
                continue
            _, data = m.search(None, "SUBJECT", f'"mailflow {run}"')
            ids = data[0].split()
            if not ids:
                continue
            _, hdrs = m.fetch(b",".join(ids), "(BODY.PEEK[HEADER.FIELDS (SUBJECT)])")
            for part in hdrs:
                if isinstance(part, tuple):
                    mm = re.search(rf"mailflow {run} (\d+)", part[1].decode())
                    if mm:
                        seen[int(mm.group(1))] = seen.get(int(mm.group(1)), 0) + 1
    finally:
        try:
            m.logout()
        except Exception:
            pass
    return seen


deadline = time.time() + 180
while True:
    try:
        seen = count()
    except (OSError, imaplib.IMAP4.error) as e:
        print(f"  imap: {e}"[:160], flush=True)
        seen = {}
    missing = [n for n in range(1, accepted + 1) if n not in seen]
    if not missing or time.time() > deadline:
        break
    time.sleep(5)

twice = sorted(n for n, c in seen.items() if c > 1)
print(f"mailflow {run}: {accepted} accepted over {sent_for:.0f}s, {retries} retried, "
      f"{accepted - len(missing)} arrived, {len(missing)} missing, {len(twice)} twice")
if missing:
    print(f"  missing: {missing[:20]}")
if twice:
    print(f"  twice: {twice[:20]}")
sys.exit(1 if missing or twice or accepted == 0 else 0)
