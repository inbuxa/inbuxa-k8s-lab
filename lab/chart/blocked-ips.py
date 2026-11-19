#!/usr/bin/env python3
"""The server's blocked addresses, as admin@lab.test.

  blocked-ips.py <server> <admin password file> list
  blocked-ips.py <server> <admin password file> unblock <ip>...

Signs in like the console (authCode with PKCE), then x:BlockedIp/get or
x:BlockedIp/set destroy. list prints one address per line.
"""
import base64, hashlib, http.client, json, secrets, sys, urllib.parse
server, pwfile, action, *ips = sys.argv[1:]
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
def jmap(calls):
    r, d = request("POST", "/jmap", {"content-type": "application/json", "authorization": "Bearer " + tok},
                   json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:inbuxa:jmap:registry"], "methodCalls": calls}))
    return json.loads(d)["methodResponses"]
res = jmap([["x:BlockedIp/get", {"ids": None}, "g"]])
items = res[0][1].get("list", [])
if action == "list":
    for i in items: print(i.get("address"), i.get("reason"), i.get("expiresAt"))
else:
    ids = [i["id"] for i in items if any(ip in json.dumps(i) for ip in ips)]
    if ids: print(json.dumps(jmap([["x:BlockedIp/set", {"destroy": ids}, "d"]])[0][1].get("destroyed")))
    else: print("nothing to unblock")
