#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L9: what a release-candidate tester's cluster is, and how the chart
# did on it, as a block to paste into an issue or forum post.
#
#   lab/report.sh [--context NAME] [-n NAMESPACE] [-r RELEASE]
#                 [--results FILE]... [--include-names]
#
# Reads, never changes: the Kubernetes version and distribution, the nodes'
# OS, kernel, runtime and architecture, the network plugin, the load
# balancer, the namespace's Pod Security level and anything it refused,
# the chart and image versions, each component's pods (ready, restarts),
# warning events, and the test results given with --results (the lab's
# e2e summary by default, if there is one).
#
# No names: nodes, the namespace, the release, registries, addresses and
# hostnames are left out, and the whole block is scrubbed of anything
# shaped like an IP address or a hostname before it's printed.
# --include-names keeps them, for a private report.
set -euo pipefail

CTX=() NS=inbuxa RELEASE=inbuxa NAMES=0 RESULTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX=(--context "$2"); shift 2 ;;
    -n|--namespace) NS="$2"; shift 2 ;;
    -r|--release) RELEASE="$2"; shift 2 ;;
    --results) RESULTS+=("$2"); shift 2 ;;
    --include-names) NAMES=1; shift ;;
    -h|--help) sed -n '4,21p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (--help)" >&2; exit 2 ;;
  esac
