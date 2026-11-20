#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# K-L10: the chart installed and upgraded by a GitOps controller instead of
# by Helm. TOOL is argocd or flux.
#
#   lab/gitops/gitops.sh controller TOOL   Argo CD (core) or Flux, from the
#                                          pinned manifest (versions.env)
#   lab/gitops/gitops.sh repo              the chart as a Helm repository in
#                                          the cluster: versions 27.1.0-lab.1
#                                          and -lab.2, the same chart
#   lab/gitops/gitops.sh apply TOOL        the Application or HelmRelease, as
#                                          the variables below say; prints
#                                          what it changed
#   lab/gitops/gitops.sh wait TOOL [SINCE] until the controller says the
#                                          current spec is in and healthy
#   lab/gitops/gitops.sh refused TOOL [SINCE]
#                                          until it says the current spec failed
#   lab/gitops/gitops.sh suspend TOOL      no syncing until the next apply
#   lab/gitops/gitops.sh state TOOL        one line: what the controller says
#
# apply reads CHART_VERSION (27.1.0-lab.1), SERVER, WEBMAIL and CONSOLE
# (each a tag or sha256:...), SEED (true) and ACK (the layout to
# acknowledge, if any). Self-heal is on in both: Argo CD's selfHeal, Flux's
# drift detection.
#
# Secrets: under Argo CD the chart renders without the cluster, so
# generateSecrets is off and the webmail's and the metrics Secrets are made
# here first, as the docs will tell people to. Flux runs Helm itself, so the
# chart makes and keeps its own, as under Helm.
#
# The chart is the checkout's (CHART_REPO, as e2e.sh); the lab's values files
# go inside the package (lab/), as values files in a chart repository do.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/../versions.env"
CHART_REPO="${CHART_REPO:-$here/../../../inbuxa-charts}"
K=(kubectl --context "kind-$KIND_CLUSTER")
REPO_URL=http://charts.lab-charts.svc:8080
fail() { echo "!! $*" >&2; exit 1; }

controller() {
  local tool="$1" url sum work
  work="$(mktemp -d)"
  case "$tool" in
    argocd)
      url="https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/core-install.yaml"
      sum="$ARGOCD_CORE_SHA256" ;;
    flux)
      url="https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION/install.yaml"
      sum="$FLUX_INSTALL_SHA256" ;;
    *) fail "argocd or flux" ;;
  esac
  curl -fsSL --retry 3 --proto '=https' -o "$work/install.yaml" "$url"
  echo "$sum  $work/install.yaml" | sha256sum -c --quiet - || fail "$url isn't the pinned manifest"
  if [ "$tool" = argocd ]; then
    "${K[@]}" create namespace argocd --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
    # Server-side: Argo CD's CRDs are too big for the last-applied annotation
    "${K[@]}" -n argocd apply --server-side --force-conflicts -f "$work/install.yaml" >/dev/null
    "${K[@]}" -n argocd rollout status deploy/argocd-repo-server --timeout=300s >/dev/null
    "${K[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
    # The core install has no API server, which is what makes the default
    # project elsewhere
    "${K[@]}" -n argocd apply -f - >/dev/null <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: default, namespace: argocd}
spec:
  sourceRepos: ["*"]
  destinations: [{server: "*", namespace: "*"}]
  clusterResourceWhitelist: [{group: "*", kind: "*"}]
EOF
    echo "   Argo CD $ARGOCD_VERSION (core)"
  else
    "${K[@]}" apply --server-side --force-conflicts -f "$work/install.yaml" >/dev/null
    for d in source-controller helm-controller; do
      "${K[@]}" -n flux-system rollout status "deploy/$d" --timeout=300s >/dev/null
    done
    echo "   Flux $FLUX_VERSION"
  fi
  rm -rf "$work"
}

repo() {
  local work v
  work="$(mktemp -d)"
  mkdir -p "$work/charts"
  for v in 27.1.0-lab.1 27.1.0-lab.2; do
    rm -rf "$work/inbuxa" && cp -r "$CHART_REPO/charts/inbuxa" "$work/inbuxa"
    mkdir -p "$work/inbuxa/lab"
    cp "$here/../chart/values-lab.yaml" "$here/../chart/values-frontends.yaml" "$work/inbuxa/lab/"
    helm package "$work/inbuxa" --version "$v" -d "$work/charts" >/dev/null
  done
  helm repo index "$work/charts" --url "$REPO_URL"
  "${K[@]}" create namespace lab-charts --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" label namespace lab-charts pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
  "${K[@]}" -n lab-charts create configmap charts --from-file="$work/charts" --dry-run=client -o yaml \
    | "${K[@]}" apply --server-side --force-conflicts -f - >/dev/null
  "${K[@]}" -n lab-charts apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: charts}
