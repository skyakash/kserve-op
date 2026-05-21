# Gaps and Observations — kserve-op

_Last updated: 2026-05-21 (after the 17-test 0.16 validation run and the 8-issue fix cycle — see `0.16-test-report.md` for per-issue traceability)._

---

## Real gaps — implementation

### 1. NetworkPolicy namespace rewriting (latent)
`rewriteEmbeddedNamespaceRefs()` in `apply.go.tmpl` handles ClusterRoleBinding subjects, WebhookConfiguration service namespaces, and cert-manager Certificate DNS names — but does **not** handle `NetworkPolicy.spec.ingress[].from[].namespaceSelector` or `egress[].to[].namespaceSelector`.

KServe does not currently ship NetworkPolicies, so this is latent. If that changes upstream, affected policies will apply with the wrong namespace selector and fail silently.

### 2. Deleted CR is not auto-recreated *(validated by T17 — Issue #9 in test report)*
`ensureDefaultCR()` creates the default CR once on startup. If a user deletes it, KServe continues running but the operator stops reconciling — no more phase updates, no retry on drift. The operator treats deletion as intentional and stays silent. This is a UX trap given the auto-init makes the CR feel fully managed.

**Confirmed during T17 (2026-05-20):** after `kubectl delete kserverawmode kserve-rawmode`, the CR is gone, the operator pod has unchanged uptime, KServe controllers keep Running, and operator logs show no reaction. Recovery is a manual `kubectl rollout restart deploy/<operator>-controller-manager` which re-triggers `ensureDefaultCR()`. Logged as a documented design choice; no in-branch fix planned.

---

## Real gaps — testing

### 3. Controller unit tests are stubs
`kserverawmode_controller_test.go` (generated from the template) only creates and deletes a CR. The implementation is proven correct by E2E, but there is no automated coverage to catch regressions in:
- The 5-phase reconcile pipeline
- The `CertManagerNotFound` error path
- Generation tracking (`ObservedGeneration` skips redundant reconciles)
- `ensureDefaultCR()` auto-init logic

Tests should be added to the templates in `kserve-operator-base/` so they regenerate into every operator build.

### 4. No golden-file tests on stage-1 generator output
`generate-kserve-raw.sh` produces the right ConfigMap patches and namespace rewrites (confirmed by E2E), but nothing enforces this across future runs. Template drift or a regression in the inline Python patch would go undetected until cluster deployment.

### 5. No shellcheck on bash scripts
None of the bash scripts (`generate-kserve-raw.sh`, `generate-kserve-operator.sh`, `mirror-images.sh`, `setup-credentials.sh`, `deploy-bundle.sh`, `enable-ingress.sh`) are statically analysed. They work correctly but there is no CI gate to catch errors before runtime.

---

## Confirmed non-gaps (closed after E2E validation)

| Item | Outcome |
|---|---|
| Design C namespace rewriting completeness | `servewell` run: all refs rewritten correctly with zero code changes — ClusterRoleBinding subjects, WebhookConfig service namespaces, cert-manager DNS names |
| Hard-coded 5-minute pod readiness wait | Ready in ~43s on the second run; nowhere near the limit |
| cert-manager pre-flight not waiting for webhook readiness | Both runs succeeded cleanly; reconcile retry loop absorbs any transient startup window |
| Auto-init CR placement | CR appeared in the correct namespace (`servewell`) immediately after OLM injected `WATCH_NAMESPACE` |

---

## Recently fixed (post-0.16 validation)

### `install.sh` sed-based namespace rewrite broken for custom `KSERVE_NAMESPACE` — FIXED
**Symptom (T03 in `0.16-test-report.md`):** `KSERVE_NAMESPACE=servewell ./install.sh` failed at stage 4 with an x509 SAN mismatch — webhook config got rewritten but cert-manager Certificate `dnsNames`/`commonName` did not, so the cert's SAN didn't match the new webhook DNS.

**Root cause:** `rewrite_ns()` in `kserve-raw-base/install.sh.tmpl` used a single sed regex that only matched scalar `namespace: kserve` lines. It missed (a) cert-manager `inject-ca-from` annotations, (b) `(Cluster)RoleBinding subjects[].namespace`, (c) `WebhookConfiguration webhooks[].clientConfig.service.namespace`, (d) `Certificate spec.commonName` and `spec.dnsNames[]`.

