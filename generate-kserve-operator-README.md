# KServe Operator Generator Script

## Overview
The `generate-kserve-operator.sh` script is an automation tool that takes a directory of cleanly extracted KServe Raw Mode YAML manifests and programmatically wraps them into a fully functional, compiled Golang Kubernetes Operator using **Operator-SDK**.

Instead of interacting with KServe manually via bash scripts, this tool builds a dedicated "Day 2" Operator (`KServeRawMode`) that orchestrates the installation, enforces webhooks, and manages the KServe lifecycle natively within the Kubernetes API.

## Prerequisites

Before running the script, ensure you have the following tools installed on your build machine. The script supports both **macOS** and **RHEL/Linux x86_64** build environments.

| Tool | Version | Purpose |
|---|---|---|
| Source Manifests (`generate-kserve-raw.sh` output) | — | Required input — run this script first |
| Operator SDK | v1.42.0+ | Scaffolds and builds the Go operator |
| Go | v1.21+ | Compiles the operator controller |
| Make | 3.81+ | Runs Operator-SDK Makefile targets |
| Docker | v20.10+ | Builds and pushes container images |
| yq | v4+ | Patches OLM bundle CSV `installModes` |
| Kustomize | v5.0+ | Generates deployment manifests (auto-downloaded; global install recommended for air-gapped) |
| skopeo | v1.0+ | **Optional** — copies images between registries when using `--customer-registry` |
| OLM | v0.28+ | Required **only** on the target cluster when using `-o` flag |

### Installing Prerequisites

**macOS (Homebrew):**
```bash
brew install go operator-sdk yq kustomize make
brew install skopeo   # optional — only needed for --customer-registry flag
# Docker: install Docker Desktop from https://docs.docker.com/desktop/mac/
```

**RHEL / CentOS / Fedora (x86_64):**
```bash
# Go
wget https://go.dev/dl/go1.21.13.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.13.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc && source ~/.bashrc
go version   # verify

# Operator SDK
export ARCH=amd64 OS=linux
curl -LO https://github.com/operator-framework/operator-sdk/releases/download/v1.42.0/operator-sdk_${OS}_${ARCH}
chmod +x operator-sdk_${OS}_${ARCH} && sudo mv operator-sdk_${OS}_${ARCH} /usr/local/bin/operator-sdk
operator-sdk version   # verify

# yq (direct binary — works on RHEL without snap)
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq --version   # verify

# Kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
kustomize version   # verify

# Make (usually pre-installed on RHEL)
sudo dnf install -y make

# skopeo (optional — only needed for --customer-registry flag)
sudo dnf install -y skopeo

# Docker Engine on RHEL
# See: https://docs.docker.com/engine/install/rhel/
# After install, start and enable:
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # allow non-root docker usage (re-login required)
```

### Installing OLM on the Target Cluster *(required for `-o` flag)*

OLM must be pre-installed on your **Kubernetes cluster** (not the build machine) before deploying via bundle:
```bash
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running
```

## How to Run

Execute the script from your terminal in the same directory where your extracted KServe manifests reside. You can provide arguments via CLI flags to automate the process, or simply run the script to use the interactive prompts:

```bash
chmod +x generate-kserve-operator.sh
./generate-kserve-operator.sh [options]
```

