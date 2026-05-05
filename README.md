# KServe Offline Operator Tooling

This repository contains powerful automated tooling designed to parse, extract, configure, and package **KServe** for standalone offline and air-gapped deployments utilizing `RawDeployment` architecture (bypassing Knative and Istio requirements).

It is composed of two primary bash automation pipelines that rely on modular template bases for their execution loops.

---

## 📚 Documentation

**Start here:**

| Doc | What it's for |
|---|---|
| [QUICK_START.md](QUICK_START.md) | Copy-paste install guide — both the **builder** workflow (Part A: extract → generate → push) and the **deployer** workflow (Part B: cert-manager → OLM → run bundle → iris smoke test). The fastest path to a working install. |
| [generate-kserve-raw-README.md](generate-kserve-raw-README.md) | Full CLI reference for the raw-extraction script. |
| [generate-kserve-operator-README.md](generate-kserve-operator-README.md) | Full CLI reference for the operator generator (all flags, install modes, customer-registry workflow). |

**Architecture & design (in [extra-docs/](extra-docs/)):**

| Doc | What it's for |
|---|---|
| [architecture-overview.md](extra-docs/architecture-overview.md) | Visual architecture — 5 mermaid diagrams covering the build factory, deployer journey, operator brain, sequence flow, and manifest pipeline. Includes E2E test validation tables. |
| [architecture-namespaces.md](extra-docs/architecture-namespaces.md) | Design discussion of the namespace topology and OLM install modes. The reasoning behind why the CR + KServe runtime co-locate in a single user-chosen namespace. |
| [why-customer-registry.md](extra-docs/why-customer-registry.md) | Why image references are baked into the OLM bundle at build time and can't cleanly be overridden at deploy time — the rationale for the `--customer-registry` flag. |
| [OPERATOR_HUB_PUBLISHING.md](extra-docs/OPERATOR_HUB_PUBLISHING.md) | How to submit the generated bundle to the public OperatorHub. |
| [test-report-customer-registry.md](extra-docs/test-report-customer-registry.md) | End-to-end test report covering customer-registry, custom-namespace, external-URL, and `--cert` scenarios. |

---

## 🛑 Prerequisites

Before running the generation scripts, ensure the following dependencies are installed on your **build machine** (supports macOS and RHEL/Linux x86_64):

| Tool | Version | Required by |
|---|---|---|
| Go | v1.21+ | `generate-kserve-operator.sh` |
| Operator SDK | v1.42+ | `generate-kserve-operator.sh` |
| Docker | v20.10+ | `generate-kserve-operator.sh` |
| Python 3 + pyyaml | Any | `generate-kserve-raw.sh` |
| yq | v4+ | `generate-kserve-operator.sh` (`--olm` flag) |
| kubectl | v1.24+ | Both scripts |
| Kustomize | v5.0+ | `generate-kserve-raw.sh` (global); auto-downloaded for operator |

### Installing Prerequisites

**macOS (Homebrew):**
```bash
brew install go operator-sdk yq kustomize python kubectl
pip3 install pyyaml
brew install skopeo   # optional — only needed for --customer-registry flag
# Docker: install Docker Desktop from https://docs.docker.com/desktop/mac/
```

**RHEL / CentOS / Fedora (x86_64):**
```bash
# Go
wget https://go.dev/dl/go1.21.13.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.13.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc && source ~/.bashrc

# Operator SDK
export ARCH=amd64 OS=linux
curl -LO https://github.com/operator-framework/operator-sdk/releases/download/v1.42.0/operator-sdk_${OS}_${ARCH}
chmod +x operator-sdk_${OS}_${ARCH} && sudo mv operator-sdk_${OS}_${ARCH} /usr/local/bin/operator-sdk

# yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# Kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# Python + pyyaml, kubectl, Docker
sudo dnf install -y python3 python3-pip
pip3 install pyyaml
sudo dnf install -y skopeo   # optional — only needed for --customer-registry flag
# kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
# Docker Engine: https://docs.docker.com/engine/install/rhel/
```

---

## 🏗️ 1. KServe Raw Mode Extractor (`generate-kserve-raw.sh`)

This script aggressively parses a local checkout of the `kserve-master` repository and builds a heavily customized, isolated Kustomize deployment package. 

* **Purpose**: Creates an independent directory containing all KServe core components pre-patched for `"defaultDeploymentMode": "RawDeployment"`.
* **Action**: Extracts KServe CRDs, RBAC, core controller manifests (patched for Raw mode), and built-in cluster predictors. cert-manager is **not** bundled — it is a cluster prerequisite installed separately.
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
   # Pre-requisite: cert-manager must be installed before the operator
   CERT_MANAGER_VERSION="v1.17.2"
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml
   kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s

   # Create the two namespaces (KServe target — default 'kserve' — and the operator pod's home)
   kubectl create namespace kserve
   kubectl create namespace kserve-operator-system

   # Option A: OLM bundle (recommended — requires OLM pre-installed)
   #          --install-mode auto-creates the OperatorGroup with the right targetNamespaces.
   operator-sdk olm install
   operator-sdk run bundle docker.io/your-org/kserve-raw-operator:v1-bundle \
     --namespace kserve-operator-system \
     --install-mode SingleNamespace=kserve
   # (add `--pull-secret-name <secret>` if your image is private)

   # Option B: Direct manifests (no OLM needed)
   kubectl apply -f p-kserve-operator-package/operator-deployment.yaml
   ```
   > The operator **auto-creates** the `KServeRawMode` CR on startup in the namespace dictated by the OperatorGroup's `targetNamespaces` (default `kserve`) — KServe installation begins immediately.
5. **Monitor** the installation progress and **validate** the Iris inference model:
   ```bash
   # Watch phase progression (no manual sleep needed)
   kubectl get kserverawmode -A -w

   # Once Ready, deploy and test the sample model
   kubectl apply -f p-kserve-operator-package/06-sample-model/sklearn-iris.yaml
   kubectl get isvc sklearn-iris -w   # wait for READY=True, then:
   kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
     curl -s -H 'Content-Type: application/json' \
     -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
     http://sklearn-iris-predictor.default.svc.cluster.local/v1/models/sklearn-iris:predict
   # Expected: {"predictions":[1]}
   ```
