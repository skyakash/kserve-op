# LocalModelCache — User Guide

`LocalModelCache` pre-fetches model weights into per-node persistent storage so InferenceServices start fast and survive without re-fetching from the original source on every Pod restart. The KServe defaults webhook auto-injects the cached PVC into matching ISVCs — the user just deploys an ISVC with the **same `storageUri`** as the cache's `sourceModelUri`.

This guide covers two flows:
- **Online** — cache fetches from a public source (`gs://`, `s3://`, `https://`, etc.)
- **Air-gapped (offline)** — cache copies from a user-populated PVC (`pvc://`); no internet egress needed at runtime

---

## Prerequisites

### 1. A multinode Kubernetes cluster

LocalModelCache fans a model across multiple worker nodes, so it needs N > 1 workers. Most production clusters (EKS, GKE, AKS, OpenShift) already meet this — no extra setup. For local testing, [kind](https://kind.sigs.k8s.io/), [k3d](https://k3d.io/), or `minikube --nodes=3` are all fine. A ready-made kind config is shipped at [`extra-docs/kind-multinode.yaml`](kind-multinode.yaml) if you pick kind.

> **Note:** single-node Docker Desktop Kubernetes can't exercise per-node fan-out.

### 2. Operator already deployed

You should have completed Part A + Part B Steps 0–5 of [QUICK_START.md](../QUICK_START.md) — operator running, KServeRawMode CR `Ready`, iris standard ISVC working.

### 3. Label worker nodes

The `kserve-localmodelnode-agent` DaemonSet uses `nodeSelector: kserve/localmodel=worker`. Label every node you want to host the cache (typically all worker nodes, leaving control-plane unlabeled). Substitute `<your-worker-name>` with the actual node names from `kubectl get nodes`:

```bash
kubectl label node <worker-1> kserve/localmodel=worker
kubectl label node <worker-2> kserve/localmodel=worker

# Verify the DaemonSet now schedules:
kubectl get ds -n kserve kserve-localmodelnode-agent
# DESIRED == <number of labeled workers>, CURRENT == DESIRED, READY == DESIRED
```

### 4. Chown the hostpath on each worker *(dev clusters only)*

> **Production clusters using CSI drivers (EBS, GCE PD, Azure Disk, OpenShift LocalVolume, etc.) skip this step entirely** — `fsGroup` propagates correctly through CSI volumes. This workaround is only for dev clusters using hostpath-backed PVs (Docker Desktop, kind, minikube — kubelet does NOT honor `fsGroup` chown there, so the first download Job fails with `Permission denied`).

Run a one-shot privileged Pod per labeled worker. **Run this AFTER applying the LocalModelCache CR** (the localmodel-agent populates `models/<cache-name>/` subdirs as root; chowning beforehand isn't enough on its own):

```bash
for n in <worker-1> <worker-2>; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: chown-${n}
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector: { kubernetes.io/hostname: ${n} }
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","mkdir -p /host/var/lib/kserve/local-models && chown -R 1000:1000 /host/var/lib/kserve/local-models"]
      securityContext: { privileged: true }
      volumeMounts: [{ name: host, mountPath: /host }]
  volumes:
    - { name: host, hostPath: { path: /, type: Directory } }
EOF
done
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod -l '!none' -n default --timeout=60s
kubectl delete pod -n default --field-selector status.phase=Succeeded
# Then trigger the failed download Jobs to retry:
kubectl delete job -n kserve-localmodel-jobs --all
```

---

## Online flow (gs://)

Uses the cache samples shipped at `p-kserve-operator-package/06-sample-model/`.

### Step 1 — Create the LocalModelNodeGroup

```bash
kubectl apply -f 06-sample-model/localmodelcache-nodegroup.yaml
kubectl get localmodelnodegroup default-worker
```

The NodeGroup defines a static PV template with `storageClassName: hostpath` on **both** the PV and PVC specs (a previous bug caused the PVC to default to the cluster default class and never bind — fixed in the shipped sample).

### Step 2 — Create the LocalModelCache

```bash
kubectl apply -f 06-sample-model/localmodelcache.yaml

# Watch until BOTH workers reach NodeDownloaded:
kubectl get localmodelcache sklearn-iris-cache -w
# status.copies.available eventually == 2; status.total == 2
```

The localmodel-controller-manager spawns one download Job per labeled worker. Each Job runs the storage-initializer that fetches `gs://kfserving-examples/models/sklearn/1.0/model` into a node-local PV. Per-node PVs end up in the `kserve-localmodel-jobs` namespace (the operator bundles this namespace — you don't create it manually).

### Step 3 — Deploy an ISVC that uses the cache

```bash
kubectl apply -f 06-sample-model/localmodelcache-isvc.yaml
kubectl wait --for=condition=Ready isvc/sklearn-iris-cached -n default --timeout=300s
```

The ISVC's `storageUri` is **the same `gs://...` URI** as the cache's `sourceModelUri`. The KServe defaults webhook recognises the match and rewrites the predictor's volume to mount the cache PVC instead of pulling from gs://. Proof of injection:

```bash
kubectl get isvc sklearn-iris-cached -n default \
  -o jsonpath='{.metadata.annotations.internal\.serving\.kserve\.io/localmodel-pvc-name}'
# Expected: sklearn-iris-cache-default-worker

kubectl get po -n default \
  -l serving.kserve.io/inferenceservice=sklearn-iris-cached \
  -o jsonpath='{.items[0].spec.volumes[?(@.name=="kserve-pvc-source")].persistentVolumeClaim.claimName}'
# Expected: sklearn-iris-cache-default-worker
```

### Step 4 — Run inference

```bash
kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-cached-predictor.default.svc.cluster.local/v1/models/sklearn-iris-cached:predict
```

✅ Expected: `{"predictions":[1]}`. The predictor pod loaded the model from the **local PVC** — no network egress to gs:// at startup.

---

## Air-gapped flow (pvc://)

Use this when the cluster has no internet egress (the original raison d'être of this operator).

### Step 1 — Create the source PVC

```bash
kubectl apply -f 06-sample-model/localmodelcache-offline-source-pvc.yaml
```

### Step 2 — Side-load the iris model into the source PVC

The YAML header contains the full procedure. Summary:

```bash
# On a machine with internet OR an internal model store, fetch model.joblib:
curl -sL https://storage.googleapis.com/kfserving-examples/models/sklearn/1.0/model/model.joblib \
  -o model.joblib

# Mount the source PVC to a temporary busybox pod and kubectl cp the file in:
kubectl run model-loader --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"offline-models-pvc"}}],"containers":[{"name":"model-loader","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"v","mountPath":"/mnt/pvc"}]}]}}'
kubectl wait --for=condition=Ready pod/model-loader --timeout=120s
kubectl exec model-loader -- mkdir -p /mnt/pvc/sklearn/iris/1.0/model
kubectl cp model.joblib default/model-loader:/mnt/pvc/sklearn/iris/1.0/model/model.joblib
kubectl delete pod model-loader
```

The path inside the PVC (`sklearn/iris/1.0/model/`) must exactly match the path component of the LocalModelCache's `sourceModelUri`.

### Step 3 — Apply the offline cache + ISVC

```bash
kubectl apply -f 06-sample-model/localmodelcache-offline.yaml
kubectl wait --for=jsonpath='{.status.copies.available}'=2 \
  localmodelcache/sklearn-iris-cache-offline --timeout=300s

kubectl apply -f 06-sample-model/localmodelcache-offline-isvc.yaml
kubectl wait --for=condition=Ready isvc/sklearn-iris-cached-offline -n default --timeout=300s
```

The defaults-webhook URI match works identically for `pvc://` URIs as for `gs://`.

### Step 4 — Run inference

```bash
kubectl run --rm -i curl-test-offline --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-cached-offline-predictor.default.svc.cluster.local/v1/models/sklearn-iris-cached-offline:predict
```

✅ Expected: `{"predictions":[1]}` with **zero network egress** at predictor startup.

---

## How it works

```
              ┌─────────────────────────────┐
              │ LocalModelCache (CR)        │
              │   sourceModelUri: gs://...  │
              │   nodeGroups: [default-...] │
              └────────────┬────────────────┘
                           │ controller spawns one download Job
                           │ per labeled worker → fetches into
                           │ per-node hostpath PV → PVC bound
                           ▼
              ┌─────────────────────────────┐
              │ kserve-localmodel-jobs ns   │
              │  - PV (per node)            │
              │  - PVC (shared)             │
              │  - Download Job (per node)  │
              └─────────────────────────────┘

              ┌─────────────────────────────┐
              │ InferenceService            │
              │   storageUri: gs://...      │
              │       ↑                     │
              │       │ (same URI as cache) │
              └────────────┬────────────────┘
                           │ defaults webhook matches by URI
                           │ injects internal annotations
                           │ rewrites predictor's volume
                           ▼
              ┌─────────────────────────────┐
              │ Predictor Pod               │
              │   volume kserve-pvc-source  │
              │     -> cache PVC            │
              │   model loads from local PV │
              │   no internet at startup    │
              └─────────────────────────────┘
```

Two flags govern the auto-injection — both already correct in the operator's bundled ConfigMap:
- `localModel.enabled: true` — without this, the webhook silently skips the URI match (upstream's default is `false`)
- `localModel.defaultJobImage: kserve/storage-initializer:v0.16.0` — pinned by the generator

---

## Cleanup

In this order to avoid orphaned resources:

```bash
# 1. Delete the ISVC first — its predictor pod holds a reference to the cache PVC.
kubectl delete isvc sklearn-iris-cached -n default
#    (or sklearn-iris-cached-offline for the offline flow)

# 2. Delete the LocalModelCache — controller deletes the per-node PVs/PVCs.
kubectl delete localmodelcache sklearn-iris-cache
#    (or sklearn-iris-cache-offline)

# 3. Delete the NodeGroup if you're done with caching entirely.
kubectl delete localmodelnodegroup default-worker

# Verify no orphaned PVs:
kubectl get pv | grep sklearn-iris-cache    # should be empty after ~30s
```

The PVs have `reclaimPolicy: Delete` so they self-destruct when their PVC is deleted. If the controller is stuck (rare — finalizers haven't run), you may need to manually clear finalizers on stuck resources.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Cache stays `NodeDownloadPending` forever | PVC not bound — usually storage class mismatch | Check `kubectl get pvc -n kserve-localmodel-jobs`. The PV and PVC must use the **same** `storageClassName`. The shipped sample pins `hostpath` on both. |
| Download Job pod errors with `Permission denied: '/mnt/models/model.joblib'` | Hostpath directory is root-owned; fsGroup doesn't propagate | Run the per-worker chown Pod from the Prerequisites section above. |
| ISVC predictor pod is `Pending` with `PVC not found` | The defaults webhook did not inject the cache PVC | Check `localModel.enabled` in the inferenceservice-config ConfigMap — it must be `true`. Check the ISVC `storageUri` **exactly** matches the LocalModelCache `sourceModelUri`. |
| LocalModelCache CR creation fails with webhook 404 | Core kserve-controller image is not v0.16.0 — older binaries lack the LocalModelCache validation handler | Re-run the operator build; ensure the v0.16.0 pin is in the embedded manifest. |
| Multi-namespace ISVC doesn't see the cache | Cache PVC is in `kserve-localmodel-jobs`; defaults webhook creates per-ISVC-namespace PVCs only when `enabled=true` | Same as above — check `localModel.enabled`. |

---

## See also

- [QUICK_START.md](../QUICK_START.md) — main install guide
- [extra-docs/0.16-migration-journey.md](0.16-migration-journey.md) Chapter 2 — design rationale and the upstream gaps this branch closed
- [extra-docs/0.16-task19-20-and-multinode-plan.md](0.16-task19-20-and-multinode-plan.md) — historical planning doc with multinode background
- [extra-docs/kind-multinode.yaml](kind-multinode.yaml) — kind cluster config fixture
- [extra-docs/LLMISVC-GUIDE.md](LLMISVC-GUIDE.md) — companion guide for the LLM serving feature
