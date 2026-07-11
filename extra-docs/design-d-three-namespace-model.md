# ADR: Design D — Three-Namespace Model for the KServe Operator

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-05-22 |
| **Decision drivers** | Real bug surfaced during T19 (storage-initializer never injected when ISVC deployed in same namespace as KServe controller); cloud-native architectural conventions; alignment with upstream KServe's mental model |
| **Supersedes** | Design C ("two-namespace model: operator-home + KServe target ns where ISVCs also live") |

---

## 1. Context

During the cluster-reset re-run of test T19 (`install-operator-deployment.sh` default-flow byte-equivalence + e2e), an iris `InferenceService` deployed into the same namespace as the KServe controller (`kserve`) crashed with:

```
kserve.errors.ModelMissingError
FileNotFoundError: [Errno 2] No such file or directory: '/mnt/models'
```

Diagnosis: the predictor pod was created **without an init container**. The storage-initializer that fetches the model from `gs://kfserving-examples/...` was never injected.

### Root cause

Upstream KServe's release manifest (`kserve-source/install/v0.18.0/kserve.yaml:1-8`) ships a `Namespace` manifest carrying three labels:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    control-plane: kserve-controller-manager
    controller-tools.k8s.io: "1.0"
    istio-injection: disabled
  name: kserve
```

The same block lives byte-for-byte in our generated `p-kserve-raw/04-kserve-core/kserve-core.yaml:1-8`. Our `generate-kserve-raw.sh` is a pure pass-through; neither it nor `install.sh`/`apply.go` adds or strips this label.

The KServe `inferenceservice.kserve-webhook-server.pod-mutator` MutatingWebhookConfiguration is configured with:

```yaml
namespaceSelector:
  matchExpressions:
  - key: control-plane
    operator: DoesNotExist
objectSelector:
  matchExpressions:
  - key: serving.kserve.io/inferenceservice
    operator: Exists
