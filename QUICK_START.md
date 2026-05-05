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

> **Version tagging:** Replace `v300` with your actual release version (e.g. `v302`, `v303`). Use a new tag for each build to avoid stale image caches on the cluster.

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

The generated package (`p-kserve-operator-package/`) contains up to **four** helper scripts:
- `setup-credentials.sh` — creates pull secrets in all required namespaces (default, kserve-operator-system, olm, operators) *(always generated)*
- `enable-ingress.sh` — patches KServe to enable Kubernetes Ingress creation; restarts the controller. Used when you want external-URL access via an ingress controller. *(always generated)*
- `mirror-images.sh` — copies operator + bundle images from the build registry to a customer registry (3 modes: online, archive, load) *(only with `--customer-registry`)*
- `deploy-bundle.sh` — one-command OLM install helper that wraps `operator-sdk run bundle ... --install-mode SingleNamespace=${KSERVE_NS}` *(only with `--customer-registry`)*

Both `mirror-images.sh` and `setup-credentials.sh` use the same `--user`/`--pass` arguments and will prompt interactively if not provided.

> Without `--customer-registry`, the package contains only `setup-credentials.sh` plus the static manifests (`operator-deployment.yaml`, `kserve-rawmode.yaml`, `06-sample-model/`, `README.md`).

---

### *(Air-gapped only)* Package images for transfer

If you generated with `--customer-registry` and the customer cluster cannot reach the build registry, archive the operator + bundle images on the builder side so they can be shipped offline:

```bash
cd p-kserve-operator-package
bash mirror-images.sh --archive
# Produces images/operator.tar + images/bundle.tar
```

Ship the **entire `p-kserve-operator-package/` folder, including `images/`** to the customer machine (USB, secure gateway, etc.). The customer-side load + deploy steps are in **Part B** below.

For online customer-registry deploys (build and customer registries reachable from the same machine), skip the `--archive` step — the customer can run `mirror-images.sh` in online mode directly per Part B's callout.

---

That completes the **builder** side. **Part B** below covers the cluster install — both the standard and customer-registry variants.

---

## Part B: Deployer — Install KServe on a Cluster

You only need the `*-package/` folder and `kubectl`/`operator-sdk` on your machine.

```bash
cd p-kserve-operator-package   # all commands below run from inside this folder
```

