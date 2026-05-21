# Air-gapped LocalModelCache demo (in-cluster Minio)

This directory contains a **self-contained, working** air-gap demo for KServe v0.16.0 LocalModelCache.

For the conceptual walkthrough and architecture, see [`extra-docs/LOCAL-MODEL-CACHE-GUIDE.md`](../../../extra-docs/LOCAL-MODEL-CACHE-GUIDE.md). This README is the imperative recipe.

---

## Why this exists

KServe v0.16.0's LocalModelCache download Job supports `s3://`, `gs://`, `http(s)://`, `abfs://`. It does **not** support `pvc://`, `file://`, `hf://`, or "skip download / pre-populated". So the only honest air-gap recipe is:

1. Run an S3-compatible store **inside the cluster** (Minio).
2. Upload the model into it once.
3. Configure a `ClusterStorageContainer` with `workloadType=localModelDownloadJob` that carries the S3 endpoint URL + credentials.
4. Apply the LocalModelCache with `sourceModelUri: s3://...`.

Everything downloaded after step 4 stays inside the cluster — no internet egress needed at runtime.

> The model file `model.joblib` shipped in this directory is the sklearn iris fixture from KServe's own sample tree (`kserve-source/docs/samples/v1beta1/sklearn/v2/model.joblib`, Apache 2.0).

---

## Prerequisites

1. **Operator already installed** and a `KServeRawMode` CR Ready (or `install.sh` finished) — see the top-level `README.md`.
2. **Multinode cluster** with at least one labeled worker:
   ```bash
   kubectl label node <worker-name> nodepool=local-models
   ```
3. **LocalModelNodeGroup applied** (reuses the existing sample):
   ```bash
   kubectl apply -f 06-sample-model/localmodelcache-nodegroup.yaml
   ```
