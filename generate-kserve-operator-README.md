# KServe Operator Generator Script

## Overview
The `generate-kserve-operator.sh` script is an automation tool that takes a directory of cleanly extracted KServe Raw Mode YAML manifests and programmatically wraps them into a fully functional, compiled Golang Kubernetes Operator using **Operator-SDK**.

Instead of interacting with KServe manually via bash scripts, this tool builds a dedicated "Day 2" Operator (`KServeRawMode`) that orchestrates the installation, enforces webhooks, and manages the KServe lifecycle natively within the Kubernetes API.

## Prerequisites

Before running the script, ensure you have the following installed and pre-configured:

1. **Source Manifests**: You **MUST** run the `generate-kserve-raw.sh` script first to extract and compile the raw YAML files from KServe master. This script depends entirely on those cleanly split, patched directories (like `04-kserve-core`).
2. **Template Base**: Ensure the `kserve-operator-base/` directory is located in the exact same folder as the script. This contains the pre-configured Golang source templates.
3. **Operator SDK**: You must have `operator-sdk` (v1.33+) installed and available in your global `$PATH`, or present locally at `./tools/operator-sdk`.
4. **Golang**: `go` must be installed (Go 1.20+) to compile the controller and manage module dependencies.
5. **Make**: Required to run the Operator-SDK Makefile targets (`make generate`, `make manifests`).

## How to Run

Execute the script from your terminal in the same directory where your extracted KServe manifests reside. You can provide arguments via CLI flags to automate the process, or simply run the script to use the interactive prompts:

```bash
chmod +x generate-kserve-operator.sh
./generate-kserve-operator.sh [options]
```

### CLI Options (For CI/CD Automation)
- `-t, --target`         : Target operator directory (e.g., `my-kserve-operator`)
- `-m, --module`         : Go module path (e.g., `github.com/user/my-kserve-operator`)
- `-d, --domain`         : API domain for Custom Resource (e.g., `akashdeo.com`)
- `-s, --source`         : Extracted KServe manifests folder (e.g., `./a-kserve-deploy`)
- `-i, --image`          : Docker image tag (e.g., `quay.io/user/kserve-raw-operator:v1`)
- `-b, --build`          : Automatically build the Docker image without prompting
- `-p, --push`           : Automatically push the Docker image without prompting
- `-x, --multi-platform` : Automatically compiles and pushes a multi-architecture image (amd64, arm64, s390x, ppc64le) using `docker-buildx`. *(Implies `-b`)*
- `-o, --olm`            : Automatically generates and builds an Operator Lifecycle Manager (OLM) Bundle image for the registry. *(Implies `-b`)*
- `--pull-secret <name>` : Automatically configures the operator to use an existing `imagePullSecret` to pull its own image (useful for private registries or Docker Hub rate limits).
- `-h, --help`           : Show help message

### Interactive Prompts
If you omit any of the required CLI flags, the script will gracefully fall back to asking you for the specific missing variables interactively:

1. **Target Directory**: The name of the new folder to create (e.g., `my-kserve-operator`).
2. **Go Module Path**: Your Go repository path (e.g., `github.com/akashdeo/my-kserve-operator`).
3. **API Domain**: The domain for your Custom Resource Group (e.g., `akashdeo.com` will result in `operator.akashdeo.com`).
4. **Manifest Directory**: The path to your previously generated manual deployment folder (e.g., `c-kserve-raw`).
5. **Docker Image Tag**: The target container registry path and tag for the operator image (e.g., `quay.io/akashdeo/kserve-raw-operator:v1`).

## What it Does (Under the Hood)

Once the parameters are provided, the script executes the following sequence autonomously:

1. **Scaffolding**: Runs `operator-sdk init` and `operator-sdk create api` to scaffold a modern `kubebuilder` project.
2. **Asset Embedding**: Copies the 5 core KServe manifest directories (`cert-manager`, `crds`, `rbac`, `core`, `runtimes`) from your source folder directly into the Go project's `internal/controller/assets/` directory.
3. **Code Templating**: Dynamically copies the `.tmpl` files from the `kserve-operator-base/` directory and injects your CLI variables via `sed`, creating three crucial Go files:
    - `api/.../kserverawmode_types.go`: Defines the Custom Resource schema (`KServeRawMode`).
    - `internal/controller/apply.go`: Implements a Kubernetes **Server-Side Apply** engine to parse and apply the embedded YAML files, bypassing standard annotation size limits.
    - `internal/controller/kserverawmode_controller.go`: Writes the main reconciliation loop. This loop explicitly maps the execution order, applies the `.yaml` assets, ensures the `kserve` namespace exists for RBAC bindings, and enforces a strict `15-second` delay prior to deploying `ServingRuntimes` to prevent Webhook race conditions.
4. **Compilation**: Automatically runs `make manifests`, `make generate`, and `go mod tidy` to ensure the DeepCopy objects, RBAC roles, and go modules are perfectly aligned.
5. **Containerization**: If requested interactively or via the `-b / --build` flag, executes `make docker-build IMG=<image-tag>`.
    - Note: If the `--multi-platform` flag is passed, this step shifts to `make docker-buildx`, which triggers a multi-architecture compile.