done
if [ ${#RESULTS[@]} -eq 0 ] && [ -f "$HOME/.cache/inbuxa-lab/e2e-summary.md" ]; then
  RESULTS=("$HOME/.cache/inbuxa-lab/e2e-summary.md")
fi
command -v kubectl >/dev/null || { echo "needs kubectl" >&2; exit 1; }
K=(kubectl "${CTX[@]}")
HELM_CTX=()
[ ${#CTX[@]} -gt 0 ] && HELM_CTX=(--kube-context "${CTX[1]}")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"${K[@]}" version -o json >"$WORK/version.json" 2>/dev/null || echo '{}' >"$WORK/version.json"
"${K[@]}" get nodes -o json >"$WORK/nodes.json"
"${K[@]}" get pods -A -o json >"$WORK/pods.json"
"${K[@]}" get daemonsets -A -o json >"$WORK/ds.json"
"${K[@]}" get namespace "$NS" -o json >"$WORK/ns.json" 2>/dev/null || echo '{}' >"$WORK/ns.json"
"${K[@]}" -n "$NS" get services -o json >"$WORK/svc.json" 2>/dev/null || echo '{"items":[]}' >"$WORK/svc.json"
"${K[@]}" -n "$NS" get events -o json >"$WORK/events.json" 2>/dev/null || echo '{"items":[]}' >"$WORK/events.json"
if command -v helm >/dev/null; then
  helm "${HELM_CTX[@]}" -n "$NS" list -o json >"$WORK/helm.json" 2>/dev/null || echo '[]' >"$WORK/helm.json"
else
  echo '[]' >"$WORK/helm.json"
fi
: >"$WORK/results.md"
for f in "${RESULTS[@]}"; do { echo; echo "From \`$(basename "$f")\`:"; echo; cat "$f"; } >>"$WORK/results.md"; done

python3 - "$WORK" "$NS" "$RELEASE" "$NAMES" <<'PY'
import collections, json, os, re, sys

work, ns, release, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
J = lambda f: json.load(open(os.path.join(work, f)))
version, nodes, pods, ds = J("version.json"), J("nodes.json")["items"], J("pods.json")["items"], J("ds.json")["items"]
nsobj, svcs, events, helm = J("ns.json"), J("svc.json")["items"], J("events.json")["items"], J("helm.json")

server = version.get("serverVersion", {}).get("gitVersion", "?")
distro = next((d for pat, d in [(r"\+k3s", "k3s"), (r"\+rke2", "RKE2"), (r"-eks-", "EKS"), (r"-gke\.", "GKE"),
                                (r"\+vmware", "Tanzu"), (r"\+k0s", "k0s"), (r"-aks", "AKS")] if re.search(pat, server)), None)
images = " ".join(c.get("image", "") for p in pods for c in p["spec"].get("containers", []))
if not distro:
    if any(n["metadata"].get("labels", {}).get("node.openshift.io/os_id") for n in nodes):
        distro = "OpenShift"
    elif re.search(r"kindest/|kindnet", images):
        distro = "kind"
    elif any("talos" in n["status"]["nodeInfo"].get("osImage", "").lower() for n in nodes):
        distro = "Talos"
    elif re.search(r"microk8s|calico.*snap", images):
        distro = "MicroK8s"
    else:
        distro = "upstream or unrecognised"

def nodeinfo(n):
    i = n["status"]["nodeInfo"]
    roles = sorted(k.split("/", 1)[1] for k in n["metadata"].get("labels", {}) if k.startswith("node-role.kubernetes.io/")) or ["worker"]
    return (",".join(roles), i.get("osImage", "?"), i.get("kernelVersion", "?"), i.get("containerRuntimeVersion", "?"), i.get("architecture", "?"))
node_rows = collections.Counter(nodeinfo(n) for n in nodes)

def present(*words):
    hay = " ".join([p["metadata"]["name"] for p in pods] + [d["metadata"]["name"] for d in ds]).lower()
    return [w for w in words if w.lower() in hay]
cni = present("cilium", "calico", "canal", "flannel", "kindnet", "weave", "antrea", "kube-router", "aws-node", "azure-cns", "ovnkube", "multus") or ["not recognised"]
lbs = present("metallb", "kube-vip", "svclb", "cilium-l2", "purelb", "openelb", "loxilb")

def short_image(image):
    """repository basename and tag or digest; no registry host."""
    name, _, digest = image.partition("@")
    repo, tag = (name.rsplit(":", 1) + [""])[:2] if ":" in name.rsplit("/", 1)[-1] else (name, "")
    base = image if names else repo.rsplit("/", 1)[-1] + (f":{tag}" if tag else "") + (f"@{digest[:19]}…" if digest else "")
    return base

ours = [p for p in pods if p["metadata"]["namespace"] == ns]
by_comp = collections.OrderedDict()
for p in sorted(ours, key=lambda p: p["metadata"].get("labels", {}).get("app.kubernetes.io/name", "") + p["metadata"]["name"]):
    labels = p["metadata"].get("labels", {})
    comp = labels.get("app.kubernetes.io/component", "?")
    owner = (p["metadata"].get("ownerReferences") or [{}])[0].get("kind", "")
    # The server's role groups are Deployments named <release>-<group>
    name = p["metadata"]["name"]
    group = re.sub(r"-[a-z0-9]{6,10}-[a-z0-9]{5}$|-[a-z0-9]{5}$", "", name)
    group = group[len(release) + 1:] if group.startswith(release + "-") and not names else group
    key = (comp, group, owner)
    statuses = p["status"].get("containerStatuses", []) or []
    e = by_comp.setdefault(key, {"pods": 0, "ready": 0, "restarts": 0, "phase": collections.Counter(), "images": set(), "why": set()})
    e["pods"] += 1
    e["ready"] += all(c.get("ready") for c in statuses) and bool(statuses)
    e["restarts"] += sum(c.get("restartCount", 0) for c in statuses)
    e["phase"][p["status"].get("phase", "?")] += 1
    e["images"].update(short_image(c["image"]) for c in p["spec"]["containers"])
    for c in statuses:
        r = (c.get("lastState", {}).get("terminated") or {}).get("reason")
        if r:
            e["why"].add(r)

psa = {k.rsplit("/", 1)[1]: v for k, v in nsobj.get("metadata", {}).get("labels", {}).items() if k.startswith("pod-security.kubernetes.io/")}
refused = [e for e in events if "violates PodSecurity" in e.get("message", "") or "forbidden" in e.get("message", "").lower()]
warnings = collections.Counter(e.get("reason", "?") for e in events if e.get("type") == "Warning")
lbsvc = [s for s in svcs if s["spec"].get("type") == "LoadBalancer"]
rel = next((h for h in helm if h.get("name") == release), {})

L = ["### inbuxa on Kubernetes: test report", ""]
L += ["| | |", "|---|---|",
      f"| Kubernetes | {server} ({distro}) |",
      f"| Nodes | {len(nodes)} |",
      f"| Network plugin | {', '.join(cni)} |",
      f"| Load balancer | {', '.join(lbs) or 'cloud or not recognised'}"
      + (f"; {len(lbsvc)} LoadBalancer service(s), class {', '.join(sorted({s['spec'].get('loadBalancerClass') or 'default' for s in lbsvc}))}, "
         f"{sum(1 for s in lbsvc if s.get('status', {}).get('loadBalancer', {}).get('ingress'))} with an address" if lbsvc else "; no LoadBalancer service") + " |",
      f"| Pod Security | {', '.join(f'{k}={v}' for k, v in sorted(psa.items())) or 'no labels on the namespace'}; "
      f"{len(refused)} refusal event(s) |",
      f"| Chart | {rel.get('chart', 'helm release not found')}, app {rel.get('app_version', '?')}, revision {rel.get('revision', '?')}, {rel.get('status', '?')} |",
      ""]
L += ["| Roles | OS | Kernel | Runtime | Arch | Nodes |", "|---|---|---|---|---|---|"]
L += [f"| {r} | {o} | {k} | {rt} | {a} | {c} |" for (r, o, k, rt, a), c in sorted(node_rows.items())]
L += ["", "| Component | Group | Pods | Ready | Restarts | Images |", "|---|---|---|---|---|---|"]
for (comp, group, owner), e in by_comp.items():
    extra = f" ({', '.join(sorted(e['why']))})" if e["why"] else ""
    phases = "" if set(e["phase"]) <= {"Running"} else " " + ", ".join(f"{v} {k}" for k, v in e["phase"].items())
    L.append(f"| {comp} | {group} ({owner}) | {e['pods']}{phases} | {e['ready']} | {e['restarts']}{extra} | {', '.join(sorted(e['images']))} |")
if warnings:
    L += ["", "Warning events in the namespace (kept about an hour): " + ", ".join(f"{k} ×{v}" for k, v in warnings.most_common())]
results = open(os.path.join(work, "results.md")).read().strip()
if results:
    L += ["", "#### Test results", "", results]
text = "\n".join(L) + "\n"

if not names:
    # Belt and braces: nothing shaped like an address or a hostname leaves
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d+)?\b", "[ip]", text)
    # IPv6 (and MACs): hex groups with "::", or five groups or more; a time
    # like 12:34:56 has three
    text = re.sub(r"(?<![\w:])[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}(?![\w:])",
                  lambda m: "[ip]" if "::" in m.group(0) or m.group(0).count(":") >= 4 else m.group(0), text, flags=re.I)
    # name.domain.tld; versions (1.2.3), file names and image tags don't match
    text = re.sub(r"\b(?=[a-z0-9-]*[a-z][a-z0-9-]*\.)(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\b(?![\w-])",
                  lambda m: m.group(0) if re.fullmatch(r"[\w-]+\.(md|json|yaml|sh|py|txt|log)", m.group(0)) else "[host]",
                  text, flags=re.I)
    if ns not in ("inbuxa", "default"):
        text = text.replace(ns, "[namespace]")
print(text)
PY