spec:
  replicas: 1
  selector: {matchLabels: {app: charts}}
  template:
    metadata: {labels: {app: charts}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 2000, runAsGroup: 2000, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: http
          image: $PG_IMAGE
          imagePullPolicy: IfNotPresent
          command: [python3, -m, http.server, "8080", --directory, /charts]
          ports: [{name: http, containerPort: 8080}]
          readinessProbe: {httpGet: {path: /index.yaml, port: http}}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 64Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: charts, mountPath: /charts}]
      volumes: [{name: charts, configMap: {name: charts}}]
---
apiVersion: v1
kind: Service
metadata: {name: charts}
spec:
  selector: {app: charts}
  ports: [{name: http, port: 8080, targetPort: http}]
EOF
  "${K[@]}" -n lab-charts rollout restart deploy/charts >/dev/null
  "${K[@]}" -n lab-charts rollout status deploy/charts --timeout=180s >/dev/null
  echo "   $REPO_URL: $(cd "$work/charts" && ls *.tgz | tr '\n' ' ')"
  rm -rf "$work"
}

# Under Argo CD: the Secrets the chart would otherwise make, made once
secrets() {
  local r
  r() { python3 -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))), end="")' "$1"; }
  if ! "${K[@]}" -n inbuxa get secret inbuxa-webmail-keys >/dev/null 2>&1; then
    "${K[@]}" -n inbuxa create secret generic inbuxa-webmail-keys \
      --from-literal=app-secret="$(r 48)" --from-literal=oauth-client-secret="$(r 48)" >/dev/null
  fi
  if ! "${K[@]}" -n inbuxa get secret inbuxa-metrics-auth >/dev/null 2>&1; then
    "${K[@]}" -n inbuxa create secret generic inbuxa-metrics-auth \
      --from-literal=username=prometheus --from-literal=password="$(r 40)" >/dev/null
  fi
}

# The values on top of the chart's and the lab's files, as JSON (which is YAML)
overrides() {
  python3 - "$1" <<'PY'
import json, os, sys
tool = sys.argv[1]
def image(repo, ref):
    i = {"repository": repo, "pullPolicy": "IfNotPresent"}
    if ref.startswith("sha256:"):
        i.update(digest=ref, tag="")
    else:
        i.update(tag=ref, digest="")
    return i
v = {
    "server": {
        "image": image("ghcr.io/inbuxa/inbuxa-server", os.environ["SERVER"]),
        "seed": {"enabled": os.environ.get("SEED", "true") == "true"},
        "metrics": {"prometheus": {"enabled": True}},
    },
    "webmail": {"image": image("ghcr.io/inbuxa/inbuxa-webmail", os.environ["WEBMAIL"])},
    "console": {"image": image("ghcr.io/inbuxa/inbuxa-admin", os.environ["CONSOLE"])},
}
if os.environ.get("ACK"):
    v["server"]["upgrade"] = {"acknowledgeLayout": int(os.environ["ACK"])}
if tool == "argocd":
    v["generateSecrets"] = False
    v["webmail"]["existingSecret"] = "inbuxa-webmail-keys"
    v["server"]["metrics"]["prometheus"]["existingSecret"] = "inbuxa-metrics-auth"
print(json.dumps(v))
PY
}

apply() {
  local tool="$1" version="${CHART_VERSION:-27.1.0-lab.1}" values
  : "${SERVER:?}" "${WEBMAIL:?}" "${CONSOLE:?}"
  values="$(overrides "$tool")"
  if [ "$tool" = argocd ]; then
    secrets
    # The finalizer: deleting the Application deletes what it made
    "${K[@]}" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: inbuxa
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: inbuxa}
  source:
    repoURL: $REPO_URL
    chart: inbuxa
    targetRevision: $version
    helm:
      releaseName: inbuxa
      valueFiles: [lab/values-lab.yaml, lab/values-frontends.yaml]
      valuesObject: $values
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    retry: {limit: 2, backoff: {duration: 10s, factor: 2, maxDuration: 1m}}
EOF
  else
    # A failed upgrade isn't rolled back: a refused layout change has
    # nothing to undo, and a rollback would run the same check (pre-rollback)
    "${K[@]}" apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata: {name: lab-charts, namespace: flux-system}
spec: {url: "$REPO_URL", interval: 1m}
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: {name: inbuxa, namespace: flux-system}
spec:
  interval: 1m
  suspend: false
  releaseName: inbuxa
  targetNamespace: inbuxa
  storageNamespace: inbuxa
  chart:
    spec:
      chart: inbuxa
      version: "$version"
      sourceRef: {kind: HelmRepository, name: lab-charts}
      valuesFiles: [values.yaml, lab/values-lab.yaml, lab/values-frontends.yaml]
  install: {timeout: 15m, remediation: {retries: 2}}
  upgrade: {timeout: 20m, remediation: {retries: 0}}
  driftDetection: {mode: enabled}
  values: $values