### CLI Options (For CI/CD Automation)
- `-t, --target`         : Target operator directory (e.g., `my-kserve-operator`)
- `-c, --clean`          : Clean the target operator directory and exit
- `-m, --module`         : Go module path (e.g., `github.com/user/my-kserve-operator`)
- `-d, --domain`         : API domain for Custom Resource (e.g., `akashdeo.com`)
- `-s, --source`         : Extracted KServe manifests folder (e.g., `./a-kserve-deploy`)
- `-i, --image`          : Docker image tag (e.g., `quay.io/user/kserve-raw-operator:v1`)
- `-b, --build`          : Automatically build the Docker image without prompting
- `-p, --push`           : Automatically push the Docker image without prompting
- `-x, --multi-platform` : Automatically compiles and pushes a multi-architecture image (amd64, arm64, s390x, ppc64le) using `docker-buildx`. *(Implies `-b`)*
- `-o, --olm`            : Automatically generates and builds an Operator Lifecycle Manager (OLM) Bundle image for the registry. *(Implies `-b`)*
- `--install-mode <mode>`: OLM install mode for the operator CSV. Valid values: `SingleNamespace` (default — operator manages one specific namespace), `OwnNamespace`, `AllNamespaces`, `MultiNamespace`. `SingleNamespace` is recommended for isolated deployments.
- `--customer-registry <prefix>`: Customer private registry prefix (e.g., `artifactory.example.com/myrepo`). When set, all image references in the generated `operator-deployment.yaml` are rewritten to point to this registry. Also generates `mirror-images.sh` (for copying images via skopeo) and `deploy-bundle.sh` (interactive OLM/direct install helper) in the package directory.
- `--pull-secret <name>` : Name of an existing `imagePullSecret` on the cluster (injected into the operator pod spec)
- `--docker-server <url>` : Registry server URL for pull secret creation (default: `docker.io`)
- `--docker-username <u>` : Registry username — when set, generates `setup-credentials.sh` in the output package
- `--docker-password <p>` : Registry password or access token — used alongside `--docker-username`
- `--cert <path>`        : Injects a certificate into the trusted chain of the Docker build stage (required for firewalls or corporate proxies).
- `-h, --help`           : Show help message

#### Example (from a real test run)

The following command was used to generate a fully multi-platform, OLM-ready operator with a Docker Hub pull secret:

```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:v303 \
  --pull-secret dockerhub-creds \
  --install-mode SingleNamespace \
  -b -p -o
```

This generates:
- **`p-kserve-operator/`** — the compiled Go operator project
- **`p-kserve-operator-package/`** — the ready-to-deploy customer package

To clean up both generated directories afterwards:
```bash
./generate-kserve-operator.sh -c p-kserve-operator
```

### Interactive Prompts
If you omit any of the required CLI flags, the script will gracefully fall back to asking you for the specific missing variables interactively:

1. **Target Directory**: The name of the new folder to create (e.g., `p-kserve-operator`).
2. **Go Module Path**: Your Go repository path (e.g., `github.com/akashdeo/p-kserve-operator`).
3. **API Domain**: The domain for your Custom Resource Group (e.g., `akashdeo.com` will result in `operator.akashdeo.com`).
4. **Manifest Directory**: The path to your previously generated raw manifests folder (e.g., `p-kserve-raw`).
5. **Docker Image Tag**: The target container registry path and tag for the operator image (e.g., `docker.io/akashneha/kserve-raw-operator:v300`).

## What it Does (Under the Hood)

Once the parameters are provided, the script executes the following sequence autonomously:

1. **Scaffolding**: Runs `operator-sdk init` and `operator-sdk create api` to scaffold a modern `kubebuilder` project.
2. **Asset Embedding**: Copies the **4** core KServe manifest directories (`crds`, `rbac`, `core`, `runtimes`) from your source folder directly into the Go project's `internal/controller/assets/` directory.
   > **Note:** `cert-manager` is intentionally excluded — it is a **cluster pre-requisite** that must be installed before the operator is deployed. The operator validates cert-manager's presence at reconcile time and surfaces a `CertManagerNotFound` error phase if absent.
3. **Code Templating**: Dynamically copies the `.tmpl` files from the `kserve-operator-base/` directory and injects your CLI variables via `sed`, creating three crucial Go files:
    - `api/.../kserverawmode_types.go`: Defines the Custom Resource schema (`KServeRawMode`).
    - `internal/controller/apply.go`: Implements a Kubernetes **Server-Side Apply** engine to parse and apply the embedded YAML files, bypassing standard annotation size limits.
    - `internal/controller/kserverawmode_controller.go`: Writes the main reconciliation loop. This loop explicitly maps the execution order, derives the install namespace from the CR's `metadata.namespace` (which the OperatorGroup's `targetNamespaces` constrains), applies the `.yaml` assets with apply-time namespace rewriting (every baked `kserve` reference becomes the chosen target), and **polls for real pod readiness** (5-second retries, 5-minute timeout) before deploying `ServingRuntimes` to prevent Webhook race conditions. The reconciler is **idempotent** — it re-applies manifests on every spec change, using `ObservedGeneration` to avoid unnecessary reconciles.
