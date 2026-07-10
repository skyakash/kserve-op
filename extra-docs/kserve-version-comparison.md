# KServe Version Compatibility Report: master vs release-0.16

_Date: 2026-05-20_

## TL;DR

**The pipeline will run to completion on release-0.16, but the output is materially different from master and will likely fail at cluster deploy time.** The blocking issue is that 0.16's `config/default/kustomization.yaml` bundles three extra subsystems (`localmodels`, `localmodelnodes`, `llmisvc`) into the core build that master deliberately leaves out. This adds Deployments and DaemonSets that depend on additional container images not present in the operator package.

> **RESOLVED (2026-05-23):** These extra subsystems are now **filtered out at extraction time** in `generate-kserve-raw.sh` (see the `DROP` dicts at the top of each kustomize step). The 0.16 build now contains only the core `kserve-controller-manager` — matching master's scope. The comparison points below remain as historical reference; the divergence they describe no longer affects our shipping artifacts.

**Recommendation (historical): do not swap to release-0.16 without modifying `generate-kserve-raw.sh` to either (a) prune the extra subsystems post-build, or (b) build a narrower kustomize target.** — **This recommendation has been implemented (option a).**

---

## Source versions

| Tree | Timestamp | Notes |
|---|---|---|
| `kserve-master` | Feb 24 2026 | Current production source; E2E-validated twice |
| `kserve-release-0.16` | Dec 2 2023 | Older release branch |

Both declare `version: "3"` in their `PROJECT` file (operator-sdk PROJECT version, not KServe version).

---

## Pipeline-relevant paths — diff summary

The pipeline ([generate-kserve-raw.sh](../generate-kserve-raw.sh)) runs four `kustomize build` operations: `config/crd`, `config/rbac`, `config/default`, `config/configmap`, `config/certmanager`, `config/runtimes`. Below is the status of each.

### 1. `config/crd/` — **MINOR**

Both versions have the same six core CRDs (`inferenceservices`, `servingruntimes`, `clusterservingruntimes`, `trainedmodels`, `inferencegraphs`, `clusterstoragecontainers`) plus localmodel CRDs.

**Difference:** 
- Master organizes localmodel CRDs into a `crd/full/localmodel/` subdirectory
- 0.16 places `serving.kserve.io_localmodelcaches.yaml`, `_localmodelnodegroups.yaml`, `_localmodelnodes.yaml` directly in `crd/full/`
- Master uses `controller-gen v0.19.0`; 0.16 uses `v0.16.2` — schemas in master have newer Kubernetes API fields (`fileKeyRef`, `restartPolicyRules`)
- Master adds llmisvc conversion webhook patches that 0.16 lacks

**Pipeline impact:** Both produce a valid CRD set. The schemas are syntactically compatible — Server-Side Apply tolerates the field differences.

---

### 2. `config/rbac/` — **COMPATIBLE**

Identical core RBAC files (auth_proxy_role, role, role_binding, service_account). Master adds `kustomization.yaml` files under `localmodel/` and `localmodelnode/` subdirectories, which are not included by the top-level `config/rbac/kustomization.yaml` either way.

**Pipeline impact:** None. Build output is functionally identical.

---

### 3. `config/default/` — **🚨 BREAKING**

This is the critical incompatibility. The `resources:` block differs significantly:

| Resource | master | 0.16 |
|---|---|---|
| `../crd` | ✅ | ✅ |
| `../rbac` | ✅ | ✅ |
| `../manager` | ✅ | ✅ |
| `../webhook` | ✅ | ✅ |
| `../certmanager/kserve` | ✅ | ❌ (uses `../certmanager` instead) |
| `../certmanager` | ❌ | ✅ |
| `../configmap` | ❌ (pipeline adds manually) | ✅ (already included) |
| `../localmodels` | ❌ | ✅ |
| `../localmodelnodes` | ❌ | ✅ |
| `../llmisvc` | ❌ | ✅ |

**0.16's build will include these extra workloads that master's does not:**
- `localmodel-controller-manager` Deployment + Service + RBAC
- `localmodel-agent` DaemonSet
- `llmisvc-controller-manager` Deployment + Service + RBAC
- Additional webhook config: `localmodelcache.serving.kserve.io` (ValidatingWebhookConfiguration)
- Additional patches: `localmodelcache_validatingwebhook_cainjection_patch.yaml`, `localmodel_manager_image_patch.yaml`, `localmodelnode_agent_image_patch.yaml`

