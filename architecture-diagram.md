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
        OperScript[["generate-kserve-operator.sh\n-t p-kserve-operator -s p-kserve-raw\n-i docker.io/akashneha/...:v300\n--pull-secret dockerhub-creds\n--install-mode OwnNamespace -b -p -o"]]:::script
        OperProj["Go Operator Project\n(p-kserve-operator/)"]:::package
        DockerImg["Container Image\ndocker.io/akashneha/kserve-raw-operator:v300\n(linux/arm64 or linux/amd64)"]:::package
        StandalonePkg["Standalone Package\n(p-kserve-operator-package/)\noperator-deployment.yaml\nkserve-rawmode.yaml\nsetup-credentials.sh\n06-sample-model/\n[mirror-images.sh]  ← with --customer-registry\n[deploy-bundle.sh]  ← with --customer-registry"]:::package
        OLMPkg["OLM Bundle Image\ndocker.io/akashneha/kserve-raw-operator:v300-bundle"]:::package

        OperScript -->|operator-sdk scaffold| OperProj
        RawPkg -..->|Embedded into assets/| OperProj
        OperProj -->|docker build + push| DockerImg
        OperProj -->|kustomize build| StandalonePkg
        OperProj -->|make bundle + push| OLMPkg
    end

    subgraph CustomerReg["Customer Registry (optional — --customer-registry flag)"]
        MirrorOnline["mirror-images.sh (online)\nskopeo copy src → customer registry"]:::script
        MirrorArchive["mirror-images.sh --archive\nskopeo save → images/*.tar"]:::script
        MirrorLoad["mirror-images.sh --load\nskopeo copy tar → customer registry"]:::script
        MirrorArchive -->|Transfer archives| MirrorLoad
    end

    StandalonePkg -.->|if --customer-registry| MirrorOnline
    StandalonePkg -.->|if --customer-registry| MirrorArchive

    subgraph Deploy["Deployment Options"]
        OLM["OLM pre-installed\noperator-sdk olm install"]:::prereq
        Creds["setup-credentials.sh\nCreates pull secrets in all namespaces"]:::script
        OLM -->|prerequisite| OLMPkg
        Creds -->|pull secret ready| OLMPkg
        OLMPkg -->|operator-sdk run bundle\nor deploy-bundle.sh| K8sCluster
        StandalonePkg -->|kubectl apply| K8sCluster
    end

    MirrorOnline -->|customer registry images ready| Creds
    MirrorLoad -->|customer registry images ready| Creds

    subgraph K8s["Target Kubernetes Cluster"]
        K8sCluster[("Kubernetes Cluster")]:::k8s
        OperPod["Operator Controller Pod\n(pulls via pull secret)"]:::k8s
        AutoCR["Auto-Init: Operator creates\nKServeRawMode CR automatically\non first startup"]:::k8s
        KServeStack["Active KServe Stack\ncert-manager + KServe CRDs + RBAC\nKServe Controller + ServingRuntimes"]:::k8s
        IFSvc["InferenceService\nsklearn-iris predictor"]:::k8s

        K8sCluster --> OperPod
        OperPod -->|Creates on startup| AutoCR
        AutoCR -->|Triggers reconcile| KServeStack
        KServeStack -->|Ready for| IFSvc
    end
```

## 2. Operator Reconciliation Loop (Internal)

Once the operator starts, it **automatically creates** a `KServeRawMode` CR and runs the following sequential reconciliation loop:

```mermaid
sequenceDiagram
    participant User
    participant K8s as Kubernetes API
    participant Ctrl as Operator Controller
    participant Assets as Embedded Assets

    Note over Ctrl: Operator starts — auto-creates KServeRawMode CR
    Ctrl->>K8s: Create KServeRawMode "kserve-rawmode" (if not exists)
    K8s->>Ctrl: Reconcile(KServeRawMode)
    Ctrl->>Assets: Read 01-cert-manager/
    Ctrl->>K8s: Server-Side Apply cert-manager
    Ctrl->>Assets: Read 02-kserve-crds/
    Ctrl->>K8s: Server-Side Apply KServe CRDs
    Ctrl->>Assets: Read 03-kserve-rbac/
    Ctrl->>K8s: Server-Side Apply RBAC + ensure kserve namespace
    Ctrl->>Assets: Read 04-kserve-core/
    Ctrl->>K8s: Server-Side Apply KServe Controller
    Note over Ctrl: Poll for pod readiness (prevents webhook race)
    Ctrl->>Assets: Read 05-kserve-runtimes/
    Ctrl->>K8s: Server-Side Apply ClusterServingRuntimes
    K8s-->>User: KServeRawMode phase: Ready
```

> No manual `kubectl apply -f kserve-rawmode.yaml` is required. The operator auto-initialises KServe on startup.

## 3. End-to-End Test Validation Summary

The following was verified in a live test on a fresh Docker Desktop Kubernetes cluster (both standard and customer-registry archive flows):

| Step | Command | Result |
|------|---------|--------|
| Extract manifests | `./generate-kserve-raw.sh -t p-kserve-raw` | ✅ All 5 manifest dirs created |
| Generate operator | `./generate-kserve-operator.sh ... -b -p -o` | ✅ Operator project + OLM bundle built and pushed |
| Archive images (customer) | `bash mirror-images.sh --archive` | ✅ images/operator.tar + images/bundle.tar created |
| Load images (customer) | `bash mirror-images.sh --load --user ... --pass ...` | ✅ Images pushed to customer registry |
| Install OLM | `operator-sdk olm install` | ✅ v0.28.0 installed, all pods Running |
| Set up credentials | `bash setup-credentials.sh --user ... --pass ...` | ✅ Pull secret created in default/olm/operators |
| Deploy bundle | `bash deploy-bundle.sh` | ✅ CSV Phase: Succeeded |
| Watch KServe install | `kubectl get kserverawmode -A -w` | ✅ Phase: Ready (~60s), no manual CR apply needed |
| Test inference | `curl .../sklearn-iris:predict` | ✅ `{"predictions":[1]}` |
| Cleanup | `./generate-kserve-operator.sh -c p-kserve-operator` | ✅ Workspace restored |