4. **Compilation**: Automatically runs `make manifests`, `make generate`, and `go mod tidy` to ensure the DeepCopy objects, RBAC roles, and go modules are perfectly aligned.
5. **Containerization**: If requested via the `-b / --build` flag, executes `docker build` to build the operator image.
   - Note: If the `--multi-platform` flag is passed, the script calls `docker buildx build --push` directly (bypassing `make docker-buildx`) to ensure build failures are always detected. A post-push `docker manifest inspect` verification confirms the image is available in the registry.
6. **Registry Push**: If requested via the `-p / --push` flag, executes `make docker-push IMG=<image-tag>` to push your newly built container directly to your remote registry.
7. **Deployment Package**: Automatically runs `kustomize build` to generate a self-contained `<target>-package/` directory with `operator-deployment.yaml` and `kserve-rawmode.yaml` ready for immediate deployment.

## Deploying the Operator

Navigate into the generated project directory:
```bash
cd p-kserve-operator
```

### Option A: Manual Cluster Deployment (Using Make)

You can interact with and deploy your custom operator to your cluster directly using the standard SDK Make targets:

```bash
# Deploy the Controller Manager to the cluster utilizing the image you just built
make deploy IMG=docker.io/akashneha/kserve-raw-operator:v300
```

### Option B: Standalone Extraction Manifests (No Make)

The script automatically generates a pre-compiled `<target>-package/` deployment folder. This means you do not need `make` or the Operator SDK available on the deployment target machine:

```bash
# 1. Apply the precompiled Operator controller
kubectl apply -f p-kserve-operator-package/operator-deployment.yaml

# 2. Watch the installation phase progress
# (The operator auto-creates the KServeRawMode CR — KServe installation begins automatically)
kubectl get kserverawmode -A -w
```

### Option C: OLM Bundle Deployment (Enterprise Ready)

If you generated an OLM bundle using the `-o` flag, you can install the operator using the **Operator Lifecycle Manager**. This is the recommended approach for production clusters as it manages upgrades and dependencies automatically.

> [!IMPORTANT]
> **OLM must be installed on your cluster before running the bundle.** On a fresh cluster, OLM is not present by default. Install it once:
> ```bash
> operator-sdk olm install
> kubectl get pods -n olm   # Wait for all pods to be Running
> ```

> [!TIP]
> **OLM Platform Compatibility**: The script uses `docker buildx build --provenance=false --sbom=false` when building the bundle image. This produces a flat single-manifest image (auto-detecting your host arch via `uname -m`). Without these flags, Docker BuildKit adds attestation manifests that create a multi-arch manifest list which OLM's image unpacker cannot resolve. This works correctly on both `linux/amd64` (x86_64) and `linux/arm64` (aarch64) hosts.

```bash
# 0. Install cert-manager (REQUIRED — the operator does not install it)
CERT_MANAGER_VERSION="v1.17.2"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s

# 1. Install OLM (once per cluster)
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running

# 2. Create the two namespaces.
#    KSERVE_NS = where the CR + KServe runtime will live (default 'kserve';
#                pick anything else, e.g. 'my-kserve', and apply-time YAML rewriting
#                will install KServe there).
KSERVE_NS=kserve
kubectl create namespace "${KSERVE_NS}"
kubectl create namespace kserve-operator-system

# 3. (Optional) Pull secret in the operator namespace, only if your image is private.
kubectl create secret docker-registry dockerhub-creds \
  --docker-server=docker.io \
  --docker-username=<registry-user> \
  --docker-password=<registry-token> \
  -n kserve-operator-system

# 4. Deploy the bundle. --install-mode auto-creates an OperatorGroup
#    targeting ${KSERVE_NS}; no manual OperatorGroup yaml needed.
operator-sdk run bundle <your-bundle-image>:<tag>-bundle \
  --namespace kserve-operator-system \
  --install-mode "SingleNamespace=${KSERVE_NS}"
# (add `--pull-secret-name dockerhub-creds` if step 3 was needed)

# 5. Watch KServe auto-installation progress (the CR is auto-created in ${KSERVE_NS})
kubectl get kserverawmode -A -w
```

