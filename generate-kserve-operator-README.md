# KServe Operator Generator Script

## Overview
The `generate-kserve-operator.sh` script is an automation tool that takes a directory of cleanly extracted KServe Raw Mode YAML manifests and programmatically wraps them into a fully functional, compiled Golang Kubernetes Operator using **Operator-SDK**.

Instead of interacting with KServe manually via bash scripts, this tool builds a dedicated "Day 2" Operator (`KServeRawMode`) that orchestrates the installation, enforces webhooks, and manages the KServe lifecycle natively within the Kubernetes API.

## Prerequisites

Before running the script, ensure you have the following installed and pre-configured:

1. **Source Manifests**: You **MUST** run the `generate-kserve-raw.sh` script first to extract and compile the raw YAML files from KServe master. This script depends entirely on those cleanly split, patched directories (like `04-kserve-core`).
2. **Template Base**: Ensure the `kserve-operator-base/` directory is located in the exact same folder as the script. This contains the pre-configured Golang source templates.
3. **Operator SDK**: You must have `operator-sdk` (v1.42.0+) installed and available in your global `$PATH`, or present locally at `./tools/operator-sdk`.
4. **Golang**: `go` must be installed (Go 1.26.0+) to compile the controller and manage module dependencies.
5. **Make**: Required to run the Operator-SDK Makefile targets (`make generate`, `make manifests`). Recommended GNU Make 3.81+ or 4.x.
6. **Docker**: `docker` must be installed (v20.10+) and running, as the script initiates `docker buildx build` for multi-architecture image compilation.
7. **Kustomize**: (v5.0+) The script automatically downloads a localized version into `bin/kustomize`, but having it globally installed allows you to bypass the proxy download step in offline environments.
8. **OLM** *(only required for OLM Bundle deployment with `-o` flag)*: The Operator Lifecycle Manager must be pre-installed on your target cluster. Install it once with:
   ```bash
   operator-sdk olm install
   ```
   Verify all pods are running before proceeding:
   ```bash
   kubectl get pods -n olm
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
  -i docker.io/akashneha/kserve-raw-operator:v152 \
  --docker-server docker.io \
  --docker-username akashneha \
  --docker-password dckr_pat_xxx \
  --pull-secret docker-pull-secret \
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
5. **Docker Image Tag**: The target container registry path and tag for the operator image (e.g., `docker.io/akashneha/kserve-raw-operator:v152`).

## What it Does (Under the Hood)

Once the parameters are provided, the script executes the following sequence autonomously:

1. **Scaffolding**: Runs `operator-sdk init` and `operator-sdk create api` to scaffold a modern `kubebuilder` project.
2. **Asset Embedding**: Copies the 5 core KServe manifest directories (`cert-manager`, `crds`, `rbac`, `core`, `runtimes`) from your source folder directly into the Go project's `internal/controller/assets/` directory.
3. **Code Templating**: Dynamically copies the `.tmpl` files from the `kserve-operator-base/` directory and injects your CLI variables via `sed`, creating three crucial Go files:
    - `api/.../kserverawmode_types.go`: Defines the Custom Resource schema (`KServeRawMode`).
    - `internal/controller/apply.go`: Implements a Kubernetes **Server-Side Apply** engine to parse and apply the embedded YAML files, bypassing standard annotation size limits.
    - `internal/controller/kserverawmode_controller.go`: Writes the main reconciliation loop. This loop explicitly maps the execution order, applies the `.yaml` assets, ensures the `kserve` namespace exists for RBAC bindings, and **polls for real pod readiness** (5-second retries, 5-minute timeout) before deploying `ServingRuntimes` to prevent Webhook race conditions. The reconciler is **idempotent** — it re-applies manifests on every spec change, using `ObservedGeneration` to avoid unnecessary reconciles.
4. **Compilation**: Automatically runs `make manifests`, `make generate`, and `go mod tidy` to ensure the DeepCopy objects, RBAC roles, and go modules are perfectly aligned.
5. **Containerization**: If requested via the `-b / --build` flag, executes `make docker-build IMG=<image-tag>`.
    - Note: If the `--multi-platform` flag is passed, this step shifts to `make docker-buildx`, which triggers a multi-architecture compile and auto-push.
6. **Registry Push**: If requested via the `-p / --push` flag, executes `make docker-push IMG=<image-tag>` to push your newly built container directly to your remote registry.
7. **Deployment Package**: Automatically runs `kustomize build` to generate a self-contained `<target>-package/` directory with `operator-deployment.yaml` and `kserverawmode-sample.yaml` ready for immediate deployment.

## Deploying the Operator

Navigate into the generated project directory:
```bash
cd p-kserve-operator
```

### Option A: Manual Cluster Deployment (Using Make)

You can interact with and deploy your custom operator to your cluster directly using the standard SDK Make targets:

```bash
# Deploy the Controller Manager to the cluster utilizing the image you just built
make deploy IMG=docker.io/akashneha/kserve-raw-operator:v152
```

### Option B: Standalone Extraction Manifests (No Make)

The script automatically generates a pre-compiled `<target>-package/` deployment folder. This means you do not need `make` or the Operator SDK available on the deployment target machine:

```bash
# 1. Apply the precompiled Operator controller
kubectl apply -f p-kserve-operator-package/operator-deployment.yaml

# 2. Wait for the operator pod to be ready before submitting the CR
kubectl rollout status deployment -n p-kserve-operator-system --timeout=120s

# 3. Trigger the KServe installation loop using the sample CR
kubectl apply -f p-kserve-operator-package/kserverawmode-sample.yaml

# 4. Watch the installation phase progress
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
# 1. Create a pull secret in the default namespace so OLM can pull the bundle image
kubectl create secret docker-registry docker-pull-secret \
  --docker-server=docker.io \
  --docker-username=<your-username> \
  --docker-password=<your-token>

# 2. Deploy the bundle (installs the Operator via OLM)
operator-sdk run bundle docker.io/akashneha/kserve-raw-operator:v152-bundle \
  --pull-secret-name docker-pull-secret

# 3. Verify the CSV (ClusterServiceVersion) reached Succeeded phase
kubectl get csv -n operators

# 4. Trigger the KServe installation by applying the sample Custom Resource
kubectl apply -f p-kserve-operator-package/kserverawmode-sample.yaml

# 5. Watch KServe pods come up
kubectl get pods -n kserve -w
```

*Note: If you provided a `--pull-secret` during generation, the generated OLM CSV will automatically include it, ensuring the bundle can be unpacked on clusters with pull restrictions.*

## Monitoring Install Progress

Once you submit the `KServeRawMode` CR, the operator progresses through granular phases you can watch in real time:

```bash
kubectl get kserverawmode -A -w
```

Expected output:
```
NAMESPACE   NAME                   PHASE                   AGE
default     kserverawmode-sample   InstallingCertManager   5s
default     kserverawmode-sample   InstallingCRDs          25s
default     kserverawmode-sample   InstallingRBAC          27s
default     kserverawmode-sample   InstallingCore          28s
default     kserverawmode-sample   InstallingRuntimes      55s
default     kserverawmode-sample   Ready                   60s
```

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
{"predictions": [1, 1]}
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
  -i docker.io/akashneha/kserve-raw-operator:v152 \
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
