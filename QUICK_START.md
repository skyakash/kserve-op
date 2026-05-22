# KServe Operator — Quick Start Guide

Two paths depending on what you're doing:
- **[Part A](#part-a-builder-build--publish-the-operator)** — you're building/publishing the operator
- **[Part B](#part-b-deployer-install-kserve-on-a-cluster)** — you have the package and just want to install KServe

---

## Part A: Builder — Build & Publish the Operator

### Prerequisites

Supported build environments: **macOS** and **RHEL/Linux x86_64**.

| Tool | macOS | RHEL/Linux |
|---|---|---|
| Go v1.21+ | `brew install go` | [go.dev/dl](https://go.dev/dl) tarball |
| Operator SDK v1.42+ | `brew install operator-sdk` | Binary from GitHub releases |
| Docker v20.10+ | Docker Desktop | `dnf install docker-ce` or see [docs.docker.com/engine/install/rhel](https://docs.docker.com/engine/install/rhel/) |
| yq v4+ | `brew install yq` | `sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq` |
| kubectl | `brew install kubectl` | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| Kustomize v5+ | `brew install kustomize` | `curl -s .../install_kustomize.sh \| bash` |
| python3 + pyyaml | `brew install python && pip3 install pyyaml` | `dnf install -y python3 python3-pip && pip3 install pyyaml` |

> See [generate-kserve-operator-README.md](./generate-kserve-operator-README.md#installing-prerequisites) for exact copy-paste install commands per platform.

### Cleaning Up / Starting Fresh

If you are re-running the build (e.g. after a cluster reset), clean both generated directories first:

```bash
./generate-kserve-operator.sh -c p-kserve-operator   # removes p-kserve-operator/ and p-kserve-operator-package/
./generate-kserve-raw.sh -c p-kserve-raw              # removes p-kserve-raw/
```

---

### Step 1 — Extract KServe raw manifests
```bash
# Run from the kserve-op workspace directory.
# -z points at the bundled KServe source zip; the script auto-extracts
# it into ./kserve-source/ (gitignored). After the first run, kserve-source/
# is reused — -z is only required when the directory doesn't exist.
./generate-kserve-raw.sh -t p-kserve-raw -z kserve-release-0.16.zip
```

### Step 2 — Generate operator, build image, and create OLM bundle
```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:v300 \
  --pull-secret dockerhub-creds \
  --install-mode SingleNamespace \
  -b -p -o
```

> **`--install-mode`** controls OLM operator install scope. Valid values: `SingleNamespace` (default — operator manages one specific namespace), `OwnNamespace`, `AllNamespaces`, `MultiNamespace`.

> **Version tagging:** Replace `v300` with your actual release version (e.g. `v302`, `v303`). Use a new tag for each build to avoid stale image caches on the cluster.

> **Behind a corporate proxy or TLS-intercepting firewall?** Add `--cert /path/to/corporate-ca.crt` to the command above. The CA gets injected into the Dockerfile builder stage's trust store so `go mod download` and other build-time fetches can talk to the proxy. The cert is **only in the builder stage** — not in the final distroless operator image — so it doesn't end up shipped to customers. See [generate-kserve-operator-README.md](generate-kserve-operator-README.md) (§ "Building Behind a Corporate Proxy") for details and a verification recipe.

### Step 2 (Alt) — Customer / Private Registry

If the operator will be deployed to a customer environment with a **private registry** (Artifactory, Harbor, ECR, Docker Hub org, etc.), add `--customer-registry`. This rewrites all image references in the output package and generates two extra helper scripts.

> **Additional prerequisite:** [`skopeo`](https://github.com/containers/skopeo) — used by `mirror-images.sh` to copy images between registries.
> - macOS: `brew install skopeo`
> - RHEL/Linux: `sudo dnf install -y skopeo`

```bash
./generate-kserve-operator.sh \
  -t p-kserve-operator \
  -m github.com/akashdeo/p-kserve-operator \
  -d akashdeo.com \
  -s p-kserve-raw \
  -i docker.io/akashneha/kserve-raw-operator:v300 \
  --pull-secret dockerhub-creds \
  --customer-registry docker.io/<customer-account> \
  --install-mode SingleNamespace \
  -b -p -o
```

> ℹ️ `--pull-secret` sets the pull secret name baked into the generated scripts. Credentials are **never embedded** — they are provided at runtime by the customer.

The generated package (`p-kserve-operator-package/`) contains up to **four** helper scripts:
- `setup-credentials.sh` — creates pull secrets in exactly 2 namespaces (`default` + the operator's home ns, default `kserve-operator-system`) per the Design C footprint. The operator namespace is configurable via `generate-kserve-operator.sh --operator-namespace=<ns>` at build time or `SYSTEM_NS=<ns>` env var at script invocation time. *(always generated; see [`extra-docs/architecture-namespaces.md` § 9](extra-docs/architecture-namespaces.md#9-design-c-footprint-always-2-namespaces-of-ours))*
- `enable-ingress.sh` — patches KServe to enable Kubernetes Ingress creation; restarts the controller. Used when you want external-URL access via an ingress controller. *(always generated)*
- `mirror-images.sh` — copies operator + bundle images from the build registry to a customer registry (3 modes: online, archive, load) *(only with `--customer-registry`)*
- `deploy-bundle.sh` — one-command OLM install helper that wraps `operator-sdk run bundle ... --install-mode SingleNamespace=${KSERVE_NS}` *(only with `--customer-registry`)*

Both `mirror-images.sh` and `setup-credentials.sh` use the same `--user`/`--pass` arguments and will prompt interactively if not provided.

> Without `--customer-registry`, the package contains only `setup-credentials.sh` plus the static manifests (`operator-deployment.yaml`, `kserve-rawmode.yaml`, `06-sample-model/`, `README.md`).

---

### *(Air-gapped only)* Package images for transfer

If you generated with `--customer-registry` and the customer cluster cannot reach the build registry, archive the operator + bundle images on the builder side so they can be shipped offline:

```bash
cd p-kserve-operator-package
bash mirror-images.sh --archive
# Produces images/operator.tar + images/bundle.tar
```

Ship the **entire `p-kserve-operator-package/` folder, including `images/`** to the customer machine (USB, secure gateway, etc.). The customer-side load + deploy steps are in **Part B** below.

For online customer-registry deploys (build and customer registries reachable from the same machine), skip the `--archive` step — the customer can run `mirror-images.sh` in online mode directly per Part B's callout.

---

That completes the **builder** side. **Part B** below covers the cluster install — both the standard and customer-registry variants.

---

## Part B: Deployer — Install KServe on a Cluster

You only need the `*-package/` folder and `kubectl`/`operator-sdk` on your machine.

```bash
cd p-kserve-operator-package   # all commands below run from inside this folder
```

> **Customer-registry workflow** *(only if your package was generated with `--customer-registry` — you'll see `mirror-images.sh` and `deploy-bundle.sh` in the directory)*: before Step 0, bring the operator + bundle images into your registry. Run **one** of:
>
> ```bash
> # (a) Online — both build and customer registries reachable from this machine:
> bash mirror-images.sh --user <customer-user> --pass <customer-token>
>
> # (b) Air-gapped — images already shipped as tar files in images/:
> bash mirror-images.sh --load --user <customer-user> --pass <customer-token>
> ```
>
> Then continue with the steps below. In **Step 3** pass the **customer-registry** credentials (the cluster will pull from there, not the build registry). In **Step 4** you can use `bash deploy-bundle.sh dockerhub-creds` as a one-line shortcut for the OLM install — it wraps the same `operator-sdk run bundle ... --install-mode SingleNamespace=${KSERVE_NS}` command shown there.

### Step 0 — Install cert-manager *(cluster pre-requisite)*

> [!IMPORTANT]
> The operator **does not install cert-manager**. cert-manager must be present in the cluster **before** the operator is deployed. The operator validates this at startup and will enter a `CertManagerNotFound` error phase with a clear message if it is absent.

#### Check if cert-manager is already installed
```bash
kubectl get crds | grep cert-manager.io
# Expected output (if installed):
# certificaterequests.cert-manager.io
# certificates.cert-manager.io
# challenges.acme.cert-manager.io
# clusterissuers.cert-manager.io
# issuers.cert-manager.io
# orders.acme.cert-manager.io
```

#### Install cert-manager (if not present)
```bash
# Pinned stable release (v1.17.2 as of April 2026 — check https://github.com/cert-manager/cert-manager/releases for latest)
CERT_MANAGER_VERSION="v1.17.2"

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

# Wait for all cert-manager pods to be Ready (typically ~60s)
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s

# Verify
kubectl get pods -n cert-manager
# Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook pods all Running
```

> **Why is cert-manager required?** KServe uses cert-manager to provision TLS certificates for its webhook endpoints. Without it, the KServe webhook admission controller cannot start.

### Step 1 — Install OLM (once per cluster)
```bash
operator-sdk olm install
kubectl get pods -n olm   # wait until all pods are Running
```

### Step 2 — Create namespaces

**Both** of Design C's 2 namespaces are now user-configurable:

- **Operator's home namespace** — defaults to `kserve-operator-system`. Override at build time via `generate-kserve-operator.sh --operator-namespace <ns>` (bakes into all generated manifests + helper-script defaults) OR at deploy time via `OPERATOR_NS=<ns>` env var on `deploy-bundle.sh` and `SYSTEM_NS=<ns>` env var on `setup-credentials.sh`. The OperatorGroup OLM creates targets the namespace passed to `--namespace` on `operator-sdk run bundle`.
- **KServe target namespace** — defaults to `kserve`. The CR and the KServe runtime live **together** here (Design C). Pick anything (e.g. `my-kserve`) via `--install-mode SingleNamespace=<ns>` on the deploy command, or `KSERVE_NAMESPACE=<ns>` env var on `install.sh` (Option C). The operator's apply-time namespace rewriting installs KServe there.

```bash
# Pick the namespace name you want for KServe (default: 'kserve').
# Both the KServeRawMode CR and the KServe runtime will live here.
KSERVE_NS=kserve

# Pick the namespace name you want for the operator pod (default: 'kserve-operator-system').
# Override at build time with: generate-kserve-operator.sh --operator-namespace=<ns>
# Override at deploy time with: OPERATOR_NS=<ns> bash deploy-bundle.sh ...
OPERATOR_NS="${OPERATOR_NS:-kserve-operator-system}"

kubectl create namespace "${KSERVE_NS}"     || true
kubectl create namespace "${OPERATOR_NS}"   || true
```

> **Why this comes before credentials:** `setup-credentials.sh` (Step 3) creates pull secrets *inside* `${OPERATOR_NS}` and `default`. If `${OPERATOR_NS}` doesn't exist yet the operator pod's image pull will later fail with no obvious cause.

### Step 3 — Set up image pull credentials *(skip if images are public)*

```bash
# With CLI args (works for both Option A — OLM and Option B — direct manifest):
bash setup-credentials.sh --user <registry-user> --pass <registry-token>

# Or interactive (will prompt for username and password):
bash setup-credentials.sh
```

For the **customer-registry** flow, pass the **customer-registry** credentials here (the cluster will pull from the customer registry, not the build registry).

> **Design C — 2 namespaces.** The script creates pull secrets in exactly two namespaces: `default` (for sample workloads like the iris ISVC) and `<system-ns>` (operator pod + OLM CatalogSource pod, both pull from here). OLM's `olm` + `operators` namespaces are infrastructure — they never need our pull secret because OLM uses its own catalog auth. Both deploy paths (OLM Option A + direct-manifest Option B) need the same 2 namespaces; no flag distinguishes them. (`--non-olm` is accepted as a deprecated no-op for backwards compatibility with earlier CI scripts.)

### Step 4 — Deploy the operator

KServe Raw Mode supports **three deploy paths**, in increasing order of simplicity:

| | Option A — OLM Bundle | Option B — Direct manifest | Option C — `install.sh` |
|---|---|---|---|
| **Who manages the operator?** | OLM (CSV reconciles) | Plain Kubernetes Deployment | No operator at all — pure `kubectl apply` |
| **Infrastructure prereq** | cert-manager + OLM (`operator-sdk olm install` brings its own `olm` + `operators` namespaces) | cert-manager | cert-manager |
| **Namespaces you create** | 2: `<operator ns>` (default `kserve-operator-system`) + `<KServe ns>` (default `kserve`). Both configurable. | Same as Option A. | 1: `<KServe ns>` (default `kserve`, override `KSERVE_NAMESPACE=...`). |
| **Pull-secret command** | `setup-credentials.sh` | `setup-credentials.sh` (same — no flag needed) | N/A (KServe upstream images are public) |
| **Pull-secret target ns** | `default` + `<operator ns>` | `default` + `<operator ns>` | N/A |
| **Custom KServe namespace** | yes — `--install-mode SingleNamespace=<name>` | currently bundled defaults only | yes — `KSERVE_NAMESPACE=<name> ./install.sh` |
| **CR + auto-init** | yes (operator runs in cluster) | yes | no — operator is not deployed; KServe runs directly |
| **Customer-facing complexity** | high (OLM concepts) | medium | low (one script, one CR-less install) |
| **Best for** | production multi-tenant clusters with OLM already adopted | private-registry environments without OLM | dev clusters, customer demos, the simplest possible deploy |
| **Steps to run** | 0 (cert-manager) → 1 (OLM) → 2 (your namespaces) → 3 (creds) → 4A → 5 → 6 | 0 → 2 (your namespaces) → 3 (creds) → 4B → 5 → 6 | 0 → run `install.sh` → 6 |
| **Tested by** | T01, T05, T10, T11, T12, T12-LIKE-REGRESSION | T04 | T02, T03-RETEST |

> **Design C (2 namespaces, always).** All three options share the same footprint OF OURS: at most 2 namespaces we create (operator home + KServe runtime). OLM's `olm` + `operators` namespaces (Option A only) are OLM infrastructure — they exist regardless of our operator and we don't put anything there. See [`extra-docs/architecture-namespaces.md`](extra-docs/architecture-namespaces.md) for the full design rationale.

If you don't have a strong preference, **start with Option C** — it's the fewest moving parts and works on any cluster.

### Decision flowchart — which path do you want?

```mermaid
flowchart TD
    Q1{Are you on a<br/>production cluster<br/>that already uses OLM?}
    Q2{Do you need the<br/>operator's lifecycle<br/>management — auto-init,<br/>5-phase reconcile,<br/>CR-driven config?}
    Q3{Is your KServe image<br/>on a private registry?}

    A[Option A — OLM Bundle<br/><i>operator-sdk run bundle</i>]
    B[Option B — Direct manifest<br/><i>kubectl apply -f operator-deployment.yaml</i>]
    C[Option C — install.sh<br/><i>no operator, no CR</i>]

    Q1 -- yes --> A
    Q1 -- no --> Q2
    Q2 -- yes --> Q3
    Q2 -- no --> C
    Q3 -- yes --> B
    Q3 -- no --> C

    classDef question fill:#fff3e0,stroke:#fb8c00,stroke-width:2px,color:#000
    classDef terminal fill:#c8e6c9,stroke:#388e3c,stroke-width:2px,color:#000
    class Q1,Q2,Q3 question
    class A,B,C terminal
```

**Quick rules of thumb:**
- **OLM already in your stack?** → Option A (matches your existing operator-management story).
- **No OLM, but you want the operator?** → Option B (private registries get full pull-secret support via `setup-credentials.sh`).
- **Just want it running fast?** → Option C (one script, no operator overhead; perfect for dev clusters, customer demos, and short-lived environments).

**Option A: OLM Bundle (recommended, `InstallMode: SingleNamespace`)**

`operator-sdk run bundle` accepts an `--install-mode` flag that auto-creates the OperatorGroup with the right `targetNamespaces` — you don't define it yourself. Pass `SingleNamespace=<your-kserve-ns>` and it wires up the rest.

```bash
# Set BUNDLE_IMAGE to where your bundle actually lives:
#   • Standard build:           <build-registry>/<image>:<tag>-bundle
#   • --customer-registry path: <customer-registry>/<image>:<tag>-bundle
#     (after `bash mirror-images.sh ...` has copied/loaded it there).
# In all cases the suffix is `-bundle` (the operator image's tag + `-bundle`).
BUNDLE_IMAGE=<your-bundle-image>

# Single-command deploy. --install-mode auto-creates an OperatorGroup in
# the operator namespace (${OPERATOR_NS}) targeting ${KSERVE_NS}; the downward-API
# WATCH_NAMESPACE then drives the auto-init's CR placement.
operator-sdk run bundle "${BUNDLE_IMAGE}" \
  --namespace "${OPERATOR_NS:-kserve-operator-system}" \
  --install-mode "SingleNamespace=${KSERVE_NS}" \
  --pull-secret-name dockerhub-creds
```

> **`--pull-secret-name`** references the secret created by `setup-credentials.sh` in Step 3. If you skipped Step 3 because your images are public, drop this flag.

> **Why no OperatorGroup yaml?** OLM forbids embedding OperatorGroups in bundles (they're user-controlled installation parameters, not operator artifacts). `operator-sdk run bundle --install-mode` generates one on the fly named `operator-sdk-og` in the operator's namespace.

> **Bundle image tag:** The bundle image tag is printed at the end of `generate-kserve-operator.sh` output, in the format `<image-tag>-bundle`.
> Example: if you built with `-i docker.io/akashneha/kserve-raw-operator:v403`, the bundle image is `docker.io/akashneha/kserve-raw-operator:v403-bundle`.

> **Customer registry flow:** If you generated with `--customer-registry`, the package contains `mirror-images.sh` and `deploy-bundle.sh`. Run `mirror-images.sh` first to push images to the customer registry, then `deploy-bundle.sh` — it handles the bundle image reference automatically.

**Option B: Direct manifests (no OLM needed — skip Step 1)**

Two equivalent invocations:

```bash
# Prereq: ${OPERATOR_NS} + <KServe ns> created (Step 2),
# and pull secret in those namespaces (Step 3 — no special flag).

# Default — uses the operator namespace baked into the package
# (kserve-operator-system, or whatever you passed to --operator-namespace at build time):
kubectl apply -f operator-deployment.yaml

# OR — choose the operator namespace at deploy time (no rebuild needed):
OPERATOR_NAMESPACE=<your-ns> bash install-operator-deployment.sh
# Python YAML walk rewrites every namespace ref in operator-deployment.yaml
# before applying. The script does --dry-run too if you want to preview.
```

> **Pure deploy-time architecture.** The wrapper script (`install-operator-deployment.sh`) mirrors `install.sh`'s rewrite pattern from Option C, making Option B symmetric: one generated package serves any namespace. Use `OPERATOR_NAMESPACE` consistently across `install-operator-deployment.sh` AND `SYSTEM_NS` on `setup-credentials.sh` so the operator pod's pull secret lands in the same namespace it's deployed into.

**Option C: `install.sh` (no operator, no OLM — pure `kubectl apply` orchestrated by a shell script)**

Use this when you don't need the operator's lifecycle management — `install.sh` applies the KServe manifests directly. Simplest path. Skip Steps 1, 2, 3 and 4A/4B entirely; run `install.sh` straight after Step 0 (cert-manager).

Host prerequisites for `install.sh`:
- `cert-manager` installed in the cluster (see Step 0)
- `python3` + `PyYAML` on the machine running the script (it does a structured YAML rewrite of namespace references — verify with `python3 -c 'import yaml'`)

```bash
# Generate the standalone deployment package (one-time):
./generate-kserve-raw.sh -t p-kserve-raw -z kserve-release-0.16.zip

# Default — install into "kserve" namespace
cd p-kserve-raw && bash install.sh

# Or pick a custom namespace name
cd p-kserve-raw && KSERVE_NAMESPACE=my-kserve bash install.sh
```

`install.sh` walks through CRDs → RBAC → core controllers → ClusterServingRuntimes in order with the right waits. After it returns, jump straight to **Step 6** (deploy an iris ISVC). Steps 5 (watching CR phases) does not apply — there is no `KServeRawMode` CR in this path. See `p-kserve-raw/README.md` for full details and the prereq install commands.

> **Auto-Init (Option A + Option B only):** The operator automatically creates a default `KServeRawMode` CR on startup, in the namespace named in the OperatorGroup's `targetNamespaces`. KServe installation begins immediately — no manual `kubectl apply -f kserve-rawmode.yaml` required. (Option C has no operator and no CR — the install is direct.)

### Step 5 — Watch installation progress *(Options A + B only — skip for Option C)*
```bash
kubectl get kserverawmode -A -w
```
Expected progression (using default `kserve` namespace):
```
NAMESPACE   NAME             PHASE                    AGE
kserve      kserve-rawmode   ValidatingCertManager    2s
kserve      kserve-rawmode   InstallingCRDs           8s
kserve      kserve-rawmode   InstallingRBAC           10s
kserve      kserve-rawmode   InstallingCore           11s
kserve      kserve-rawmode   InstallingRuntimes       38s
kserve      kserve-rawmode   Ready                    43s
```

Once the CR is `Ready`, the steady-state pod set in the KServe namespace looks like this:

```bash
kubectl get pods -n kserve
```
```
NAME                                                    READY   STATUS    RESTARTS   AGE
kserve-controller-manager-<rand>                        2/2     Running   0          90s
kserve-localmodel-controller-manager-<rand>             1/1     Running   0          90s
llmisvc-controller-manager-<rand>                       1/1     Running   0          90s
```

```bash
kubectl get ds -n kserve
```
```
NAME                          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR              AGE
kserve-localmodelnode-agent   0         0         0       0            0           kserve/localmodel=worker   90s
```

> **DaemonSet `DESIRED=0` is expected on a fresh install.** The `kserve-localmodelnode-agent` DaemonSet uses a `nodeSelector: kserve/localmodel=worker`. Until you opt nodes in (`kubectl label node <worker> kserve/localmodel=worker`), no node matches and the DaemonSet correctly schedules zero pods. This is **not a failure** — it's a feature: it lets you keep the LocalModelCache subsystem inert on clusters where you don't need per-node model caching. Once you label nodes, the DaemonSet scales up automatically. See [`extra-docs/LOCAL-MODEL-CACHE-GUIDE.md`](extra-docs/LOCAL-MODEL-CACHE-GUIDE.md) for the labeling step.

If cert-manager is missing, the phase will show `CertManagerNotFound` and the operator logs will display:
```
ERROR cert-manager is required but was not found in the cluster ...
      Please install cert-manager before deploying the KServe operator.
      See: https://cert-manager.io/docs/installation/
```
Install cert-manager and the operator will automatically retry and proceed.

### Step 6 — Deploy and test the Iris inference model (in-cluster URL)
```bash
kubectl apply -f 06-sample-model/sklearn-iris.yaml

# Wait for predictor to be ready (~30s)
kubectl get isvc sklearn-iris -w   # wait for READY=True

# Test inference via internal cluster URL (always works without ingress)
kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-predictor.default.svc.cluster.local/v1/models/sklearn-iris:predict
```
✅ Expected: `{"predictions":[1]}`

### Step 6b — *(Optional)* Test via external hostname (requires nginx-ingress)

By default KServe disables Kubernetes Ingress creation. To use the external URL shown in `kubectl get isvc` (e.g. `http://sklearn-iris-default.example.com`), follow these steps.

**Install nginx-ingress controller:**
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=120s
```

**Patch KServe to enable Ingress creation with nginx:**

```bash
# Default — installs into 'kserve' ns, sets ingressClassName=nginx
bash enable-ingress.sh

# Custom KServe namespace:
KSERVE_NS=my-kserve bash enable-ingress.sh

# Different ingress class (e.g. haproxy, traefik):
bash enable-ingress.sh --class haproxy
```

The script patches the `inferenceservice-config` ConfigMap (the `ingress` field is a JSON-encoded string inside the ConfigMap — needs parse / modify / re-serialize, and the operator owns the field via Server-Side Apply so `--force-conflicts` is required), then restarts `kserve-controller-manager` and waits for the new pod to be Ready before returning. Run `cat enable-ingress.sh` (or `bash enable-ingress.sh -h`) for details.

**Add local DNS entry** (for Docker Desktop / local clusters):
```bash
# Idempotent — safe to re-run; the entry is only appended once.
HOST_ENTRY="127.0.0.1 sklearn-iris-default.example.com"
grep -qF "${HOST_ENTRY}" /etc/hosts \
  || sudo bash -c "echo '${HOST_ENTRY}' >> /etc/hosts"
```

**Recreate the InferenceService** (so KServe creates the Ingress with the new config):
```bash
kubectl delete isvc sklearn-iris --ignore-not-found
kubectl apply -f 06-sample-model/sklearn-iris.yaml
kubectl get isvc sklearn-iris -w   # wait for READY=True
```

**Verify Ingress and test:**

After the ISVC reaches `READY=True`, the Ingress object is created — but its `ADDRESS` column may be empty for the first ~30s while nginx-ingress programs the route. Wait until `ADDRESS` is `localhost` before curl-ing.

```bash
kubectl get ingress -A
# Expected (after ADDRESS populates):
# NAMESPACE  NAME          CLASS  HOSTS                                    ADDRESS    PORTS  AGE
# default    sklearn-iris  nginx  sklearn-iris-default.example.com,...     localhost  80     30s

curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-default.example.com/v1/models/sklearn-iris:predict
```
✅ Expected: `{"predictions":[1]}`

> **Production note:** Replace `example.com` with your real domain and point DNS to the ingress load balancer IP/hostname. No `/etc/hosts` entry needed in production.

### Step 6c — *(Optional)* Test LocalModelCache (per-node model caching)

`LocalModelCache` pre-fetches a model onto each labeled worker node so InferenceServices start faster and survive without internet egress. The operator package ships sample manifests in `06-sample-model/` for both **online** (gs://) and **air-gapped** (pvc://) variants.

```bash
# Quick test (requires a multinode cluster — your production cluster, or
# any local-multinode tool like kind/k3d/minikube --nodes=3 — single-node
# Docker Desktop cannot exercise per-node placement):
kubectl label node <worker-1> kserve/localmodel=worker
kubectl apply -f 06-sample-model/localmodelcache-nodegroup.yaml
kubectl apply -f 06-sample-model/localmodelcache.yaml
kubectl wait --for=jsonpath='{.status.copies.available}'=1 \
  localmodelcache/sklearn-iris-cache --timeout=180s
kubectl apply -f 06-sample-model/localmodelcache-isvc.yaml
# Predictor pod will mount the cached PVC (no internet pull at startup).
```

📖 **Full walkthrough** — prerequisites, dev-cluster chown workaround, online (gs://) and air-gap (Minio/HTTP) options, cleanup, troubleshooting:  
👉 [extra-docs/LOCAL-MODEL-CACHE-GUIDE.md](extra-docs/LOCAL-MODEL-CACHE-GUIDE.md)

### Step 6d — *(Optional)* Test LLMInferenceService (LLM serving via Gateway API)

`LLMInferenceService` is KServe 0.16's new resource for serving large language models via Gateway API routing. The operator package ships a **smoke-only** sample (placeholder model URI) that validates the controller wiring without requiring real LLM compute.

```bash
kubectl apply -f 06-sample-model/llmisvc-smoke.yaml
# Within ~10s, the controller creates:
kubectl get deploy llmisvc-smoke-kserve          # Deployment (0/1, expected — placeholder model)
kubectl get svc llmisvc-smoke-kserve-workload-svc  # Service on port 8000
# The reconcile pipeline (Workload → Router → Scheduler → HTTPRoute) is logged
# by the llmisvc controller — see GUIDE for the verification commands.
```

📖 **Full walkthrough** — smoke test, Phase 2 with Gateway API CRDs + real LLM model, sizing:  
👉 [extra-docs/LLMISVC-GUIDE.md](extra-docs/LLMISVC-GUIDE.md)

---

## Part C: Alternative — Offline / Air-Gapped Model Test

If your cluster cannot reach `gs://` (Google Cloud Storage) to download model weights, the iris ISVC in Step 6 above will fail (the default `sklearn-iris.yaml` uses a `gs://` `storageUri`). Use this PVC-based offline alternative instead.

### 1. Create a local PersistentVolumeClaim
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: offline-models-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
```

### 2. Download and side-load the model into the PVC
*(On a machine with internet access)*
```bash
curl -sL https://storage.googleapis.com/kfserving-examples/models/sklearn/1.0/model/model.joblib -o model.joblib

# Mount the PVC to a temporary pod
kubectl run model-loader --image=busybox --restart=Never --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"offline-models-pvc"}}],"containers":[{"name":"model-loader","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"v","mountPath":"/mnt/pvc"}]}]}}'

# Copy the file inside
kubectl wait --for=condition=Ready pod/model-loader
kubectl exec model-loader -- mkdir -p /mnt/pvc/sklearn/iris/1.0/model
kubectl cp model.joblib default/model-loader:/mnt/pvc/sklearn/iris/1.0/model/model.joblib
kubectl delete pod model-loader
```

### 3. Deploy the InferenceService using the PVC
```bash
cat <<EOF | kubectl apply -f -
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-iris-pvc"
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
spec:
  predictor:
    sklearn:
      storageUri: "pvc://offline-models-pvc/sklearn/iris/1.0/model"
EOF
```

### 4. Test inference
```bash
kubectl get isvc sklearn-iris-pvc -w   # wait for READY=True

kubectl run --rm -i curl-test-offline --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-pvc-predictor.default.svc.cluster.local/v1/models/sklearn-iris-pvc:predict
```
✅ Expected: `{"predictions":[1]}`
