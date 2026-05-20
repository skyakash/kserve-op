# Gaps and Observations — kserve-op

_Last updated: 2026-05-20 (reassessed after two successful E2E runs: namespace `kserve` and `servewell`)_

---

## Real gaps — implementation

### 1. NetworkPolicy namespace rewriting (latent)
`rewriteEmbeddedNamespaceRefs()` in `apply.go.tmpl` handles ClusterRoleBinding subjects, WebhookConfiguration service namespaces, and cert-manager Certificate DNS names — but does **not** handle `NetworkPolicy.spec.ingress[].from[].namespaceSelector` or `egress[].to[].namespaceSelector`.

KServe does not currently ship NetworkPolicies, so this is latent. If that changes upstream, affected policies will apply with the wrong namespace selector and fail silently.

### 2. Deleted CR is not auto-recreated
`ensureDefaultCR()` creates the default CR once on startup. If a user deletes it, KServe continues running but the operator stops reconciling — no more phase updates, no retry on drift. The operator treats deletion as intentional and stays silent. This is a UX trap given the auto-init makes the CR feel fully managed.

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