> **Customer-registry workflow** *(only if your package was generated with `--customer-registry` — you'll see `mirror-images.sh` and `deploy-bundle.sh` in the directory)*: before Step 0, bring the operator + bundle images into your registry. Run **one** of:
>
> ```bash
> # (a) Online — both build and customer registries reachable from this machine:
> bash mirror-images.sh --user <customer-user> --pass <customer-token>
>
> # (b) Air-gapped — images already shipped as tar files in images/:
> bash mirror-images.sh --load --user <customer-user> --pass <customer-token>
> ```
>
> Then continue with the steps below. In **Step 3** pass the **customer-registry** credentials (the cluster will pull from there, not the build registry). In **Step 4** you can use `bash deploy-bundle.sh dockerhub-creds` as a one-line shortcut for the OLM install — it wraps the same `operator-sdk run bundle ... --install-mode SingleNamespace=${KSERVE_NS}` command shown there.

### Step 0 — Install cert-manager *(cluster pre-requisite)*

> [!IMPORTANT]
> The operator **does not install cert-manager**. cert-manager must be present in the cluster **before** the operator is deployed. The operator validates this at startup and will enter a `CertManagerNotFound` error phase with a clear message if it is absent.

#### Check if cert-manager is already installed
```bash
kubectl get crds | grep cert-manager.io
# Expected output (if installed):
# certificaterequests.cert-manager.io
# certificates.cert-manager.io
# challenges.acme.cert-manager.io
# clusterissuers.cert-manager.io
# issuers.cert-manager.io
# orders.acme.cert-manager.io
```

#### Install cert-manager (if not present)
```bash
# Pinned stable release (v1.17.2 as of April 2026 — check https://github.com/cert-manager/cert-manager/releases for latest)
CERT_MANAGER_VERSION="v1.17.2"

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

# Wait for all cert-manager pods to be Ready (typically ~60s)
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s

# Verify
kubectl get pods -n cert-manager
# Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook pods all Running
```

> **Why is cert-manager required?** KServe uses cert-manager to provision TLS certificates for its webhook endpoints. Without it, the KServe webhook admission controller cannot start.

### Step 1 — Install OLM (once per cluster)
```bash
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running
```

### Step 2 — Create namespaces

The operator pod always runs in a fixed `kserve-operator-system` namespace. The CR and the KServe runtime live **together** in a namespace of your choice — defaults to `kserve`, but you can pick anything (e.g. `my-kserve`) and the operator's apply-time namespace rewriting will install KServe there. The OperatorGroup defined in Step 4 is the single source of truth.

```bash
# Pick the namespace name you want for KServe (default: 'kserve').
# Both the KServeRawMode CR and the KServe runtime will live here.
KSERVE_NS=kserve

kubectl create namespace "${KSERVE_NS}"          || true
kubectl create namespace kserve-operator-system  || true
```

> **Why this comes before credentials:** `setup-credentials.sh` (Step 3) creates pull secrets *inside* `kserve-operator-system`, `olm`, `operators`, and `default`. If those namespaces don't exist yet, the script silently skips them — and the operator pod's image pull will later fail with no obvious cause. OLM created `olm`/`operators` in Step 1; you create the other two here.

### Step 3 — Set up image pull credentials *(skip if images are public)*

```bash
# With CLI args:
bash setup-credentials.sh --user <registry-user> --pass <registry-token>

# Or interactive (will prompt for username and password):
bash setup-credentials.sh
```

For the **customer-registry** flow, pass the **customer-registry** credentials here (the cluster will pull from the customer registry, not the build registry).

### Step 4 — Deploy the operator

**Option A: OLM Bundle (recommended, `InstallMode: SingleNamespace`)**

`operator-sdk run bundle` accepts an `--install-mode` flag that auto-creates the OperatorGroup with the right `targetNamespaces` — you don't define it yourself. Pass `SingleNamespace=<your-kserve-ns>` and it wires up the rest.

```bash
# Set BUNDLE_IMAGE to where your bundle actually lives:
#   • Standard build:           <build-registry>/<image>:<tag>-bundle
#   • --customer-registry path: <customer-registry>/<image>:<tag>-bundle
#     (after `bash mirror-images.sh ...` has copied/loaded it there).
# In all cases the suffix is `-bundle` (the operator image's tag + `-bundle`).
BUNDLE_IMAGE=<your-bundle-image>

# Single-command deploy. --install-mode auto-creates an OperatorGroup in
# kserve-operator-system targeting ${KSERVE_NS}; the downward-API
# WATCH_NAMESPACE then drives the auto-init's CR placement.
operator-sdk run bundle "${BUNDLE_IMAGE}" \
  --namespace kserve-operator-system \
  --install-mode "SingleNamespace=${KSERVE_NS}" \
  --pull-secret-name dockerhub-creds
```

> **`--pull-secret-name`** references the secret created by `setup-credentials.sh` in Step 3. If you skipped Step 3 because your images are public, drop this flag.

> **Why no OperatorGroup yaml?** OLM forbids embedding OperatorGroups in bundles (they're user-controlled installation parameters, not operator artifacts). `operator-sdk run bundle --install-mode` generates one on the fly named `operator-sdk-og` in the operator's namespace.

> **Bundle image tag:** The bundle image tag is printed at the end of `generate-kserve-operator.sh` output, in the format `<image-tag>-bundle`.
> Example: if you built with `-i docker.io/akashneha/kserve-raw-operator:v403`, the bundle image is `docker.io/akashneha/kserve-raw-operator:v403-bundle`.

> **Customer registry flow:** If you generated with `--customer-registry`, the package contains `mirror-images.sh` and `deploy-bundle.sh`. Run `mirror-images.sh` first to push images to the customer registry, then `deploy-bundle.sh` — it handles the bundle image reference automatically.

**Option B: Direct manifests (no OLM needed — skip Steps 1 and 4)**
```bash
kubectl apply -f operator-deployment.yaml
# Note: direct deploy uses the bundled defaults (kserve-operator-system + kserve).
# To use a custom KServe namespace name without OLM, use the standalone install.sh
# in p-kserve-raw with KSERVE_NAMESPACE=<your-name> set in the env.
```

> **Auto-Init:** The operator automatically creates a default `KServeRawMode` CR on startup, in the namespace named in the OperatorGroup's `targetNamespaces`. KServe installation begins immediately — no manual `kubectl apply -f kserve-rawmode.yaml` required.

### Step 5 — Watch installation progress
```bash
kubectl get kserverawmode -A -w
```
Expected progression (using default `kserve` namespace):
```
NAMESPACE   NAME             PHASE                    AGE
kserve      kserve-rawmode   ValidatingCertManager    2s
kserve      kserve-rawmode   InstallingCRDs           8s
kserve      kserve-rawmode   InstallingRBAC           10s
kserve      kserve-rawmode   InstallingCore           11s
kserve      kserve-rawmode   InstallingRuntimes       38s
kserve      kserve-rawmode   Ready                    43s
```

If cert-manager is missing, the phase will show `CertManagerNotFound` and the operator logs will display:
```
ERROR cert-manager is required but was not found in the cluster ...
      Please install cert-manager before deploying the KServe operator.
      See: https://cert-manager.io/docs/installation/
```
Install cert-manager and the operator will automatically retry and proceed.

### Step 6 — Deploy and test the Iris inference model (in-cluster URL)
```bash
kubectl apply -f 06-sample-model/sklearn-iris.yaml

# Wait for predictor to be ready (~30s)
kubectl get isvc sklearn-iris -w   # wait for READY=True

# Test inference via internal cluster URL (always works without ingress)
kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-predictor.default.svc.cluster.local/v1/models/sklearn-iris:predict
```
✅ Expected: `{"predictions":[1]}`

### Step 6b — *(Optional)* Test via external hostname (requires nginx-ingress)

By default KServe disables Kubernetes Ingress creation. To use the external URL shown in `kubectl get isvc` (e.g. `http://sklearn-iris-default.example.com`), follow these steps.

**Install nginx-ingress controller:**
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=120s
```

**Patch KServe to enable Ingress creation with nginx:**

```bash
# Default — installs into 'kserve' ns, sets ingressClassName=nginx
bash enable-ingress.sh

# Custom KServe namespace:
KSERVE_NS=my-kserve bash enable-ingress.sh

# Different ingress class (e.g. haproxy, traefik):
bash enable-ingress.sh --class haproxy
```

The script patches the `inferenceservice-config` ConfigMap (the `ingress` field is a JSON-encoded string inside the ConfigMap — needs parse / modify / re-serialize, and the operator owns the field via Server-Side Apply so `--force-conflicts` is required), then restarts `kserve-controller-manager` and waits for the new pod to be Ready before returning. Run `cat enable-ingress.sh` (or `bash enable-ingress.sh -h`) for details.

**Add local DNS entry** (for Docker Desktop / local clusters):
```bash
# Idempotent — safe to re-run; the entry is only appended once.
HOST_ENTRY="127.0.0.1 sklearn-iris-default.example.com"
grep -qF "${HOST_ENTRY}" /etc/hosts \
  || sudo bash -c "echo '${HOST_ENTRY}' >> /etc/hosts"
```

**Recreate the InferenceService** (so KServe creates the Ingress with the new config):
```bash
kubectl delete isvc sklearn-iris --ignore-not-found
kubectl apply -f 06-sample-model/sklearn-iris.yaml
kubectl get isvc sklearn-iris -w   # wait for READY=True
```

**Verify Ingress and test:**

After the ISVC reaches `READY=True`, the Ingress object is created — but its `ADDRESS` column may be empty for the first ~30s while nginx-ingress programs the route. Wait until `ADDRESS` is `localhost` before curl-ing.

```bash
kubectl get ingress -A
# Expected (after ADDRESS populates):
# NAMESPACE  NAME          CLASS  HOSTS                                    ADDRESS    PORTS  AGE
# default    sklearn-iris  nginx  sklearn-iris-default.example.com,...     localhost  80     30s

curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-default.example.com/v1/models/sklearn-iris:predict
```
✅ Expected: `{"predictions":[1]}`

> **Production note:** Replace `example.com` with your real domain and point DNS to the ingress load balancer IP/hostname. No `/etc/hosts` entry needed in production.

---

## Part C: Alternative — Offline / Air-Gapped Model Test

If your cluster cannot reach `gs://` (Google Cloud Storage) to download model weights, the iris ISVC in Step 6 above will fail (the default `sklearn-iris.yaml` uses a `gs://` `storageUri`). Use this PVC-based offline alternative instead.

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
