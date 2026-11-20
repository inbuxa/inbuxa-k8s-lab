#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""An account's mail, as something two stores can be compared by: one line
per mailbox with its message count and a SHA-256 over the sorted SHA-256s
of its messages, read whole over IMAPS (993). Or, with `send N`, N messages
to the account over SMTP (25) first, each with an attachment, and waits
until IMAP shows them (in any mailbox).

  ACCOUNT=user@domain PASSWORD_FILE=... mailbox-digest.py LB [send N]

The lab's certificate is self-signed, so TLS isn't verified.
"""
import hashlib, imaplib, os, re, smtplib, ssl, sys, time, uuid
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

lb = sys.argv[1]
account = os.environ["ACCOUNT"]
password = open(os.environ["PASSWORD_FILE"]).read().strip()
tls = ssl.create_default_context()
tls.check_hostname = False
tls.verify_mode = ssl.CERT_NONE


def imap():
    m = imaplib.IMAP4_SSL(lb, 993, ssl_context=tls, timeout=30)
    m.login(account, password)
    return m


def names(m):
    typ, boxes = m.list()
    for line in boxes:
        name = re.search(rb'"([^"]*)"$|(\S+)$', line.strip())
        yield (name.group(1) or name.group(2)).decode()


def total(m):
    # Every mailbox: the spam filter may put a test message in Junk
    count = 0
    for name in names(m):
        typ, data = m.select(f'"{name}"', readonly=True)
        if typ == "OK":
            count += int(data[0])
    return count


if len(sys.argv) > 2 and sys.argv[2] == "send":
    count = int(sys.argv[3])
    m = imap()
    before = total(m)
    run = uuid.uuid4().hex[:8]
    # A session per message: servers cap the messages one session may send
    for i in range(count):
        with smtplib.SMTP(lb, 25, timeout=30) as s:
            msg = EmailMessage()
            # Its own sender domain: the default throttle allows 25 an hour
            # from one sender domain to one recipient
            msg["From"] = f"lab-sender@m{i}.{run}.sender.test"
            msg["To"] = account
            msg["Subject"] = f"backup-test {run} {i}"
            msg["Date"] = formatdate()
            msg["Message-ID"] = make_msgid(domain="sender.test")
            msg.set_content(f"Sent by the inbuxa-k8s-lab backup test, {i} of {count}.\n")
            msg.add_attachment((f"line {i}: " + uuid.uuid4().hex + "\n") * (60 + 17 * i),
                               filename=f"notes-{i}.txt")
            s.send_message(msg)
        # Under the default 5 a second from one address
        time.sleep(0.3)
    for _ in range(60):
        if total(m) >= before + count:
            break
        time.sleep(2)
    else:
        sys.exit(f"only {total(m) - before} of {count} arrived")
    m.logout()

m = imap()
for name in list(names(m)):
    typ, data = m.select(f'"{name}"', readonly=True)
    if typ != "OK":
        continue
    count = int(data[0])
    hashes = []
    if count:
        typ, data = m.fetch(f"1:{count}", "(BODY.PEEK[])")
        hashes = sorted(hashlib.sha256(part[1]).hexdigest()
                        for part in data if isinstance(part, tuple))
    digest = hashlib.sha256("\n".join(hashes).encode()).hexdigest()
    print(f"{name}\t{count}\t{digest}")
m.logout()
