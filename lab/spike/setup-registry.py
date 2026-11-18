#!/usr/bin/env python3
"""Point a fresh store at the lab's NATS and S3 and create the role groups,
through a recovery-mode node (setup-pod.yaml) reached on a local port.

  RECOVERY_ADMIN=admin:pw S3_ACCESS_KEY=... setup-registry.py http://127.0.0.1:18080 [all|show]

Secrets stay out of the registry: NATS and S3 secrets are File secrets every
node reads from /etc/inbuxa/secrets. Only the S3 access key id is a value.

Role groups (the chart's front / mta / core):
  core   no INBUXA_ROLE: everything, including the task scheduler
  peer   protocols, task queue, indexing, maintenance; no scheduler, no
         outbound, no spam training, no metrics, no push notifications
  peer-mta  peer plus outbound mail
"""
import base64, json, os, sys, urllib.error, urllib.request

URL = sys.argv[1].rstrip("/")
STEP = sys.argv[2] if len(sys.argv) > 2 else "all"
AUTH = "Basic " + base64.b64encode(os.environ["RECOVERY_ADMIN"].encode()).decode()
USING = ["urn:ietf:params:jmap:core", "urn:inbuxa:jmap:registry"]
SECRETS = "/etc/inbuxa/secrets"
PEER_OFF = ["taskScheduler", "outboundMta", "spamClassifierTraining", "metricsCalculate", "metricsPush", "pushNotifications"]


def call(calls):
    req = urllib.request.Request(URL + "/jmap", data=json.dumps({"using": USING, "methodCalls": calls}).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": AUTH})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)["methodResponses"]
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:500]}")


def redact(o):
    if isinstance(o, dict):
        return {k: "<redacted>" if any(x in k.lower() for x in ("secret", "password", "token")) else redact(v) for k, v in o.items()}
    return [redact(x) for x in o] if isinstance(o, list) else o


def ok(resps):
    bad = False
    for name, args, tag in resps:
        problems = {k: args[k] for k in ("notCreated", "notUpdated", "notDestroyed") if args.get(k)}
        if name == "error" or problems:
            bad = True
            print(tag, "PROBLEM", json.dumps(redact(problems or args))[:600])
        else:
            print(tag, "OK")
    if bad:
        sys.exit(1)


if STEP == "all":
    ok(call([["x:BlobStore/set", {"update": {"singleton": {
        "@type": "S3", "bucket": "inbuxa-blobs",
        "region": {"@type": "Custom", "customEndpoint": "http://garage.data.svc:3900", "customRegion": "garage"},
        "accessKey": {"@type": "Value", "value": os.environ["S3_ACCESS_KEY"]},
        "secretKey": {"@type": "File", "filePath": f"{SECRETS}/s3-secret-key"},
        "timeout": 30000, "maxRetries": 3, "verifyAfterWrite": False}}}, "blob"]]))
    ok(call([["x:Coordinator/set", {"update": {"singleton": {
        "@type": "Nats", "addresses": {"nats.data.svc:4222": True}, "authUsername": "inbuxa",
        "authSecret": {"@type": "File", "filePath": f"{SECRETS}/nats-password"}}}}, "coord"]]))
    have = {r["name"]: r["id"] for r in call([["x:ClusterRole/get", {"ids": None}, "r"]])[0][1]["list"]}
    want = {
        "peer": {"description": "front: protocols, task queue, indexing, maintenance; no scheduler, no outbound",
                 "tasks": {"@type": "DisableSome", "taskTypes": {t: True for t in PEER_OFF}}, "listeners": {"@type": "EnableAll"}},
        "peer-mta": {"description": "mta: peer plus outbound mail",
                     "tasks": {"@type": "DisableSome", "taskTypes": {t: True for t in PEER_OFF if t != "outboundMta"}},
                     "listeners": {"@type": "EnableAll"}},
    }
    ok(call([["x:ClusterRole/set", {"create": {n: dict(v, name=n) for n, v in want.items() if n not in have},
                                    "update": {have[n]: v for n, v in want.items() if n in have}}, "roles"]]))
r = call([["x:BlobStore/get", {"ids": ["singleton"]}, "b"], ["x:Coordinator/get", {"ids": ["singleton"]}, "c"],
          ["x:ClusterRole/get", {"ids": None, "properties": ["name"]}, "r"], ["x:NetworkListener/get", {"ids": None}, "l"]])
print(json.dumps(redact(r), indent=1)[:5000])