4. **Continuous-chown helper** (dev clusters only — hostpath-backed StorageClass on Docker Desktop / kind / minikube):
   ```bash
   kubectl apply -f 06-sample-model/chown-hostpath-helper.yaml
   kubectl rollout status daemonset/chown-hostpath-helper -n kserve-localmodel-jobs --timeout=60s
   ```
   Production CSI clusters skip this. After the air-gap cache reaches `NodeDownloaded`, delete the helper:
   `kubectl delete -f 06-sample-model/chown-hostpath-helper.yaml`. See [`extra-docs/LOCAL-MODEL-CACHE-GUIDE.md`](../../../extra-docs/LOCAL-MODEL-CACHE-GUIDE.md#4-apply-the-continuous-chown-helper-dev-clusters-only) for the explainer.

---

## Steps

```bash
# Step 1 — Stand up in-cluster Minio
kubectl apply -f 06-sample-model/airgap-localmodelcache/00-minio-namespace.yaml
kubectl apply -f 06-sample-model/airgap-localmodelcache/01-minio-credentials.yaml
kubectl apply -f 06-sample-model/airgap-localmodelcache/02-minio-deployment.yaml
kubectl apply -f 06-sample-model/airgap-localmodelcache/03-minio-service.yaml
kubectl wait --for=condition=Available deployment/minio -n minio --timeout=180s

# Step 2 — Seed the iris model into Minio
#  (a) create a ConfigMap from the shipped model.joblib
kubectl create configmap -n minio iris-model-seed \
  --from-file=model.joblib=06-sample-model/airgap-localmodelcache/model.joblib
#  (b) apply the bootstrap Job — it creates the "models" bucket and
#      uploads model.joblib at the exact key the LocalModelCache expects
kubectl apply -f 06-sample-model/airgap-localmodelcache/04-minio-bootstrap-job.yaml
kubectl wait --for=condition=Complete job/minio-bootstrap -n minio --timeout=120s
# Verify the upload:
kubectl exec -n minio deploy/minio -- mc alias set self http://localhost:9000 minioadmin minioadmin >/dev/null
kubectl exec -n minio deploy/minio -- mc ls self/models/sklearn/iris/1.0/

# Step 3 — Wire up LocalModelCache to authenticate to Minio
kubectl apply -f 06-sample-model/airgap-localmodelcache/05-localmodel-s3-credentials.yaml
kubectl apply -f 06-sample-model/airgap-localmodelcache/06-clusterstoragecontainer-s3.yaml

# Step 4 — Apply the air-gap LocalModelCache and wait for download
kubectl apply -f 06-sample-model/airgap-localmodelcache/07-localmodelcache-airgap.yaml
# Watch until copies.available == number of worker nodes in the NodeGroup:
kubectl get localmodelcache sklearn-iris-cache-airgap -w -o jsonpath='{.status}{"\n"}'

# Step 5 — Apply the ISVC and run inference
kubectl apply -f 06-sample-model/airgap-localmodelcache/08-localmodelcache-airgap-isvc.yaml
kubectl wait --for=condition=Ready isvc/sklearn-iris-cached-airgap --timeout=180s
kubectl run -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -H 'Content-Type: application/json' \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-cached-airgap-predictor.default.svc.cluster.local/v1/models/sklearn-iris-cached-airgap:predict
# Expected: {"predictions":[1]}
kubectl delete pod curl-test
```

---

## Verifying it's actually air-gapped

- **Download Job pod talked only to Minio:**
  ```bash
  JOB_POD=$(kubectl get pod -n kserve-localmodel-jobs -l model=sklearn-iris-cache-airgap -o jsonpath='{.items[0].metadata.name}')
  kubectl logs -n kserve-localmodel-jobs "$JOB_POD"
  # Expect: connections to http://minio.minio.svc:9000, no external URLs
  ```

- **Env var injection landed correctly:**
  ```bash
  kubectl get pod -n kserve-localmodel-jobs "$JOB_POD" \
    -o jsonpath='{.spec.containers[0].env[?(@.name=="AWS_ENDPOINT_URL")].value}{"\n"}'
  # Expect: http://minio.minio.svc:9000
  ```

- **Predictor pod mounts the cache PVC, not Minio:**
  ```bash
  kubectl describe pod -l serving.kserve.io/inferenceservice=sklearn-iris-cached-airgap | grep -A2 'Mounts\|Volumes'
  # Expect: a `pvc://sklearn-iris-cache-airgap-default-worker/...` storage-initializer-source mount
  ```

---

## Cleanup

```bash
kubectl delete -f 06-sample-model/airgap-localmodelcache/08-localmodelcache-airgap-isvc.yaml
kubectl delete -f 06-sample-model/airgap-localmodelcache/07-localmodelcache-airgap.yaml
kubectl delete -f 06-sample-model/airgap-localmodelcache/06-clusterstoragecontainer-s3.yaml
kubectl delete -f 06-sample-model/airgap-localmodelcache/05-localmodel-s3-credentials.yaml
kubectl delete namespace minio
kubectl delete configmap iris-model-seed -n minio --ignore-not-found
```

> Heads up: ISVC deletion may hang on KServe v0.16.0 due to an upstream finalizer-cleanup bug (Issue #3 / T15). See [`extra-docs/LOCAL-MODEL-CACHE-GUIDE.md` → Stuck ISVC cleanup](../../../extra-docs/LOCAL-MODEL-CACHE-GUIDE.md#stuck-isvc-cleanup-kserve-v0160-upstream-bug) for the 3-step `scale 0 → patch finalizers → scale 1` recovery.

---

## Production checklist

This demo is **deliberately minimal**. Before adapting for production:

| Demo choice | Production replacement |
|---|---|
| `minio/minio` with hardcoded `minioadmin/minioadmin` | Hardened S3-compatible store (Minio Operator, AWS S3 via VPC endpoint, OpenShift Data Foundation, etc.) with rotated credentials from your secret manager |
| `emptyDir` `/data` | PVC bound to a CSI-backed StorageClass |
| `image: quay.io/minio/minio:RELEASE.…` pulled from internet | Image mirrored into your private registry (extend `mirror-images.sh` to include Minio + storage-initializer tags) |
| Secrets in plain YAML committed to git | Secret created out-of-band by sealed-secrets / external-secrets-operator / your secret manager |
| `S3_USE_HTTPS=0`, `S3_VERIFY_SSL=0` | TLS-terminated Minio + proper CA on the storage-initializer trust store |
| Single replica Minio | Distributed Minio (Operator) for HA, OR a managed S3 service if your "air-gap" allows it |
