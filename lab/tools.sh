#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# The tools the lab runs with, at pinned versions, each checked against the
# project's published SHA-256 (K-L1): kind, kubectl and Helm, for linux/amd64
# or linux/arm64, into DIR (default ~/.local/bin).
#
#   lab/tools.sh [DIR]
#
# To move a pin, change the version and both of its sums together.
set -euo pipefail

DIR="${1:-$HOME/.local/bin}"
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "linux/amd64 or linux/arm64 only" >&2; exit 2 ;;
esac

KIND_VERSION=v0.33.0
KIND_SHA256_amd64=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
KIND_SHA256_arm64=20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2
KUBECTL_VERSION=v1.37.2
KUBECTL_SHA256_amd64=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
KUBECTL_SHA256_arm64=fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509
HELM_VERSION=v4.3.2
HELM_SHA256_amd64=d1c0278d46beab79582d7e50f5b3dc206944ba8e577cde618513fd07daa53983
HELM_SHA256_arm64=df31cb61680ef728f82c770e5280dd565617bee6b039d37e85c677288be4bbb0

mkdir -p "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sum() { local v="$1_SHA256_$ARCH"; echo "${!v}"; }
# fetch URL SHA256 FILE: download URL to $WORK/FILE and check its hash
fetch() {
  curl -fsSL --retry 3 --proto '=https' -o "$WORK/$3" "$1"
  echo "$2  $WORK/$3" | sha256sum -c --quiet -
}

fetch "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH" "$(sum KIND)" kind
install -m 0755 "$WORK/kind" "$DIR/kind"
fetch "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl" "$(sum KUBECTL)" kubectl
install -m 0755 "$WORK/kubectl" "$DIR/kubectl"
fetch "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" "$(sum HELM)" helm.tgz
tar -xzf "$WORK/helm.tgz" -C "$WORK" "linux-$ARCH/helm"
install -m 0755 "$WORK/linux-$ARCH/helm" "$DIR/helm"

"$DIR/kind" version
# sed reads everything: head would leave kubectl writing to a closed pipe
# (SIGPIPE, 141 under pipefail)
"$DIR/kubectl" version --client | sed -n 1p
"$DIR/helm" version --short