**Pipeline impact:**
1. The generated `04-kserve-core/kserve-core.yaml` will be ~3x larger
2. Operator's `apply.go` will try to deploy these extras via Server-Side Apply
3. Their image references (`localmodel-manager`, `localmodel-agent`, `llmisvc-controller`) need to resolve in the target cluster — the customer registry workflow doesn't mirror these images
4. The new localmodelcache webhook needs its `service.namespace` rewritten — `apply.go`'s generic webhook handler will do this correctly, but the failure mode if the webhook can't reach its backend is hard cluster-wide

---

### 4. `config/configmap/inferenceservice.yaml` — **COMPATIBLE**

Both versions have the same JSON-stringified top-level keys (`deploy`, `ingress`, `storageInitializer`, `predictors`, etc.). The Python ConfigMap patch in `generate-kserve-raw.sh:143-173` will find and modify the correct keys in both versions.

Minor differences (master only):
- New field `s3CABundleConfigMap` in storageInitializer config (irrelevant to our patches)
- Cosmetic comment changes

**Pipeline impact:** Patch will succeed identically on both versions.

---

### 5. `config/certmanager/` — **COMPATIBLE**

Different file organization, equivalent output:
- Master: `issuer.yaml` (just the Issuer) + a `kserve/` subdirectory with `certificate.yaml`
- 0.16: a single `certificate.yaml` containing both Issuer and Certificate

The kustomization.yaml in each version references the right file. Both produce the same Issuer + Certificate pair after build.

**Pipeline impact:** None.

---

### 6. `config/runtimes/` — **MINOR**

Master ships 13 ClusterServingRuntimes; 0.16 ships 11. **Missing in 0.16:**
- `kserve-openvino.yaml`
- `kserve-predictiveserver.yaml`

The 11 common runtimes (sklearn, xgboost, lightgbm, pytorch, tensorflow, triton, huggingface, mlserver, paddle, pmml) are present in both. Minor schema differences in a few runtime files (probably image tag bumps).

**Pipeline impact:** The Iris test uses `sklearn` which exists in both. Users who need openvino or predictiveserver would be broken.

---

### 7. `config/manager/` — **COMPATIBLE**

The Deployment manifest is identical. Only `service.yaml` has minor differences (likely port label tweaks).

**Pipeline impact:** None.

---

## Will our build work on 0.16?

### Stage 1 (generate-kserve-raw.sh) — runs to completion ✅
All four kustomize builds will succeed. The Python ConfigMap patch will find its keys. Output files will be generated.

### Stage 2 (generate-kserve-operator.sh) — runs to completion ✅
The operator scaffold doesn't introspect the embedded manifests; it just embeds whatever Stage 1 produced.

### Cluster deploy — **likely fails ❌**
The auto-init CR will trigger reconcile. apply.go will try to apply:
- `localmodel-controller-manager` Deployment → ImagePullBackOff (image not in customer registry)
- `localmodel-agent` DaemonSet → ImagePullBackOff
- `llmisvc-controller-manager` Deployment → ImagePullBackOff
- `localmodelcache` ValidatingWebhookConfiguration → applies fine, but its backend pod is the failing localmodel-controller-manager. **The webhook may block ISVC creation cluster-wide** if it has failurePolicy: Fail.

### Iris inference test — **possibly blocked ❌**
Depending on whether the localmodelcache webhook intercepts InferenceService admission. If it's scoped only to localmodelcache resources (likely), the iris ISVC would still work. If it intercepts all serving.kserve.io resources, it would fail.

---

## What it would take to make 0.16 work

Three viable paths:

1. **Patch `generate-kserve-raw.sh` to fork the kustomization on the fly.** Before `kustomize build config/default`, write a temp overlay that strips `../localmodels`, `../localmodelnodes`, `../llmisvc` from the resources list. ~10 lines of bash + yq. Lowest risk.

2. **Post-build YAML filtering.** After `kustomize build`, parse the output and drop any document where `metadata.name` matches `^localmodel-` or `^llmisvc-` or where the kind is one of the localmodel/llmisvc-specific types. More fragile (regex on names).

3. **Add `--customer-registry` mirrors for localmodel + llmisvc images** and accept them as part of the install. Largest scope; turns the operator into a heavier deployment that includes features the team has not designed around.

---

## Three highest-risk items if 0.16 swap proceeds without modification

