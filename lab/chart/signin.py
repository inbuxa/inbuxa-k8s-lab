#!/usr/bin/env python3
"""A browser signing in to the webmail across two replicas.

Starts the sign-in on webmail replica A, signs in on the server's page (its
API, as the page itself does), comes back to replica B, then uses the
session on both: B and A each fetch the account's session from the server,
and each runs a JMAP Mailbox/get. Every URL is a port-forward; the public
addresses are names only.

  signin.py <webmail A> <webmail B> <server> <account> <password file>
"""
import http.client
import json
import sys
import urllib.parse

a, b, server, account, password_file = sys.argv[1:6]
password = open(password_file).read().strip()


def request(base, method, path, headers=None, body=None):
    u = urllib.parse.urlsplit(base)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    conn.request(method, path, body=body, headers=headers or {})
    res = conn.getresponse()
    data = res.read()
    conn.close()
    return res, data


def cookie(res, name):
    for header, value in res.getheaders():
        if header.lower() == "set-cookie" and value.startswith(name + "="):
            return value.split(";", 1)[0].split("=", 1)[1]
    return None


def fail(msg):
    print("!!", msg)
    sys.exit(1)


# 1. Replica A sends the browser to the server's page
res, _ = request(a, "GET", "/api/auth/oauth/start?username=" + urllib.parse.quote(account))
if res.status != 302:
    fail(f"start on A: {res.status}")
to = urllib.parse.urlsplit(res.getheader("location"))
q = dict(urllib.parse.parse_qsl(to.query))
bound = cookie(res, "ihm_session_signin")
if not bound:
    fail("start on A set no state cookie")
print(f"A: sends the browser to {to.scheme}://{to.netloc}{to.path} as {q['client_id']}, "
      f"state cookie {len(bound)} bytes")

# 2. The server's page: the account's password, for this client and redirect
res, data = request(server, "POST", "/api/auth", {"content-type": "application/json"}, json.dumps({
    "type": "authCode",
    "accountName": account,
    "accountSecret": password,
    "clientId": q["client_id"],
    "redirectUri": q["redirect_uri"],
    "scope": q.get("scope"),
    "codeChallenge": q["code_challenge"],
    "codeChallengeMethod": q["code_challenge_method"],
    "state": q["state"],
}))
answer = json.loads(data or b"{}")
code = answer.get("client_code") or answer.get("clientCode")
if res.status != 200 or not code:
    fail(f"server sign-in: {res.status} {answer.get('type')}")
print(f"server: signed {account} in, code issued for {q['redirect_uri']}")

# 3. The browser comes back to replica B
res, _ = request(b, "GET", "/api/auth/callback?" + urllib.parse.urlencode({"code": code, "state": q["state"]}),
                 {"cookie": f"ihm_session_signin={bound}"})
where = res.getheader("location")
session = cookie(res, "ihm_session")
if res.status != 302 or where != "/" or not session:
    fail(f"callback on B: {res.status} -> {where}")
print(f"B: finished the sign-in A started, session cookie {len(session)} bytes")

# 4. The session works on both
for name, base in (("B", b), ("A", a)):
    res, data = request(base, "GET", "/api/auth/session", {"cookie": f"ihm_session={session}"})
    if res.status != 200:
        fail(f"session on {name}: {res.status} {data[:200]!r}")
    mail_account = json.loads(data).get("primaryAccounts", {}).get("urn:ietf:params:jmap:mail")
    if not mail_account:
        fail(f"session on {name} names no mail account")
    res, data = request(base, "POST", "/api/jmap", {
        "cookie": f"ihm_session={session}",
        "content-type": "application/json",
        "x-requested-with": "ihasmail",
    }, json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
                   "methodCalls": [["Mailbox/get", {"accountId": mail_account, "properties": ["name"]}, "0"]]}))
    body = json.loads(data or b"{}")
    calls = body.get("methodResponses") or []
    if res.status != 200 or not calls or calls[0][0] != "Mailbox/get":
        fail(f"JMAP on {name}: {res.status} {str(body)[:300]}")
    print(f"{name}: session and JMAP work ({len(calls[0][1].get('list', []))} mailboxes)")