EOF
  fi
}

suspend() {
  if [ "$1" = argocd ]; then
    "${K[@]}" -n argocd patch application inbuxa --type json \
      -p '[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' >/dev/null
  else
    "${K[@]}" -n flux-system patch helmrelease inbuxa --type merge -p '{"spec": {"suspend": true}}' >/dev/null
  fi
}

# One JSON object: what the controller says about the current spec.
#   ok: in and healthy; failed: it gave up on it; op: the last sync
#   (Argo CD) or the spec generation looked at (Flux), to tell an answer
#   about a new spec from the last one; deployed: when the last sync or
#   Helm release was, which a steady app doesn't change
state() {
  local tool="$1" ns=argocd kind=application
  [ "$tool" = flux ] && ns=flux-system kind=helmrelease
  "${K[@]}" -n "$ns" get "$kind" inbuxa -o json | python3 -c '
import json, sys
tool, a = sys.argv[1], json.load(sys.stdin)
s, spec = a.get("status", {}), a["spec"]
if tool == "argocd":
    op = s.get("operationState", {})
    phase = op.get("phase", "")
    want = spec["source"]["targetRevision"]
    synced = s.get("sync", {}).get("status") == "Synced" and s.get("sync", {}).get("revision") == want
    healthy = s.get("health", {}).get("status") == "Healthy"
    print(json.dumps({"ok": synced and healthy and phase == "Succeeded", "failed": phase in ("Failed", "Error"),
                      "op": op.get("startedAt", ""), "deployed": op.get("startedAt", ""), "sync": s.get("sync", {}).get("status"),
                      "health": s.get("health", {}).get("status"), "phase": phase,
                      "revision": s.get("sync", {}).get("revision"), "message": op.get("message", "")[:300]}))
else:
    cond = {c["type"]: c for c in s.get("conditions", [])}
    ready = cond.get("Ready", {})
    current = s.get("observedGeneration") == a["metadata"]["generation"]
    hist = s.get("history", [])
    want = spec["chart"]["spec"]["version"]
    # Flux adds +N to the version of a chart it rebuilt with valuesFiles
    got = (hist[0].get("chartVersion") or "").split("+")[0] if hist else None
    ok = current and ready.get("status") == "True" and got == want
    failed = current and ready.get("status") == "False" and (
        cond.get("Stalled", {}).get("status") == "True" or ready.get("reason", "").endswith("Failed"))
    print(json.dumps({"ok": ok, "failed": failed, "op": "gen:" + str(s.get("observedGeneration")),
                      "deployed": hist[0].get("lastDeployed", "") if hist else "",
                      "ready": ready.get("status"), "reason": ready.get("reason"),
                      "version": got,
                      "actions": len(hist), "message": ready.get("message", "")[:300]}))
' "$tool"
}

# wait|refused TOOL [SINCE] [TIMEOUT]: SINCE is the op the state had before
# the apply, so the answer is about this spec, not the last one
await() {
  local want="$1" tool="$2" since="${3:-}" timeout="${4:-1500}" end s
  end=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$end" ]; do
    s="$(state "$tool" 2>/dev/null || echo '{}')"
    if python3 -c '
import json, sys
s, want, since = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
new = s.get("op", "") != since or not since
sys.exit(0 if new and s.get(want) else 1)' "$s" "$want" "$since"; then
      echo "$s"
      return 0
    fi
    if [ "$want" = failed ] && python3 -c '
import json, sys
s, since = json.loads(sys.argv[1]), sys.argv[2]
sys.exit(0 if s.get("ok") and (s.get("op", "") != since or not since) else 1)' "$s" "$since"; then
      echo "$s" >&2
      fail "$tool took the spec"
    fi
    if [ "$want" = ok ] && python3 -c '
import json, sys
s, since = json.loads(sys.argv[1]), sys.argv[2]
sys.exit(0 if s.get("failed") and (s.get("op", "") != since or not since) else 1)' "$s" "$since"; then
      echo "$s" >&2
      fail "$tool gave up on the spec"
    fi
    sleep 5
  done
  echo "$s" >&2
  fail "$tool: not $want after ${timeout}s"
}

field() { state "$1" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }

case "${1:-}" in
  controller) controller "$2" ;;
  repo) repo ;;
  apply) apply "$2" ;;
  wait) await ok "$2" "${3:-}" "${4:-1500}" ;;
  refused) await failed "$2" "${3:-}" "${4:-900}" ;;
  suspend) suspend "$2" ;;
  state) state "$2" ;;
  op) field "$2" op ;;
  deployed) field "$2" deployed ;;
  *) sed -n '4,33p' "$0"; exit 2 ;;
esac
