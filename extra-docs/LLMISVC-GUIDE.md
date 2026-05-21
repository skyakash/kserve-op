# LLMInferenceService — User Guide

`LLMInferenceService` is KServe 0.16's resource for serving large language models. It complements standard `InferenceService` by adding Gateway API-native routing, multi-node parallelism (prefill/decode split, worker fan-out), and a vLLM-friendly Deployment template.

This branch ships a **smoke-test sample** that proves the controller wiring without requiring real LLM compute. Production (real inference) is documented as Phase 2 below.

---

## Phase 1: smoke test (no real LLM, ~5 min)

### What it validates

- The `llmisvc-controller-manager` Pod is running and reconciling
- A `Deployment` and `Service` are created from the CR
- The controller's reconcile pipeline (`Workload → Router → Scheduler → HTTPRoute`) traverses all stages
- Gateway API is **not required** for the smoke — the controller gracefully no-ops the HTTPRoute step

### Prerequisites

You should have completed Part A + Part B Steps 0–5 of [QUICK_START.md](../QUICK_START.md) — operator running, KServeRawMode CR `Ready`. The llmisvc subsystem is bundled, so `kubectl get deploy -n kserve llmisvc-controller-manager` should already show `1/1 Running`.

### Run the smoke test

```bash
kubectl apply -f 06-sample-model/llmisvc-smoke.yaml
```

The shipped sample uses `model.uri: hf://kserve-tiny-test/placeholder` — a deliberately fake reference. The controller still reconciles the CR and creates resources; only the Pod's model-fetch init-container will fail (expected).

### Verify the controller wiring

```bash
# 1. The CR status reflects Progressing (expected — predictor not Ready)
kubectl get llminferenceservice llmisvc-smoke
# NAME           URL   READY   REASON
# llmisvc-smoke        False   Progressing

# 2. Deployment exists (0/1 — the Pod will Init-fail because of the placeholder URI)
kubectl get deploy llmisvc-smoke-kserve
# READY  UP-TO-DATE  AVAILABLE
# 0/1    1           0

# 3. Service exists on port 8000
kubectl get svc llmisvc-smoke-kserve-workload-svc
# TYPE       CLUSTER-IP    PORT(S)
# ClusterIP  10.96.x.y     8000/TCP

# 4. The controller logs walk the reconcile pipeline:
kubectl logs -n kserve deploy/llmisvc-controller-manager --tail=20 \
  | grep -E "llmisvc-smoke|Reconciling"
# Expected lines:
#   "Reconciling multi-node workload"
#   "Reconciling single-node workload"
#   "Reconciling Router"
#   "Reconciling Scheduler"
#   "Reconciling HTTPRoute"
#   "No HTTPRoute configuration found, marking HTTPRoutesReady as True"
```

✅ **Smoke pass:** all four reconcile stages logged, Deployment + Service exist. Pod's `Init:0/1` is fine — the placeholder model is intentional.

### Cleanup

```bash
kubectl delete llminferenceservice llmisvc-smoke
```

---

## Phase 2: real LLM inference (out of scope for this branch)

To actually serve an LLM, you need **two additional prerequisites** plus a real model. This branch documents the path but does not ship a tested sample for it (the smaller models are still ~500 MB – 2 GB of RAM, beyond typical Docker Desktop / kind comfort).

### Prerequisite 1: install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl get crd | grep gateway.networking.k8s.io
# Expected: gateways, httproutes, gatewayclasses, etc.
```

Without these, the llmisvc controller logs `"No HTTPRoute configuration found, marking HTTPRoutesReady as True"` and the Deployment/Service still get created — but no external routing.

### Prerequisite 2: a GatewayClass + Gateway

The exact resources depend on your ingress implementation. For local testing, `envoy-gateway` is a common choice. Outside the scope of this guide — see [gateway-api.dev](https://gateway-api.sigs.k8s.io/).

### Prerequisite 3: a real model and enough cluster resources

Suggested starting points by size:

| Model | Approximate footprint | Notes |
|---|---|---|
| `TinyLlama-1.1B` | ~2 GB RAM, CPU OK | Smallest practical chat model |
| `gpt2` (124M) | ~500 MB RAM | Older; vLLM compatibility varies |
| `mistralai/Mistral-7B-v0.1` | 14 GB+ RAM or GPU required | Production-grade |

### Update the YAML

Edit `06-sample-model/llmisvc-smoke.yaml` (or copy to a new file):

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: llmisvc-tinyllama
spec:
  model:
    name: tinyllama
    uri: hf://TinyLlama/TinyLlama-1.1B-Chat-v1.0   # ← real model
  replicas: 1
```

Apply and wait for the Pod to reach `Ready` (model download via the storage-initializer may take several minutes on first run).

```bash
kubectl apply -f llmisvc-tinyllama.yaml
kubectl wait --for=condition=Ready llminferenceservice/llmisvc-tinyllama --timeout=600s
```

Once Ready, the Service exposes vLLM's OpenAI-compatible API on port 8000.

---

## How it works

The llmisvc controller stamps Deployments from `LLMInferenceServiceConfig` template CRs (the operator bundles 8 of these: `kserve-config-llm-template`, `kserve-config-llm-decode-template`, `kserve-config-llm-prefill-template`, etc.). For a basic single-Pod serve, it uses `kserve-config-llm-template` which:

- Runs `vllm serve /mnt/models` as the main command
- Pulls the model via a storage-initializer init-container into the Pod's `/mnt/models`
- Exposes port 8000 with liveness/readiness probes on `/health`

The Router/Scheduler stages of the reconcile create:
- A `Service` of type ClusterIP for in-cluster access
- An `HTTPRoute` (only when Gateway API CRDs are installed) for external routing
- Optionally `InferencePool` resources for batched/scheduled requests

For multi-node parallelism (prefill/decode split, leader/worker), see `spec.prefill`, `spec.worker`, and `spec.parallelism` in the CRD — both decode and worker templates ship in the bundle.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| llmisvc controller in `CrashLoopBackOff` with `customresourcedefinitions ... is forbidden` | Upstream `llmisvc-manager-role` lacks CRD read for the storage-version migration the binary runs at startup | Fixed on this branch — the generator post-processor appends the missing permission. If you see this, you're running an older build. |
| LLMInferenceService stuck `Progressing` and predictor Pod Init-fails | Model URI is wrong / unreachable (expected for the placeholder smoke) | For smoke: this is fine. For real inference: check the `hf://` URI resolves to a real model and that the cluster has internet egress to huggingface.co. |
| Controller logs `HTTPRoutesReady as True` but no actual route exists | Gateway API CRDs not installed | This is the **smoke path** — Phase 2 requires installing Gateway API CRDs separately. |
| llmisvc-smoke deployed but the Pod's image cannot be pulled | The bundled image `kserve/llmisvc-controller:v0.16.0` requires registry access. Customer-registry builds mirror it. | For customer-registry deploys, ensure `mirror-images.sh` ran successfully and includes the llmisvc-controller image. |

---

## See also

- [QUICK_START.md](../QUICK_START.md) — main install guide; Step 6d points here
- [extra-docs/0.16-migration-journey.md](0.16-migration-journey.md) Chapter 1 — the upstream CRD-read-permission gap that this branch closed
- [extra-docs/LOCAL-MODEL-CACHE-GUIDE.md](LOCAL-MODEL-CACHE-GUIDE.md) — companion guide for the per-node model caching feature
- KServe 0.16 LLMInferenceService API reference: [kserve.github.io/website/0.16/](https://kserve.github.io/website/0.16/) (upstream docs)
- Gateway API: [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/)
