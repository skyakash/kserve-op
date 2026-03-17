# Aggregated Implementation Plans from Previous Conversations

---

## Conversation: KServe Operator Generation & Testing (822052e3-67fd-4825-aaee-351d667f288b)

# Image Override at Operator Install Time

## Problem

The `operator-deployment.yaml` in the generated customer package has the operator container image hardcoded at generation time (e.g., `docker.io/akashneha/kserve-raw-operator:v51`). Customers who mirror images to their own private registry can't easily change this without editing the YAML manually.

## Solution

Add an `install.sh` to the generated customer package (`<target>-package/`). This script will:
1. Accept an optional `--image <registry/image:tag>` flag to override the baked-in image
2. If provided, patch `operator-deployment.yaml` in-place using `sed` before applying
3. Apply the patched manifest and the CR automatically

Customers only need `bash` and `kubectl` — no Go, Make, or operator-sdk required.

## Proposed Changes

---

### Operator Package Template

#### [NEW] [install.sh.tmpl](file:///Users/akashdeo/kserve-op/kserve-operator-base/install.sh.tmpl)

A new shell script template copied to `<target>-package/install.sh` at generation time. Contains:
- `--image <tag>` CLI flag to override image at install time
- `--pull-secret <name>` CLI flag to patch in a pull secret at install time
- `--olm` flag for OLM bundle deployment path with `operator-sdk run bundle`
- Defaults to the baked-in image if no `--image` is provided
- Applies `operator-deployment.yaml` → `kserve-rawmode.yaml` in order

Also stores the baked-in default image in a `IMAGE` variable at the top of the script so the user can see what it is by reading `install.sh`.

---

### Generation Script

#### [MODIFY] [generate-kserve-operator.sh](file:///Users/akashdeo/kserve-op/generate-kserve-operator.sh)

After generating the package directory, copy and process the new `install.sh.tmpl`:
- Replace `REPLACE_IMAGE_TAG` placeholder with actual `${IMAGE_TAG}`
- Replace `REPLACE_BUNDLE_IMG` placeholder with actual `${BUNDLE_IMG}` (if OLM bundle was built)
- Replace `REPLACE_TARGET_DIR_NAME` placeholder with actual `${TARGET_DIR_NAME}`
- `chmod +x` the generated script
- Also update the `package-readme.md.tmpl` to mention `install.sh --image`

---

### Package README Template

#### [MODIFY] [package-readme.md.tmpl](file:///Users/akashdeo/kserve-op/kserve-operator-base/package-readme.md.tmpl)

Update the `Option A` section to mention the `install.sh` script and the `--image` override flag as the recommended customer deployment method.

---

## Verification Plan

### Manual Verification (shell test)

After implementation, verify the feature works end-to-end:

1. Re-generate the operator package:
   ```bash
   ./generate-kserve-operator.sh -c test-kserve-op
   rm -rf test-kserve-operator-package
   ./generate-kserve-operator.sh -t test-kserve-op -m github.com/test/test-kserve-op \
     -d akashdeo.com -s p-kserve-raw \
     -i docker.io/akashneha/kserve-raw-operator:v51 -b
   ```

2. Check `install.sh` was generated in the package:
   ```bash
   ls -la test-kserve-op-package/install.sh
   ```

3. Run `--help` on the generated install script:
   ```bash
   ./test-kserve-op-package/install.sh --help
   ```

4. Run a dry-run with a custom image to verify the patch logic substitutes the image correctly:
   ```bash
   ./test-kserve-op-package/install.sh --image my-registry.com/my-org/kserve-op:v99 --dry-run
   # Verify output shows the substituted image
   grep "my-registry.com/my-org/kserve-op:v99" test-kserve-op-package/operator-deployment.yaml
   ```

5. Clean up:
   ```bash
   ./generate-kserve-operator.sh -c test-kserve-op
   ```


---

## Conversation: Airgap KServe Simulation (f702480b-c307-4652-b6da-bbdf132635e1)

# KServe Operator Installation Plan

