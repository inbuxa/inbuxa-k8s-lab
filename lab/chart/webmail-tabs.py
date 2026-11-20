#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Open webmail tabs through a restart (K-W5), run inside the cluster so
every connection goes through the webmail Service, as a browser's would
through an ingress.

  ACCOUNT=... PASSWORD_FILE=... STOP_FILE=... webmail-tabs.py WEBMAIL SERVER

Signs in once, then until STOP_FILE appears:

  - TABS tabs (default 3), each holding /api/events open as EventSource
    does: when a stream ends it reconnects after a second
  - a JMAP Mailbox/get every 200 ms, as a busy tab's requests

and prints one JSON line: requests made and failed (with the errors), and
per tab how its streams ended (cleanly, or cut off mid-stream) and the
longest wait for a stream to deliver again. A clean end is what the
browser takes in its stride; a failed request is what shows an error.
"""
import http.client, json, os, sys, threading, time, urllib.parse

webmail, server = sys.argv[1:3]
account = os.environ["ACCOUNT"]
password = open(os.environ["PASSWORD_FILE"]).read().strip()
stop = os.environ["STOP_FILE"]
TABS = int(os.environ.get("TABS", "3"))


def request(base, method, path, headers=None, body=None, timeout=30):
    u = urllib.parse.urlsplit(base)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=timeout)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        res = conn.getresponse()
        return res, res.read()
    finally:
        conn.close()


def cookie(res, name):
    for header, value in res.getheaders():
        if header.lower() == "set-cookie" and value.startswith(name + "="):
            return value.split(";", 1)[0].split("=", 1)[1]
    return None


def sign_in():
    res, _ = request(webmail, "GET", "/api/auth/oauth/start?username=" + urllib.parse.quote(account))
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(res.getheader("location")).query))
    bound = cookie(res, "ihm_session_signin")
    res, data = request(server, "POST", "/api/auth", {"content-type": "application/json"}, json.dumps({
        "type": "authCode", "accountName": account, "accountSecret": password, "clientId": q["client_id"],
        "redirectUri": q["redirect_uri"], "scope": q.get("scope"), "codeChallenge": q["code_challenge"],
        "codeChallengeMethod": q["code_challenge_method"], "state": q["state"]}))
    a = json.loads(data)
    code = a.get("client_code") or a.get("clientCode")
    res, _ = request(webmail, "GET", "/api/auth/callback?" + urllib.parse.urlencode({"code": code, "state": q["state"]}),
                     {"cookie": f"ihm_session_signin={bound}"})
    session = cookie(res, "ihm_session")
    res, data = request(webmail, "GET", "/api/auth/session", {"cookie": f"ihm_session={session}"})
    return session, json.loads(data)["primaryAccounts"]["urn:ietf:params:jmap:mail"]


session, mail_account = sign_in()
H = {"cookie": f"ihm_session={session}"}
lock = threading.Lock()
report = {"requests": 0, "failed": 0, "errors": [], "tabs": []}


def tab(i):
    me = {"streams": 0, "clean_ends": 0, "cut_off": 0, "longest_gap_s": 0.0}
    with lock:
        report["tabs"].append(me)
    last_event = time.time()
    u = urllib.parse.urlsplit(webmail)
    while not os.path.exists(stop):
        try:
            conn = http.client.HTTPConnection(u.hostname, u.port, timeout=45)
            conn.request("GET", "/api/events?types=*&closeafter=no&ping=30", headers=dict(H, accept="text/event-stream"))
            res = conn.getresponse()
            if res.status != 200:
                raise RuntimeError(f"HTTP {res.status}")
            me["streams"] += 1
            while not os.path.exists(stop):
                line = res.readline()
                if not line:
                    me["clean_ends"] += 1   # the stream ended properly
                    break
                if line.startswith((b"event:", b":")):
                    now = time.time()
                    me["longest_gap_s"] = max(me["longest_gap_s"], round(now - last_event, 1))
                    last_event = now
            conn.close()
        except Exception as e:  # reset, refused, an incomplete chunk: cut off
            if os.path.exists(stop):
                break
            me["cut_off"] += 1
            with lock:
                report["errors"].append(f"tab {i} stream: {type(e).__name__}: {e}"[:160])
        time.sleep(1)   # EventSource's first retry, as push.ts does


threads = [threading.Thread(target=tab, args=(i,), daemon=True) for i in range(TABS)]
for t in threads:
    t.start()

body = json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
                   "methodCalls": [["Mailbox/get", {"accountId": mail_account, "properties": ["name"]}, "0"]]})
while not os.path.exists(stop):
    with lock:
        report["requests"] += 1
    try:
        res, data = request(webmail, "POST", "/api/jmap", dict(H, **{"content-type": "application/json",
                            "x-requested-with": "ihasmail"}), body)
        if res.status != 200 or b"Mailbox/get" not in data:
            raise RuntimeError(f"HTTP {res.status} {data[:80]!r}")
    except Exception as e:
        with lock:
            report["failed"] += 1
            report["errors"].append(f"request: {type(e).__name__}: {e}"[:160])
    time.sleep(0.2)

for t in threads:
    t.join(timeout=50)
report["errors"] = report["errors"][:15]
print(json.dumps(report))
