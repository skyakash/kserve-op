# KServe Version Compatibility Report: master vs release-0.16

_Date: 2026-05-20_

## TL;DR

**The pipeline will run to completion on release-0.16, but the output is materially different from master and will likely fail at cluster deploy time.** The blocking issue is that 0.16's `config/default/kustomization.yaml` bundles three extra subsystems (`localmodels`, `localmodelnodes`, `llmisvc`) into the core build that master deliberately leaves out. This adds Deployments and DaemonSets that depend on additional container images not present in the operator package.

**Recommendation: do not swap to release-0.16 without modifying `generate-kserve-raw.sh` to either (a) prune the extra subsystems post-build, or (b) build a narrower kustomize target.**

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
