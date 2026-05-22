# KServe Operator — Namespace & Install-Mode Design

This document explains how Kubernetes namespaces and OLM install modes interact in the KServe Raw Mode operator, what the current design looks like, what the alternatives are, and which design we recommend going forward.

It is meant to be read top-to-bottom by someone who hasn't worked on this project — review it with your team before we commit to a final design.

---

## 1. Why this matters

Several distinct things have to live somewhere on a cluster when you install KServe via this operator:

- **The operator itself** (the controller pod that manages KServe's lifecycle)
- **The CR** that asks the operator to install KServe (`KServeRawMode`)
- **KServe's own runtime** (its controller-manager, webhooks, ConfigMap)
- **The InferenceServices users deploy** (and the predictor pods they spawn)
- **cert-manager** (a cluster prerequisite)

If you put these in the wrong namespaces — or collapse roles that should stay separate — you get fragile RBAC, awkward upgrade paths, multi-tenancy blockers, and confusing `kubectl get` output. Picking the right shape now saves rework later.

---

## 2. The five conceptual roles

```mermaid
flowchart LR
    classDef prereq fill:#ffe6a7,stroke:#ff9f1c,stroke-width:2px,color:#000
    classDef operator fill:#bbdefb,stroke:#1976d2,stroke-width:2px,color:#000
    classDef cr fill:#e1bee7,stroke:#7b1fa2,stroke-width:2px,color:#000
    classDef runtime fill:#c8e6c9,stroke:#388e3c,stroke-width:2px,color:#000
    classDef workload fill:#ffccbc,stroke:#d84315,stroke-width:2px,color:#000

    A[1. cert-manager<br/>cluster prerequisite]:::prereq
    B[2. The operator<br/>lifecycle manager]:::operator
    C[3. The CR<br/>install request]:::cr
    D[4. KServe runtime<br/>controller + webhooks + ConfigMap]:::runtime
    E[5. InferenceServices<br/>user workloads + predictor pods]:::workload

    A -.required by.-> D
    B -- watches --> C
    C -- triggers install of --> D
    D -- watches & serves --> E
```

| # | Role | Lifecycle | Who owns it |
|---|------|-----------|-------------|
| 1 | cert-manager | Independent — installed before the operator, never managed by it | Cluster admin |
| 2 | Operator pod | Installed via OLM bundle or direct kubectl | Cluster admin |
| 3 | KServeRawMode CR | One per cluster (singleton); created automatically by the operator at startup | Operator |
| 4 | KServe runtime | Created/destroyed by the operator in response to the CR | Operator |
| 5 | InferenceServices | Created by end users in any namespace they want | End users |

Roles 2, 3, 4 and 5 each have a different lifecycle, RBAC profile, and blast radius — that's why they tend to live in different namespaces.

---

## 3. What's deployed today (current design)

```mermaid
flowchart TB
    classDef prereq fill:#ffe6a7,stroke:#ff9f1c,stroke-width:1px,color:#000
    classDef operator fill:#bbdefb,stroke:#1976d2,stroke-width:1px,color:#000
    classDef cr fill:#e1bee7,stroke:#7b1fa2,stroke-width:1px,color:#000
    classDef runtime fill:#c8e6c9,stroke:#388e3c,stroke-width:1px,color:#000
    classDef workload fill:#ffccbc,stroke:#d84315,stroke-width:1px,color:#000
    classDef olm fill:#eceff1,stroke:#607d8b,stroke-width:1px,stroke-dasharray:4 4,color:#000

    subgraph cluster[Kubernetes cluster]
      direction TB

      subgraph cm[ns: cert-manager]
        cmpods[cert-manager pods x3]:::prereq
      end

      subgraph olm[ns: olm + operators]
        olmpods[OLM controllers]:::olm
      end

      subgraph opsys["ns: kserve-operator-system"]
        operpod[p-kserve-operator-controller-manager]:::operator
      end

      subgraph defns[ns: default]
        cr1[KServeRawMode CR]:::cr
        isvc1[sklearn-iris ISVC<br/>predictor pod]:::workload
      end

      subgraph kservens[ns: kserve]
        kctrl[kserve-controller-manager<br/>webhook svc + ConfigMap]:::runtime
      end
    end

    operpod -- watches --> cr1
    cr1 -.installs into.-> kservens
    kctrl -.serves.-> isvc1
```

Four namespaces are in play (excluding cert-manager and OLM infra):

| Namespace | What lives here | Notes |
|-----------|-----------------|-------|
| `kserve-operator-system` | Operator pod | Created by user before deploy |
| `default` | CR + sample InferenceService | The CR landed here because the OperatorGroup targets `default` |
| `kserve` | KServe runtime (controller, webhook svc, ConfigMap) | Created by user as a prereq |
| `<wherever>` | Real-world InferenceServices | User chooses |

**The CR ending up in `default` is a side effect of how the OperatorGroup is configured today** (`SingleNamespace` install mode targeting `default`). It's not particularly intentional and pollutes a namespace users typically use for ad-hoc work.

---

## 4. OLM install modes — primer

Every operator installed via OLM has an **OperatorGroup**. The OperatorGroup defines which namespace(s) the operator's CRs are watched in. The CSV declares which **install modes** (i.e. which OperatorGroup geometries) it supports. There are four modes.

```mermaid
flowchart LR
    classDef pod fill:#bbdefb,stroke:#1976d2,stroke-width:2px,color:#000
    classDef cr fill:#e1bee7,stroke:#7b1fa2,stroke-width:2px,color:#000
    classDef ns fill:#fff,stroke:#666,stroke-dasharray:4 4

    subgraph own[OwnNamespace]
        direction TB
        subgraph ns_own[ns: kserve-operator-system]
            o_own[operator pod]:::pod
            cr_own[CR]:::cr
        end
    end

    subgraph single[SingleNamespace]
        direction TB
        subgraph ns_s_op[ns: kserve-operator-system]
            o_single[operator pod]:::pod
        end
        subgraph ns_s_target[ns: target-ns]
            cr_single[CR]:::cr
        end
        ns_s_op -.watches.-> ns_s_target
    end

    subgraph multi[MultiNamespace]
        direction TB
        subgraph ns_m_op[ns: kserve-operator-system]
            o_multi[operator pod]:::pod
        end
        subgraph ns_m_a[ns: ns-a]
            cr_multi_a[CR-a]:::cr
        end
        subgraph ns_m_b[ns: ns-b]
            cr_multi_b[CR-b]:::cr
        end
        ns_m_op -.watches.-> ns_m_a
        ns_m_op -.watches.-> ns_m_b
    end

    subgraph all[AllNamespaces]
        direction TB
        subgraph ns_a_op[ns: operators]
            o_all[operator pod]:::pod
        end
        subgraph ns_a_x[ns: anywhere]
            cr_all[CR]:::cr
        end
        ns_a_op -.watches all.-> ns_a_x
    end
```

| Mode | OperatorGroup `targetNamespaces` | Where the CR lives | Typical use case |
|------|----------------------------------|---------------------|------------------|
| **OwnNamespace** | `[<operator-ns>]` | Same namespace as the operator pod | Singleton operators that manage themselves |
| **SingleNamespace** | `[<exactly one other ns>]` | That one other namespace | Operator pod runs centrally, CRs live in a tenant namespace |
| **MultiNamespace** | `[ns-a, ns-b, ...]` | Any of the listed namespaces | One operator instance serving multiple specific tenants |
| **AllNamespaces** | `[]` (empty = all) | Anywhere on the cluster | Cluster-wide operators (operator pod is forced into the OLM `operators` namespace) |

### The key thing to internalize

**Install mode is not about RBAC scope** (the operator's cluster-scoped permissions come from its CSV regardless of mode). It's about **where the CR lives** relative to where the operator pod runs.

For a singleton like ours — one KServe install per cluster — `MultiNamespace` and `AllNamespaces` are overkill. The interesting choice is between **OwnNamespace** and **SingleNamespace**.

---

## 5. Three viable designs for our operator

We've narrowed the choice to three shapes. All three keep the operator in a fixed namespace (`kserve-operator-system`) and let cert-manager + ISVCs live where they always lived.

### Design A — SingleNamespace targeting `default` (TODAY)

```mermaid
flowchart TB
    classDef pod fill:#bbdefb,stroke:#1976d2,color:#000
    classDef cr fill:#e1bee7,stroke:#7b1fa2,color:#000
    classDef runtime fill:#c8e6c9,stroke:#388e3c,color:#000

    subgraph A1[ns: kserve-operator-system]
        op_a[operator pod]:::pod
    end
    subgraph A2[ns: default]
        cr_a[CR]:::cr
    end
    subgraph A3[ns: kserve]
        rt_a[KServe runtime]:::runtime
    end

    op_a -.watches.-> cr_a
    cr_a -- triggers install into --> rt_a
```

- Operator: `kserve-operator-system`
- CR: `default`
- KServe runtime: `kserve`
- **3 namespaces in our footprint.** CR pollutes the user-facing `default` namespace.

### Design B — OwnNamespace

```mermaid
flowchart TB
    classDef pod fill:#bbdefb,stroke:#1976d2,color:#000
    classDef cr fill:#e1bee7,stroke:#7b1fa2,color:#000
    classDef runtime fill:#c8e6c9,stroke:#388e3c,color:#000

    subgraph B1["ns: kserve-operator-system"]
        op_b[operator pod]:::pod
        cr_b[CR]:::cr
    end
    subgraph B2[ns: kserve]
        rt_b[KServe runtime]:::runtime
    end

    op_b -.watches.-> cr_b
    cr_b -- triggers install into --> rt_b
```

- Operator + CR: `kserve-operator-system`
- KServe runtime: `kserve` (or whatever name we pick)
- **2 namespaces.** The CR is cleanly bundled with the operator.
- Standard OLM convention for singleton platform operators.

### Design C — SingleNamespace targeting the user's chosen KServe namespace

```mermaid
flowchart TB
    classDef pod fill:#bbdefb,stroke:#1976d2,color:#000
    classDef cr fill:#e1bee7,stroke:#7b1fa2,color:#000
    classDef runtime fill:#c8e6c9,stroke:#388e3c,color:#000

    subgraph C1[ns: kserve-operator-system]
        op_c[operator pod]:::pod
    end
    subgraph C2["ns: my-kserve (user-chosen name)"]
        cr_c[CR]:::cr
        rt_c[KServe runtime]:::runtime
    end

    op_c -.watches.-> cr_c
    cr_c -- triggers install into --> rt_c
```

- Operator: `kserve-operator-system`
- CR + KServe runtime: **same namespace, name chosen by user** (defaults to `kserve`)
- **2 namespaces.** The CR sits next to the thing it manages.
- The user picks the namespace name **once** — when they create the namespace and the OperatorGroup. There's nothing else to configure.

---

## 6. Side-by-side comparison

| | Design A (current) | Design B (OwnNamespace) | Design C (user-chosen target) |
|---|---|---|---|
| Operator footprint | 3 namespaces | 2 namespaces | 2 namespaces |
| CR location | `default` (fixed) | Operator namespace (fixed) | User's chosen KServe namespace |
| KServe runtime location | `kserve` | `kserve` | User-chosen (`my-kserve`, etc.) |
| Source of truth for "where is KServe?" | Two places (`default` + `kserve`) | Two places (operator-system + `kserve`) | **One place** (the user's namespace) |
| User-friendly default flow | Awkward (CR in `default`) | Clean | Clean |
| Custom KServe namespace name | Hard (must coordinate two settings) | Possible (separate `spec.kserveNamespace` knob) | **Native** (just name the namespace what you want) |
| Uninstall | Two deletes | One delete (drop operator-system) | Two deletes (drop both namespaces) |
| Multi-tenant ISVCs | ✅ supported (independent of this choice) | ✅ supported | ✅ supported |
| Multi-tenant **KServe** installs | ❌ KServe is cluster-singleton — out of scope for all three | ❌ same | ❌ same |

---

## 7. Recommended design — Design D (three-namespace model)

> **Note (2026-05-22):** This section was **Design C** until T19 surfaced that ISVCs deployed in the runtime-control namespace can't get the storage-initializer injected — upstream KServe's pod-mutator webhook has a `namespaceSelector: control-plane DoesNotExist` guard that filters out the `kserve` namespace. We pivoted to **Design D**, which separates the workload namespace from the runtime-control namespace. The full Architecture Decision Record is in [`design-d-three-namespace-model.md`](design-d-three-namespace-model.md). The historical "Design C" three-section is kept at the bottom of §7 (under "Historical: Design C") for context. **Design D supersedes Design C in this doc and in code.**

### Three namespaces

| # | Role | Default | Override env var (deploy-time) | Owner | What lives there |
|---|---|---|---|---|---|
| 1 | **Operator-home** | `kserve-operator-system` | `OPERATOR_NAMESPACE` / `OPERATOR_NS` / `SYSTEM_NS` | Platform / SRE | Operator pod + RBAC + pull secret |
| 2 | **Runtime-control** | `kserve` | `KSERVE_NS` / `KSERVE_NAMESPACE` | Platform / SRE | KServe controllers + webhooks + `KServeRawMode` CR; cluster-scoped resources (CRDs, ClusterServingRuntimes) logically owned here |
| 3 | **Workload** | `default` | `KSERVE_WORKLOAD_NS` (comma-separated multi-ns supported) | App team / data scientist | `InferenceService`, `LLMInferenceService`, predictor pods, model PVCs |

**Rule:** ns #1 and #2 are singletons per cluster; ns #3 is plural (multi-tenant ready). No resource of ours (operator, controllers, webhooks, CRDs) lives in ns #3. No user workload lives in ns #1 or #2.

### Why three namespaces

- **One source of truth per concern.** Operator lifecycle, KServe lifecycle, workload lifecycle — three independent owners, three independent namespaces.
- **No extra CRD knob.** The CR's `metadata.namespace` still IS the runtime-control configuration. No `spec.kserveNamespace` field.
- **Workload-vs-control separation** matches cloud-native conventions (Istio, Knative, Cert-Manager, Argo, Tekton, GKE Config Connector). Blast radius isolation, RBAC granularity, quota separation, independent upgrade lifecycles, multi-tenant readiness.
- **Aligns with upstream KServe.** The pod-mutator webhook's anti-self-injection guard assumes workloads live in a separate ns from the controllers. We respect the assumption; we don't fight upstream.
- **Defaults are easy.** A user who doesn't want to think about it gets `kserve-operator-system` + `kserve` + `default` (workloads in `default` ns). This is what every test T01-T16 actually did by accident — Design D codifies the de facto pattern.

### How the operator derives the target namespace

```
OperatorGroup.targetNamespaces = [my-kserve]
        │
        ▼
OLM injects WATCH_NAMESPACE=my-kserve into the operator pod
        │
        ▼
Manager configured to watch my-kserve for KServeRawMode CRs
        │
        ▼
auto-init creates CR in my-kserve
        │
        ▼
Reconcile sees req.Namespace == "my-kserve"
        │
        ▼
applyManifests(targetNS = "my-kserve")
        │
        ▼
apply.go rewrites every "namespace: kserve" reference in the
embedded KServe YAML → "my-kserve" before applying
```

### What the user-facing flow looks like

```bash
# 1. Pick whatever namespace name you want for KServe
kubectl create namespace my-kserve

# 2. Operator namespace (always the same)
kubectl create namespace kserve-operator-system

# 3. OperatorGroup targets the user's chosen ns
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kserve-operator-og
  namespace: kserve-operator-system
spec:
  targetNamespaces:
    - my-kserve
EOF

# 4. Install
operator-sdk run bundle docker.io/.../v401-bundle --namespace kserve-operator-system
# → operator pod in kserve-operator-system
# → CR auto-created in my-kserve
# → KServe runtime installed in my-kserve
# → done
```

If the user accepts the default name, replace `my-kserve` with `kserve`. That's the only difference.

### What changes in the codebase

| File | Change |
|---|---|
| `kserve-operator-base/kserverawmode_types.go.tmpl` | Drop `KServeNamespace` field from CRD spec (or mark deprecated/ignored for back-compat) |
| `kserve-operator-base/kserverawmode_controller.go.tmpl` | Replace `resolveKServeNamespace()` with `req.Namespace`; auto-init reads `WATCH_NAMESPACE` |
| `kserve-operator-base/apply.go.tmpl` | Add `targetNS` parameter; rewrite `kserve` → `targetNS` on object namespaces, ClusterRoleBinding subjects, *WebhookConfiguration `clientConfig.service.namespace` |
| `kserve-raw-base/install.sh.tmpl` | Standalone manual-install path: accept `KSERVE_NAMESPACE` env var (default `kserve`), apply same YAML rewrites |
| `kserve-raw-base/README.md.tmpl` | Document the namespace knob in the standalone path |
| `generate-kserve-operator.sh` | Make sure `--install-mode SingleNamespace` is the default (it already is); update the package README to show the OperatorGroup setup with a clear "rename `my-kserve` to whatever you want" callout |
| `QUICK_START.md` | Update Step 4 to make the namespace name a single visible variable |

The original Path 1 plan kept a separate `spec.kserveNamespace` field. This design **removes that field entirely** — the API gets simpler, not more complex.

---

## 8. Constraints and limitations to be aware of

1. **KServe is a cluster singleton today.** Its CRDs and WebhookConfigurations are cluster-scoped, so there can only be one KServe install per cluster regardless of which design we pick. SingleNamespace install mode reflects this honestly. If you ever need multiple parallel KServes, the design has to change to something fundamentally different (e.g. cluster-scoped CR + per-namespace install records).
2. **InferenceServices are independent.** Users deploy ISVCs into whatever namespace they want — the operator and KServe runtime don't dictate this. Multi-tenancy lives at the ISVC level (many namespaces of ISVCs, served by one KServe).
3. **cert-manager is always separate.** It's a cluster prerequisite, never managed by this operator.
4. **The operator's namespace name is not magic.** We default to `kserve-operator-system` because that's the OLM convention — but if a user renames it (e.g. `kserveops`), nothing breaks. It's just a label.

---

## 9. Design D footprint: 3 namespaces of ours (all user-configurable at deploy time)

A common point of confusion: when reading the OLM-deploy path (Option A) someone might count **5 namespaces** — `olm`, `operators`, `kserve-operator-system`, `<KServe ns>`, and `<workload ns>` — and think the operator is "namespace-heavy." It is not. **Design D involves 3 namespaces we logically own**, regardless of which deploy path the customer picks:

| Namespace | Owner | What lives there |
|---|---|---|
| `olm`, `operators` | OLM project (created by `operator-sdk olm install`) | OLM infrastructure (we don't touch) |
| `kserve-operator-system` (Design D #1) | **Us** | KServeRawMode operator pod + OLM CatalogSource pod for our bundle |
| `kserve` (or `<KServe ns>`, Design D #2) | **Us** | KServe controllers + webhooks + `KServeRawMode` CR + cluster-scoped resources |
| `default` (or `<KSERVE_WORKLOAD_NS>`, Design D #3) | **User app team** | ISVCs + predictor pods + model PVCs |

**The two OLM namespaces are infrastructure** — `operator-sdk olm install` creates them whether we exist or not. Pre-existing OLM users already have them. They host OLM, not us.

**Customer footprint is always:**
- Option A (OLM): 3 namespaces of ours + 2 OLM-infrastructure namespaces (only if they didn't already exist)
- Option B (direct manifest): 3 namespaces of ours
- Option C (`install.sh`): 2 namespaces (the operator is not deployed; KServe controllers + workload)

`setup-credentials.sh` reflects Design D: pull secret lands in `SYSTEM_NS` always; in each `KSERVE_WORKLOAD_NS` ns only when the package was built with `--customer-registry` (or `--also-workload-ns` is passed at deploy time). Public-image predictors don't need pull secrets in workload ns. The `--non-olm` flag is still a deprecated no-op for backwards compatibility.

### All three namespaces are user-configurable

All three Design D namespaces are **user-configurable at DEPLOY TIME ONLY**. The baked default in all generated artifacts is `kserve-operator-system` + `kserve` + `default` — customers override at apply time via env vars on the helper scripts, no rebuild needed.

| Namespace | Default | How to configure (deploy-time only) | Where it's used |
|---|---|---|---|
| **Operator-home** (Design D #1) | `kserve-operator-system` | `OPERATOR_NAMESPACE=<ns>` env var on `install-operator-deployment.sh` (Option B wrapper rewrites the YAML on-the-fly). `OPERATOR_NS=<ns>` env var on `deploy-bundle.sh` (Option A — passes through to `operator-sdk run bundle --namespace=<ns>`). `SYSTEM_NS=<ns>` env var on `setup-credentials.sh`. | Operator pod home; OLM CatalogSource pod for the bundle. |
| **Runtime-control** (Design D #2) | `kserve` | `KSERVE_NS=<ns>` env var on `install-operator-deployment.sh` (Option B — rewrites Deployment's WATCH_NAMESPACE env). `--install-mode SingleNamespace=<ns>` on `operator-sdk run bundle` (Option A). `KSERVE_NAMESPACE=<ns>` env var on `install.sh` (Option C). | KServe controller pods; the `KServeRawMode` CR. **NOT where ISVCs live.** |
| **Workload** (Design D #3) | `default` | `KSERVE_WORKLOAD_NS=<ns1>,<ns2>,...` env var on `setup-credentials.sh` (comma-separated; pull-secret placement). At ISVC deploy time: `kubectl -n "${KSERVE_WORKLOAD_NS:-default}" apply -f sklearn-iris.yaml`. | InferenceServices, LLMInferenceServices, predictor pods, model PVCs. |

**Backwards compatibility:** all existing CI scripts and customer invocations that don't set any of these env vars get byte-identical output to before — operator in `kserve-operator-system`, KServe in `kserve`, ISVCs in `default` (which was also the de facto pattern under Design C since all `kubectl apply -f sklearn-iris.yaml` calls were unqualified). Adopt the env-var overrides only if you have naming collisions or org-naming conventions to honor.

**Historical note (Design C):** A two-namespace model briefly existed that co-located ISVCs with the KServe controller in one namespace. It was superseded by Design D after T19 surfaced that the upstream pod-mutator webhook's `namespaceSelector: control-plane DoesNotExist` guard filters out the runtime-control ns (which carries `control-plane: kserve-controller-manager` label inherited from upstream's Namespace manifest at `p-kserve-raw/04-kserve-core/kserve-core.yaml:1-8`). Storage-initializer was never injected, predictor crashed. See [`design-d-three-namespace-model.md`](design-d-three-namespace-model.md) for the full ADR including alternatives considered and rejected (strip the label / drop the manifest / etc).

**Historical note (build-time flag):** A build-time `--operator-namespace=<ns>` flag briefly existed (commit `0ef4d9d`) — removed in `cbe9838` because deploy-time env vars dominate it in flexibility and two parallel ways to set the same thing creates customer confusion.

### Pure deploy-time symmetry

As of the `install-operator-deployment.sh` wrapper, **all three deploy paths support deploy-time namespace selection** without rebuilding the package:

| Path | Mechanism | Deploy command |
|---|---|---|
| **Option A (OLM)** | OLM rewrites the CSV's namespaced resources at install time | `OPERATOR_NS=<ns> bash deploy-bundle.sh <secret>` (or `operator-sdk run bundle --namespace=<ns>` directly) |
| **Option B (Direct YAML)** | Wrapper script does Python YAML walk before `kubectl apply -f -` | `OPERATOR_NAMESPACE=<ns> bash install-operator-deployment.sh` |
| **Option C (install.sh)** | install.sh's existing Python rewrite handles KServe manifests | (Operator not deployed; the operator-namespace concept doesn't apply) |

The Option B wrapper's rewrite categories are intentionally smaller than `install.sh`'s (no Certificate `dnsNames`, no `inject-ca-from` annotations, no Webhook `clientConfig` — `operator-deployment.yaml` has none of those):
1. `kind == "Namespace"` AND `metadata.name == <baked>` → rename
2. `metadata.namespace == <baked>` (SA, Role, RoleBinding, Service, Deployment) → rewrite
3. `(Cluster)RoleBinding.subjects[].namespace == <baked>` → rewrite

When `OPERATOR_NAMESPACE` matches the baked-in default (or is unset), the rewrite short-circuits and `stdin → stdout` passes through verbatim — byte-equivalent to `kubectl apply -f operator-deployment.yaml`.

---

## 10. Glossary

| Term | Meaning |
|------|---------|
| **CR** (Custom Resource) | An instance of a CRD. Here: a `KServeRawMode` object that asks the operator to install KServe. |
| **CRD** (Custom Resource Definition) | The schema that defines a custom kind. Cluster-scoped. |
| **CSV** (ClusterServiceVersion) | An OLM manifest describing an operator's metadata, RBAC, and supported install modes. |
| **OperatorGroup** | An OLM object that says "this operator watches these namespaces." Lives in the operator's namespace. |
| **Install mode** | A category of OperatorGroup geometry: OwnNamespace, SingleNamespace, MultiNamespace, AllNamespaces. |
| **OLM** (Operator Lifecycle Manager) | A Kubernetes-native subsystem that installs and updates operators from bundle images. |
| **Bundle** | A container image that packages an operator's CSV, CRDs, and metadata for OLM consumption. |
| **InferenceService (ISVC)** | A KServe CR that defines a model serving endpoint. Creates predictor pods in its own namespace. |

---

## 11. Resolved design decisions

After review, the team committed to these answers (now reflected in the implementation):

| Decision | Choice | Rationale |
|---|---|---|
| `spec.kserveNamespace` field on the CRD | **Dropped entirely.** | The CR's `metadata.namespace` is the single source of truth — a separate spec field would only invite confusion (which one wins on mismatch?). Pre-1.0 branch, no users in the wild. |
| Operator pod's namespace | **Hardcoded to `kserve-operator-system`.** | Predictable, well-known location decoupled from the Go project directory name (the `-t` flag still controls the project dir, but the runtime ns is constant). Deploy commands in QUICK_START.md become guaranteed-correct rather than coincidentally-right. |
| Standalone `install.sh` (no-operator path) | **Accepts `KSERVE_NAMESPACE` env var, default `kserve`.** | Symmetric with the operator path. The script rewrites `namespace: kserve` references in the bundled manifests on the way to `kubectl`, anchored on YAML field syntax to avoid touching identifiers like `kserve-controller-manager` or image refs like `kserve/agent:latest`. |
