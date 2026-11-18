#!/usr/bin/env python3
"""First boot of a fresh store through a bootstrap-mode node (bootstrap-pod.yaml).

  BOOTSTRAP_ADMIN=admin:pw bootstrap.py http://127.0.0.1:18080 MAIL_HOST DOMAIN

Names PostgreSQL as the data store (password as a File secret), creates the
administrator, listeners and keys. Prints the administrator's username; the
password goes to the file named by ADMIN_OUT (0600), never to stdout.
"""
import base64, json, os, sys, urllib.request

url, host, domain = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
auth = "Basic " + base64.b64encode(os.environ["BOOTSTRAP_ADMIN"].encode()).decode()
update = {
    "serverHostname": host, "defaultDomain": domain, "requestTlsCertificate": False, "generateDkimKeys": True,
    "tracer": {"@type": "Stdout", "enable": True, "level": "info", "ansi": False, "multiline": False, "lossy": False,
               "events": {}, "eventsPolicy": "exclude"},
    "dataStore": {"@type": "PostgreSql", "host": "inbuxa-pg-rw.data.svc", "port": 5432, "database": "inbuxa",
                  "authUsername": "inbuxa", "authSecret": {"@type": "File", "filePath": "/etc/inbuxa/secrets/pg-password"},
                  "useTls": False, "poolMaxConnections": 20},
}
body = {"using": ["urn:ietf:params:jmap:core", "urn:inbuxa:jmap:registry"],
        "methodCalls": [["x:Bootstrap/set", {"update": {"singleton": update}}, "0"]]}
req = urllib.request.Request(url + "/jmap", data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "Authorization": auth})
resp = json.load(urllib.request.urlopen(req, timeout=120))["methodResponses"][0]
if resp[0] == "error" or resp[1].get("notUpdated"):
    sys.exit("bootstrap failed: " + json.dumps(resp)[:800])
admin = resp[1]["updated"]["singleton"]
out = os.environ.get("ADMIN_OUT", "admin.json")
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(admin).encode()); os.close(fd)
print("administrator:", admin.get("username"), "(password in", out + ")")
