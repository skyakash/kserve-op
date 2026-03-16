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

### Step 2 — Set up image pull credentials
```bash
# Apply operator manifests first (creates the operator system namespace)
kubectl apply -f operator-deployment.yaml

# Then run the credential helper (skip if images are public)
bash setup-credentials.sh
```

### Step 3 — Deploy the operator via OLM bundle *(OR use direct manifests below)*
```bash
operator-sdk run bundle docker.io/your-org/kserve-raw-operator:v1-bundle \
  --pull-secret-name docker-pull-secret
```

> **Alternative (Direct, no OLM):** Skip Step 1 & this Step 3. The `kubectl apply` in Step 2 already deployed the operator.

### Step 4 — Install KServe by applying the Custom Resource
```bash
kubectl apply -f kserverawmode-sample.yaml
```

### Step 5 — Watch installation progress
```bash
kubectl get kserverawmode -A -w
```
Expected progression:
```
PHASE                   → InstallingCertManager → InstallingCRDs → InstallingRBAC → InstallingCore → InstallingRuntimes → Ready
```

### Step 6 — Deploy and test the Iris inference model
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
