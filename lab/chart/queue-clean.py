#!/usr/bin/env python3
"""Removes the queued messages a test sent: from a sender, since a time.

  queue-clean.py <server> <admin password file> <sender> <since, ISO 8601 UTC>

Prints how many it removed.
"""
import json, subprocess, sys
server, pwfile, sender, since = sys.argv[1:]
here = __file__.rsplit("/", 1)[0]
def jmap(calls):
    out = subprocess.run([sys.executable, f"{here}/admin-jmap.py", server, pwfile], input=json.dumps(calls),
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)
got = jmap([["x:QueuedMessage/query", {}, "q"],
            ["x:QueuedMessage/get", {"#ids": {"resultOf": "q", "name": "x:QueuedMessage/query", "path": "/ids"},
                                     "properties": ["returnPath", "createdAt"]}, "g"]])
ids = [m["id"] for m in got[1][1]["list"] if m.get("returnPath") == sender and m.get("createdAt", "") >= since]
if ids:
    res = jmap([["x:QueuedMessage/set", {"destroy": ids}, "d"]])[0][1]
    if res.get("notDestroyed"):
        sys.exit(f"not removed: {json.dumps(res['notDestroyed'])[:300]}")
print(len(ids))
