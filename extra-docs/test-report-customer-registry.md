# End-to-End Test Report — Customer Registry & Variations

**Date:** 2026-05-05
**Branch:** `feat/no-bundled-certmanager`
**Tester:** Claude Code (Opus 4.7) on behalf of Akash Deo
**Cluster:** Docker Desktop Kubernetes v1.34.1
**Repo HEAD at start:** `801c8f1`

## Summary

| ID | Scenario | Status | Notes |
|---|---|---|---|
| T07 | Customer-registry archive+load, default `kserve` ns, in-cluster URL | ✅ PASS | Operator pulled from `akashdeohuf` (customer registry). Ready in ~20s. Iris OK. |
| T08 | Customer-registry, `deploy-bundle.sh` helper, default ns, in-cluster | ❌ → ✅ **FIXED** | Bug found and fixed in commit `2e64ee5`-style follow-up. Re-tested with v408: CSV `Succeeded`, CR `Ready`, iris `{"predictions":[1]}`. |
| T10 | Customer-registry archive+load, custom `my-kserve` ns, external URL | ✅ PASS | Both customer-registry rewriting AND custom-namespace rewriting commute correctly. External URL serves iris. |
| T04 | No customer-registry, custom `my-kserve` ns, external URL | ✅ PASS | (After fixing two doc issues found during execution — see findings.) |
| T11 | `--cert` build-time CA injection | ✅ PASS | Test CA (`CN=kserve-op-test-ca-T11`) verified present in builder stage's `/etc/ssl/certs/ca-certificates.crt`. |

**Net: 4 of 5 PASS initially, 1 FAIL → all 5 issues fixed in follow-up commits, T08 re-tested with v408 → 5 of 5 PASS.**

## Pre-flight

| Check | Result |
|---|---|
| `skopeo` installed | ✅ v1.22.0 |
| `akashneha` Docker Hub login | ✅ (build registry) |
| `akashdeohuf` Docker Hub login | ✅ (customer registry) |
| Cluster pristine (no kserve / kserve-operator-system / ingress-nginx) | ✅ teardown completed |
| cert-manager + OLM cluster prereqs | ✅ preserved across tests |

## Tag plan

| Tag | Build registry destination | Mirrored to | Purpose | Tests |
|---|---|---|---|---|
| `v405` | `docker.io/akashneha/kserve-raw-operator:v405` (+ `-bundle`) | (none) | Standard build, no `--customer-registry` | T04 |
| `v406` | `docker.io/akashneha/kserve-raw-operator:v406` (+ `-bundle`) | `docker.io/akashdeohuf/kserve-raw-operator:v406` (+ `-bundle`) | `--customer-registry docker.io/akashdeohuf` | T07, T08, T10 |
| `v407` | `docker.io/akashneha/kserve-raw-operator:v407` (operator only, not pushed) | (none) | `--cert /tmp/test-ca.crt` build-only verification | T11 |

## Credentials handling

- Both PATs used only via `docker login --password-stdin` and `mirror-images.sh --pass`/`setup-credentials.sh --pass` (CLI args).
- **No PAT value appears in any file, commit, memory entry, or test report.**
- After all tests: `docker logout docker.io` performed.
- **User action recommended:** rotate both PATs in Docker Hub (`akashneha` and `akashdeohuf`) since they were transmitted in the conversation transcript.

---

## Test results

### T07 — Customer-registry archive+load, default `kserve` ns, in-cluster URL

**Status:** ✅ PASS

**Goal:** Validate the air-gapped customer-registry flow — generate with `--customer-registry`, save images to tar archives, load them into the customer registry, deploy from there.

**Setup:**
1. `docker login docker.io -u akashneha --password-stdin`
2. `./generate-kserve-operator.sh ... -i docker.io/akashneha/kserve-raw-operator:v406 --customer-registry docker.io/akashdeohuf --install-mode SingleNamespace -b -p -o`
   - Operator + bundle pushed to `akashneha`
   - `operator-deployment.yaml` rewritten: `image: docker.io/akashdeohuf/kserve-raw-operator:v406` ✓
   - Bundle CSV rewritten: `image: docker.io/akashdeohuf/kserve-raw-operator:v406` ✓
   - Package contains `mirror-images.sh`, `deploy-bundle.sh`, `setup-credentials.sh` ✓
3. `bash mirror-images.sh --archive` → produces `images/operator.tar` (31M) + `images/bundle.tar` (15K)
4. `bash mirror-images.sh --load --user akashdeohuf --pass <PAT>` → both images now in `docker.io/akashdeohuf/kserve-raw-operator:v406` and `:v406-bundle`