**Fix:** Replaced the sed body with an inline Python heredoc that does a structured YAML walk mirroring `apply.go`'s `rewriteEmbeddedNamespaceRefs()` + `rewriteSvcDNSNamespace()` byte-for-byte. Default-namespace flow is preserved via a `TARGET == BAKED` short-circuit (stdin passes through verbatim — T02 stays bit-identical). Added a pre-flight check requiring `python3` + `PyYAML` on the install host (already a build prereq; now also a runtime prereq for `install.sh`).

### Offline LocalModelCache sample using unsupported `pvc://` URI — FIXED
**Symptom (T14 in `0.16-test-report.md`):** Our shipped "air-gapped LocalModelCache" sample used `sourceModelUri: pvc://...`. The download Job failed with `Cannot recognize storage type for pvc://...` and the cache reached `NodeDownloadError`. The GUIDE's "Air-gapped flow (pvc://)" section walked customers through a path that cannot work on KServe v0.16.0.

**Root cause:** KServe v0.16.0's LocalModelCache download path only supports `s3://`, `gs://`, `http(s)://`, `abfs://` (see `kserve-source/pkg/agent/storage/provider.go:26-36` — `SupportedProtocols`). `pvc://` is for the regular ISVC predictor-pod storage-initializer, NOT for the LocalModelCache download Job. The two storage-initializer code paths handle different URI sets.

**Fix:** Deleted the three broken `localmodelcache-offline-*-sample.yaml.tmpl` files. Added a new self-contained `kserve-raw-base/airgap-localmodelcache/` sub-directory shipping an in-cluster Minio (`s3://`) recipe: Minio Deployment + bootstrap Job + S3 credentials Secret + a `ClusterStorageContainer` with `workloadType=localModelDownloadJob` carrying `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` + `AWS_ENDPOINT_URL=http://minio.minio.svc:9000` env wiring + the LocalModelCache and ISVC. Rewrote `LOCAL-MODEL-CACHE-GUIDE.md`'s air-gap section. Added T14-RETEST to the test report.

### `enable-ingress.sh` webhook race after controller restart — FIXED
**Symptom (T06 + T12 in `0.16-test-report.md`):** `enable-ingress.sh` did `kubectl rollout restart` + `kubectl wait --for=condition=Ready pods` and then returned. The next `kubectl apply` of an ISVC raced the freshly-started controller pod and failed with `failed calling webhook "inferenceservice.kserve-webhook-server.defaulter": context deadline exceeded`. Both T06 and T12 needed a manual `sleep 20` to unblock — i.e. pod Ready ≠ webhook Ready.

**Root cause:** The controller's `readinessProbe` targets the HTTP health endpoint on port 8081, which flips Ready well before the webhook HTTPS server on port 9443 starts listening. The "correct" upstream fix would be to also probe 9443, but that would touch `kserve-source/`-derived manifests — which is a hard rule in this repo (we treat upstream as read-only).

**Fix:** In `generate-kserve-operator.sh`'s heredoc that emits `enable-ingress.sh`, inserted an in-cluster probe between the existing `kubectl wait` and the success-echo. Probe spawns `kubectl run -n ${KSERVE_NS} --image=curlimages/curl:8.10.1 --restart=Never --rm --attach` and loops `curl --silent --insecure --max-time 3 https://kserve-webhook-server-service:443/` up to 30 × 2 s = 60 s. Any HTTP response (TLS handshake completed) = success. Replaces the `sleep 20` workaround with a deterministic signal. Self-contained — no new host-side dependency on the customer's machine (kubectl already required). See T06-RETEST.

### LocalModelCache chown ordering on hostpath dev clusters — FIXED
**Symptom (T13 + T14-RETEST in `0.16-test-report.md`):** On hostpath-backed dev clusters (Docker Desktop, kind, minikube), the documented "chown the hostpath once, then apply LocalModelCache" sequence failed. The localmodel-agent (root) creates `models/<cache>/` subdirs AFTER the initial chown, leaving them root-owned; the download Job (UID 1000) then hit `PermissionError: '/mnt/models/model.joblib.…'` and the cache went to `NodeDownloadError`. Both T13 and T14-RETEST needed manual re-chown rounds + Job deletions to retry.

**Root cause:** A single chown can't close the race because the agent populates subdirs on its own cadence as the cache fetch progresses. The GUIDE's previous "run chown AFTER apply" instruction was still wrong — the agent's subdir creation continues for tens of seconds after the user's "after-apply" chown.

