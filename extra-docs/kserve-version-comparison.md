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
- **T31** (cluster-based regression guard): deploys a negative case (webhook rejection expected) plus a positive case (`Standard` + `hpa` annotations → deploy succeeds). If upstream ever loosens the validator, this test fails and this section stops rotting. **The exact negative-case annotation differs by KServe version — see the two subsections below.**
- **T32** (no-cluster static guard): greps `p-kserve-raw/04-kserve-core/kserve-core.yaml` and `p-kserve-raw/06-sample-model/sklearn-iris.yaml` to confirm both say `"Standard"` and neither says `"RawDeployment"`.

### ConfigMap default flip side effect: implicit scaleMetric validation (discovered 2026-07-10 on v0.16, expanded 2026-07-11 on v0.17)

**Correction to the "Downstream user impact: none" claim originally made above** — there is one real, subtle effect worth documenting, and it evolved between v0.16.0 and v0.17.0.

Upstream KServe has a **defaulting (mutating) webhook** at `pkg/apis/serving/v1beta1/inference_service_defaults.go` that touches the `serving.kserve.io/deploymentMode` annotation before the validating webhook ever sees it. Combined with the validator dispatcher's inner `switch` on `autoscalerClass` (§ "Root cause" above), which has **no `default` case** for the `"Standard"` branch, this produces a behavioral difference where `scaleMetric` validation is silently skipped whenever the annotation ends up as `"Standard"` with no `autoscalerClass` set.

**v0.16.0 behavior (discovered 2026-07-10):** the defaulting webhook only stamps `deploymentMode: "Standard"` onto ISVCs that have **NO** `deploymentMode` annotation at all (`!ok` branch), and only when the ConfigMap's own default is `"Standard"`/`"ModelMesh"`:

```go
// v0.16.0 — pkg/apis/serving/v1beta1/inference_service_defaults.go:158-166
deploymentMode, ok := isvc.ObjectMeta.Annotations[constants.DeploymentMode]
if !ok {
    if deployConfig.DefaultDeploymentMode == string(constants.ModelMeshDeployment) ||
        deployConfig.DefaultDeploymentMode == string(constants.Standard) {
        isvc.ObjectMeta.Annotations[constants.DeploymentMode] = deployConfig.DefaultDeploymentMode
    }
}
```

An ISVC with an **explicit** legacy annotation (`deploymentMode: "RawDeployment"`) is left untouched by this logic — it survives to the validator as `"RawDeployment"`, which is not the literal string `"Standard"`, so it correctly falls into the dispatcher's `default:` branch and gets KPA-validated (i.e. `scaleMetric: cpu` is correctly rejected). This is why v0.16's T31 negative case uses an explicit `RawDeployment` annotation.

**v0.17.0 behavior (discovered 2026-07-11 — this is new, not present in v0.16.0):** upstream added a **normalization step** that runs even when the annotation IS present:

```go
// v0.17.0 — pkg/apis/serving/v1beta1/inference_service_defaults.go:157-169
deploymentMode, ok := isvc.Annotations[constants.DeploymentMode]
if ok {
    if deploymentMode == string(constants.LegacyRawDeployment) {
        isvc.Annotations[constants.DeploymentMode] = string(constants.Standard)
        deploymentMode = string(constants.Standard)
    }
    if deploymentMode == string(constants.LegacyServerless) {
        isvc.Annotations[constants.DeploymentMode] = string(constants.Knative)
        deploymentMode = string(constants.Knative)
    }
}
// ...then the same !ok branch as v0.16 for ConfigMap-default filling...
```

This means on v0.17, **any** ISVC with an explicit `deploymentMode: "RawDeployment"` annotation is unconditionally rewritten to `"Standard"` before the validator ever runs — regardless of the ConfigMap's own default value. **The v0.16 workaround (explicit `RawDeployment` annotation) no longer produces a rejection on v0.17** — it now silently passes through unvalidated, the same loophole as the annotation-less case. Verified directly on this project's v0.17.0 build: `kubectl apply` of an ISVC with `deploymentMode: "RawDeployment"` + `scaleMetric: cpu` succeeded and reached `Ready` with no rejection.

**v0.17's T31 negative case uses `deploymentMode: "ModelMesh"` instead** — this value is not in upstream's normalization list (only `RawDeployment`→`Standard` and `Serverless`→`Knative` are rewritten), so it survives unmodified to the validator, correctly misses the `"Standard"` case in the dispatcher switch, falls into `default:`, and gets KPA-validated (`scaleMetric: cpu` correctly rejected with the exact `[cpu] is not a supported metric` message). Confirmed working via T31 on the v0.17.0 build.

