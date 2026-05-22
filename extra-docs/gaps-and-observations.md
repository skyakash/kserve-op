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

**Adjacent variant — FIXED in commit `95ffc69` (Follow-up B):** The same `ensureDefaultCR()` retry loop previously gave up after 5 attempts (~30 s total). If a customer started the operator pod BEFORE creating the KServe target namespace, the retry would exhaust and the same rollout-restart recovery was needed. Now the loop retries indefinitely with exponential backoff capped at 30 s — once the namespace appears (even hours later), the next retry succeeds. This fix addresses the "namespace created after operator startup" variant but **does NOT** address the "user deleted the CR after it reached Ready" variant above — that's still a documented design choice.

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

## Good first issues — priority for contributors

The 5 "Real gaps" above are all open. Ranked by **return-on-investment** (impact / effort) for someone picking up the codebase:

| Rank | Gap | Why this ROI | Effort | Independent of other work? |
|---|---|---|---|---|
| 🥇 #1 | **No shellcheck on bash scripts** (Real-gap #5) | A single GitHub Actions workflow file gets static analysis on every PR; catches the kind of bugs we hand-fixed during the 0.16 cycle (e.g. Issue #8's `read` on closed stdin, mode-flag arg parsing). Low-risk, high-leverage, no domain knowledge required. | ~1 hour | ✅ Yes — pure CI hardening |
| 🥈 #2 | **Controller unit tests are stubs** (Real-gap #3) | Operator-sdk scaffold stubs need real assertions for the 5-phase reconcile pipeline + `ensureDefaultCR` + cert-manager pre-flight. High coverage gain; protects against regression in the most complex code we own. Requires Go + envtest familiarity. | ~1 day | ✅ Yes — purely additive to `kserve-operator-base/` |
| 🥉 #3 | **No golden-file tests on stage-1 generator output** (Real-gap #4) | The inline Python YAML walks in `generate-kserve-raw.sh` produce ~3 MB of patched manifests. A `diff -r` against a checked-in `testdata/golden/` directory would catch any unintended template-output drift. Bash + Python knowledge; no Go required. | ~3 hours | ✅ Yes — checked-in fixture + a CI step |
| #4 | **Deleted CR is not auto-recreated** (Real-gap #2 / Issue #9) | Could add a watch on `KServeRawMode` deletion events that re-fires `ensureDefaultCR()`. Currently a documented design choice; depends on whether the maintainer wants "delete CR = self-heal" semantics (some prefer "delete = intentional teardown"). UX improvement, requires design call first. | ~half a day | ⚠️ Requires design decision before code |
| #5 | **NetworkPolicy ns-rewriting (latent)** (Real-gap #1) | Latent until KServe upstream starts shipping NetworkPolicies. Adding a 6th category to `rewriteEmbeddedNamespaceRefs()` is mechanical (mirror an existing category). Low impact today; future-proofing. | ~1 hour | ✅ Yes — small targeted edit |

**Recommended starter path for a new contributor:**
1. **Pick #1 (shellcheck CI)** — gets you familiar with the bash scripts, the priority list, and the CI surface in one shot. Low risk of breaking anything.
2. **Then #3 (golden-file tests)** — natural follow-up; you'll have already learned the script outputs.
3. **Then #2 (controller unit tests)** — most impactful but requires more onboarding to Go + envtest + the reconcile semantics. Best after you've absorbed the codebase via #1 and #3.

Items #4 and #5 are stretch goals — wait until you've shipped the first three.

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

### Design C → Design D pivot: workload namespace separated from runtime-control — FIXED
**Symptom (T19 attempt, 2026-05-22):** After cluster reset and a fresh build, iris ISVC deployed via `kubectl -n kserve apply -f sklearn-iris.yaml` crashed with `FileNotFoundError: /mnt/models`. The predictor pod had no `storage-initializer` init container.

**Root cause:** Upstream KServe ships a `Namespace` manifest with label `control-plane: kserve-controller-manager` (`p-kserve-raw/04-kserve-core/kserve-core.yaml:1-8`, byte-for-byte pass-through from `kserve-source/install/v0.16.0/kserve.yaml`). The pod-mutator webhook `inferenceservice.kserve-webhook-server.pod-mutator` has `namespaceSelector: control-plane DoesNotExist` (upstream's anti-self-injection guard). When ISVCs land in the same namespace as the KServe controller (Design C's stated invariant), the webhook is filtered → storage-initializer never injected.

T01–T16 passed historically because every `kubectl apply -f sklearn-iris.yaml` was unqualified (no `-n`) and landed in `default`, which has no `control-plane` label. T19 was the first test that intentionally put an ISVC in `kserve` ns per Design C's invariant.

**Fix:** Adopted Design D — three-namespace model (operator-home + runtime-control + workload). New env var `KSERVE_WORKLOAD_NS` (comma-separated, default `default`) on `setup-credentials.sh`. ISVCs explicitly deployed in `-n "${KSERVE_WORKLOAD_NS:-default}"`. Zero `apply.go.tmpl` / `kserve-source/` changes — we stop violating upstream's assumption instead of patching around it. Pull-secret placement gated on `--customer-registry` (or `--also-workload-ns` opt-in) so public images don't get over-provisioned secrets in workload ns. Multi-tenant workload onboarding via `KSERVE_WORKLOAD_NS=team-a,team-b` unblocked. Full ADR: [`design-d-three-namespace-model.md`](design-d-three-namespace-model.md).

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