1. **localmodelcache ValidatingWebhookConfiguration failurePolicy** — could block all InferenceService creation cluster-wide if the localmodel-controller-manager pod (which backs the webhook) is in ImagePullBackOff
2. **localmodel-agent DaemonSet** schedules on every node; if image pull fails, every node has a failed pod, polluting `kubectl get pods -A`
3. **Operator's auto-init reconcile loop** — apply.go's pod-readiness wait is 5 minutes. With 3+ failing Deployments, every reconcile will time out, leaving the CR stuck in `InstallingCore` phase indefinitely

---

## Recommendation

Stay on `master` for now. If there is a business reason to use 0.16 (e.g., support contract, customer requirement), implement Option 1 above: modify Stage 1 to strip the extra subsystems from the default overlay. Re-run the same E2E test we just completed twice and confirm output parity with master.

---

## Downstream chart compatibility: v0.15 → v0.16 breaking change for user InferenceServices

**Added 2026-07-03** after a colleague reported an admission-webhook rejection while migrating a Helm chart (`nwdaf-model-0.2.1`) from a v0.15.x cluster to our v0.16 build. Same repro symptom pattern shows up regardless of infrastructure — this is pure upstream KServe behavior, not a project bug.

### Symptom

```
* admission webhook "inferenceservice.kserve-webhook-server.validator" denied the request:
    [cpu] is not a supported metric
```

After removing `scaleMetric: cpu` from the chart, the error mutates to `[memory] is not a supported metric` — the same block emits both.

### Root cause

Upstream KServe v0.15 → v0.16 renamed the deployment-mode string. From `kserve-source.v0.16/pkg/constants/constants.go:215`:

```go
LegacyRawDeployment DeploymentModeType = "RawDeployment"  // deprecated: use Standard
Standard            DeploymentModeType = "Standard"       // NEW canonical value
```

The admission validator's dispatcher in `kserve-source.v0.16/pkg/apis/serving/v1beta1/inference_service_validation.go:258` only matches the **new canonical string**:

```go
switch deploymentMode {
case string(constants.Standard):        // ← matches literal "Standard" ONLY
    switch autoscalerClass {
    case "hpa":  → HPA validator (cpu, memory both allowed)
    case "keda": → KEDA validator
    }
default:                                 // ← "RawDeployment", empty, anything else lands here
    if annotationClass == "hpa.autoscaling.knative.dev" {
        → HPA validator
    }
    → KPA validator (only concurrency, rps allowed)
}
```

The same `ComponentExtensionSpec` (which carries `scaleMetric` / `scaleTarget`) is embedded inline in **predictor, transformer, and explainer** specs (`predictor.go:73`, `transformer.go:28`, `explainer.go:37`). The validator iterates all three at `:138-140`. Any single component with `scaleMetric: cpu|memory` while dispatch annotations are missing triggers the error — which is why removing the field from just one block doesn't help.

### Who this hits

Charts written against KServe **v0.15.x** that hardcode `serving.kserve.io/deploymentMode: "RawDeployment"` together with `scaleMetric: cpu` or `scaleMetric: memory`. On v0.15 the string `"RawDeployment"` matched the HPA-routing case; on v0.16 it doesn't, so cpu/memory metrics get rejected.

The KServe sample charts (sklearn-iris, etc.) don't set `scaleMetric` at all — they use the default (`concurrency`), which is legal in the KPA branch. That's why the sample deploys clean while the user's chart trips.

### Two fix paths (chart-side)

**Fastest unblock** — strip the fields, let KServe use default concurrency-based scaling:

Delete every `scaleMetric:` and `scaleTarget:` line from the chart's `templates/inferenceservice.yaml` — **from both predictor AND transformer blocks** (and explainer if present). Repackage and reinstall.

**Proper fix** — modernize the annotations so cpu/memory-based scaling still works:

Edit the chart's `templates/inferenceservice.yaml` `metadata.annotations` block:

```yaml
metadata:
  annotations:
    serving.kserve.io/deploymentMode: "Standard"      # was "RawDeployment" — must be literal "Standard"
    serving.kserve.io/autoscalerClass: "hpa"          # required to dispatch to HPA validator
```

Both annotations must be present, and they must be on `metadata.annotations` — not `spec.predictor.annotations` (pod-template annotations are not read by the validator).

### Debug recipe for a stuck user

```bash
# Render the chart locally
helm template <release> <chart.tgz> -f values.yaml > /tmp/rendered.yaml

# Find every occurrence of cpu / memory / scaleMetric / autoscaler in the rendered manifest
grep -niE 'cpu|memory|scaleMetric|scaleTarget|autoscaling|autoscaler|deploymentMode' /tmp/rendered.yaml
```

