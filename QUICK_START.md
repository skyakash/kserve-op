# KServe Operator — Quick Start Guide

Four sections — pick what you need:
- **[Part A](#part-a-builder-build--publish-the-operator)** — you're building/publishing the operator
- **[Part B](#part-b-deployer-install-kserve-on-a-cluster)** — you have the package and just want to install KServe
- **[Part C](#part-c-alternative--offline--air-gapped-model-test)** — offline / air-gapped model test using a PVC
- **[Part D](#part-d-troubleshooting)** — troubleshooting recipes (`[cpu]`/`[memory] is not a supported metric` and other common admission-webhook rejections)

---

## Part A: Builder — Build & Publish the Operator

### Prerequisites

Supported build environments: **macOS** and **RHEL/Linux x86_64**.

| Tool | macOS | RHEL/Linux |
|---|---|---|
| Go v1.21+ | `brew install go` | [go.dev/dl](https://go.dev/dl) tarball |
| Operator SDK v1.42+ | `brew install operator-sdk` | Binary from GitHub releases |
| Docker v20.10+ **or** Podman v4+ | Docker Desktop, or `brew install podman && podman machine init --cpus 4 --memory 6144 --disk-size 40 && podman machine start` (defaults of 2 CPU / 2 GB OOM the build) | `dnf install docker-ce` (see [docs.docker.com](https://docs.docker.com/engine/install/rhel/)) or `dnf install podman` |
| yq v4+ | `brew install yq` | `sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq` |
| kubectl | `brew install kubectl` | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| Kustomize v5+ | `brew install kustomize` | `curl -s .../install_kustomize.sh \| bash` |
| python3 (3.7+ recommended) + pyyaml (5.1+) | `brew install python && pip3 install 'pyyaml>=5.1'` | `dnf install -y python3 python3-pip && pip3 install --upgrade 'pyyaml>=5.1'` |

> See [generate-kserve-operator-README.md](./generate-kserve-operator-README.md#installing-prerequisites) for exact copy-paste install commands per platform.

### Validated toolchain versions (known-good for KServe v0.16.0)

The reference build + the 16-test e2e validation (see [`extra-docs/0.16-test-report.md`](extra-docs/0.16-test-report.md)) were performed with these exact versions on macOS arm64. **For reproducible results, match the 🔴 must-match floors at minimum.** The 🟡 should-match items are unlikely to bite you but have known compatibility edges. The 🟢 nice-to-match items behave consistently across recent versions.

| Tool | Validated | Project minimum | Criticality | Why |
|---|---|---|---|---|
| Go | 1.26.3 | 1.21+ | 🟡 should match | operator-sdk's generated `go.mod` requires it |
| operator-sdk | 1.42.2 | 1.42+ | 🔴 must match | older versions scaffold incompatible boilerplate + bundle CSV format |
| Docker / Podman | docker 29.5.2 / podman 4+ | 20.10+ / v4+ | 🟢 nice | builds + pushes images; 20.10+ all behave similarly |
| Python | 3.13.9 (3.6 also works) | 3.7+ recommended | 🟢 nice | scripts use basic features only |
| **PyYAML** | **6.0.3** | **5.1+** | 🔴 must match | the `sort_keys=False` kwarg used in the YAML rewrites was added in 5.1 |
| yq | v4.53.2 | v4+ | 🔴 must match | **v3 syntax is incompatible** for CSV install-mode patching |
| Kustomize | v5.8.1 | v5+ | 🔴 must match | **v4 syntax differs**, doesn't support `labels:` field used in newer KServe `config/default` |
| kubectl | v1.34.1 | v1.24+ | 🟡 should match | Server-side apply behaviors stabilized in 1.24+ |
| skopeo (customer-registry only) | 1.22.2 | any recent | 🟢 nice | image mirroring; only needed with `--customer-registry` |
| make | GNU Make 3.81 | any | 🟢 nice | drives operator-sdk make targets |

**Cluster-side toolchain (deploy time, NOT build time):**

| Tool | Validated | Notes |
|---|---|---|
| cert-manager | **v1.17.2** | per [`0.16-test-report.md`](extra-docs/0.16-test-report.md) §T01 — webhook TLS dependency |
| OLM | v0.29.0 (auto-installed by `operator-sdk olm install`) | bundles + CSV machinery |
| Kubernetes | 1.27–1.34 | KServe v0.16.0 supported range |

**Image pins baked into the build** (set by `generate-kserve-raw.sh` at extraction time — no per-customer choice):
- `kserve/kserve-controller:v0.16.0`
- `kserve/storage-initializer:v0.16.0`
- `quay.io/brancz/kube-rbac-proxy:v0.18.0` (inherited from upstream)

#### Self-diagnostic — two scripts at the repo root

The repo ships two scripts so you don't have to copy-paste a diagnostic snippet from this doc:

| Script | What it does | Exit code |
|---|---|---|
| **`bash check-build-prereqs.sh`** | Smart pre-flight: parses each tool's `--version` output, compares against the 🔴 must-match floors above, prints a colored pass/fail table | **0** = safe to build / **1** = at least one REQUIRED check failed |
| `bash print-build-versions.sh` | Passive dump of every tool's version + OS info — handy for bug reports, no checking | 0 always |

**Recommended workflow — run the smart check before invoking the build:**

```bash
bash check-build-prereqs.sh && bash generate-kserve-operator.sh ...
```

If you're using the customer-registry flow (`--customer-registry` flag), pass it to the pre-flight too so `skopeo` is elevated to REQUIRED:

```bash
bash check-build-prereqs.sh --customer-registry
```

Sample output (passing machine):

```
REQUIRED (failures block the build):
  ✓ operator-sdk 1.42.2       (need ≥1.42)
  ✓ PyYAML       6.0.3        (need ≥5.1)
  ✓ yq           4.53.2       (need ≥4.0)
  ✓ kustomize    5.8.1        (need ≥5.0)
  ✓ container    docker 29.5.2

RECOMMENDED (older may surface edge-case bugs):
  ✓ Go           1.26.3       (recommend ≥1.21)
  ✓ Python       3.13.9       (recommend ≥3.7)
  ✓ kubectl      1.34.1       (recommend ≥1.24)

✓ All build-side prereqs OK. Safe to run generate-kserve-raw.sh and generate-kserve-operator.sh.
```

Sample output (RHEL 7 / CentOS 7 box hitting the colleague's PyYAML issue):

```
REQUIRED (failures block the build):
  ✓ operator-sdk 1.42.0       (need ≥1.42)
  ✗ PyYAML       3.13         TOO OLD (need ≥5.1)
  ✗ yq           3.4.1        TOO OLD (need ≥4.0)
  ...

✗ 2 REQUIRED check(s) failed. Fix before running the build scripts.
  See QUICK_START.md § Validated toolchain versions for upgrade commands per platform.
```

> **Deploy-time prereqs** (cert-manager, OLM, Python+PyYAML for install.sh) are checked automatically by the customer-facing scripts in the generated package — `setup-credentials.sh` for OLM, `install.sh` for the non-OLM path, `install-operator-deployment.sh` for the direct-manifest path. You don't need to run a separate pre-flight at deploy time.

> **Docker or Podman?** `generate-kserve-operator.sh` works with either — it auto-detects (**docker preferred when both are present**, so if you want podman on a machine that also has docker, you **must** export `CONTAINER_TOOL=podman` in every shell). Podman needs no `buildx` (multi-arch is native). Before any build that pushes (`-p` / `-o` / `-x`), log in with the matching tool: `docker login <registry>` **or** `podman login <registry>`. On macOS, podman needs a running, **sized** VM (see prereqs table — defaults OOM the build). For multi-arch `-x` on native Linux podman you'll also need qemu-user-static — see [generate-kserve-operator-README.md § Building with Podman](generate-kserve-operator-README.md#building-with-podman-no-docker) for the full podman-only walkthrough (machine sizing, qemu, short-name resolution, troubleshooting).

### Cleaning Up / Starting Fresh

If you are re-running the build (e.g. after a cluster reset), clean both generated directories first:

```bash
./generate-kserve-operator.sh -c p-kserve-operator   # removes p-kserve-operator/ and p-kserve-operator-package/
./generate-kserve-raw.sh -c p-kserve-raw              # removes p-kserve-raw/
```

---

> **Before Step 1 + Step 2, verify your toolchain:** run `bash check-build-prereqs.sh` (smart pass/fail; pass `--customer-registry` if you'll use that flag). It catches the most common build-time errors (PyYAML < 5.1, yq v3, kustomize v4, operator-sdk < 1.42) BEFORE invoking the generators, so you don't waste a 5-minute build on a missing dep. Wire it as a gate: `bash check-build-prereqs.sh && ./generate-kserve-raw.sh ...`. See [§ Validated toolchain versions](#validated-toolchain-versions-known-good-for-kserve-v0160) above for the criticality breakdown and sample output.

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

> **Behind a corporate proxy or TLS-intercepting firewall?** You'll typically need **two** flags together:
> - `--cert /path/to/corporate-ca.crt` — injects the corp CA into the Dockerfile builder's trust store so TLS handshakes verify cleanly.
> - `--http-proxy <url> --https-proxy <url> --no-proxy <list>` — all three together (the script rejects partial use) — injects `ENV HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (and lowercase variants) into the builder stage so `go mod download` and other build-time fetches actually *route* through the proxy. Without these, `go mod download` will get `connection reset by peer` even with the cert.
>
> Both flags are scoped to the **builder stage only** — neither the CA nor the proxy URL is baked into the final distroless operator image, so nothing leaks to customers. Example:
>
> ```bash
> bash generate-kserve-operator.sh \
>   ...flags... \
>   --cert corp-ca-chain.crt \
>   --http-proxy http://proxy.example.com:80 \
>   --https-proxy http://proxy.example.com:80 \
>   --no-proxy localhost,127.0.0.1,artifactory.example.com
> ```
>
> See [generate-kserve-operator-README.md § Building Behind a Corporate Proxy](generate-kserve-operator-README.md#building-behind-a-corporate-proxy-or-tls-intercepting-firewall-cert) for the full walkthrough + verification recipe.

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
- `setup-credentials.sh` — creates pull secrets per the Design D footprint. Always in `SYSTEM_NS` (operator's home ns, default `kserve-operator-system`); also in each `KSERVE_WORKLOAD_NS` (workload namespace(s), default `default`, comma-separated multi-ns supported) when the package was built with `--customer-registry` or `--also-workload-ns` is passed. Override defaults at script invocation via `SYSTEM_NS=<ns>` and `KSERVE_WORKLOAD_NS=<ns1>,<ns2>,...` env vars. *(always generated; see [`extra-docs/design-d-three-namespace-model.md`](extra-docs/design-d-three-namespace-model.md))*
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

**All three** of Design D's namespaces are user-configurable at deploy time. See [`extra-docs/design-d-three-namespace-model.md`](extra-docs/design-d-three-namespace-model.md) for the architecture rationale.

- **Operator-home namespace** (Design D #1) — baked default `kserve-operator-system`. Override at **deploy time** via env vars on the helper scripts:
  - `OPERATOR_NAMESPACE=<ns>` on `install-operator-deployment.sh` (Option B wrapper)
  - `OPERATOR_NS=<ns>` on `deploy-bundle.sh` (Option A / OLM)
  - `SYSTEM_NS=<ns>` on `setup-credentials.sh` (pull-secret target)
- **Runtime-control namespace** (Design D #2) — baked default `kserve`. Where the KServe controllers + webhooks + the `KServeRawMode` CR live. Pick a custom name via `--install-mode SingleNamespace=<ns>` (Option A), `KSERVE_NS=<ns>` env var on `install-operator-deployment.sh` (Option B), or `KSERVE_NAMESPACE=<ns>` env var on `install.sh` (Option C).
- **Workload namespace** (Design D #3, NEW) — baked default `default`. Where the user's `InferenceService` and predictor pods live. Override via `KSERVE_WORKLOAD_NS=<ns>` (single team) or `KSERVE_WORKLOAD_NS=<ns1>,<ns2>,...` (multi-team) env var on `setup-credentials.sh`, and pass `-n "${KSERVE_WORKLOAD_NS:-default}"` to your `kubectl apply` commands for ISVCs.

```bash
# Pick the namespace name you want for the KServe controllers (default: 'kserve').
KSERVE_NS=kserve

# Pick the namespace name you want for the operator pod (default: 'kserve-operator-system').
OPERATOR_NS="${OPERATOR_NS:-kserve-operator-system}"

# Pick the workload namespace(s) for your ISVCs (default: 'default').
# Comma-separated for multi-team: KSERVE_WORKLOAD_NS=team-a,team-b,team-c.
KSERVE_WORKLOAD_NS="${KSERVE_WORKLOAD_NS:-default}"

kubectl create namespace "${KSERVE_NS}"     || true
kubectl create namespace "${OPERATOR_NS}"   || true
# Workload ns: 'default' always exists; create others explicitly:
IFS=',' read -ra _WL_NSES <<<"${KSERVE_WORKLOAD_NS}"
for ns in "${_WL_NSES[@]}"; do
    [[ "${ns}" != "default" ]] && kubectl create namespace "${ns}" || true
done
```

> **Why this comes before credentials:** `setup-credentials.sh` (Step 3) creates pull secrets *inside* `${OPERATOR_NS}` (always) and each `${KSERVE_WORKLOAD_NS}` namespace (when `--customer-registry` was used at build time or `--also-workload-ns` is passed). If the target namespaces don't exist yet, the script fails-fast with a clear error pointing at the right `kubectl create namespace` command.

### Step 3 — Set up image pull credentials *(skip if images are public)*

```bash
# With CLI args (works for both Option A — OLM and Option B — direct manifest):
bash setup-credentials.sh --user <registry-user> --pass <registry-token>

# Or interactive (will prompt for username and password):
bash setup-credentials.sh
```

For the **customer-registry** flow, pass the **customer-registry** credentials here (the cluster will pull from the customer registry, not the build registry).

> **Design D — pull-secret placement.** The script always creates the pull secret in `${SYSTEM_NS}` (operator pod + OLM CatalogSource pod pull from here). It additionally creates the secret in each `${KSERVE_WORKLOAD_NS}` namespace **only when** the package was built with `--customer-registry` (private predictor images need a pull secret) **or** `--also-workload-ns` is passed on the CLI. With the public-image default, workload ns gets no pull secret — over-provisioning to namespaces that never use it is avoided. OLM's `olm` + `operators` namespaces are infrastructure — they never need our pull secret. (`--non-olm` is accepted as a deprecated no-op for backwards compatibility.)

### Step 4 — Deploy the operator

KServe Raw Mode supports **three deploy paths**, in increasing order of simplicity:

| | Option A — OLM Bundle | Option B — Direct manifest | Option C — `install.sh` |
|---|---|---|---|
| **Who manages the operator?** | OLM (CSV reconciles) | Plain Kubernetes Deployment | No operator at all — pure `kubectl apply` |
| **Infrastructure prereq** | cert-manager + OLM (`operator-sdk olm install` brings its own `olm` + `operators` namespaces) | cert-manager | cert-manager |
| **Namespaces you create** | 3 (Design D): `<operator ns>` (default `kserve-operator-system`) + `<KServe ns>` (default `kserve`) + `<workload ns>` (default `default` — already exists). All configurable. | Same as Option A. | 2: `<KServe ns>` (default `kserve`, override `KSERVE_NAMESPACE=...`) + `<workload ns>` (default `default`). |
| **Pull-secret command** | `setup-credentials.sh` | `setup-credentials.sh` (same — no flag needed) | N/A (KServe upstream images are public) |
| **Pull-secret target ns** | `<operator ns>` always; `<workload ns>` only if `--customer-registry` or `--also-workload-ns` | Same as Option A | N/A |
| **Custom KServe namespace** | yes — `--install-mode SingleNamespace=<name>` | currently bundled defaults only | yes — `KSERVE_NAMESPACE=<name> ./install.sh` |
| **CR + auto-init** | yes (operator runs in cluster) | yes | no — operator is not deployed; KServe runs directly |
| **Customer-facing complexity** | high (OLM concepts) | medium | low (one script, one CR-less install) |
| **Best for** | production multi-tenant clusters with OLM already adopted | private-registry environments without OLM | dev clusters, customer demos, the simplest possible deploy |
| **Steps to run** | 0 (cert-manager) → 1 (OLM) → 2 (your namespaces) → 3 (creds) → 4A → 5 → 6 | 0 → 2 (your namespaces) → 3 (creds) → 4B → 5 → 6 | 0 → run `install.sh` → 6 |
| **Tested by** | T01, T05, T10, T11, T12, T12-LIKE-REGRESSION | T04 | T02, T03-RETEST |

> **Design D (3 namespaces).** All three options share the same footprint OF OURS: 3 namespaces (operator home + runtime-control + workload). The workload ns is plural-allowed (`KSERVE_WORKLOAD_NS=team-a,team-b,...`) for multi-team setups. OLM's `olm` + `operators` namespaces (Option A only) are OLM infrastructure — they exist regardless of our operator and we don't put anything there. See [`extra-docs/design-d-three-namespace-model.md`](extra-docs/design-d-three-namespace-model.md) for the full ADR including the bug Design D fixes.

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
#   • Standard build:           <build-registry>/<image>-bundle:<tag>
#   • --customer-registry path: <customer-registry>/<image>-bundle:<tag>
#     (after `bash mirror-images.sh ...` has copied/loaded it there).
# Convention: `-bundle` is appended to the IMAGE NAME (before the tag),
# matching the upstream OperatorHub pattern (e.g. quay.io/operatorhubio/<x>-bundle:v1).
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

> **Bundle image name:** The bundle image name is derived by appending `-bundle` to the operator image name (before the `:tag`), printed at the end of `generate-kserve-operator.sh` output. Format: `<registry>/<image>-bundle:<tag>`.
> Example: if you built with `-i docker.io/akashneha/kserve-raw-operator:v403`, the bundle image is `docker.io/akashneha/kserve-raw-operator-bundle:v403`.

> **Customer registry flow:** If you generated with `--customer-registry`, the package contains `mirror-images.sh` and `deploy-bundle.sh`. Run `mirror-images.sh` first to push images to the customer registry, then `deploy-bundle.sh` — it handles the bundle image reference automatically.

**Option B: Direct manifests (no OLM needed — skip Step 1)**

Two equivalent invocations:

```bash
# Prereq: ${OPERATOR_NS} + <KServe ns> created (Step 2),
# and pull secret in those namespaces (Step 3 — no special flag).

# Default — uses the baked-in operator namespace 'kserve-operator-system':
kubectl apply -f operator-deployment.yaml

# OR — choose BOTH namespaces at deploy time (no rebuild needed):
OPERATOR_NAMESPACE=<your-operator-ns> KSERVE_NS=<your-kserve-ns> \
  bash install-operator-deployment.sh
# - OPERATOR_NAMESPACE rewrites every namespace ref in operator-deployment.yaml
#   (Namespace.metadata.name + metadata.namespace on namespaced resources + RBAC subjects).
# - KSERVE_NS rewrites the Deployment's WATCH_NAMESPACE env var from the
#   OLM-downward-API source to a literal value, so the operator targets your
#   chosen KServe namespace for the auto-init CR + KServe runtime install.
# The script supports --dry-run if you want to preview the rewritten YAML.
```

> **Pure deploy-time architecture.** The wrapper script (`install-operator-deployment.sh`) mirrors `install.sh`'s rewrite pattern from Option C, making Option B symmetric: one generated package serves any namespace. Use `OPERATOR_NAMESPACE` consistently across `install-operator-deployment.sh` AND `SYSTEM_NS` on `setup-credentials.sh` so the operator pod's pull secret lands in the same namespace it's deployed into. `KSERVE_NS` lets you also target a custom KServe namespace without rebuilding.

**Option C: `install.sh` (no operator, no OLM — pure `kubectl apply` orchestrated by a shell script)**

Use this when you don't need the operator's lifecycle management — `install.sh` applies the KServe manifests directly. Simplest path. Skip Steps 1, 2, 3 and 4A/4B entirely; run `install.sh` straight after Step 0 (cert-manager).

Host prerequisites for `install.sh`:
- `cert-manager` installed in the cluster (see Step 0)
- `python3` (3.7+ recommended) + `PyYAML` (5.1+) on the machine running the script — it does a structured YAML rewrite of namespace references. Verify with `python3 -c 'import yaml; print(yaml.__version__)'` (must print 5.1 or higher). Upgrade with `pip3 install --upgrade 'pyyaml>=5.1'`. Older PyYAML (RHEL 7/CentOS 7's bundled 3.13) errors with `TypeError: safe_dump_all() got an unexpected keyword argument 'sort_keys'`. **Python 3.6 also works** if you're stuck on a legacy distro — the scripts themselves use only basic Python features — but you'll need to cap PyYAML (`pip3 install 'pyyaml>=5.1,<5.5'` — PyYAML 5.5+ dropped 3.6 support). Note that Python 3.6 reached end-of-life in December 2021 and receives no security updates; upgrading to a supported Python is strongly recommended for production use.

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
NAME                                READY   STATUS    RESTARTS   AGE
kserve-controller-manager-<rand>    2/2     Running   0          90s
```

> **Only one KServe controller pod.** Upstream KServe v0.16 ships two additional controllers (`llmisvc-controller-manager` and `kserve-localmodel-controller-manager` + a `kserve-localmodelnode-agent` DaemonSet) for `LLMInferenceService` and `LocalModelCache` features. This project filters them out at build time — see `generate-kserve-raw.sh`. If you see extra pods, you may be running an older package built before the removal.

If cert-manager is missing, the phase will show `CertManagerNotFound` and the operator logs will display:
```
ERROR cert-manager is required but was not found in the cluster ...
      Please install cert-manager before deploying the KServe operator.
      See: https://cert-manager.io/docs/installation/
```
Install cert-manager and the operator will automatically retry and proceed.

### Step 6 — Deploy and test the Iris inference model (in-cluster URL)

The iris ISVC lives in the **workload namespace** (Design D #3, default `default`). Override with `KSERVE_WORKLOAD_NS=<your-ns>` env var if you've onboarded a team-specific namespace via `setup-credentials.sh`. See [`extra-docs/design-d-three-namespace-model.md`](extra-docs/design-d-three-namespace-model.md) for the three-namespace model.

```bash
kubectl apply -n "${KSERVE_WORKLOAD_NS:-default}" -f 06-sample-model/sklearn-iris.yaml

# Wait for predictor to be ready (~30s)
kubectl get isvc sklearn-iris -n "${KSERVE_WORKLOAD_NS:-default}" -w   # wait for READY=True

# Test inference via internal cluster URL (always works without ingress)
kubectl run --rm -i curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -H "Content-Type: application/json" \
  -d '{"instances":[[6.8,2.8,4.8,1.4]]}' \
  http://sklearn-iris-predictor.default.svc.cluster.local/v1/models/sklearn-iris:predict
```

> The cluster URL above assumes `KSERVE_WORKLOAD_NS=default`. For a different workload ns, the service DNS is `sklearn-iris-predictor.<your-ns>.svc.cluster.local`.
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
kubectl delete isvc sklearn-iris -n "${KSERVE_WORKLOAD_NS:-default}" --ignore-not-found
kubectl apply -n "${KSERVE_WORKLOAD_NS:-default}" -f 06-sample-model/sklearn-iris.yaml
kubectl get isvc sklearn-iris -n "${KSERVE_WORKLOAD_NS:-default}" -w   # wait for READY=True
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

> **Project scope:** this build ships **only the core `kserve-controller-manager`** (InferenceService serving). The `LLMInferenceService` and `LocalModelCache` features from upstream KServe v0.16 are filtered out at extraction time and intentionally not bundled. If you need LLM serving or per-node model caching, see the project history for previous commits that bundled those, or re-introduce them by reverting the filter additions in `generate-kserve-raw.sh`.

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
    serving.kserve.io/deploymentMode: "Standard"
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

---

## Part D: Troubleshooting

### `[cpu]` or `[memory]` is not a supported metric

**Symptom.** InferenceService creation is rejected by the admission webhook:
```
admission webhook "inferenceservice.kserve-webhook-server.validator" denied the request:
    [cpu] is not a supported metric
```
Removing `scaleMetric: cpu` from your Helm values often just shifts the error to `[memory]` — same underlying issue.

**Who hits this.** Users whose InferenceService (or Helm chart) was written against KServe **v0.15.x** and hardcodes:
- `serving.kserve.io/deploymentMode: "RawDeployment"` (the legacy string), AND
- `scaleMetric: cpu` or `scaleMetric: memory` on any of predictor, transformer, or explainer.

**Root cause.** Upstream KServe renamed the deployment-mode string in v0.16: `"RawDeployment"` → `"Standard"`. The admission validator only routes to the CPU/memory-allowing (HPA) branch when the annotation value matches the literal new string `"Standard"` AND the `autoscalerClass` annotation is `"hpa"`. Anything else — including the legacy `"RawDeployment"` string — falls back to the concurrency-based (KPA) validator, which rejects both `cpu` and `memory`. The `scaleMetric` field lives on all three component specs (predictor, transformer, explainer), so removing it from one block just uncovers the next.

Confirmed in source:
- `kserve-source.v0.16/pkg/constants/constants.go:215` — `LegacyRawDeployment DeploymentModeType = "RawDeployment" // deprecated: use Standard`
- `kserve-source.v0.16/pkg/apis/serving/v1beta1/inference_service_validation.go:258` — validator dispatcher switch

**Fix A — fastest unblock (strip the fields).** In your chart's `templates/inferenceservice.yaml`, delete every `scaleMetric:` and `scaleTarget:` line from every component block. KServe falls back to `concurrency`-based scaling, which is universally accepted.

```yaml
spec:
  predictor:
    # scaleMetric: cpu          ← delete
    # scaleTarget: 80           ← delete
    ...
  transformer:
    # scaleMetric: memory       ← delete
    # scaleTarget: 60           ← delete
    ...
```

Repackage the chart (`tar -czf`) and reinstall.

**Fix B — modernize the annotations (keeps CPU/memory-based autoscaling).** Edit the same template file, adding two annotations to `metadata.annotations`:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: {{ .Release.Name }}
  annotations:
    serving.kserve.io/deploymentMode: "Standard"      # replaces legacy "RawDeployment"
    serving.kserve.io/autoscalerClass: "hpa"          # required to dispatch to HPA validator
spec:
  predictor:
    scaleMetric: cpu             # now valid
    scaleTarget: 80
    ...
```

Both annotations must be on `metadata.annotations` — not `spec.predictor.annotations` (pod-template annotations aren't read by the validator).

**Debug recipe** — find every place your chart is still emitting `cpu` / `memory`:

```bash
helm template <release> <chart.tgz> -f values.yaml > /tmp/rendered.yaml

grep -niE 'cpu|memory|scaleMetric|scaleTarget|autoscaling|autoscaler|deploymentMode' /tmp/rendered.yaml
```

If `cpu` or `memory` shows up in the output, that's your source — usually either a hardcoded `scaleMetric: cpu` in the template, or a Helm `default "cpu"` fallback in an expression like `{{ .Values.scaleMetric | default "cpu" }}`.

See `extra-docs/kserve-version-comparison.md` § "Downstream chart compatibility: v0.15 → v0.16 breaking change" for the full source-code trace.
