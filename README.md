# KServe Offline Operator Tooling

This repository contains powerful automated tooling designed to parse, extract, configure, and package **KServe** for standalone offline and air-gapped deployments utilizing `RawDeployment` architecture (bypassing Knative and Istio requirements).

It is composed of two primary bash automation pipelines that rely on modular template bases for their execution loops.

---

## 🛑 Prerequisites

Before running the generation scripts, ensure the following dependencies are installed on your build machine:

* **[Go](https://go.dev/doc/install)** (v1.20+)
* **[Operator SDK](https://sdk.operatorframework.io/docs/installation/)** (v1.33+)
* **[Docker](https://docs.docker.com/get-docker/)** (Required for container builds & multi-arch `buildx`)
* **[Python 3](https://www.python.org/downloads/)** (With the `yaml` package installed: `pip install pyyaml`)
* **[kubectl](https://kubernetes.io/docs/tasks/tools/)**
* **[Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/)** (v5.0+)

---

## 🏗️ 1. KServe Raw Mode Extractor (`generate-kserve-raw.sh`)

This script aggressively parses a local checkout of the `kserve-master` repository and builds a heavily customized, isolated Kustomize deployment package. 

* **Purpose**: Creates an independent directory containing all KServe core components pre-patched for `"defaultDeploymentMode": "RawDeployment"`.
* **Action**: Extracts `Cert-Manager`, KServe CRDs, RoleBindings, and built-in cluster predictors.
* **Component Template Base**: `kserve-raw-base/` 
  * *Contains the markdown READMEs, quick-install shell scripts, and sample Iris payloads dynamically injected into the extracted folder.*
* **Command Syntax**: 
  ```bash
  ./generate-kserve-raw.sh --target extracted-kserve-dir
  ```

---

## ⚙️ 2. KServe Standalone Operator Generator (`generate-kserve-operator.sh`)

This script utilizes `operator-sdk` (v1.42.0+) to dynamically scaffold a custom Golang operator that can install and manage the extracted raw KServe manifests natively.

* **Purpose**: Compiles a production-ready Operator container image and generates a lightweight "Customer Distribution Package" containing the CRDs necessary to remotely trigger the internal KServe installation loop on a target Kubernetes cluster.
* **Action**: Builds Golang reconcilers, maps namespaces, triggers Docker `buildx` multi-architecture compilation (amd64, arm64, s390x), and bundles the final YAML assets. 
* **Component Template Base**: `kserve-operator-base/`
  * *Contains the Golang `.tmpl` files that define the Types, Controller logic, and Apply rules, alongside the customer package README generator.*
* **Command Syntax**:
  ```bash
  # Standard Build
  ./generate-kserve-operator.sh \
    --target my-operator \
    --module github.com/my-org/my-operator \
    --domain custom.domain.io \
    --source extracted-kserve-dir \
    --image docker.io/my-org/kserve-op:latest
    
  # Multi-Architecture Push (CI/CD)
  ./generate-kserve-operator.sh [flags...] --multi-platform
  ```

---

## 🛠️ Typical Workflow Execution

1. **Clone** the official `kserve` repository directly into this workspace (`./kserve-master`).
2. **Execute** `generate-kserve-raw.sh` to extract and configure the standalone YAML configuration.
   ```bash
   ./generate-kserve-raw.sh -t p-kserve-raw
   ```
3. **Execute** `generate-kserve-operator.sh` against the extracted folder to compile the final Go-based Kubernetes Operator and generate the redistributable installer bundle.
   ```bash
   ./generate-kserve-operator.sh \
     -t p-kserve-operator \
     -m github.com/your-org/my-kserve-operator \
     -d your.domain.com \
     -s p-kserve-raw \
     -i docker.io/your-org/kserve-raw-operator:v1 \
     -b -p
   ```
4. **Deploy** the generated package to your cluster:
   ```bash
   # Option A: Direct manifests
   kubectl apply -f p-kserve-operator-package/operator-deployment.yaml
   kubectl apply -f p-kserve-operator-package/kserve-rawmode.yaml

   # Option B: OLM bundle (requires OLM pre-installed)
   operator-sdk run bundle docker.io/your-org/kserve-raw-operator:v1-bundle \
     --pull-secret-name docker-pull-secret
   kubectl apply -f p-kserve-operator-package/kserve-rawmode.yaml
   ```
5. **Monitor** the installation progress and **validate** the Iris inference model:
   ```bash
   # Watch phase progression (no manual sleep needed)
   kubectl get kserverawmode -A -w

   # Once Ready, deploy and test the sample model
   kubectl apply -f p-kserve-operator-package/06-sample-model/sklearn-iris.yaml
   kubectl port-forward svc/sklearn-iris-predictor 8080:80 &
   curl -s -H 'Content-Type: application/json' \
     -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
     http://localhost:8080/v1/models/sklearn-iris:predict
   # Expected: {"predictions":[1]}
   ```
