# KServe Raw Mode Extraction Script

## Overview
The `generate-kserve-raw.sh` script is a utility designed to completely parse the official `kserve-master` repository and programmatically generate a self-contained, offline-ready folder containing everything you need to install KServe in **Raw Deployment Mode**.

This allows you to bypass complex Helm charts, Istio, or Knative dependencies by isolating pure KServe YAML manifests and patching the configurations to ensure Kubernetes Deployments handle your machine learning models directly.

## Prerequisites

Before running the script, ensure you meet the following requirements on your local machine:

1. **KServe Source Code**: The `kserve-master` directory must exist in the exact same parent directory as this script. The script uses Kustomize to build manifests directly from this source code.
2. **Kustomize**: The `kustomize` CLI tool must be installed and available in your system `$PATH` (The KServe `Makefile` normally installs this in `bin/kustomize`, but global availability is recommended).
3. **Python 3**: Python is required to safely inject the `RawDeployment` configuration directly into the KServe `inferenceservice-config` ConfigMap block without corrupting the YAML structure.
4. **curl**: Used to pull the specific version of the `cert-manager` manifest.

### Installing Prerequisites
If you are missing the required tools, you can install them using the following commands:

**macOS (Homebrew):**
```bash
brew install kustomize python curl
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install python3 curl -y
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

**Linux (RHEL/CentOS/Fedora):**
```bash
sudo dnf install python3 curl -y
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

## How to Run

Execute the script from your terminal:

```bash
chmod +x generate-kserve-raw.sh
./generate-kserve-raw.sh [options]
```

### CLI Options (CI/CD Automation)
You can bypass the interactive prompts by supplying the target directory via the `-t` flag. This allows you to run the script headlessly in automated pipelines:

- `-t, --target <name>` : Target extraction directory name (e.g., `c-kserve-raw`)
- `-h, --help`          : Show help message

### Interactive Prompt
If you run the script without any arguments, it will fall back to an interactive prompt:
```text
Enter the name of the target directory to create (e.g., my-kserve-deploy): 
```
If you type `kserve-prod-deploy`, the script will create this folder right next to the script and populate it.

## What it Outputs
The generated directory will contain carefully split sub-directories alongside deployment execution scripts:

1. **`01-cert-manager/`**: Contains the `v1.13.0` release of cert-manager (a hard requirement for KServe webhooks).
2. **`02-kserve-crds/`**: Contains the Custom Resource Definitions (like `InferenceService`, `ClusterServingRuntime`, and `LLMInferenceServiceConfig`).
3. **`03-kserve-rbac/`**: Contains the necessary ClusterRoles and authentication manifests.
4. **`04-kserve-core/`**: Contains the KServe Controller Manager deployments. **Crucially, the script patches the inline ConfigMap so `defaultDeploymentMode` is explicitly set to `RawDeployment`, and explicitly appends the `selfsigned-issuer` so webhooks can establish TLS.**
5. **`05-kserve-runtimes/`**: Contains the out-of-the-box predictors (Scikit-Learn, PyTorch, HuggingFace).
6. **`06-sample-model/`**: Contains a fully configured `sklearn-iris.yaml` Service and an `iris-input.json` test payload to immediately verify your cluster is functioning.

### Installation Shell Script and Documentation
Finally, the script automatically generates two top-level execution files inside your new target directory:
- **`README.md`**: A standalone Markdown file explaining exactly how to utilize the generated manifests.
- **`install.sh`**: An automated bash deployer. You can distribute this entire folder to your cluster administrators and they just run:

```bash
cd <your-target-directory>
./install.sh
```

The installer handles race-conditions by imposing explicit `kubectl wait` and `sleep 15` buffers, ensuring the webhooks do not reject the KServe runtime configurations during a cold start, and then prints exact copy-paste terminal commands to test the Iris model.
