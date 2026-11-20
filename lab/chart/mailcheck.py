#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""The mail test client (K-L2): what a mail client and the internet do with
an installed chart, each check named, one table at the end.

  KCTX=kind-inbuxa-lab mailcheck.py LB HTTP ALICE_PASSWORD_FILE ADMIN_PASSWORD_FILE

LB is the mail Service's address (25, 465, 993), HTTP the server's http
port (http://127.0.0.1:N through a port-forward). Checks, as alice@lab.test:

  smtp in      a message from another domain on 25
  submission   alice sends on 465 (implicit TLS, AUTH): to herself, and out
  imap         both arrive, found over IMAPS on 993
  jmap         both found with Email/query, signed in with OAuth
  smtp out     the outgoing one reaches the outside server (mail-sink.yaml)
               from alice, DKIM-signed for lab.test
  caldav       an event put, read back and deleted
  carddav      a contact the same

Mail for sink.test goes to the sink by a Relay route this sets up, as
admin@lab.test, if it isn't there (route "lab-sink" and one line in the
outbound strategy). Exits 1 if any check failed. The lab's certificate is
self-signed, so TLS isn't verified.
"""
import base64, hashlib, http.client as httpc, imaplib, json, os, secrets, smtplib, ssl
import subprocess, sys, time, urllib.parse, uuid
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

lb, http_base, alice_pw_file, admin_pw_file = sys.argv[1:5]
KCTX = os.environ.get("KCTX", "kind-inbuxa-lab")
ALICE = "alice@lab.test"
alice_pw = open(alice_pw_file).read().strip()
admin_pw = open(admin_pw_file).read().strip()
run = uuid.uuid4().hex[:10]
SINK = "sink.lab-sink.svc.cluster.local"
tls = ssl.create_default_context()
tls.check_hostname = False
tls.verify_mode = ssl.CERT_NONE
results = []


def check(name):
    def wrap(fn):
        t = time.time()
        try:
            detail = fn() or ""
            results.append((name, True, detail, time.time() - t))
        except Exception as e:  # each check reports, the rest still run
            results.append((name, False, f"{type(e).__name__}: {e}"[:200], time.time() - t))
        return fn
    return wrap


def web(method, path, body=None, headers=None):
    u = urllib.parse.urlsplit(http_base)
    c = httpc.HTTPConnection(u.hostname, u.port, timeout=60)
    h = {"Host": "mail.lab.test"}
    h.update(headers or {})
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    d = r.read()
    c.close()
    return r.status, d


def oauth(account, password):
    """A bearer token, signed in as the console does (its OAuth client)."""
    v = secrets.token_urlsafe(48)
    ch = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()
    red = "https://admin.lab.test/oauth/callback"
    s, d = web("POST", "/api/auth", json.dumps({
        "type": "authCode", "accountName": account, "accountSecret": password, "clientId": "inbuxa-admin",
        "redirectUri": red, "codeChallenge": ch, "codeChallengeMethod": "S256", "state": "x"}),
        {"content-type": "application/json"})
    if s != 200:
        raise RuntimeError(f"/api/auth for {account}: HTTP {s} {d[:120]!r}")
    code = json.loads(d)["client_code"]
    s, d = web("POST", "/auth/token", urllib.parse.urlencode({
        "grant_type": "authorization_code", "code": code, "redirect_uri": red,
        "client_id": "inbuxa-admin", "code_verifier": v}),
        {"content-type": "application/x-www-form-urlencoded"})
    if s != 200:
        raise RuntimeError(f"/auth/token for {account}: HTTP {s}")
    return json.loads(d)["access_token"]


def jmap(token, using, calls):
    s, d = web("POST", "/jmap", json.dumps({"using": using, "methodCalls": calls}),
                {"content-type": "application/json", "authorization": "Bearer " + token})
    if s != 200:
        raise RuntimeError(f"jmap: HTTP {s} {d[:160]!r}")
    out = json.loads(d)["methodResponses"]
    for name, args, tag in out:
        if name == "error":
            raise RuntimeError(f"jmap {tag}: {args}")
    return out


def ensure_sink_route():
    """Mail for sink.test to the sink: a Relay route and its strategy line."""
    reg = ["urn:ietf:params:jmap:core", "urn:inbuxa:jmap:registry"]
    tok = oauth("admin@lab.test", admin_pw)
    routes, strategy = jmap(tok, reg, [["x:MtaRoute/get", {}, "r"],
                                       ["x:MtaOutboundStrategy/get", {"ids": ["singleton"]}, "s"]])
    if not any(r.get("name") == "lab-sink" for r in routes[1]["list"]):
        jmap(tok, reg, [["x:MtaRoute/set", {"create": {"sink": {
            "@type": "Relay", "name": "lab-sink", "description": "The lab's outside mail server (mail-sink.yaml)",
            "address": SINK, "port": 25, "protocol": "smtp", "implicitTls": False,
            "allowInvalidCerts": True}}}, "c"]])
    route = strategy[1]["list"][0]["route"]
    rule = {"if": "rcpt_domain == 'sink.test'", "then": "'lab-sink'"}
    if rule not in route["match"].values():
        match = {str(i): m for i, m in enumerate([rule] + list(route["match"].values()))}
        jmap(tok, reg, [["x:MtaOutboundStrategy/set", {"update": {"singleton": {
            "route": {"match": match, "else": route["else"]}}}}, "u"]])
    # The strategy reaches every node by the cluster's config reload
    time.sleep(5)


def message(frm, to, subject):
    m = EmailMessage()
    m["From"], m["To"], m["Subject"] = frm, to, subject
    m["Date"] = formatdate()
    m["Message-ID"] = make_msgid(domain=frm.split("@")[1])
    m.set_content(f"{subject}\n")
    return m


SUBJECT = f"mailcheck {run}"
sent = {}


@check("smtp in")
def smtp_in():
    # A sender domain of its own: the default throttle allows 25 an hour
    # from one sender domain to one recipient
    with smtplib.SMTP(lb, 25, timeout=30) as s:
        s.send_message(message(f"lab-sender@{run}.sender.test", ALICE, f"{SUBJECT} in"))
    sent["in"] = f"{SUBJECT} in"
    return "accepted on 25"


@check("submission")
def submission():
    ensure_sink_route()
    with smtplib.SMTP_SSL(lb, 465, timeout=30, context=tls) as s:
        s.login(ALICE, alice_pw)
        s.send_message(message(ALICE, ALICE, f"{SUBJECT} self"))
        s.send_message(message(ALICE, "probe@sink.test", f"{SUBJECT} out"))
    sent["self"], sent["out"] = f"{SUBJECT} self", f"{SUBJECT} out"
    return "accepted on 465 with AUTH: to alice and to probe@sink.test"


def imap_find():
    found = {}
    m = imaplib.IMAP4_SSL(lb, 993, ssl_context=tls, timeout=30)
    try:
        m.login(ALICE, alice_pw)
        _, boxes = m.list()
        for line in boxes:
            name = line.decode().rsplit(' "/" ', 1)[-1].strip()
            if m.select(name, readonly=True)[0] != "OK":
                continue
            for key in ("in", "self"):
                if key in sent:
                    _, data = m.search(None, "SUBJECT", f'"{sent[key]}"')
                    if data[0].split():
                        found[key] = name.strip('"')
    finally:
        m.logout()
    return found


@check("imap")
def imap():
    want = {k for k in ("in", "self") if k in sent}
    if not want:
        raise RuntimeError("nothing was sent")
    deadline, found = time.time() + 90, {}
    while time.time() < deadline:
        found = imap_find()
        if want <= found.keys():
            return ", ".join(f"{k} in {v}" for k, v in sorted(found.items()))
        time.sleep(2)
    raise RuntimeError(f"not found over IMAPS: {sorted(want - found.keys())}")


@check("jmap")
def jmap_check():
    tok = oauth(ALICE, alice_pw)
    s, d = web("GET", "/jmap/session", None, {"authorization": "Bearer " + tok})
    if s != 200:
        raise RuntimeError(f"session: HTTP {s}")
    acct = json.loads(d)["primaryAccounts"]["urn:ietf:params:jmap:mail"]
    using = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
    deadline = time.time() + 90
    while True:
        out = jmap(tok, using, [
            ["Email/query", {"accountId": acct, "filter": {"subject": SUBJECT}}, "q"],
            ["Email/get", {"accountId": acct, "#ids": {"resultOf": "q", "name": "Email/query", "path": "/ids"},
                           "properties": ["subject"]}, "g"]])
        subjects = sorted(e["subject"] for e in out[1][1]["list"])
        want = sorted(sent[k] for k in ("in", "self") if k in sent)
        if want and all(w in subjects for w in want):
            return f"Email/query found {len(subjects)}"
        if time.time() > deadline:
            raise RuntimeError(f"Email/query found {subjects}, wanted {want}")
        time.sleep(3)


@check("smtp out")
def smtp_out():
    if "out" not in sent:
        raise RuntimeError("nothing was sent")
    deadline = time.time() + 90
    while True:
        logs = subprocess.run(["kubectl", "--context", KCTX, "-n", "lab-sink", "logs", "deploy/sink"],
                              capture_output=True, text=True, timeout=30).stdout
        for line in logs.splitlines():
            if not line.startswith("{"):
                continue
            rec = json.loads(line)
            if rec["subject"] == sent["out"]:
                if rec["from"] != ALICE or rec["rcpts"] != ["probe@sink.test"]:
                    raise RuntimeError(f"arrived wrong: from {rec['from']} to {rec['rcpts']}")
                if not any("d=lab.test" in h.replace(" ", "") for h in rec["dkim"]):
                    raise RuntimeError("arrived without a DKIM signature for lab.test")
                return f"reached the sink from {rec['ehlo'] or '?'}, DKIM d=lab.test"
        if time.time() > deadline:
            raise RuntimeError("never reached the sink")
        time.sleep(3)


BASIC = {"authorization": "Basic " + base64.b64encode(f"{ALICE}:{alice_pw}".encode()).decode()}


def dav_roundtrip(collection, name, ctype, body, marker):
    path = f"/dav/{collection}/alice%40lab.test/default/{name}"
    s, _ = web("PUT", path, body.encode(), dict(BASIC, **{"content-type": ctype}))
    if s not in (201, 204):
        raise RuntimeError(f"PUT: HTTP {s}")
    s, d = web("GET", path, None, BASIC)
    if s != 200 or marker not in d.decode():
        raise RuntimeError(f"GET: HTTP {s}, {'with' if marker in d.decode() else 'without'} it")
    s, _ = web("DELETE", path, None, BASIC)
    if s not in (200, 204):
        raise RuntimeError(f"DELETE: HTTP {s}")
    s, _ = web("GET", path, None, BASIC)
    if s != 404:
        raise RuntimeError(f"still there after DELETE: HTTP {s}")
    return "put, read back, deleted"


@check("caldav")
def caldav():
    uid = f"mailcheck-{run}@lab.test"
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    ics = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//inbuxa lab//mailcheck//EN\r\nBEGIN:VEVENT\r\n"
           f"UID:{uid}\r\nDTSTAMP:{stamp}\r\nDTSTART:{stamp}\r\nDURATION:PT30M\r\n"
           f"SUMMARY:mailcheck {run}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    return dav_roundtrip("cal", f"{run}.ics", "text/calendar; charset=utf-8", ics, uid)


@check("carddav")
def carddav():
    uid = f"mailcheck-{run}"
    vcf = (f"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:{uid}\r\nFN:Mailcheck {run}\r\n"
           f"EMAIL:probe@{run}.sender.test\r\nEND:VCARD\r\n")
    return dav_roundtrip("card", f"{run}.vcf", "text/vcard; charset=utf-8", vcf, uid)


width = max(len(n) for n, *_ in results)
print(f"mailcheck {run}:")
for name, ok, detail, took in results:
    print(f"  {'ok  ' if ok else 'FAIL'} {name:<{width}}  {took:5.1f}s  {detail}")
sys.exit(0 if all(ok for _, ok, *_ in results) else 1)
