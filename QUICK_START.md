# KServe Operator — Quick Start Guide

Two paths depending on what you're doing:
- **[Part A](#part-a-builder-build--publish-the-operator)** — you're building/publishing the operator
- **[Part B](#part-b-deployer-install-kserve-on-a-cluster)** — you have the package and just want to install KServe

---

## Part A: Builder — Build & Publish the Operator

### Prerequisites

Supported build environments: **macOS** and **RHEL/Linux x86_64**.

| Tool | macOS | RHEL/Linux |
|---|---|---|
| Go v1.21+ | `brew install go` | [go.dev/dl](https://go.dev/dl) tarball |
| Operator SDK v1.42+ | `brew install operator-sdk` | Binary from GitHub releases |
| Docker v20.10+ | Docker Desktop | `dnf install docker-ce` or see [docs.docker.com/engine/install/rhel](https://docs.docker.com/engine/install/rhel/) |
| yq v4+ | `brew install yq` | `sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq` |
| kubectl | `brew install kubectl` | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| Kustomize v5+ | `brew install kustomize` | `curl -s .../install_kustomize.sh \| bash` |
| python3 + pyyaml | `brew install python && pip3 install pyyaml` | `dnf install -y python3 python3-pip && pip3 install pyyaml` |

> See [generate-kserve-operator-README.md](./generate-kserve-operator-README.md#installing-prerequisites) for exact copy-paste install commands per platform.

### Cleaning Up / Starting Fresh

If you are re-running the build (e.g. after a cluster reset), clean both generated directories first:

```bash
./generate-kserve-operator.sh -c p-kserve-operator   # removes p-kserve-operator/ and p-kserve-operator-package/
./generate-kserve-raw.sh -c p-kserve-raw              # removes p-kserve-raw/
```

---

### Step 1 — Extract KServe raw manifests
```bash
# Run from the kserve-op workspace directory
./generate-kserve-raw.sh -t p-kserve-raw
```

### Step 2 — Generate operator, build image, and create OLM bundle
```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:v300 \
  --pull-secret dockerhub-creds \
  --install-mode SingleNamespace \
  -b -p -o
```

> **`--install-mode`** controls OLM operator install scope. Valid values: `SingleNamespace` (default — operator manages one specific namespace), `OwnNamespace`, `AllNamespaces`, `MultiNamespace`.

### Step 2 (Alt) — Customer / Private Registry

If the operator will be deployed to a customer environment with a **private registry** (Artifactory, Harbor, ECR, Docker Hub org, etc.), add `--customer-registry`. This rewrites all image references in the output package and generates two extra helper scripts.

> **Additional prerequisite:** [`skopeo`](https://github.com/containers/skopeo) — used by `mirror-images.sh` to copy images between registries.
> - macOS: `brew install skopeo`
> - RHEL/Linux: `sudo dnf install -y skopeo`

```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:v300 \
  --pull-secret dockerhub-creds \
  --customer-registry docker.io/<customer-account> \
  --install-mode SingleNamespace \
  -b -p -o
```

> ℹ️ `--pull-secret` sets the pull secret name baked into the generated scripts. Credentials are **never embedded** — they are provided at runtime by the customer.

The generated package (`p-kserve-operator-package/`) contains three helper scripts:
- `mirror-images.sh` — copies images from the source registry to the customer registry (3 modes: online, archive, load)
- `setup-credentials.sh` — creates pull secrets in all required namespaces
- `deploy-bundle.sh` — interactive installer (OLM bundle or direct `kubectl apply`)

Both `mirror-images.sh` and `setup-credentials.sh` use the same `--user`/`--pass` arguments and will prompt interactively if not provided.

---

**Option A — Online (both registries accessible from one machine):**

Run all commands from the package directory:
```bash
cd p-kserve-operator-package

# 1. Copy images from source registry → customer registry
bash mirror-images.sh --user <customer-user> --pass <customer-token>

# 2. Install OLM (once per cluster)
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running

# 3. Create pull secrets on the cluster
bash setup-credentials.sh --user <customer-user> --pass <customer-token>

# 4. Deploy the operator
bash deploy-bundle.sh
# For private clusters that require explicit pull secrets:
# bash deploy-bundle.sh dockerhub-creds
```

---

**Option B — Offline / Air-gapped (images shipped as tar archives):**

```bash
# ── BUILDER MACHINE (has internet access) ──────────────────────────
cd p-kserve-operator-package

# Save images to local tar archives
bash mirror-images.sh --archive
# Produces: images/operator.tar + images/bundle.tar

# Transfer the ENTIRE package folder (including images/) to the customer machine
# ── CUSTOMER MACHINE (air-gapped) ──────────────────────────────────
cd p-kserve-operator-package

# 1. Load and push archives to customer registry
bash mirror-images.sh --load --user <customer-user> --pass <customer-token>

# 2. Install OLM (once per cluster)
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running

# 3. Create pull secrets on the cluster
bash setup-credentials.sh --user <customer-user> --pass <customer-token>

# 4. Deploy the operator
bash deploy-bundle.sh
# For private clusters that require explicit pull secrets:
# bash deploy-bundle.sh dockerhub-creds
```

This outputs two directories:
- `p-kserve-operator/` — the compiled Go operator project
- `p-kserve-operator-package/` — the **distributable package** (share this with deployers)

---

## Part B: Deployer — Install KServe on a Cluster

You only need the `*-package/` folder and `kubectl`/`operator-sdk` on your machine.

```bash
cd p-kserve-operator-package   # all commands below run from inside this folder
```

### Step 0 — Verify cert-manager is installed *(pre-requisite)*

> [!IMPORTANT]
> The operator **does not install cert-manager**. It must be present in the cluster before deployment. The operator will enter `CertManagerNotFound` phase and surface a clear error if it is absent.

```bash
# Check cert-manager CRDs are registered
kubectl get crds | grep cert-manager.io
# Expected output should include: certificates.cert-manager.io, issuers.cert-manager.io, etc.

# If not installed, install cert-manager first:
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=120s
```

### Step 1 — Install OLM (once per cluster)
```bash
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running
```

### Step 2 — Set up image pull credentials *(skip if images are public)*
```bash
# With CLI args:
bash setup-credentials.sh --user <registry-user> --pass <registry-token>

# Or interactive (will prompt for username and password):
bash setup-credentials.sh
```

### Step 3 — Create the KServe namespace

The operator does **not** create the KServe namespace automatically — you must create it before deploying.

```bash
# Default namespace (matches the CR default):
kubectl create namespace kserve

# Or use a custom namespace — you will need to set spec.kserveNamespace in the CR:
kubectl create namespace <your-namespace>
```

### Step 4 — Deploy the operator

**Option A: OLM Bundle (recommended, `InstallMode: SingleNamespace`)**

`SingleNamespace` mode requires a **dedicated operator namespace** with an `OperatorGroup` that targets the namespace the CR will be created in (e.g. `default`). The operator must NOT be installed into `default` or `operators` (those already have OperatorGroups from OLM install).

```bash
# 4a. Create a dedicated namespace for the operator itself
kubectl create namespace kserve-operator-system

# 4b. Create the pull secret in that namespace (needed to pull the operator image)
kubectl create secret docker-registry dockerhub-creds \
  --docker-server=docker.io \
  --docker-username=<registry-user> \
  --docker-password=<registry-token> \
  -n kserve-operator-system

# 4c. Create an OperatorGroup in the operator namespace, targeting 'default'
#     (the namespace where the KServeRawMode CR will live)
kubectl apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kserve-operator-og
  namespace: kserve-operator-system
spec:
  targetNamespaces:
    - default
EOF

# 4d. Deploy via OLM bundle into the dedicated operator namespace
operator-sdk run bundle <bundle-image> \
  --pull-secret-name dockerhub-creds \
  --namespace kserve-operator-system
```

> **Why a dedicated namespace?**
> OLM enforces exactly **one** `OperatorGroup` per namespace. The `operators` namespace already has `global-operators` (AllNamespaces scope) and installing into `default` would trigger OwnNamespace mode. A fresh dedicated namespace avoids both conflicts.

> **Customer registry flow:** If using `deploy-bundle.sh`, it will prompt you. Run `mirror-images.sh` first to push images to the customer registry, then run `deploy-bundle.sh` — it handles the bundle image reference automatically.

**Option B: Direct manifests (no OLM needed — skip Steps 1, 3, and 4a–4c)**
```bash
kubectl apply -f operator-deployment.yaml
```

> **Auto-Init:** The operator automatically creates a default `KServeRawMode` CR on startup targeting namespace `kserve`. KServe installation begins immediately — no manual `kubectl apply -f kserve-rawmode.yaml` required.
> To install into a different namespace, apply the CR manually with `spec.kserveNamespace` set to your namespace.

### Step 5 — Watch installation progress
```bash
kubectl get kserverawmode -A -w
```
Expected progression:
```
NAMESPACE   NAME             PHASE                    AGE
default     kserve-rawmode   ValidatingCertManager    2s
default     kserve-rawmode   InstallingCRDs           8s
default     kserve-rawmode   InstallingRBAC           10s
default     kserve-rawmode   InstallingCore           11s
default     kserve-rawmode   InstallingRuntimes       38s
default     kserve-rawmode   Ready                    43s
```

If cert-manager is missing, the phase will show `CertManagerNotFound` and the operator logs will display:
```
ERROR cert-manager is required but was not found in the cluster ...
      Please install cert-manager before deploying the KServe operator.
      See: https://cert-manager.io/docs/installation/
```
Install cert-manager and the operator will automatically retry and proceed.

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
kubectl run model-loader --image=busybox --restart=Never --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"offline-models-pvc"}}],"containers":[{"name":"model-loader","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"v","mountPath":"/mnt/pvc"}]}]}}'

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
