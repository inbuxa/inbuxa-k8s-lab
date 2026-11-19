#!/usr/bin/env python3
"""JMAP method calls as admin@lab.test, read as JSON from stdin.

  admin-jmap.py <server> <admin password file> < calls.json

Signs in like the console (as blocked-ips.py) and prints the
methodResponses as JSON. Exits non-zero on an HTTP error.
"""
import base64, hashlib, http.client, json, secrets, sys, urllib.parse
server, pwfile = sys.argv[1:]
def request(method, path, headers=None, body=None):
    u = urllib.parse.urlsplit(server); c = http.client.HTTPConnection(u.hostname, u.port, timeout=60)
    c.request(method, path, body=body, headers=headers or {}); r = c.getresponse(); d = r.read(); c.close(); return r, d
v = secrets.token_urlsafe(48); ch = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()
red = "https://admin.lab.test/oauth/callback"
r, d = request("POST", "/api/auth", {"content-type": "application/json"}, json.dumps({"type": "authCode", "accountName": "admin@lab.test",
    "accountSecret": open(pwfile).read().strip(), "clientId": "inbuxa-admin", "redirectUri": red, "codeChallenge": ch, "codeChallengeMethod": "S256", "state": "x"}))
code = json.loads(d)["client_code"]
r, d = request("POST", "/auth/token", {"content-type": "application/x-www-form-urlencoded"}, urllib.parse.urlencode({"grant_type": "authorization_code",
    "code": code, "redirect_uri": red, "client_id": "inbuxa-admin", "code_verifier": v}))
tok = json.loads(d)["access_token"]
r, d = request("POST", "/jmap", {"content-type": "application/json", "authorization": "Bearer " + tok},
               json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:inbuxa:jmap:registry"], "methodCalls": json.load(sys.stdin)}))
if r.status != 200:
    sys.exit(f"jmap: HTTP {r.status}: {d[:300]!r}")
print(json.dumps(json.loads(d)["methodResponses"]))