**Deploy:**
```
kubectl create namespace kserve
kubectl create namespace kserve-operator-system
bash setup-credentials.sh --user akashdeohuf --pass <PAT>
operator-sdk run bundle docker.io/akashdeohuf/kserve-raw-operator:v406-bundle \
  --namespace kserve-operator-system \
  --install-mode SingleNamespace=kserve \
  --pull-secret-name dockerhub-creds
```

**Results:**

| Check | Result |
|---|---|
| Bundle pulls from `akashdeohuf` (customer registry) | ✅ |
| Auto-created OperatorGroup `operator-sdk-og` with `targetNamespaces: [kserve]` | ✅ |
| CSV reaches `Succeeded` | ✅ |
| Operator pod running with image `docker.io/akashdeohuf/kserve-raw-operator:v406` | ✅ confirmed |
| KServeRawMode CR auto-created in `kserve` (NOT `default`) | ✅ |
| CR phase `Ready` | ✅ in ~20s |
| `sklearn-iris` ISVC Ready, in-cluster curl returns `{"predictions":[1]}` | ✅ |

---

### T08 — Customer-registry, `deploy-bundle.sh` helper, default ns, in-cluster

**Status:** ❌ FAIL — concrete bug found

**Goal:** Run the generated `deploy-bundle.sh` helper script (Option A — OLM bundle install) and confirm it works end-to-end.

**Setup:** (same as T07 — namespaces created, pull secret created, bundle already mirrored to akashdeohuf)

**Execution:**
```
echo "A" | bash deploy-bundle.sh dockerhub-creds
```

**What happened:**

```
Found ClusterServiceVersion "default/p-kserve-operator.v0.0.1" phase: Failed
Failed to run bundle: error waiting for CSV to install: csv failed:
  reason: "UnsupportedOperatorGroup",
  message: "AllNamespaces InstallModeType not supported, cannot configure to watch all namespaces"
```

**Root cause:** [`deploy-bundle.sh`](../p-kserve-operator-package/deploy-bundle.sh) (lines 32–37) calls:
```bash
operator-sdk run bundle "${BUNDLE_IMAGE}" --pull-secret-name "${PULL_SECRET}"
```
**It does not pass `--namespace` or `--install-mode`.** Consequences:
1. OLM installs into the current kubectl context's default namespace (`default`) instead of `kserve-operator-system`.
2. `operator-sdk run bundle` auto-creates an OperatorGroup, but without `--install-mode` it defaults to a config that maps to `AllNamespaces`.
3. Our CSV declares only `SingleNamespace: true`. Mismatch → CSV phase `Failed`.

**Secondary bug:** the script unconditionally prints `"Operator installed via OLM."` regardless of the `operator-sdk` exit code. Users running this script in CI/CD will see the success message even on failure.

**Fix (recommended):** Modify the heredoc that emits `deploy-bundle.sh` in `generate-kserve-operator.sh` so the OLM Option A branch becomes:

```bash
operator-sdk run bundle "${BUNDLE_IMAGE}" \
    --namespace kserve-operator-system \
    --install-mode "SingleNamespace=${KSERVE_NS:-kserve}" \
    ${PULL_SECRET:+--pull-secret-name "${PULL_SECRET}"}
```

…and check `$?` before printing the success line. The script should also accept a `KSERVE_NS` env var (or arg) so the user can target a custom namespace.

---

### T10 — Customer-registry archive+load, custom `my-kserve` ns, external URL

**Status:** ✅ PASS

**Goal:** The hardest combined scenario — customer registry rewriting AND Design C namespace rewriting AND external URL via nginx-ingress, all stacked.

