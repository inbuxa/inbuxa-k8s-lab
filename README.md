<p align="center">
  <img src="./img/brand/inbuxa-lockup-light.svg" alt="inbuxa" height="140">
</p>

<h3 align="center">
  The test lab for inbuxa on Kubernetes
</h3>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-2dd4bf?style=flat-square"></a>
  <a href="https://github.com/inbuxa/inbuxa-k8s-lab/actions/workflows/e2e.yml"><img alt="End to end" src="https://img.shields.io/github/actions/workflow/status/inbuxa/inbuxa-k8s-lab/e2e.yml?branch=main&label=e2e&style=flat-square"></a>
  <a href="https://community.coffeylabs.org/c/inbuxa/5"><img alt="Forum: community.coffeylabs.org" src="https://img.shields.io/badge/forum-community.coffeylabs.org-0f766e?style=flat-square"></a>
  <a href="https://discord.gg/nqcY4TKfAn"><img alt="Chat on Discord" src="https://img.shields.io/discord/1523538164084637797?label=discord&logo=discord&logoColor=white&color=5865f2&style=flat-square"></a>
</p>

---

> [!NOTE]
> Development happens on [git.coffeylabs.org/inbuxa/inbuxa-k8s-lab](https://git.coffeylabs.org/inbuxa/inbuxa-k8s-lab); the copy on GitHub is a read-only mirror, and where the end-to-end runs happen.
> Report issues at **[git.coffeylabs.org/inbuxa/inbuxa-k8s-lab/issues](https://git.coffeylabs.org/inbuxa/inbuxa-k8s-lab/issues)**, join discussions at **[community.coffeylabs.org](https://community.coffeylabs.org)**, or chat on **[Discord](https://discord.gg/nqcY4TKfAn)**.

Where [the inbuxa Helm chart](https://git.coffeylabs.org/inbuxa/inbuxa-charts)
is tested on real clusters: end to end, upgrades, failures and load. It's
for developing the chart, not for running mail; the chart's repository says
how to install it.

`lab/e2e.sh` is the whole lab from nothing: the cluster, the chart with the
images the next chart release names (inbuxa-charts `release/suite.yaml`),
seeded, then mail, the webmail and the console, timing each part. It wants
inbuxa-charts checked out next to this repository (or `CHART_REPO=`), and
kind, kubectl and Helm, which `lab/tools.sh` installs at pinned versions,
each checked against its published checksum. CI runs it on GitHub's amd64
and arm64 runners (`.github/workflows/e2e.yml`).

`lab/up.sh` is just the cluster: kind, Kyverno and the policies, MetalLB,
and the data layer (CloudNativePG, NATS, Garage). It adds the Helm
repositories it needs; the versions are pinned in `lab/versions.env`.
`lab/down.sh` removes it all.

The `inbuxa` namespace enforces Pod Security "restricted" and the policies in
`lab/policy/defaults.yaml`: a read-only root, no service-account token (except
the upgrade Job's), secrets never in the environment, and a deny-all
NetworkPolicy over every pod. `lab/policy/policy-test.sh` checks that the
chart passes them and that a bad value is refused.

## License

Free software under the [Apache License 2.0](LICENSE), and a Coffey Labs
project.