### `setup-credentials.sh` OLM-namespace coupling — FIXED (refined further to Design-C-aligned 2-namespace footprint)

**Original symptom (T04 in `0.16-test-report.md`):** `setup-credentials.sh` pre-flight unconditionally required `olm` + `operators` namespaces (created by `operator-sdk olm install`). **Option B users** (direct manifest deploy via `kubectl apply -f operator-deployment.yaml`, no OLM) skipped that step and hit fail-fast pre-flight errors. T04 only worked because its operator image was public; a customer-registry build with a private image would have blocked Option B entirely.

**Initial fix:** Added a `--non-olm` flag to skip OLM-namespace checks AND skip creating secrets in `olm`/`operators`.

**Subsequent refinement (post-review of namespace footprint):** Investigation against the live T12-LIKE cluster proved that **no production code path consumes pull secrets in `olm` or `operators`** — they were created defensively but never used. Deleting them from a 18-hour-running cluster left the operator + KServe + iris ISVC healthy (verified). The `olm` and `operators` namespaces are **OLM infrastructure** (per `architecture-namespaces.md` § 9), not ours.

**Cleaned-up behavior:** `setup-credentials.sh` now creates pull secrets in exactly **2 namespaces** (`default` + the operator's `${SYSTEM_NS}`), regardless of OLM or non-OLM deploy path. Both Option A and Option B users use the same `bash setup-credentials.sh --user X --pass Y` invocation — no flag distinguishes them. `--non-olm` is preserved as a silently-accepted **deprecated no-op** for backwards compatibility with earlier CI scripts. QUICK_START.md Step 3 + the 3-deploy-path comparison table updated to reflect the 2-namespace Design-C footprint honestly. New § 9 in `architecture-namespaces.md` explicitly distinguishes "namespaces we own" from "OLM infrastructure namespaces." Validated live: the script's only behavior change is the absence of `Creating pull secret 'dockerhub-creds' in namespace 'olm/operators'` lines — no functional regression.

### LocalModelCache `localModel.defaultJobImage` ConfigMap setting not honored — WORKAROUND IN PLACE (upstream still open)
**Symptom (T14):** ConfigMap correctly carries `localModel.defaultJobImage: "kserve/storage-initializer:v0.16.0"` (verified both in the embedded YAML and in the live cluster), but the localmodelnode controller's default-container fallback path ignores it and uses `kserve/storage-initializer:latest`. Filed-but-not-actioned upstream defect.

**Root cause:** `pkg/controller/v1alpha1/localmodelnode/controller.go:175-203` (`getContainerSpecForStorageUri`) iterates `ClusterStorageContainer` instances; if none matches, falls back to a default container that hardcodes `kserve/storage-initializer:latest` (line ~199) instead of consulting `LocalModelConfig.DefaultJobImage` from the ConfigMap.

**Workaround in place (side-effect of Issue #2 fix):** The shipped air-gap sample at `kserve-raw-base/airgap-localmodelcache/06-clusterstoragecontainer-s3.yaml` defines a `ClusterStorageContainer` with `workloadType: localModelDownloadJob` AND explicit `image: kserve/storage-initializer:v0.16.0`. When a `ClusterStorageContainer` matches the cache's URI prefix, the controller honors its image — bypassing the broken ConfigMap-fallback path entirely. **For online (`gs://`) flows that depend on the default container, the issue remains visible** but the impact is small (`:latest` is currently equivalent to `:v0.16.0` upstream; would only diverge on a future tag mismatch). If/when that's a real problem, ship a parallel `ClusterStorageContainer` for `gs://` with the pinned image as a one-line follow-up sample. Upstream filing recommended once we're ready to engage KServe maintainers.

### Build-time `--operator-namespace` flag removed; deploy-time-only namespace selection — DONE
**Symptom:** Two parallel ways existed to customize the operator's home namespace — a build-time `--operator-namespace=<ns>` flag (commit `0ef4d9d`) AND deploy-time env vars (`OPERATOR_NAMESPACE` on the wrapper, `OPERATOR_NS` on `deploy-bundle.sh`, `SYSTEM_NS` on `setup-credentials.sh`). User feedback during T18 prep flagged this as confusing: "which one do I use? what happens if I set both?"

**Resolution:** Removed the build-time flag entirely. The baked default in all generated artifacts is now the canonical `kserve-operator-system`. Customers customize **at deploy time only** via the env vars listed above. Generator's `OPERATOR_NAMESPACE` variable, the `--operator-namespace` case-statement entry, the help-text line, and the three placeholder-substitution blocks (`__SYSTEM_NS__`, `__OPERATOR_NS__`, `__OPERATOR_NS_DEFAULT__`) are all gone. Heredocs inline `kserve-operator-system` directly.

**Validated live:** generator rejects `--operator-namespace=foo` ("Unknown parameter"). Default-flag build produces 9 `kserve-operator-system` refs in `operator-deployment.yaml`. Deploy-time `OPERATOR_NAMESPACE=ops-custom KSERVE_NS=servewell bash install-operator-deployment.sh --dry-run` still produces 9 `ops-custom` refs (wrapper rewrite works unchanged). One namespace-selection story, zero confusion.

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
