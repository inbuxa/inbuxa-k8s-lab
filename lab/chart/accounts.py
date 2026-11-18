#!/usr/bin/env python3
"""Creates the smoke test's mail account, through a recovery-mode node.

  RECOVERY_ADMIN=admin:pw PASSWORD_FILE=... accounts.py URL DOMAIN USER

The password is generated here and written to PASSWORD_FILE (0600); it
never goes to stdout. An account that exists already gets the new password.
"""
import base64, json, os, secrets, sys, urllib.request

url, domain, user = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
auth = "Basic " + base64.b64encode(os.environ["RECOVERY_ADMIN"].encode()).decode()
USING = ["urn:ietf:params:jmap:core", "urn:inbuxa:jmap:registry"]


def call(calls):
    req = urllib.request.Request(url + "/jmap", data=json.dumps({"using": USING, "methodCalls": calls}).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": auth})
    return json.load(urllib.request.urlopen(req, timeout=60))["methodResponses"]


r = call([["x:Domain/query", {"filter": {"name": domain}}, "q"],
          ["x:Domain/get", {"#ids": {"resultOf": "q", "name": "x:Domain/query", "path": "/ids"}, "properties": ["name"]}, "g"]])
domains = [d for d in r[1][1]["list"] if d["name"] == domain]
if not domains:
    sys.exit(f"no domain {domain}: {json.dumps(r)[:400]}")
domain_id = domains[0]["id"]

password = secrets.token_urlsafe(24)
r = call([["x:Account/set", {"create": {"a": {
    "@type": "User", "name": user, "domainId": domain_id,
    "credentials": {"0": {"@type": "Password", "secret": password}}, "roles": {"@type": "User"}}}}, "c"]])
created = r[0][1].get("created", {})
if not created:
    sys.exit("account not created: " + json.dumps(r[0][1].get("notCreated"))[:400])
fd = os.open(os.environ["PASSWORD_FILE"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, password.encode()); os.close(fd)
print(f"account {user}@{domain} created")