**Downstream user impact, corrected for each version:**
- **v0.16.0:** users whose charts hardcode `serving.kserve.io/deploymentMode: "RawDeployment"` continue to get scaleMetric validated as before. Users whose charts set no `deploymentMode` annotation at all lose the implicit validation.
- **v0.17.0 (this is a real behavior change from v0.16.0, not a regression in this project):** users whose charts hardcode `serving.kserve.io/deploymentMode: "RawDeployment"` **also** lose the implicit scaleMetric validation now, because upstream normalizes the annotation to `"Standard"` before the validator runs. Practically this is still believed to be low-impact — no legitimate chart should be relying on webhook rejection as its testing strategy — but it means the "explicit RawDeployment annotation still gets validated" mitigation documented for v0.16 does **not** carry forward to v0.17. This is purely an upstream KServe behavior change between the two releases; nothing in this project's generator or ConfigMap patching caused it.
- **v0.18.0 (re-verified fresh during the v0.18 upgrade, 2026-07-12):** the normalization list is **unchanged from v0.17.0** — still only `RawDeployment`→`Standard` and `Serverless`→`Knative`, confirmed by re-reading `inference_service_defaults.go:163-186` in the v0.18.0 source before running T31 (not assumed to carry over blindly — each version bump re-checks this file fresh). v0.17's `deploymentMode: "ModelMesh"` T31 negative-case recipe continues to work unchanged on v0.18: `ModelMesh` is still not in the normalization list, survives to the validator unmodified, correctly misses the `"Standard"` dispatcher case, and gets KPA-validated (`scaleMetric: cpu` rejected with the exact `[cpu] is not a supported metric` message). Confirmed via T31 on the v0.18.0 build.

## Downstream chart compatibility: v0.17 → v0.18

**New in v0.18.0 (not present in v0.17.0 or earlier):** upstream added a blocked-environment-variable admission validator that rejects any container setting `PYTHONPATH`.

### Symptom

```
admission webhook "inferenceservice.kserve-webhook-server.validator" denied the request:
    setting PYTHONPATH in container "kserve-container" is not allowed for security reasons
```

### Root cause

New file `pkg/validation/env_policy.go`:

```go
// v0.18.0 — pkg/validation/env_policy.go:25-43
var DefaultBlockedEnvVars = []string{
    "PYTHONPATH",
}

func ValidateBlockedEnvVars(containers []corev1.Container, blockedVars []string) error {
    blocked := make(map[string]bool, len(blockedVars))
    for _, v := range blockedVars {
        blocked[v] = true
    }
    for _, container := range containers {
        for _, env := range container.Env {
            if blocked[env.Name] {
                return fmt.Errorf("setting %s in container %q is not allowed for security reasons", env.Name, container.Name)
            }
        }
    }
    return nil
}
```

Called from two admission paths, both confirmed in the v0.18.0 source:
- `pkg/apis/serving/v1beta1/inference_service_validation.go:200` — `validateBlockedEnvVars(isvc)`, checking `Spec.Predictor.Containers` + `InitContainers` + `WorkerSpec.Containers`/`InitContainers`, plus `Spec.Transformer`/`Spec.Explainer` containers.
- `pkg/webhook/admission/servingruntime/servingruntime_webhook.go:270` — the same check for `ServingRuntime`/`ClusterServingRuntime` `Spec.Containers` + `Spec.WorkerSpec.Containers`.

This is a genuinely new upstream restriction, not a rename or normalization of an existing behavior — any InferenceService, ServingRuntime, or ClusterServingRuntime manifest that previously set `PYTHONPATH` at the container-env level (valid on v0.17 and earlier) is now rejected outright on v0.18.

### Who this hits

Users with a custom predictor, transformer, or explainer image that relies on a runtime `PYTHONPATH` override (commonly to point at a vendored `site-packages` directory, or to work around an import-path quirk) set via the Kubernetes container `env:` field rather than baked into the image.

### Fix

Move the `PYTHONPATH` value into the image itself — either a Dockerfile `ENV PYTHONPATH=...` line, or an `export PYTHONPATH=...` inside the container's own entrypoint/startup script. The validator only inspects the Kubernetes-level `container.Env` list; it has no visibility into an image's baked-in environment.

### Effect on our own project

No impact on the shipped `kserve-raw-base/sklearn-iris.yaml.tmpl` sample — it sets no `PYTHONPATH`. No generator code changes required; this is purely a new upstream admission-time constraint that downstream users of the built operator may need to adapt to, same shape as the v0.15→v0.16 scaleMetric break.

Coverage locked in:
- **T33** (cluster-based regression guard, new for v0.18): deploys a negative case (`PYTHONPATH` set on the predictor container → webhook rejection expected, exact message verified) plus a positive case (no `PYTHONPATH` → deploy succeeds, inference returns `{"predictions":[1]}`). If upstream ever removes or loosens this validator, T33 fails and this section stops rotting.

Full test execution record: `extra-docs/0.18-test-report.md` §T33. Full memory record: [[kserve-017-to-018-pythonpath-env-block]].