6. **Registry Push**: If requested interactively or via the `-p / --push` flag, executes `make docker-push IMG=<image-tag>` to push your newly built container directly to your remote registry. (Auto-pushed if `--multi-platform` is used).

```bash
cd <your-target-directory>
```

### Option A: Manual Cluster Deployment (Using Make)

You can interact with and deploy your custom operator to your cluster directly using the standard SDK Make targets:

```bash
# Deploy the Controller Manager to the cluster utilizing the image you just built
make deploy IMG=your-registry/kserve-raw-operator:v1
```

### Option B: Standalone Extraction Manifests (No Make)

Our automated script natively utilizes Kustomize (`make kustomize`) at the conclusion of the generation cycle to automatically precompile and output a standalone deployment payload. This means you do not need `make` or the Operator SDK available on the deployment target machine to install your operator:

```bash
# 1. Apply the precompiled Operator controller
kubectl apply -f operator-deployment.yaml

# 2. Trigger the KServe installation loop using the sample payload
sleep 5
kubectl apply -f kserverawmode-sample.yaml
```

### Option C: OLM Bundle Deployment (Enterprise Ready)

If you generated an OLM bundle using the `-o` flag, you can install the operator using the **Operator Lifecycle Manager**. This is the recommended approach for production clusters as it manages upgrades and dependencies automatically:

```bash
# Deploy the bundle directly using Operator SDK
operator-sdk run bundle <your-image-tag>-bundle
```

*Note: If you provided a `--pull-secret`, the generated OLM CSV will automatically include it, ensuring the bundle can be unpacked on clusters with pull restrictions.*

## End-to-End Validation (Testing Iris Inference)

Once the `KServeRawMode` custom resource has been submitted, you can monitor the installation of KServe:

```bash
kubectl get pods -n kserve
```

When all controller pods stabilize, prove the Raw Mode installation handles Machine Learning workloads by deploying the sample `sklearn-iris` model:

1. **Submit the InferenceService:** Assuming you ran the `generate-kserve-raw.sh` script previously, locate the included iris payload:
    ```bash
    kubectl apply -f ../<your-raw-source-dir>/06-sample-model/sklearn-iris.yaml
    ```
2. **Monitor the Predictor:**
    ```bash
    kubectl get pods -l serving.kserve.io/inferenceservice=sklearn-iris
    ```
    Once the `sklearn-iris-predictor-<hash>` pod is `Running 1/1`, the API is online.
3. **Execute an Inference Request:** Port-forward the service to invoke the model on localhost:
    ```bash
    kubectl port-forward svc/sklearn-iris-predictor 8080:80 &
    
    curl -s -X POST -H "Content-Type: application/json" \
      -d '{"instances": [[6.8, 2.8, 4.8, 1.4], [6.0, 3.4, 4.5, 1.6]]}' \
      "http://localhost:8080/v1/models/sklearn-iris:predict"
    ```

**Expected Result:**
```json
{"predictions": [1, 1]}
```

If you receive the prediction integer array back, your generated Operator has successfully established a fully functioning, dependency-free KServe environment on your cluster!

## Using Internal Registries

The tooling is registry-agnostic. To use an internal or private registry:

1.  **Specify the Full URL**: Use the full registry path in the `--image` flag:
    `--image internal-registry.com/my-project/kserve-operator:v1`
2.  **Local Authentication**: Run `docker login internal-registry.com` on your build machine before running the script.
3.  **Cluster Authentication**: Use the `--pull-secret` flag to specify the name of the Kubernetes `docker-registry` secret that the cluster will use to pull the images.

```bash
./generate-kserve-operator.sh \
  --image internal-registry.com/my-project/kserve-operator:v1 \
  --pull-secret my-internal-secret \
  --olm
```

## Handling KServe Dependencies (Mirrors)

By default, the KServe manifests extracted by `generate-kserve-raw.sh` reference official images hosted on **Docker Hub** (e.g., `kserve/kserve-controller`) and **Quay.io** (e.g., `quay.io/jetstack/cert-manager-controller`).

If your environment blocks access to these public registries, you should:

1.  **Mirror the Images**: Pull the official images and push them to your internal registry.
2.  **Redirect the Manifests**: Before running `generate-kserve-operator.sh`, you can use Kustomize to redirect the source manifests in your extracted folder:
    ```bash
    cd <extracted-raw-folder>/04-kserve-core
    kustomize edit set image kserve/kserve-controller=internal-registry.com/mirrors/kserve-controller:v0.12.0
    ```
3.  **ConfigMap Updates**: KServe also uses a ConfigMap (`inferenceservice-config`) to define images for predictors (sklearn, pytorch, etc.). Our automated generator preserves these references. You can manually edit the `04-kserve-core/kserve-core.yaml` to point these to your internal mirrors if required.