## User Review Required
> [!NOTE]
> **Using Local Registry**: Since port 5000 is occupied by Control Center (AirPlay), we will run a local registry on port **5001**.
> Docker images will be pushed to `localhost:5001/kserve-installer:v1`.

## Proposed Changes

### Documentation
#### [NEW] [FRESH_INSTALL_GUIDE.md](file:///Users/akashdeo/kserve-raw-installer/FRESH_INSTALL_GUIDE.md)
Detailed step-by-step guide covering:
1.  **Prerequisites Installation**:
    -   Go (via brew/tarball)
    -   Operator SDK (via brew)
    -   Kustomize (via make/brew)
    -   OLM (via curl/operator-sdk)
2.  **Local Registry Setup**:
    -   `docker run -d -p 5001:5000 --restart=always --name registry registry:2`
3.  **Operator Deployment**:
    -   Setting `IMG=localhost:5001/kserve-installer:v1`.
    -   `make docker-build docker-push`
    -   `make deploy`
3.  **KServe Installation**:
    -   Applying the `KServeStack` CR.

### Code
No Go code changes planned unless the existing controller proves non-functional during verification.

## Verification Plan

### Automated Steps
-   **Verify Prerequisites**: Check versions of Go, Operator SDK, OLM.
-   **Build Operator**: `make docker-build` successful.
-   **Deploy Operator**: `make deploy` successful; operator pod running.

### Manual Verification
-   **Install KServe**: Apply `config/samples/kserve_v1alpha1_kservestack.yaml`.
-   **Verify Components**: Check if Istio, Knative, Cert-Manager, and KServe pods are running in their respective namespaces.
-   **Smoke Test**: Deploy a sample InferenceService (iris model) and check if it becomes ready.


---

## Conversation: Creating OperatorHub Bundle (d6dfb99c-db87-4553-9962-acb7d43448b2)

# Implementation Plan: Air-Gapped KServe Operator Bundle

This plan outlines the creation of a self-contained "Air-Gapped" operator bundle in `kserve-raw-operator-ag`. This bundle will include all source code, local tools, and manifests required to install KServe without internet connectivity.

## User Review Required

> [!IMPORTANT]
> Since I cannot physically download and store multi-GB Docker image layers in your filesystem environment easily, the "packaging" will consist of **Mirroring Scripts**. You will need to run these scripts on a machine *with* internet access to pull the images, and then move them (as tarballs) to your air-gapped environment.

## Proposed Changes

### [kserve-raw-operator-ag-customer]
- **Rendered Manifests**: Use `kustomize` to generate a single `operator-install.yaml`. No build tools needed for the customer.
- **Image Archiver**: Run `save_images.sh` to generate a `tars/` folder containing archival versions of all ~26 required images.
- **Image Transport Scripts**:
    - `save_images.sh`: Runs on internet-connected PC to `docker save` all images to a `tars/` folder.
    - `load_images.sh`: Runs at customer site to `docker load` and `docker push` to their local registry.
- **Customer Guide**: Simplified, non-technical instructions for deployment.
- **ZIP Creation**: Final packaging into `kserve-raw-operator-bundle.zip`.

### [OperatorHub Bundle]
- **Bundle Generation**: Execute `make bundle` in `kserve-raw-operator`.
- **CSV Metadata**: Manually enrich `bundle/manifests/kserve-raw-operator.clusterserviceversion.yaml` with:
    - **Icon**: Base64 encoded image.
    - **Maintainers**: Contact information.
    - **Links**: Documentation and source code.
    - **Categories**: AI/Machine Learning, Cloud Native.
    - **Description**: Detailed multi-line description.
- **Validation**: Use `operator-sdk bundle validate ./bundle` to ensure compliance with OperatorHub standards.
- **Packaging**: Build and push the bundle image: `akashneha/kserve-raw-operator-bundle:v0.1.0`.

## Verification Plan

### Automated Tests
- `ls -R kserve-raw-operator-ag/dependencies` to verify all manifests are present.
- Dry-run of the `mirror_images.sh` script to verify image tagging logic.

### Manual Verification
- The user will be asked to verify that they can run the `mirror_images.sh` script.

