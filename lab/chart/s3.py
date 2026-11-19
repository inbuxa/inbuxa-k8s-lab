#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Just enough S3 for the lab's tests, with the standard library only:
path-style requests signed with SigV4, to the lab's Garage through a
port-forward.

  S3_ENDPOINT=http://127.0.0.1:13900 S3_REGION=garage \\
  S3_ACCESS_KEY_FILE=... S3_SECRET_KEY_FILE=... s3.py <command> <bucket> [arg]

  ls <bucket> [prefix]     keys under prefix, one per line
  get <bucket> <key>       the object, to stdout
  empty <bucket> [prefix]  deletes every object under prefix; prints how many
"""
import datetime, hashlib, hmac, os, sys, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

ENDPOINT = os.environ["S3_ENDPOINT"].rstrip("/")
REGION = os.environ.get("S3_REGION", "us-east-1")
ACCESS = open(os.environ["S3_ACCESS_KEY_FILE"]).read().strip()
SECRET = open(os.environ["S3_SECRET_KEY_FILE"]).read().strip()
NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"


def request(method, bucket, key="", query=None):
    query = query or {}
    host = urllib.parse.urlsplit(ENDPOINT).netloc
    path = "/" + bucket + ("/" + urllib.parse.quote(key, safe="/~") if key else "")
    canonical_query = "&".join(
        f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(str(v), safe='~')}"
        for k, v in sorted(query.items())
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, date = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    payload = hashlib.sha256(b"").hexdigest()
    headers = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": amz_date}
    signed = ";".join(sorted(headers))
    canonical = "\n".join([
        method, path, canonical_query,
        "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload,
    ])
    scope = f"{date}/{REGION}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical.encode()).hexdigest()])
    k = ("AWS4" + SECRET).encode()
    for part in (date, REGION, "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={ACCESS}/{scope}, "
                                f"SignedHeaders={signed}, Signature={signature}")
    url = ENDPOINT + path + ("?" + canonical_query if canonical_query else "")
    req = urllib.request.Request(url, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def keys(bucket, prefix=""):
    token = None
    while True:
        query = {"list-type": "2", "prefix": prefix}
        if token:
            query["continuation-token"] = token
        root = ET.fromstring(request("GET", bucket, query=query))
        for c in root.iter(NS + "Contents"):
            yield c.find(NS + "Key").text
        token_el = root.find(NS + "NextContinuationToken")
        if root.findtext(NS + "IsTruncated") != "true" or token_el is None:
            return
        token = token_el.text


command, bucket = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
if command == "ls":
    for key in keys(bucket, arg):
        print(key)
elif command == "get":
    sys.stdout.buffer.write(request("GET", bucket, arg))
elif command == "empty":
    gone = 0
    for key in list(keys(bucket, arg)):
        request("DELETE", bucket, key)
        gone += 1
    print(gone)
else:
    sys.exit(f"unknown command {command}")
