# KServe Operator — Quick Start Guide

Two paths depending on what you're doing:
- **[Part A](#part-a-builder-build--publish-the-operator)** — you're building/publishing the operator
- **[Part B](#part-b-deployer-install-kserve-on-a-cluster)** — you have the package and just want to install KServe

---

## Part A: Builder — Build & Publish the Operator

### Prerequisites
- `go` v1.21+, `make`, `docker`, `operator-sdk` v1.42+, `kubectl`, `python3 + pyyaml`

### Step 1 — Extract KServe raw manifests
```bash
cd /path/to/kserve-op
./generate-kserve-raw.sh -t p-kserve-raw
```

### Step 2 — Generate operator, build image, and create OLM bundle
```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/your-org/my-kserve-operator \
  -d your.domain.com \
  -s p-kserve-raw \
  -i docker.io/your-org/kserve-raw-operator:v1 \
  --docker-server docker.io \
  --docker-username <your-user> \
  --docker-password <your-token> \
  --pull-secret docker-pull-secret \
  -b -p -o
```

This outputs two directories:
- `p-kserve-operator/` — the compiled Go operator project
- `p-kserve-operator-package/` — the **distributable package** (share this with deployers)

---

## Part B: Deployer — Install KServe on a Cluster

You only need the `*-package/` folder and `kubectl`/`operator-sdk` on your machine.

### Step 1 — Install OLM (once per cluster)
```bash
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running
```

### Step 2 — Set up image pull credentials *(skip if images are public)*
```bash
bash setup-credentials.sh
```

### Step 3 — Deploy the operator

**Option A: OLM Bundle (recommended)**
```bash
operator-sdk run bundle docker.io/your-org/kserve-raw-operator:v1-bundle \
  --pull-secret-name docker-pull-secret
```

**Option B: Direct manifests (no OLM needed — skip Step 1)**
```bash
kubectl apply -f operator-deployment.yaml
```

> **Auto-Init:** The operator automatically creates a default `KServeRawMode` CR on startup. KServe installation begins immediately — no manual `kubectl apply -f kserve-rawmode.yaml` required.

### Step 4 — Watch installation progress
```bash
kubectl get kserverawmode -A -w
```
Expected progression:
```
PHASE                   → InstallingCertManager → InstallingCRDs → InstallingRBAC → InstallingCore → InstallingRuntimes → Ready
```

### Step 5 — Deploy and test the Iris inference model
```bash
kubectl apply -f 06-sample-model/sklearn-iris.yaml

# Wait for predictor to be ready (~30s)
kubectl get isvc sklearn-iris -w   # wait for READY=True

# Test inference
kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-predictor.default.svc.cluster.local/v1/models/sklearn-iris:predict
```
✅ Expected: `{"predictions":[1]}`

---

## Part C: Alternative — Offline / Air-Gapped Model Test

If your cluster cannot reach `gs://` (Google Cloud Storage) to download model weights, `Step 5` above will fail. Use this PVC-based offline alternative instead.

### 1. Create a local PersistentVolumeClaim
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: offline-models-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
```

### 2. Download and side-load the model into the PVC
*(On a machine with internet access)*
```bash
curl -sL https://storage.googleapis.com/kfserving-examples/models/sklearn/1.0/model/model.joblib -o model.joblib

# Mount the PVC to a temporary pod
kubectl run model-loader --image=curlimages/curl --restart=Never --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"offline-models-pvc"}}],"containers":[{"name":"model-loader","image":"curlimages/curl","command":["sleep","3600"],"volumeMounts":[{"name":"v","mountPath":"/mnt/pvc"}]}]}}'

# Copy the file inside
kubectl wait --for=condition=Ready pod/model-loader
kubectl exec model-loader -- mkdir -p /mnt/pvc/sklearn/iris/1.0/model
kubectl cp model.joblib default/model-loader:/mnt/pvc/sklearn/iris/1.0/model/model.joblib
kubectl delete pod model-loader
```

### 3. Deploy the InferenceService using the PVC
```bash
cat <<EOF | kubectl apply -f -
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-iris-pvc"
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
spec:
  predictor:
    sklearn:
      storageUri: "pvc://offline-models-pvc/sklearn/iris/1.0/model"
EOF
```

### 4. Test inference
```bash
kubectl get isvc sklearn-iris-pvc -w   # wait for READY=True

kubectl run --rm -i curl-test-offline --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-pvc-predictor.default.svc.cluster.local/v1/models/sklearn-iris-pvc:predict
```
✅ Expected: `{"predictions":[1]}`
