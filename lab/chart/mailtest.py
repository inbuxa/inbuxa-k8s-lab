#!/usr/bin/env python3
"""The chart smoke test's mail check: a message in over SMTP on port 25,
then found over IMAPS on 993, both through the mail Service's address.

  ACCOUNT=user@domain PASSWORD_FILE=... mailtest.py LB_ADDRESS

The server's certificate is self-signed in the lab, so TLS isn't verified.
"""
import imaplib, os, smtplib, ssl, sys, time, uuid
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

lb = sys.argv[1]
account = os.environ["ACCOUNT"]
password = open(os.environ["PASSWORD_FILE"]).read().strip()
token = uuid.uuid4().hex
tls = ssl.create_default_context()
tls.check_hostname = False
tls.verify_mode = ssl.CERT_NONE

msg = EmailMessage()
# A sender domain with no DNS at all: one that publishes DMARC (example.net
# does, p=reject) would send the message to Junk
# ...and one of its own each run: the server's default throttle allows 25
# messages an hour from one sender domain to one recipient
msg["From"] = f"lab-sender@{token[:12]}.sender.test"
msg["To"] = account
msg["Subject"] = f"chart smoke {token}"
msg["Date"] = formatdate()
msg["Message-ID"] = make_msgid(domain="sender.test")
msg.set_content("Sent by the inbuxa-k8s-lab chart smoke test.\n")

started = time.time()
with smtplib.SMTP(lb, 25, timeout=30) as smtp:
    smtp.ehlo("lab-client.sender.test")
    if smtp.has_extn("starttls"):
        smtp.starttls(context=tls)
        smtp.ehlo("lab-client.sender.test")
    smtp.send_message(msg)
print(f"SMTP: accepted for {account}")

deadline = started + 90
while True:
    with imaplib.IMAP4_SSL(lb, 993, ssl_context=tls, timeout=30) as imap:
        imap.login(account, password)
        # The lab has no public DNS, so the sender can't pass SPF, DKIM or
        # reverse DNS and the spam filter files it in Junk, rightly. The test
        # is the path through the chart, so either folder will do.
        where = None
        for folder in ("INBOX", "Junk Mail", "Junk"):
            if imap.select(f'"{folder}"', readonly=True)[0] != "OK":
                continue
            _, found = imap.search(None, "SUBJECT", f'"{token}"')
            if found[0].split():
                where = folder
                break
        if where:
            print(f"IMAPS: delivered to {where}, found after {time.time() - started:.1f}s")
            break
    if time.time() > deadline:
        sys.exit("IMAPS: the message never arrived")
    time.sleep(3)
