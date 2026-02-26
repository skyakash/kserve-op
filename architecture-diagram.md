# KServe Operator Packaging Architecture

This project automates the extraction, packaging, and deployment of KServe in **Raw Deployment Mode** (without Istio/Knative dependencies). It consists of two main pipelines: extracting the manifests and wrapping them into a standalone Kubernetes Operator.

## 1. High-Level Architecture Flow

```mermaid
flowchart TD
    classDef script fill:#f9f,stroke:#333,stroke-width:2px;
    classDef package fill:#bbf,stroke:#333,stroke-width:1px;
    classDef k8s fill:#dfd,stroke:#333,stroke-width:1px;
    classDef prereq fill:#ffd,stroke:#888,stroke-width:1px,stroke-dasharray:5;

    Source[("kserve-master\n(Upstream Repo)")] --> ExtractScript

    subgraph Phase1["Phase 1 — generate-kserve-raw.sh"]
        ExtractScript[["generate-kserve-raw.sh\n-t p-kserve-raw"]]:::script
        RawPkg["Raw Manifest Package\n(p-kserve-raw/)\n01-cert-manager\n02-kserve-crds\n03-kserve-rbac\n04-kserve-core ← RawDeployment patched\n05-kserve-runtimes\n06-sample-model"]:::package
        ExtractScript -->|Extracts & Patches| RawPkg
    end

    RawPkg -->|Source input| OperScript

    subgraph Phase2["Phase 2 — generate-kserve-operator.sh"]
        OperScript[["generate-kserve-operator.sh\n-t p-kserve-operator -s p-kserve-raw\n-i docker.io/akashneha/...:v51\n--pull-secret dockerhub-creds -x -o"]]:::script
        OperProj["Go Operator Project\n(p-kserve-operator/)"]:::package
        DockerImg["Container Image\ndocker.io/akashneha/kserve-raw-operator:v51\n(multi-platform: amd64/arm64)"]:::package
        StandalonePkg["Standalone Package\n(p-kserve-operator-package/)\noperator-deployment.yaml\nkserverawmode-sample.yaml\n06-sample-model/"]:::package
        OLMPkg["OLM Bundle Image\ndocker.io/akashneha/kserve-raw-operator:v51-bundle"]:::package

        OperScript -->|operator-sdk scaffold| OperProj
        RawPkg -.->|Embedded into assets/| OperProj
        OperProj -->|docker buildx push| DockerImg
        OperProj -->|kustomize build| StandalonePkg
        OperProj -->|make bundle + push| OLMPkg
    end

    subgraph Deploy["Deployment Options"]
        OLM["OLM pre-installed\noperator-sdk olm install"]:::prereq
        OLM -->|prerequisite| OLMPkg
        OLMPkg -->|operator-sdk run bundle| K8sCluster
        StandalonePkg -->|kubectl apply| K8sCluster
    end

    subgraph K8s["Target Kubernetes Cluster"]
        K8sCluster[("Kubernetes Cluster")]:::k8s
        OperPod["Operator Controller Pod\n(pulls from dockerhub-creds secret)"]:::k8s
        CR["kubectl apply kserverawmode-sample.yaml\nKServeRawMode CR"]:::k8s
        KServeStack["Active KServe Stack\ncert-manager + KServe CRDs + RBAC\nKServe Controller + ServingRuntimes"]:::k8s
        IFSvc["InferenceService\nsklearn-iris predictor"]:::k8s

        K8sCluster --> OperPod
        OperPod -->|Watches| CR
        CR -->|Triggers reconcile| KServeStack
        KServeStack -->|Ready for| IFSvc
    end
```

## 2. Operator Reconciliation Loop (Internal)

Once the `KServeRawMode` CR is applied, the operator runs the following sequential reconciliation loop:

```mermaid
sequenceDiagram
    participant User
    participant K8s as Kubernetes API
    participant Ctrl as Operator Controller
    participant Assets as Embedded Assets

    User->>K8s: kubectl apply kserverawmode-sample.yaml
    K8s->>Ctrl: Reconcile(KServeRawMode)
    Ctrl->>Assets: Read 01-cert-manager/
    Ctrl->>K8s: Server-Side Apply cert-manager
    Ctrl->>Assets: Read 02-kserve-crds/
    Ctrl->>K8s: Server-Side Apply KServe CRDs
    Ctrl->>Assets: Read 03-kserve-rbac/
    Ctrl->>K8s: Server-Side Apply RBAC + ensure kserve namespace
    Ctrl->>Assets: Read 04-kserve-core/
    Ctrl->>K8s: Server-Side Apply KServe Controller
    Note over Ctrl: Wait 15s for webhooks to stabilise
    Ctrl->>Assets: Read 05-kserve-runtimes/
    Ctrl->>K8s: Server-Side Apply ClusterServingRuntimes
    K8s-->>User: KServe fully operational
```

## 3. End-to-End Test Validation Summary

The following was verified in a live test on a fresh Docker Desktop Kubernetes cluster:

| Step | Command | Result |
|------|---------|--------|
| Extract manifests | `./generate-kserve-raw.sh -t p-kserve-raw` | ✅ All 5 manifest dirs created |
| Generate operator | `./generate-kserve-operator.sh ... -x -o` | ✅ Operator project + OLM bundle built |
| Install OLM | `operator-sdk olm install` | ✅ v0.28.0 installed |
| Deploy bundle | `operator-sdk run bundle ...v51-bundle` | ✅ CSV Phase: Succeeded |
| Apply CR | `kubectl apply -f ...kserverawmode-sample.yaml` | ✅ KServe 2/2 Running |
| Test inference | `curl .../sklearn-iris:predict` | ✅ `{"predictions":[1,1]}` |
| Cleanup | `./generate-kserve-operator.sh -c p-kserve-operator` | ✅ Workspace restored |