**Fix:** Shipped a **continuous-chown DaemonSet** at `kserve-raw-base/chown-hostpath-helper-sample.yaml.tmpl` → `06-sample-model/chown-hostpath-helper.yaml`. One Pod per labeled worker (`nodeSelector: kserve/localmodel=worker`), runs `chown -R 1000:1000 /host-models; sleep 30` in a loop until the user deletes it. Idempotent — each iteration after the first is a no-op. Rewrote `LOCAL-MODEL-CACHE-GUIDE.md` Prereqs § 4 to walk through it (apply before Cache CR, delete after cache reaches `NodeDownloaded`). Dev-only — production CSI clusters skip it.

### LocalModelCache ISVC deletion hangs on upstream KServe v0.16.0 finalizer bug — DOCS WORKAROUND SHIPPED
**Symptom (T15):** `kubectl delete isvc <name>` against an ISVC matching a LocalModelCache hangs indefinitely. ISVC enters `Terminating` with `deletionTimestamp` set but never disappears.

**Root cause (upstream defect):** Controller "Deleting external resources" reconcile triggers the defaulting webhook on the metadata update; defaulter re-injects the LocalModelCache PVC annotation; validating webhook fires on that update and rejects with `"deploymentMode cannot be changed from 'Standard' to 'RawDeployment'"`. Finalizer never clears.

