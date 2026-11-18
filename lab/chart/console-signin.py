#!/usr/bin/env python3
"""The console's sign-in, as its browser does it.

Loads the console and checks it points at the server; signs in on the
server's page as the public client inbuxa-admin with PKCE, back to the
console's own callback; exchanges the code; and calls the server from the
console's origin, which CORS has to allow. URLs are port-forwards; the
public addresses are names only.

  console-signin.py <console> <server> <console public URL> <server public URL> <account> <password file>
"""
import base64
import hashlib
import http.client
import json
import secrets
import sys
import urllib.parse

console, server, console_url, server_url, account, password_file = sys.argv[1:7]
password = open(password_file).read().strip()


def request(base, method, path, headers=None, body=None):
    u = urllib.parse.urlsplit(base)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    conn.request(method, path, body=body, headers=headers or {})
    res = conn.getresponse()
    data = res.read()
    conn.close()
    return res, data


def fail(msg):
    print("!!", msg)
    sys.exit(1)


# 1. The console, pointed at the server
res, page = request(console, "GET", "/")
csp = res.getheader("content-security-policy") or ""
if res.status != 200 or f'content="{server_url}"' not in page.decode():
    fail(f"console page: {res.status}, api-base-url not {server_url}")
if f"connect-src 'self' {server_url}" not in csp:
    fail(f"console CSP doesn't let it reach the server: {csp}")
print(f"console: served, api-base-url and connect-src name {server_url}")

# 2. The server's page, for the console's client and callback
verifier = secrets.token_urlsafe(48)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
redirect = f"{console_url}/oauth/callback"
res, data = request(server, "POST", "/api/auth", {"content-type": "application/json"}, json.dumps({
    "type": "authCode", "accountName": account, "accountSecret": password,
    "clientId": "inbuxa-admin", "redirectUri": redirect,
    "codeChallenge": challenge, "codeChallengeMethod": "S256", "state": "lab",
}))
answer = json.loads(data or b"{}")
code = answer.get("client_code") or answer.get("clientCode")
if res.status != 200 or not code:
    fail(f"sign-in as inbuxa-admin to {redirect}: {res.status} {answer.get('type')}")
print(f"server: signed {account} in for inbuxa-admin, back to {redirect}")

# 3. The code for a token, as the console's page exchanges it
res, data = request(server, "GET", "/.well-known/oauth-authorization-server")
token_path = urllib.parse.urlsplit(json.loads(data)["token_endpoint"]).path
res, data = request(server, "POST", token_path, {"content-type": "application/x-www-form-urlencoded"},
                    urllib.parse.urlencode({"grant_type": "authorization_code", "code": code,
                                            "redirect_uri": redirect, "client_id": "inbuxa-admin",
                                            "code_verifier": verifier}))
token = json.loads(data or b"{}").get("access_token")
if res.status != 200 or not token:
    fail(f"token exchange: {res.status} {data[:200]!r}")
print("server: exchanged the code for a token")

# 4. From the console's origin: the preflight, then the call
res, _ = request(server, "OPTIONS", "/jmap/session", {
    "origin": console_url, "access-control-request-method": "GET",
    "access-control-request-headers": "authorization"})
allowed = res.getheader("access-control-allow-origin")
if allowed not in (console_url, "*"):
    fail(f"preflight from {console_url}: {res.status}, allow-origin {allowed}")
res, data = request(server, "GET", "/jmap/session", {"authorization": f"Bearer {token}", "origin": console_url})
if res.status != 200 or res.getheader("access-control-allow-origin") not in (console_url, "*"):
    fail(f"JMAP session from {console_url}: {res.status}")
print(f"server: allows {console_url}; the token opens {json.loads(data).get('username')}'s session")
