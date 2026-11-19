# inbuxa-k8s-lab

Test lab for inbuxa on Kubernetes: end-to-end, chaos, upgrade and soak tests.

`lab/up.sh` brings up a kind cluster with the data layer, Kyverno and the
policies. It needs the Helm repositories `cnpg`, `nats`, `metallb` and
`kyverno` (https://kyverno.github.io/kyverno/); the versions are pinned in
`lab/versions.env`.

The `inbuxa` namespace enforces Pod Security "restricted" and the policies in
`lab/policy/defaults.yaml`: a read-only root, no service-account token (except
the upgrade Job's), secrets never in the environment, and a deny-all
NetworkPolicy over every pod. `lab/policy/policy-test.sh` checks that the
chart passes them and that a bad value is refused.