**Fix scope:** Upstream filing is out-of-scope for this branch (we don't modify `kserve-source/`). Docs-only workaround shipped: new "Stuck ISVC cleanup" sub-section in `LOCAL-MODEL-CACHE-GUIDE.md` Troubleshooting documents the **5-step** recovery — flip `failurePolicy=Ignore` on both webhook configs → scale controller to 0 → patch finalizers → scale controller back up → restore `failurePolicy=Fail`. The naively-shorter 3-step "scale 0 → patch → scale 1" suggested in the test report **did not work** when validated during T15-RETEST: the API server's `failurePolicy: Fail` rejects any patch that times out trying to reach the webhook. `failurePolicy: Ignore` alone also doesn't work (it only admits **unreachable** webhooks, not webhooks that return a **deny** verdict). Both are needed: webhook unreachable + Ignore-on-failure = admit-as-no-op. When upstream KServe ships the real fix (defaulter should be a no-op for finalizer-only updates), this workaround can be removed.

### `generate-kserve-operator.sh` exit-1 after `-b` build masked `-o` bundle generation — FIXED
**Symptom (T08 + T09 in `0.16-test-report.md`):** `./generate-kserve-operator.sh ... -b` (or `-b -o`) printed `"The Operator container image '${IMAGE_TAG}' has been successfully built!"` and then exited 1 with no error message. With `-b -o`, the OLM-bundle block at line 406 never ran and `p-kserve-operator-package/` was never created — silently misleading CI/CD.

**Root cause:** The push block (`generate-kserve-operator.sh:388-404`) had only two branches: `AUTO_PUSH=true` → push, else `read -p "...?"`. When the script is invoked non-interactively (CI, piped stdin) with `-b` but no `-p`, the `read` returned exit code 1 on closed/non-TTY stdin, and `set -e` (line 8) killed the script before the OLM-bundle block could run. The bug was orthogonal to `--cert` / `--customer-registry` — those just happened to be set in T08/T09.

**Fix:** Added a third branch: when `AUTO_BUILD=true` but `AUTO_PUSH` is unset, set `PUSH_CHOICE="n"` and print `"Skipping image push (pass -p to push automatically)."` — never reach the `read`. Pre-existing happy paths (`-b -p`, `-b -p -o`) are byte-equivalent to before (`AUTO_PUSH=true` branch unchanged). Interactive flow (no `-b`) also unchanged. Validated live: T08-RETEST (`-b` alone) and T09-RETEST (`-b -o`) both exit 0; the OLM-bundle block runs for `-b -o`; `bundle.Dockerfile` + `clusterserviceversion.yaml` + bundle manifests all materialize.

### `setup-credentials.sh` OLM-namespace coupling blocked Option B users with private registries — FIXED
**Symptom (T04 in `0.16-test-report.md`):** `setup-credentials.sh` pre-flight unconditionally required `olm` + `operators` namespaces (created by `operator-sdk olm install` in QUICK_START Part B Step 1). **Option B users** (Step 4 Option B — direct manifest deploy via `kubectl apply -f operator-deployment.yaml`, no OLM) skip Step 1 and so hit a fail-fast pre-flight at Step 3 with `❌ Prerequisites not met: namespace 'olm' missing` + same for `operators`. T04 didn't actually need a pull secret (operator image is public), but a customer-registry build with a private image would block Option B entirely.

**Fix:** Added a `--non-olm` boolean flag to `setup-credentials.sh` (heredoc in `generate-kserve-operator.sh:825-925`). When set: pre-flight checks only the operator's `${SYSTEM_NS}`; secret creation runs only in `default` + `${SYSTEM_NS}`; success message reflects Option B mode; next-hint block points at `kubectl apply -f operator-deployment.yaml`. Also added an `-h|--help` block (the script previously had none). Existing flag set (`--user / --pass / --server`) unchanged; default behavior (no `--non-olm`) byte-equivalent to T04 for OLM users. QUICK_START.md Steps 3 + 4 updated to document the flag. Validated live in T04-RETEST: `--help` works, `--non-olm` correctly skips OLM checks + creates secrets in the right two namespaces, exit 0.

### LocalModelCache `localModel.defaultJobImage` ConfigMap setting not honored — WORKAROUND IN PLACE (upstream still open)
**Symptom (T14):** ConfigMap correctly carries `localModel.defaultJobImage: "kserve/storage-initializer:v0.16.0"` (verified both in the embedded YAML and in the live cluster), but the localmodelnode controller's default-container fallback path ignores it and uses `kserve/storage-initializer:latest`. Filed-but-not-actioned upstream defect.

**Root cause:** `pkg/controller/v1alpha1/localmodelnode/controller.go:175-203` (`getContainerSpecForStorageUri`) iterates `ClusterStorageContainer` instances; if none matches, falls back to a default container that hardcodes `kserve/storage-initializer:latest` (line ~199) instead of consulting `LocalModelConfig.DefaultJobImage` from the ConfigMap.

**Workaround in place (side-effect of Issue #2 fix):** The shipped air-gap sample at `kserve-raw-base/airgap-localmodelcache/06-clusterstoragecontainer-s3.yaml` defines a `ClusterStorageContainer` with `workloadType: localModelDownloadJob` AND explicit `image: kserve/storage-initializer:v0.16.0`. When a `ClusterStorageContainer` matches the cache's URI prefix, the controller honors its image — bypassing the broken ConfigMap-fallback path entirely. **For online (`gs://`) flows that depend on the default container, the issue remains visible** but the impact is small (`:latest` is currently equivalent to `:v0.16.0` upstream; would only diverge on a future tag mismatch). If/when that's a real problem, ship a parallel `ClusterStorageContainer` for `gs://` with the pinned image as a one-line follow-up sample. Upstream filing recommended once we're ready to engage KServe maintainers.

---

## Status summary (as of 2026-05-21)

All 9 issues surfaced during the 17-test 0.16 validation run have a landing:

| Issue | Severity | Status |
|---|---|---|
| #1 — install.sh structured ns rewrite | High | ✅ FIXED (T03-RETEST) |
| #2 — Offline LocalModelCache pvc:// sample | High | ✅ FIXED (T14-RETEST) |
| #3 — ISVC finalizer hang | High | ✅ DOCS WORKAROUND (T15-RETEST) |
| #4 — defaultJobImage ConfigMap | Medium | ⚠️ WORKAROUND via Issue #2's ClusterStorageContainer; upstream open |
| #5 — chown ordering on hostpath | Medium | ✅ FIXED (chown helper DaemonSet) |
| #6 — setup-credentials.sh OLM coupling | Medium | ✅ FIXED (T04-RETEST) |
| #7 — enable-ingress.sh webhook race | Medium | ✅ FIXED (T06-RETEST) |
| #8 — generator `-b` exit-1 | Medium | ✅ FIXED (T08-RETEST + T09-RETEST) |
| #9 — Deleted CR not auto-recreated | Low (design choice) | Documented; manual `kubectl rollout restart` to recover |

Real-gap items #1, #3, #4, #5 above (NetworkPolicy rewriting, controller unit-test stubs, no golden-file tests, no shellcheck) remain open — these are testing/CI gaps that don't surface during functional E2E, but matter for long-term regression hygiene. Tracking separately.