> **Why no OperatorGroup yaml?** OLM forbids embedding OperatorGroups in bundles (they're user-controlled installation parameters). `operator-sdk run bundle --install-mode` generates one on the fly named `operator-sdk-og` in the operator namespace.

*Note: If you provided a `--pull-secret` during generation, the generated OLM CSV will automatically include it, ensuring the bundle can be unpacked on clusters with pull restrictions.*

---

### Option D: Customer / Private Registry Deployment

If deploying to a customer environment with a private registry (e.g., Artifactory, Harbor, ECR), use the `--customer-registry` flag at generation time:

```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:<tag> \
  --customer-registry localhost:5001/myrepo \
  --pull-secret dockerhub-creds \
  --install-mode SingleNamespace \
  -b -p -o
```

The generated `p-kserve-operator-package/` directory contains up to four helper scripts:

| File | When generated | Purpose |
|---|---|---|
| `setup-credentials.sh` | Always | Creates `dockerhub-creds` pull secret in `default`, `kserve-operator-system`, `olm`, `operators`. Pre-flight checks cert-manager + namespaces and fails fast if anything is missing. Accepts `--user`/`--pass` CLI args or prompts interactively. |
| `enable-ingress.sh` | Always | Patches KServe's `inferenceservice-config` ConfigMap to enable Ingress creation, restarts the controller, waits for Ready. Use this only when you want external URLs via an ingress controller. Accepts `KSERVE_NS` env var (default `kserve`) and `--class` flag (default `nginx`). |
| `mirror-images.sh` | With `--customer-registry` | Copies operator + bundle images from build registry → customer registry. Supports 3 modes: **online** (direct), **archive** (save to tar), **load** (push from tar). |
| `deploy-bundle.sh` | With `--customer-registry` | One-command OLM install — wraps `operator-sdk run bundle ... --install-mode SingleNamespace=${KSERVE_NS:-kserve} --pull-secret-name <secret>`. Interactive: prompts for OLM bundle vs. direct `kubectl apply` path. |

> **Cluster prerequisites for both deployer workflows:**
> 1. cert-manager installed (`kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml`)
> 2. OLM installed (`operator-sdk olm install`)
> 3. Both namespaces pre-created on the cluster:
>    ```bash
>    kubectl create namespace kserve                  # KServe target ns (override with KSERVE_NS)
>    kubectl create namespace kserve-operator-system  # operator pod home
>    ```

**Deployer workflow — Option A (online, both registries on one machine):**
```bash
cd p-kserve-operator-package

# 1. Mirror images to customer registry
bash mirror-images.sh --user <customer-user> --pass <customer-token>

# 2. Set up pull credentials
bash setup-credentials.sh --user <customer-user> --pass <customer-token>

# 3. Deploy
bash deploy-bundle.sh dockerhub-creds
# To install KServe into a custom namespace name:
#   KSERVE_NS=my-kserve bash deploy-bundle.sh dockerhub-creds
```

**Deployer workflow — Option B (offline/air-gapped, images shipped as archives):**
```bash
# --- On a machine WITH internet access (builder side) ---
cd p-kserve-operator-package
bash mirror-images.sh --archive
# Produces: images/operator.tar  +  images/bundle.tar
# Transfer the entire package folder (including images/) to the customer machine

# --- On the customer (air-gapped) machine ---
cd p-kserve-operator-package
bash mirror-images.sh --load --user <customer-user> --pass <customer-token>
bash setup-credentials.sh --user <customer-user> --pass <customer-token>
bash deploy-bundle.sh dockerhub-creds
# (cert-manager and OLM must already be installed on the air-gapped cluster
#  — typically pre-staged by the cluster admin before the package arrives)
```

> **Note:** `mirror-images.sh` prompts interactively for credentials if `--dest-user`/`--dest-pass` are not provided. No credentials are embedded in the generated scripts.

## Monitoring Install Progress

Once you submit the `KServeRawMode` CR, the operator progresses through granular phases you can watch in real time:

```bash
kubectl get kserverawmode -A -w
```

Expected output (using default `kserve` namespace; the column tracks the OperatorGroup's `targetNamespaces`):
```
NAMESPACE   NAME             PHASE                    AGE
kserve      kserve-rawmode   ValidatingCertManager    2s
kserve      kserve-rawmode   InstallingCRDs           8s
kserve      kserve-rawmode   InstallingRBAC           10s
kserve      kserve-rawmode   InstallingCore           11s
kserve      kserve-rawmode   InstallingRuntimes       38s
kserve      kserve-rawmode   Ready                    43s
```

If cert-manager is absent, the phase shows `CertManagerNotFound` and the operator logs display an actionable error. Install cert-manager and the operator retries automatically.

The operator polls for real pod readiness at each stage — no manual `sleep` commands needed.

---

## End-to-End Validation (Testing Iris Inference)

Once the `KServeRawMode` custom resource has been submitted and KServe pods are running, you can validate the installation end-to-end using the included Iris model:

```bash
# Verify KServe controller is healthy
kubectl get pods -n kserve
```

Expected output:
```
NAME                                         READY   STATUS    RESTARTS   AGE
kserve-controller-manager-7c77df7f5d-z2qlq   2/2     Running   0          70s
```

When all controller pods are `Running`, deploy the sample `sklearn-iris` model:

1. **Submit the InferenceService** (included in the generated package):
    ```bash
    kubectl apply -f p-kserve-operator-package/06-sample-model/sklearn-iris.yaml
    ```
2. **Monitor the Predictor Pod:**
    ```bash
    kubectl get pods -l serving.kserve.io/inferenceservice=sklearn-iris -w
    ```
    Once the `sklearn-iris-predictor-<hash>` pod is `1/1 Running`, the API is online.
3. **Execute an Inference Request:** Port-forward the service and invoke the model:
    ```bash
    kubectl port-forward svc/sklearn-iris-predictor 8080:80 &

    curl -s -X POST -H "Content-Type: application/json" \
      -d @p-kserve-operator-package/06-sample-model/iris-input.json \
      "http://localhost:8080/v1/models/sklearn-iris:predict"
    ```

    **Alternative (in-cluster, no port-forward needed):**
    ```bash
    kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
      curl -s -H "Content-Type: application/json" \
      -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
      http://sklearn-iris-predictor.default.svc.cluster.local/v1/models/sklearn-iris:predict
    ```

**Expected Result:**
```json
{"predictions":[1]}
```

If you receive the prediction integer array back, your generated Operator has successfully established a fully functioning, dependency-free KServe environment on your cluster!

## Using Docker Hub with a Pull Secret

If your cluster needs a Kubernetes secret to pull images from Docker Hub (to avoid rate limits or authenticate to a private repo), use the `--pull-secret` flag when generating:

```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:v300 \
  --pull-secret dockerhub-creds \
  -b -p -o
```

The `dockerhub-creds` secret name will be embedded directly into the operator's pod spec and OLM CSV, so no manual patching is required after deployment.

## Handling KServe Dependencies (Mirrors)

By default, the KServe manifests extracted by `generate-kserve-raw.sh` reference official images hosted on **Docker Hub** (e.g., `kserve/kserve-controller`) and **Quay.io** (e.g., `quay.io/jetstack/cert-manager-controller`).

If your environment blocks access to these public registries, you should:

1.  **Mirror the Images**: Pull the official images and push them to your internal registry.
2.  **Redirect the Manifests**: Before running `generate-kserve-operator.sh`, you can use Kustomize to redirect the source manifests in your extracted folder:
    ```bash
    cd p-kserve-raw/04-kserve-core
    kustomize edit set image kserve/kserve-controller=internal-registry.com/mirrors/kserve-controller:v0.12.0
    ```
3.  **ConfigMap Updates**: KServe also uses a ConfigMap (`inferenceservice-config`) to define images for predictors (sklearn, pytorch, etc.). Our automated generator preserves these references. You can manually edit the `04-kserve-core/kserve-core.yaml` to point these to your internal mirrors if required.