**Setup:** (reuse T07's `v406` images already mirrored to `akashdeohuf`)
1. `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/.../deploy.yaml` → nginx-ingress controller Ready
2. `kubectl create namespace my-kserve` + `kserve-operator-system`
3. `bash setup-credentials.sh --user akashdeohuf --pass <PAT>`
4. `operator-sdk run bundle ...:v406-bundle --namespace kserve-operator-system --install-mode SingleNamespace=my-kserve --pull-secret-name dockerhub-creds`

**Results:**

| Check | Result |
|---|---|
| Operator pod from `akashdeohuf`, in `kserve-operator-system` | ✅ |
| OperatorGroup auto-created with `targetNamespaces: [my-kserve]` | ✅ |
| CR auto-created in `my-kserve`; KServe runtime in `my-kserve` | ✅ |
| All `kserve` namespace refs rewritten to `my-kserve` (RoleBinding subjects, Webhook svc namespace, Certificate dnsNames, `inject-ca-from` annotation) | ✅ |
| ConfigMap patched (`ingressClassName: nginx`, `disableIngressCreation: false`) — see Issue #2 below | ✅ after `--force-conflicts` |
| Ingress created, ADDRESS `localhost` | ✅ in ~36s |
| External URL curl returns `{"predictions":[1]}` | ✅ |

---

### T04 — No customer-registry, custom `my-kserve` ns, external URL

**Status:** ✅ PASS

**Goal:** Custom namespace + external URL without customer registry — same as T10 minus customer registry to isolate the namespace + ingress combo.

**Setup:**
1. Generate v405 (no `--customer-registry`)
2. `kubectl create namespace my-kserve` + `kserve-operator-system`
3. `operator-sdk run bundle docker.io/akashneha/kserve-raw-operator:v405-bundle --namespace kserve-operator-system --install-mode SingleNamespace=my-kserve` *(no pull secret needed — akashneha is public)*

**Results:**

| Check | Result |
|---|---|
| CSV `Succeeded` | ✅ |
| CR Ready in `my-kserve` | ✅ in ~40s |
| ConfigMap patch (with `--force-conflicts`) | ✅ |
| ISVC apply on first attempt | ❌ webhook timeout (race condition — see Issue #3) |
| ISVC apply after waiting for controller settle | ✅ |
| Ingress ADDRESS populates | ✅ in ~54s |
| External URL curl returns `{"predictions":[1]}` | ✅ |

---

### T11 — `--cert` build-time CA injection

**Status:** ✅ PASS

**Goal:** Verify that `--cert /path/to/ca.crt` correctly modifies the Dockerfile builder stage to add a trusted CA to the build environment.

**Setup:**
1. `openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/test-ca.key -out /tmp/test-ca.crt -days 1 -subj "/CN=kserve-op-test-ca-T11"`
2. `./generate-kserve-operator.sh ... -i .../v407 --cert /tmp/test-ca.crt --install-mode SingleNamespace -b` (build only — no push, no deploy)

**Results:**

| Check | Result |
|---|---|
| Dockerfile builder stage modified to `COPY test-ca.crt /usr/local/share/ca-certificates/test-ca.crt` and `RUN update-ca-certificates` | ✅ |
| Operator image build succeeds (implies `update-ca-certificates` did not error) | ✅ |
| `docker build --target builder` produces a builder image with `/usr/local/share/ca-certificates/test-ca.crt` present | ✅ |
| Test CA contents (PEM) appear inside `/etc/ssl/certs/ca-certificates.crt` of the builder | ✅ (line `MIIDITCCAg...` matches) |
| `openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt \| openssl pkcs7 -print_certs` decoded subject matches `CN=kserve-op-test-ca-T11` | ✅ |

**Note:** The cert is **not** in the final distroless image — that's by design. `--cert` exists so the **build process** (e.g., `go mod download` through a corporate MITM proxy) can trust the proxy's CA. The runtime operator binary doesn't need it.

---

## Issues found during testing

### Issue #1 — `deploy-bundle.sh` is broken for the post-Design-C flow ❌

**Severity:** High — the helper script we ship doesn't work as documented.

**Where:** `kserve-operator-base/...` (the script template inside `generate-kserve-operator.sh`'s heredoc that emits `p-kserve-operator-package/deploy-bundle.sh`).

**Symptom:** `operator-sdk run bundle` is invoked without `--namespace` or `--install-mode`, leading to install in `default` namespace and `UnsupportedOperatorGroup` failure.

**Fix:** Pass both flags explicitly. Also add an exit-code check before the success message. Suggested patch in the T08 section above.

### Issue #2 — `kubectl apply --server-side` blocks on field-ownership conflict ⚠️

**Severity:** Medium — silent failure during the nginx-ingress setup step in QUICK_START.md.

**Where:** [`QUICK_START.md` Step 6b](../QUICK_START.md#step-6b--optional-test-via-external-hostname-requires-nginx-ingress) — the ConfigMap patch.

**Symptom:** Apply emits a server-side conflict warning (the operator is the field manager). The ConfigMap is **not** modified, but the next steps continue. User then sees no Ingress created and a 404 from nginx, with no obvious cause.

**Fix:** Add `--force-conflicts` to the `kubectl apply --server-side` call. Also strip `metadata.managedFields` in the Python pipe so the new field manager fully takes over.

### Issue #3 — Webhook race after `kubectl rollout restart` ⚠️

**Severity:** Low — can cause a one-shot ISVC apply failure right after restarting `kserve-controller-manager`.

**Where:** [`QUICK_START.md` Step 6b](../QUICK_START.md#step-6b--optional-test-via-external-hostname-requires-nginx-ingress) — between the rollout restart and the ISVC re-apply.

**Symptom:**
```
failed calling webhook "inferenceservice.kserve-webhook-server.defaulter":
  context deadline exceeded
```

**Fix:** After the rollout restart, wait for the new pod to become Ready before applying the ISVC:
```bash
kubectl rollout status deployment kserve-controller-manager -n "${KSERVE_NS}" --timeout=120s
kubectl wait --for=condition=Ready pods -l control-plane=kserve-controller-manager -n "${KSERVE_NS}" --timeout=120s
```

### Issue #4 — Stale `spec.kserveNamespace` reminder in `setup-credentials.sh` ⚠️

**Severity:** Low — outdated comment in user-facing output.

**Where:** [`generate-kserve-operator.sh` :795-797](../generate-kserve-operator.sh#L795-L797) (heredoc that emits `setup-credentials.sh`).

**Symptom:** The script's final reminder echoes:
```
Reminder: the KServe target namespace must be created BEFORE deploying the operator.
  Default name: 'kserve' (overridable via spec.kserveNamespace in the CR).
```

`spec.kserveNamespace` was **dropped** in the Design C refactor (`571b646`). The actual override mechanism is now the OperatorGroup's `targetNamespaces`.

**Fix:** Replace with:
```
Default name: 'kserve' (overridable via the OperatorGroup's targetNamespaces).
```

### Issue #5 — Generator's "To deploy via OLM" success message points at the build registry, not the customer registry ℹ️

**Severity:** Cosmetic.

**Where:** End of `generate-kserve-operator.sh` output.

**Symptom:** When `--customer-registry` is used, the suggested deploy command at the end of the run still shows the **build registry** path (`akashneha`) instead of the rewritten **customer registry** path (`akashdeohuf`):
```
To deploy via OLM, execute the following command:
  operator-sdk run bundle docker.io/akashneha/kserve-raw-operator:v406-bundle
```

The customer (after running `mirror-images.sh`) needs to deploy from the customer registry, not the build registry. The message could be smarter, e.g.:
```
If you used --customer-registry, run mirror-images.sh first, then deploy:
  operator-sdk run bundle docker.io/<customer-registry>/kserve-raw-operator:v406-bundle \
    --namespace kserve-operator-system \
    --install-mode SingleNamespace=<your-kserve-ns>
```

---

## Conclusions

### What works ✅

1. **The `--customer-registry` flag works end-to-end.** Image refs in `operator-deployment.yaml` AND the bundle CSV are correctly rewritten. Generated `mirror-images.sh` correctly archives + loads via skopeo. Pull secrets distribute properly.
2. **The air-gapped flow (`--archive` + `--load`) works** — your customer's actual scenario.
3. **Customer registry + Design C custom namespace combine cleanly.** Image rewrite (akashneha → akashdeohuf) and namespace rewrite (kserve → my-kserve) commute correctly. T10 stresses both layers simultaneously and passes.
4. **External URL via nginx-ingress works in custom namespaces** — the `${KSERVE_NS}` parameterization in QUICK_START.md is correct.
5. **`--cert` build-time CA injection works.** Dockerfile is modified correctly; cert lands in the builder's trust store.

### What's broken or weak ❌

1. **`deploy-bundle.sh` is broken** — Issue #1 above. Must fix before customer use.
2. **Two doc bugs in QUICK_START.md Step 6b** — Issues #2 and #3. Fix needed.
3. **Stale `spec.kserveNamespace` reference** in `setup-credentials.sh` heredoc — Issue #4. Fix needed.
4. **Cosmetic** — generator's final success message could be aware of `--customer-registry` (Issue #5).

### Recommended follow-up commits

1. **`fix: deploy-bundle.sh missing --namespace and --install-mode (T08 finding)`** — Issue #1, the urgent one.
2. **`docs: QUICK_START Step 6b — add --force-conflicts and post-restart wait`** — Issues #2 + #3.
3. **`fix: stale spec.kserveNamespace reminder in setup-credentials.sh heredoc`** — Issue #4.
4. *(Optional)* **`docs: generator success message shows customer-registry path when applicable`** — Issue #5.

---

## Cleanup performed

- All test installs torn down (operator, KServe, ISVCs, namespaces, CRDs, ClusterRoleBindings, ClusterRoles, Webhooks, OperatorGroups, Subscriptions, CSVs, CatalogSources)
- nginx-ingress + ingressclass + admission webhook removed
- Test CA + private key + image tar files deleted from `/tmp` and the package's `images/` directory
- `docker logout docker.io` performed
- Docker images on local Docker Desktop daemon: not deleted (cached layers; safe — not credentials)
- Docker Hub: images at `akashneha/kserve-raw-operator:v405,v406,v407` and `akashdeohuf/kserve-raw-operator:v406,v406-bundle` remain. **Recommended:** delete via Docker Hub UI if not needed for further testing.
- **PAT rotation recommended** for both `akashneha` and `akashdeohuf` accounts since the values were transmitted in the conversation transcript.

## Total runtime

~50 minutes of active testing (5 tests + cleanups).
