# KServe Operator Architecture Diagram

The following diagram illustrates the end-to-end flow of the operator generation, build process (including firewall traversal), and cluster deployment:

```mermaid
graph TD
    %% Styling
    classDef user fill:#2d3748,stroke:#4a5568,stroke-width:2px,color:#fff
    classDef script fill:#3182ce,stroke:#2b6cb0,stroke-width:2px,color:#fff
    classDef git fill:#dd6b20,stroke:#c05621,stroke-width:2px,color:#fff
    classDef docker fill:#e53e3e,stroke:#c53030,stroke-width:2px,color:#fff
    classDef k8s fill:#38a169,stroke:#2f855a,stroke-width:2px,color:#fff
    classDef secret fill:#d69e2e,stroke:#b7791f,stroke-width:2px,color:#fff

    %% Components
    subgraph SG1 [Lab Build Environment]
        UserAction["👨‍💻 User Action"] ::: user
        RawExtract["📂 c-kserve-raw (Extracted Manifests)"] ::: git
        Cert["📜 cert.crt (Firewall Trusted Chain)"] ::: secret
        DockerCreds["🔑 docker login rajeshpnhcl"] ::: secret
        
        Generator["⚙️ generate-kserve-operator.sh"] ::: script
        
        subgraph SG2 [Docker Build Engine]
            GoBuilder["📦 Builder Stage (FROM golang:1.24) <br> + update-ca-certificates"] ::: docker
            Proxy["🌐 Corporate Firewall (Deep Packet Inspection)"]
            GoMods["📦 Go Modules (proxy.golang.org)"]
            FinalImage["🐳 Final Operator Image (FROM distroless)"] ::: docker
        end
    end

    subgraph SG3 [External Systems]
        Registry["🐳 Docker Hub Registry (rajeshpnhcl/...)"] ::: docker
    end

    subgraph SG4 [Kubernetes Target Cluster]
        OLM["⚙️ Operator Lifecycle Manager (OLM)"] ::: k8s
        ClusterSecrets["🔐 ImagePullSecret (dockerhub-creds)"] ::: secret
        ControllerPod["🏃 Operator Pod (KServeRawMode Controller)"] ::: k8s
        CRD["📄 Custom Resource (KServeRawMode)"] ::: k8s
        
        subgraph SG5 [Target Workloads]
            SetupSequence["🔢 KServe Raw Sequence <br> 1. Cert-Manager <br> 2. CRDs <br> 3. Webhooks <br> 4. Core Controllers <br> 5. Serving Runtimes"] ::: k8s
            InferencePods["🚀 Running Inferences (e.g., sklearn-iris)"] ::: k8s
        end
    end

    %% Workflows
    UserAction -->|Executes Script| Generator
    RawExtract -.->|Source Manifests| Generator
    Cert -.->|Injected via --cert| Generator
    DockerCreds -.->|Push Authentication| Generator
    
    %% Generator Flow
    Generator -->|1. Generate Go Code| GoBuilder
    GoBuilder -->|2. Secure HTTPS connection| Proxy
    Proxy -->|Passes SSL Check| GoMods
    GoMods -.->|Downloads dependencies| GoBuilder
    GoBuilder -->|3. Compile binary| FinalImage
    FinalImage -->|4. Push Image| Registry

    %% Deployment Flow
    FinalImage -.->|5. Generate Artifacts| OLM
    OLM -->|6. Deploy Operator| ControllerPod
    Registry -.->|7. Pull Image| ControllerPod
    ClusterSecrets -.->|Authenticates| ControllerPod
    
    %% Execution Flow
    CRD -->|8. Apply CR| ControllerPod
    ControllerPod -->|9. Server-Side Apply| SetupSequence
    SetupSequence -->|10. Ready| InferencePods
```
