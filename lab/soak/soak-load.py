#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""The soak's steady mail load (K-L7), from outside the cluster through its
load balancer, as real clients reach it. Runs until killed, and picks up
where it left off when started again: everything it knows is in STATE.

  ACCOUNT=user@domain PASSWORD_FILE=... STATE=dir soak-load.py LB

  inbound   a message every IN_EVERY s (10) over SMTP 25, each from its own
            sender domain, retried like an MTA when refused
  verify    every 30 s, over IMAPS: which arrived (any mailbox), then
            deleted, so the mailbox stays small; a number seen again after
            that came twice
  outbound  a message every OUT_EVERY s (60) over submission 465 with AUTH,
            to soak-0@sink.test ... soak-9@sink.test in turn (the server
            allows 25 an hour from one sender domain to one recipient, and
            probe@sink.test is left to chart/mailcheck.py); soak-watch.py
            checks the sink received each once
  idle      IDLE_CLIENTS (2) IMAP connections in IDLE: how often they're
            told of new mail, and how often they drop. They watch the
            mailbox the soak's mail lands in (verify finds it: unknown
            senders' mail goes to Junk Mail), as a client watches INBOX

STATE/load.json is rewritten every 30 s; STATE/events.jsonl gets a line
for anything that went wrong. The lab's certificate is self-signed, so TLS
isn't verified.
"""
import imaplib, json, os, re, smtplib, socket, ssl, sys, threading, time, uuid
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

lb = sys.argv[1]
account = os.environ["ACCOUNT"]
password = open(os.environ["PASSWORD_FILE"]).read().strip()
state_dir = os.environ["STATE"]
IN_EVERY = float(os.environ.get("IN_EVERY", "10"))
OUT_EVERY = float(os.environ.get("OUT_EVERY", "60"))
IDLE_CLIENTS = int(os.environ.get("IDLE_CLIENTS", "2"))
SINK_SPREAD = int(os.environ.get("SINK_SPREAD", "10"))
tls = ssl.create_default_context()
tls.check_hostname = False
tls.verify_mode = ssl.CERT_NONE
lock = threading.RLock()  # event() and save() are called with it held
STATE = os.path.join(state_dir, "load.json")
EVENTS = os.path.join(state_dir, "events.jsonl")

try:
    S = json.load(open(STATE))
except (OSError, ValueError):
    S = {"run": uuid.uuid4().hex[:8], "started": time.time(),
         "inbound": {"next": 1, "sent": 0, "retries": 0, "arrived": 0, "twice": 0},
         "pending": {}, "arrived_late": 0, "slowest_s": 0,
         "outbound": {"next": 1, "sent": 0, "retries": 0}, "out_sent": {},
         "idle": {"notices": 0, "drops": 0, "longest_quiet_s": 0},
         "seen": {}, "starts": 0}
S["starts"] += 1
run = S["run"]


def event(kind, detail):
    with lock:
        with open(EVENTS, "a") as f:
            f.write(json.dumps({"at": time.time(), "kind": kind, "detail": str(detail)[:200]}) + "\n")


def save():
    with lock:
        # A duplicate a day late is still caught; older arrivals are dropped
        old = time.time() - 2 * 86400
        S["seen"] = {n: v for n, v in S.get("seen", {}).items() if v[1] > old}
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(S, f)
        os.replace(tmp, STATE)


def message(frm, to, subject):
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = frm, to, subject
    msg["Date"] = formatdate()
    msg["Message-ID"] = make_msgid(domain=f"{run}.soak.test")
    msg.set_content(subject + "\n")
    return msg


def every(seconds, fn):
    """fn() every `seconds`, keeping to the schedule; fn handles its errors."""
    nxt = time.time()
    while True:
        fn()
        nxt += seconds
        time.sleep(max(0, nxt - time.time()))


def inbound():
    with lock:
        n = S["inbound"]["next"]
    # A sender domain per message: the default throttle allows 25 an hour
    # from one sender domain to one recipient
    msg = message(f"soak@m{n}.{run}.sender.test", account, f"soak {run} in {n}")
    try:
        # As an MTA waits (RFC 5321 4.5.3.2); see chart/mailflow.py
        with smtplib.SMTP(timeout=20) as s:
            s.connect(lb, 25)
            s.sock.settimeout(300)
            s.send_message(msg)
    except (OSError, smtplib.SMTPException) as e:
        with lock:
            S["inbound"]["retries"] += 1
        event("inbound-retry", f"{n}: {type(e).__name__}: {e}")
        return  # the same number goes again next time
    with lock:
        S["inbound"]["next"] = n + 1
        S["inbound"]["sent"] += 1
        S["pending"][str(n)] = time.time()
    save()  # at once: a restart must never send a number twice


def outbound():
    with lock:
        n = S["outbound"]["next"]
    msg = message(account, f"soak-{n % SINK_SPREAD}@sink.test", f"soak {run} out {n}")
    try:
        with smtplib.SMTP_SSL(lb, 465, context=tls, timeout=20) as s:
            s.sock.settimeout(300)
            s.login(account, password)
            s.send_message(msg)
    except (OSError, smtplib.SMTPException) as e:
        with lock:
            S["outbound"]["retries"] += 1
        event("outbound-retry", f"{n}: {type(e).__name__}: {e}")
        return
    with lock:
        S["outbound"]["next"] = n + 1
        S["outbound"]["sent"] += 1
        S["out_sent"][str(n)] = time.time()
    save()


SUBJECT = re.compile(rf"soak {run} in (\d+)")


def verify():
    try:
        m = imaplib.IMAP4_SSL(lb, 993, ssl_context=tls, timeout=60)
    except OSError as e:
        event("verify", f"connect: {e}")
        return
    try:
        m.login(account, password)
        _, boxes = m.list()
        for line in boxes:
            name = line.decode().rsplit(' "/" ', 1)[-1].strip()
            if m.select(name)[0] != "OK":
                continue
            _, data = m.search(None, "SUBJECT", f'"soak {run} in"')
            ids = data[0].split()
            if not ids:
                continue
            _, hdrs = m.fetch(b",".join(ids), "(UID BODY.PEEK[HEADER.FIELDS (SUBJECT)])")
            now = time.time()
            for part in hdrs:
                if not isinstance(part, tuple):
                    continue
                mm = SUBJECT.search(part[1].decode(errors="replace"))
                uid = re.search(rb"UID (\d+)", part[0])
                if not mm or not uid:
                    continue
                n, copy = mm.group(1), f"{name}:{uid.group(1).decode()}"
                with lock:
                    sent = S["pending"].pop(n, None)
                    if sent is not None:
                        S["inbound"]["arrived"] += 1
                        S["seen"][n] = [copy, now]
                        S["landed"] = name
                        took = now - sent
                        S["slowest_s"] = max(S["slowest_s"], round(took))
                        if took > 900:
                            S["arrived_late"] += 1
                    elif S["seen"].get(n, [None])[0] != copy:
                        S["inbound"]["twice"] += 1
                        S["seen"][n] = [copy, now]
                        event("twice", f"in {n} arrived again ({name})")
                    # else: this very copy, left by a delete that was cut short
            # What arrived is on disk before it's deleted, so a restart in
            # between neither loses it nor counts it twice
            save()
            m.store(b",".join(ids), "+FLAGS", "\\Deleted")
            m.expunge()
    except (OSError, imaplib.IMAP4.error) as e:
        event("verify", f"{type(e).__name__}: {e}")
    finally:
        try:
            m.logout()
        except Exception:
            pass
    save()


def idle(i):
    """One client in IDLE, as a desktop mail app holds it; re-issued every
    25 minutes (RFC 2177 asks for under 29)."""
    while not S.get("landed"):
        time.sleep(5)
    last_notice = time.time()
    while True:
        sock = None
        try:
            raw = socket.create_connection((lb, 993), timeout=30)
            sock = tls.wrap_socket(raw, server_hostname="mail.lab.test")
            f = sock.makefile("rb")

            def cmd(tag, text):
                sock.sendall(f"{tag} {text}\r\n".encode())
                while True:
                    line = f.readline()
                    if not line:
                        raise ConnectionError("closed")
                    if line.startswith(tag.encode() + b" "):
                        if b" OK" not in line[:12]:
                            raise ConnectionError(line.decode(errors="replace").strip())
                        return

            f.readline()  # greeting
            cmd("a1", f'LOGIN "{account}" "{password}"')
            cmd("a2", f"SELECT {S['landed']}")
            n = 3
            while True:
                tag = f"a{n}"
                n += 1
                sock.sendall(f"{tag} IDLE\r\n".encode())
                sock.settimeout(60)
                renew = time.time() + 25 * 60
                while time.time() < renew:
                    try:
                        line = f.readline()
                    except socket.timeout:
                        continue
                    if not line:
                        raise ConnectionError("closed in IDLE")
                    if line.endswith(b"EXISTS\r\n"):
                        now = time.time()
                        with lock:
                            S["idle"]["notices"] += 1
                            S["idle"]["longest_quiet_s"] = max(S["idle"]["longest_quiet_s"], round(now - last_notice))
                        last_notice = now
                sock.sendall(b"DONE\r\n")
                sock.settimeout(30)
                while not f.readline().startswith(tag.encode() + b" "):
                    pass
        except (OSError, ConnectionError, ssl.SSLError) as e:
            with lock:
                S["idle"]["drops"] += 1
            event("idle-drop", f"client {i}: {type(e).__name__}: {e}")
        finally:
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass
        time.sleep(5)


save()
event("start", f"run {run}, start {S['starts']}")
for target in ([lambda: every(IN_EVERY, inbound), lambda: every(OUT_EVERY, outbound), lambda: every(30, verify)]
               + [(lambda i=i: idle(i)) for i in range(IDLE_CLIENTS)]):
    threading.Thread(target=target, daemon=True).start()
while True:
    time.sleep(30)
    save()
