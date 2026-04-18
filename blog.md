# Building a Production-Like Homelab on GKE: A GitOps Story

*What I thought would take a weekend turned into a deep dive on every sharp edge in the CNCF ecosystem.*

## The Goal

Build a GKE homelab that mirrors what a real platform team runs: GitOps with ArgoCD, a service mesh with Istio, progressive delivery with Argo Rollouts and Kargo, observability with Prometheus and Grafana, and policy enforcement with Kyverno. Make it fully self-healing — every change goes through Git, nothing touched by hand.

Simple enough on paper.

## The Stack

| Layer | Tool |
|---|---|
| GitOps | ArgoCD + ApplicationSet |
| Promotion engine | Kargo |
| Service mesh | Istio (Gateway API) |
| Progressive delivery | Argo Rollouts |
| Observability | kube-prometheus-stack, Kiali, Loki |
| Policy | Kyverno |
| Cross-platform mesh | Consul (Nomad federation) |
| Secrets | External Secrets Operator → GCP Secret Manager |
| TLS | cert-manager + Cloudflare DNS-01 |

---

## Lesson 1: GKE Has Opinions About Gateway API

GKE `CHANNEL_STANDARD` ships with a `ValidatingAdmissionPolicy` that blocks any Gateway API CRD not labeled `gateway.networking.k8s.io/channel: standard`. This single policy caused two separate failures.

**First victim: Consul API Gateway.** Consul 1.9.x bundles Gateway API v0.6.2 CRDs marked as experimental. The admission policy rejected them outright. Fix: `manageExternalCRDs: false` in the Consul Helm values, and manually install the standard-channel CRDs at v1.5.1.

**Second victim: Consul connect-inject.** Even after the CRD installation fix, connect-inject crashed on startup:

```
unable to register field indexes: failed to get API group resources:
gateway.networking.k8s.io/v1alpha2: the server could not find the requested resource
```

Consul 1.22's connect-inject controller still registers watchers for `v1alpha2` resources (TCPRoute, TLSRoute). These only exist in the experimental channel. Installing them with the annotation relabeled from `experimental` to `standard` was the pragmatic fix for a homelab.

**The pattern:** When a controller fails to start with an API discovery error, it's usually looking for a CRD that graduated out of the version you're running, or never made it into a restricted environment's allowlist.

---

## Lesson 2: ArgoCD Server-Side Apply Fights You Over Field Ownership

The plan was to manage IP allowlisting via `loadBalancerSourceRanges` on the Istio gateway Service. Put the office IPs in git, add home IP via `kubectl patch`, configure `ignoreDifferences` to stop ArgoCD from overwriting the manual addition.

This does not work.

`ignoreDifferences` tells ArgoCD not to *report* a diff. It does not stop ArgoCD from *writing* its desired state via Server-Side Apply. Every sync, ArgoCD would re-apply its managed fields — overwriting the manually-added home IP.

The real fix: move IP enforcement to Istio `AuthorizationPolicy`. Policies at the mesh level are independent resources that ArgoCD manages declaratively. The Cloudflare IPs and GitHub webhook IPs live in git. The home IP lives in a separate `AuthorizationPolicy` that ArgoCD has no knowledge of.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: home-allowlist
  namespace: istio-gateway
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: istio-gateway
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks:
              - <YOUR_HOME_IP>/32
```

One catch: `remoteIpBlocks` uses the actual client IP, which only works if `externalTrafficPolicy: Local` is set on the Service. With `Cluster` (the default), SNAT hides the original source IP and Envoy sees the node IP instead.

---

## Lesson 3: kube-prometheus-stack's Silent Selector Override

The prometheus-operator's `Prometheus` CR has a `serviceMonitorSelector` that determines which `ServiceMonitor` resources it picks up. The default in kube-prometheus-stack is `{matchLabels: {release: kube-prometheus-stack}}`.

Third-party Helm charts (podinfo, Istio, etc.) ship their own `ServiceMonitor` resources without that label. They get silently ignored. No error, no warning — Prometheus just never scrapes them.

The fix is to open the selector:

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelector: {}
    podMonitorSelector: {}
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
```