```

The `namespaceSelector` is upstream's **anti-self-injection guard** — it prevents the webhook from being applied to namespaces that hold KServe's own controllers. When a user deploys an ISVC into the labeled `kserve` namespace, the namespace selector filters the webhook out entirely → no init container injected → predictor crashes on missing `/mnt/models`.

### Why prior tests didn't catch this

Phase-1 exploration of `extra-docs/0.16-test-report.md` confirmed: in **every** test from T01 through T16, the iris apply command was an unqualified `kubectl apply -f sklearn-iris.yaml` (no `-n` flag). That resolved to the kubectl context default namespace, which is `default`. The `default` namespace has no `control-plane` label, so the webhook fired and storage-initializer was injected.

T07 even sets `namespace: default` explicitly in inline YAML.

T19 was the **first test** that intentionally followed Design C's invariant ("ISVCs live in the KServe target ns") and put the iris ISVC in `kserve`. The bug surfaced immediately.

### Why Design C is unfixable as-stated

Design C said: "two namespaces of ours — operator-home + KServe target — both configurable at deploy time; user workloads (ISVCs) live in the KServe target ns alongside the controller."

That invariant fights upstream KServe's mental model. Upstream assumes the controller's namespace is reserved for the controller and user workloads live elsewhere. The webhook configuration encodes that assumption with the `control-plane DoesNotExist` guard.

Three sub-optimal ways to make Design C work were considered and rejected:

1. **Strip the `control-plane` label** from the Namespace manifest in `rewrite_ns()` and `apply.go`. Fights upstream; every KServe release we'd re-verify the guard still works the way we patched around. Maintenance burden grows linearly with KServe releases.
2. **Drop the Namespace manifest entirely** from the apply stream. Same fragility class as (1). Slightly cleaner code.
3. **Document "don't deploy ISVCs in runtime-control ns"** without changing the topology. Asymmetric: default `kserve` ns is broken, custom `servewell` ns "works" because `kubectl create namespace servewell` doesn't carry the label and `rewrite_ns()` only touches `metadata.namespace` not `metadata.name` (so the upstream `Namespace: kserve` manifest creates a *stray* labeled `kserve` ns alongside `servewell`, but the user's workloads are in label-clean `servewell`). Hidden contradiction.

---

## 2. Decision

Adopt the **three-namespace model (Design D)**.

| # | Role | Default name | Override env var (deploy-time) | Owner | Singleton/Plural | What lives there |
|---|---|---|---|---|---|---|
| 1 | **Operator-home** | `kserve-operator-system` | `OPERATOR_NAMESPACE` / `OPERATOR_NS` / `SYSTEM_NS` *(existing)* | Platform / SRE | Singleton per cluster | `p-kserve-operator-controller` Deployment + its RBAC + pull secret |
| 2 | **Runtime-control** | `kserve` | `KSERVE_NS` / `KSERVE_NAMESPACE` *(existing)* | Platform / SRE | Singleton per cluster | `kserve-controller-manager`, webhooks, the `KServeRawMode` CR; cluster-scoped resources (CRDs, ClusterServingRuntimes) are logically owned here. **(Project scope is now core-only — `llmisvc-controller-manager` and `kserve-localmodel-controller-manager` are filtered out at build time.)** |
| 3 | **Workload** *(NEW)* | `default` | **`KSERVE_WORKLOAD_NS`** *(NEW; comma-separated list supported)* | App team / data scientist | **Plural-allowed** | `InferenceService`, predictor pods, model PVCs, app Secrets |

**Rule:** no resource of ours (operator, KServe controllers, webhooks, CRDs) lives in role #3. No user workload lives in role #1 or #2.

**Default-of-defaults UX:** user runs nothing → operator in `kserve-operator-system`, runtime in `kserve`, workloads in `default`. Matches the de facto behavior every prior test exhibited; the deviation was Design C's stated invariant, not the tests.

---

## 3. Rationale — cloud-native architectural first principles

Industry convention (Istio, Knative, Cert-Manager, Argo, Tekton, Flux, GKE Config Connector, the broader OperatorHub ecosystem) treats *runtime-control* namespaces and *workload* namespaces as architecturally distinct concerns. The split exists because:

1. **Blast radius.** A bug in a user workload (OOM, runaway predictor, bad RBAC) shouldn't be one `kubectl delete ns` away from nuking the controller that serves every other team's workloads.
2. **RBAC granularity.** App teams get edit rights on their own workload ns. Cluster admins get edit on the runtime-control ns. If both live in the same ns, that line can't be drawn.
3. **Quota and limits.** ResourceQuotas on the workload ns shouldn't squeeze the controller's headroom.
4. **NetworkPolicy.** Control plane traffic (webhook calls, ConfigMap reads) and data plane traffic (model fetches, prediction RPCs) want different policies. Mixing them complicates policy authoring.
5. **Independent upgrade lifecycles.** Upgrade the controller (runtime-control ns) without re-deploying workloads (workload ns). Faster rollback.
6. **Multi-tenant readiness.** One control plane → many workload namespaces is the natural multi-tenant story. Design D unblocks it for free (Design C painted us into single-tenant).
7. **Alignment with upstream KServe.** The pod-mutator `namespaceSelector: control-plane DoesNotExist` guard exists because upstream assumes workloads live elsewhere. Working *with* upstream costs nothing; working *against* it costs every release.

---

## 4. Consequences

### Positive

- **Zero changes** to `apply.go.tmpl`, `install.sh.tmpl`, `kserve-source/`, or `kserve-operator-base/` Go templates.
- **The bug fix is a side effect of correct architecture** — we don't patch around upstream, we stop violating its assumptions.
- **Multi-tenant workload onboarding** via `KSERVE_WORKLOAD_NS=team-a,team-b` comma-separated lists.
- **Default UX is identical** to what users observed before: iris in `default` ns, controller in `kserve`. We codify the de facto pattern.

### Neutral / costs

- One new env var (`KSERVE_WORKLOAD_NS`) and one new flag (`--also-workload-ns`) to document.
- `setup-credentials.sh` heredoc grows by ~25 lines (env var declaration, IFS comma-split, fail-fast pre-flight loop, pull-secret-placement gate).
- Doc sweep: ~10 files, ~150 line edits — mostly adding `-n "${KSERVE_WORKLOAD_NS:-default}"` to existing `kubectl apply` examples that historically had no `-n`.
- Pull-secret placement gated on `--customer-registry`: if absent, pull secret is created only in `SYSTEM_NS` (where operator + bundle pods live). Public images don't need pull secrets in the workload ns. Opt-in escape hatch via `--also-workload-ns` flag for the rare private-predictor-image case.

### Negative

- One more thing for the user to know about. Mitigated by: (a) good defaults (`default` works without setting anything), (b) ADR + memory file as canonical reference, (c) consistent naming with the other two ns env vars.

---

## 5. Alternatives considered (rejected)

| Alternative | Why rejected |
|---|---|
| **(A) Strip the `control-plane` label** in `rewrite_ns()` + `apply.go` | Fights upstream. Re-verify every KServe release. Permanent divergence. Bug fix that doesn't address the underlying architectural mismatch. |
| **(B) Drop the Namespace manifest entirely** from the apply stream | Same fragility class as (A). Slightly cleaner code but same maintenance debt. |
| **(C) Keep Design C; document "don't deploy ISVCs in runtime-control ns"** | Asymmetric: default `kserve` ns broken (label inherited from upstream Namespace manifest); custom `servewell` ns "works" because `kubectl create namespace` doesn't carry the label and `rewrite_ns` doesn't touch `metadata.name`. Hidden contradiction; future user will trip on it. |
| **(D) Comma-separated `KSERVE_WORKLOAD_NS` from day one (CHOSEN)** | Trivial in bash (`IFS=',' read -ra`); avoids future contract break when a customer asks for multi-team support; single-ns case stays simple. |

---

## 6. Non-goals (explicitly out of scope)

- **Tenant RBAC isolation.** Design D *enables* multi-namespace workloads but does not provide tenant isolation. The KServe controller has cluster-scoped RBAC on `inferenceservices`; any user with `create` rights in a workload ns can deploy. Operators wanting per-team isolation should layer their own `Role`/`RoleBinding` on `inferenceservices.serving.kserve.io` per workload ns. This is a customer-deployment concern, not a generator concern.
- **Per-team OperatorGroup auto-management.** A customer wanting "one operator, N teams, isolated webhook configs" can build their own OperatorGroup with `AllNamespaces` install-mode (already supported by upstream OLM). Not for this commit.
- **Cluster-scoped resource ownership labeling.** CRDs and ClusterServingRuntimes are cluster-scoped; assigning them a "namespace" is metaphorical. Documented as "logically owned by runtime-control ns" without enforcement.

---

## 7. Implementation summary

See `/Users/akashdeo/.claude/plans/i-want-you-to-adaptive-bonbon.md` for the full execution plan. Key touchpoints:

- **`generate-kserve-operator.sh`** — setup-credentials.sh heredoc + generator-level override table + `--help` update. ~30 line delta.
- **`extra-docs/architecture-namespaces.md`** — superseded in place: § 7 + § 9 rewritten as Design D; Design C kept as historical subsection pointing here.
- **`QUICK_START.md`** + **`package-readme.md.tmpl`** + **`generate-kserve-operator-README.md`** + **`gaps-and-observations.md`** + **`0.16-test-report.md`** — doc sweep adding `-n "${KSERVE_WORKLOAD_NS:-default}"` to every ISVC apply example; T20 reframed as 3-way flagship; T22 split into T22a (1-ns) and T22b (multi-ns). (LLMISVC-GUIDE.md and LOCAL-MODEL-CACHE-GUIDE.md were later deleted with the llmisvc + localmodel controller removal.)
- **Memory consolidation** — canonical `namespace_design.md`; `operator_namespace_configurability.md` shrunk to a redirect stub.

---

## 8. References

- **Upstream Namespace manifest with offending label:** `kserve-source/install/v0.18.0/kserve.yaml:1-8` (verified pass-through to `p-kserve-raw/04-kserve-core/kserve-core.yaml:1-8`).
- **Pod-mutator webhook config with the namespaceSelector guard:** `MutatingWebhookConfiguration inferenceservice.serving.kserve.io`, webhook `inferenceservice.kserve-webhook-server.pod-mutator`, `namespaceSelector.matchExpressions[0]`.
- **Live differential test results (this session):** iris in `default` → Ready 27s, inference returns `{"predictions":[1]}`. iris in `kserve` → predictor `CrashLoopBackOff`, no init container, `FileNotFoundError: /mnt/models`.
- **Prior in-flight architecture doc:** `extra-docs/architecture-namespaces.md` (Design C — to be superseded).
- **Session transcript:** `~/.claude/projects/-Users-akashdeo-kserve-op/752a310c-6990-4a92-9145-8ddbf4faa550.jsonl`.
- **Plan file:** `~/.claude/plans/i-want-you-to-adaptive-bonbon.md`.
- **Related memory files:** `namespace_design.md` (canonical post-D), `webhook_failurepolicy_semantics.md`, `install_sh_namespace_rewrite.md`.

---

## 9. Decision log entry

> **2026-05-22 — Design D adopted.** Architect: Akash Deo. Trigger: T19 storage-initializer-not-injected bug in `kserve` ns. Three-namespace model with new `KSERVE_WORKLOAD_NS` env var (comma-separated, default `default`). Zero `kserve-source/` edits. Zero `apply.go.tmpl` edits. Aligns with upstream KServe + cloud-native conventions. Multi-tenant story unblocked; RBAC isolation deferred as non-goal.
