# KServe Operator Packaging Architecture

This project automates the extraction, packaging, and deployment of KServe in **Raw Deployment Mode** (without Istio/Knative dependencies). It consists of two main pipelines: extracting the manifests and wrapping them into a standalone Kubernetes Operator.

## 1. High-Level Architecture Flow

```mermaid
flowchart TD
    classDef script fill:#f9f,stroke:#333,stroke-width:2px;
    classDef package fill:#bbf,stroke:#333,stroke-width:1px;
    classDef k8s fill:#dfd,stroke:#333,stroke-width:1px;

    Source[("kserve-master\n(Upstream Repo)")] --> ExtractScript

    subgraph Phase 1: Raw Manifest Extraction
        ExtractScript[["1. generate-kserve-raw.sh"]]:::script
        RawPkg["Manual Deployment Package\n(Patched for Raw Mode)"]:::package
        
        ExtractScript -->|Extracts & Patches| RawPkg
        Notes1>Configures inferenceservice-config\ndefaultDeploymentMode: RawDeployment] -.-> RawPkg
    end

    RawPkg -->|Provides Manifests| OperScript

    subgraph Phase 2: Operator Generation
        OperScript[["2. generate-kserve-operator.sh"]]:::script
        OperProj["Operator SDK Project\n(Go-based Meta-Operator)"]:::package
        
        OperScript -->|Scaffolds via operator-sdk| OperProj
        RawPkg -.->|Copied to internal/controller/assets| OperProj
    end

    subgraph Deployment Options
        OperProj -->|kustomize build| StandalonePkg["Standalone Operator Package\n(operator-deployment.yaml)"]:::package
        OperProj -->|make bundle| OLMPkg["OLM Bundle\n(OperatorHub Ready)"]:::package
        OperProj -->|make docker-build| DockerImg["Operator Container Image"]:::package
    end

    StandalonePkg --> K8sCluster
    OLMPkg --> K8sCluster

    subgraph Target Kubernetes Cluster
        K8sCluster[("Kubernetes Cluster")]:::k8s
        CR["KServeRawMode\n(Custom Resource)"]:::k8s
        GoController["Operator Controller\n(Running in Pod)"]:::k8s
        
        K8sCluster -->|User Applies| CR
        CR -->|Triggers| GoController
        GoController -->|Applies embedded assets| KServeActive["Active KServe Raw\nInstallation"]:::k8s
    end
```

## 2. Generated Operator Internal Execution

The resulting generated Go Operator has the following internal structure to reconcile the KServe installation:

```mermaid
graph LR
    User([User]) -->|kubectl apply| CR(KServeRawMode CR)
    
    subgraph Generated Operator Pod
        Controller(kserverawmode_controller.go)
        Assets[(Embedded Manifests)]
        ApplyLogic(apply.go)
        
        CR -.->|Reconcile Request| Controller
        Controller -->|Read| Assets
        Controller -->|Passes objects| ApplyLogic
    end
    
    ApplyLogic -->|Server-Side Apply| K8sAPI(Kubernetes API Server)
    
    K8sAPI -->|Creates| CM(cert-manager)
    K8sAPI -->|Creates| CRDs(KServe CRDs)
    K8sAPI -->|Creates| Core(KServe Core Controller)
    K8sAPI -->|Creates| Runtimes(ClusterServingRuntimes)
```