The `NilUsesHelmValues` flags are the part the docs don't shout about. Setting the selectors to `{}` without also setting those flags to `false` does nothing — the chart overrides your empty object back to the label-based default at render time.

---

## Lesson 4: Istio's Dynamic Webhook Drift

Istiod dynamically flips `failurePolicy` on its admission webhooks at runtime based on whether the control plane is healthy. This means every time ArgoCD syncs, it sees the webhook as drifted from the git-committed value and tries to correct it — triggering another Istiod reconcile — which sets it back — creating a sync loop.

Fix: tell ArgoCD to ignore that field entirely.

```yaml
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions:
      - .webhooks[]?.failurePolicy
```

This pattern comes up with any controller that mutates its own resources after deployment. The rule: if a controller owns a field at runtime, that field should never be in git.

---

## Lesson 5: Secrets Are Everywhere Until They're Not

The initial setup had OAuth client IDs in values files, a classic PAT in a Kubernetes Secret, and HMAC webhook secrets stored with trailing newlines (because `echo` adds one and `openssl | gcloud` piped through it).

The trailing newline on the HMAC secret is particularly painful: the secret appears correct when you inspect it, but HMAC verification fails because the signature is computed over 41 bytes (`secret\n`) while ArgoCD computes over 40 (`secret`). The fix is `printf '%s'` instead of `echo` when storing secrets.

Systematic fix: everything sensitive moves to GCP Secret Manager, synced into Kubernetes via External Secrets Operator with `creationPolicy: Merge` so multiple ExternalSecrets can contribute fields to one Kubernetes Secret.

---

## Lesson 6: Argo Rollouts and the Deployment Deadlock

Adding an Argo Rollout with `workloadRef` pointing at an existing Deployment doesn't immediately transfer pod management. If the Deployment has 10 replicas and the Rollout also spins up 10, you briefly have 20 pods on a 4-node cluster — which exhausts CPU requests even though actual utilization is ~25%.

The scheduler uses requests, not actual usage. A cluster running at 95% *requested* CPU with 25% *actual* CPU will still refuse to schedule new pods.

The fix in the moment: manually scale the Deployment to 0. The fix for the future: understand that CPU requests are reservations, and size them accordingly — especially when adding sidecar containers like Istio's `istio-proxy` which defaults to 100m CPU request per pod.

---

## Lesson 7: kustomize Catches You When ArgoCD Doesn't

One of the more avoidable failures: a JSON patch using `op: add` on a path that didn't exist.

```yaml
- op: add
  path: /spec/template/metadata/annotations/sidecar.istio.io~1proxyCPU
  value: "10m"
```

This works fine on Deployments that already have pod template annotations. It fails with a cryptic error on Deployments that have none:

```
add operation does not apply: doc is missing path
```

ArgoCD reported the error after trying to sync. A `kustomize build` run locally (or in CI) would have caught it before the push. This is why the repo now has a GitHub Actions workflow that runs `kustomize build` on all overlays on every push — failing fast before ArgoCD ever sees the manifests.

The fix for the patch: use a strategic merge patch instead of JSON patch. Strategic merge handles absent parent paths gracefully.

---

## The Recurring Theme

Every one of these issues follows the same pattern: a tool that works perfectly in isolation misbehaves when it meets the specific combination of GKE admission policies, ArgoCD Server-Side Apply, and other controllers that also claim ownership of resources.

The docs for each tool describe how it works alone. The sharp edges are all at the intersections.

The homelab exists to hit these intersections deliberately, figure out how they actually work, and document the fixes before they become production incidents.

---

*Stack source: [github.com/theopsbadger/badgerops](https://github.com/theopsbadger/badgerops)*