The output reveals exactly which template line is emitting the offending metric — usually either a hardcoded `scaleMetric: cpu` or a Helm `default "cpu"` fallback the user wasn't aware of.

### Effect on our own project

Our `generate-kserve-raw.sh` now emits `defaultDeploymentMode: Standard` in the ConfigMap — the v0.16+ canonical value aligned with the upstream rename this section describes. Prior builds emitted `RawDeployment`, which the runtime controller still honors as a legacy alias for backwards-compat with existing user ISVCs. The alignment happened 2026-07-08 after a colleague migrating a v0.15-era Helm chart hit the `[cpu] is not a supported metric` webhook rejection above and confirmed the "Standard" fix worked in production.

Coverage locked in:
- **T31** (cluster-based regression guard): deploys a negative case (explicit `deploymentMode: "RawDeployment"` + `scaleMetric: cpu` → webhook rejection expected — see the discovery below for why this uses an *explicit* legacy annotation rather than an annotation-less ISVC) plus the positive case (`Standard` + `hpa` annotations → deploy succeeds). If upstream ever loosens the validator, this test fails and this section stops rotting.
- **T32** (no-cluster static guard): greps `p-kserve-raw/04-kserve-core/kserve-core.yaml` and `p-kserve-raw/06-sample-model/sklearn-iris.yaml` to confirm both say `"Standard"` and neither says `"RawDeployment"`.

### ConfigMap default flip side effect: implicit scaleMetric validation (discovered 2026-07-10)

**Correction to the "Downstream user impact: none" claim originally made above** — there is one real, subtle effect worth documenting.

Upstream KServe has a **defaulting (mutating) webhook** at `pkg/apis/serving/v1beta1/inference_service_defaults.go:158-166` that copies the ConfigMap's `defaultDeploymentMode` onto any ISVC that doesn't set the `serving.kserve.io/deploymentMode` annotation explicitly — **but only when that ConfigMap value is `"Standard"` or `"ModelMesh"`**:

```go
deploymentMode, ok := isvc.ObjectMeta.Annotations[constants.DeploymentMode]
if !ok {
    if deployConfig.DefaultDeploymentMode == string(constants.ModelMeshDeployment) ||
        deployConfig.DefaultDeploymentMode == string(constants.Standard) {
        isvc.ObjectMeta.Annotations[constants.DeploymentMode] = deployConfig.DefaultDeploymentMode
    }
}
```

Combined with the validator dispatcher's inner `switch` on `autoscalerClass` (§ "Root cause" above), which has **no `default` case** for the `"Standard"` branch, this produces a behavioral difference:

| ConfigMap default | ISVC with NO explicit `deploymentMode` annotation, `scaleMetric: cpu` |
|---|---|
| `"RawDeployment"` (pre-flip) | Defaulter does nothing (condition doesn't match) → dispatcher sees empty `deploymentMode` → `default` branch → KPA validator → **`cpu` REJECTED** |
| `"Standard"` (post-flip, current) | Defaulter stamps `deploymentMode: "Standard"` → dispatcher matches `"Standard"` case → inner switch on empty `autoscalerClass` has no match and **no default** → function returns `nil` → **`cpu` PASSES UNVALIDATED** |

**In plain terms:** before our flip, any ISVC that didn't set an explicit annotation got its `scaleMetric` implicitly validated via the KPA path (only `concurrency`/`rps` allowed). After our flip, that same ISVC's `scaleMetric` is **not validated at all** unless the user also sets an explicit `autoscalerClass` annotation. This is **more permissive, not more restrictive** — nothing that used to work now breaks — but the implicit safety net that used to catch invalid `scaleMetric` values on annotation-less ISVCs is gone.

**Downstream user impact of our flip, corrected:** users whose charts hardcode the legacy `serving.kserve.io/deploymentMode: "RawDeployment"` string continue to work exactly as before (this explicit annotation still routes to the `default` branch regardless of the ConfigMap value — confirmed by T31's redesigned negative case). Users whose charts set **no `deploymentMode` annotation at all** and rely on implicit validation to catch scaleMetric typos will find that validation is now silently skipped. This is not believed to be a practical problem (no legitimate chart should be relying on webhook rejection as its testing strategy), but it's worth knowing if debugging a scenario where an invalid `scaleMetric` value doesn't get caught post-flip.

This is upstream KServe's own defaulting logic, not a kserve-op bug — no code change needed on our side. Documented here for completeness since it was discovered while validating the flip.
