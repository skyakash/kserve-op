# Aggregated Tasks from Previous Conversations

---

## Conversation: KServe Operator Generation & Testing (822052e3-67fd-4825-aaee-351d667f288b)

# Documentation Review Changes

## generate-kserve-raw-README.md
- [ ] Add concrete example command under "How to Run" using `p-kserve-raw` as target

## generate-kserve-operator-README.md
- [ ] Remove dangling `cd <your-target-directory>` block (lines 74-76) with no context
- [ ] Add full example command under "How to Run" using actual test values
- [ ] Update Option A with real example using `p-kserve-operator`
- [ ] Update Option B with real paths (`p-kserve-operator-package/`)
- [ ] Update Option C with real image tags and package dir name
- [ ] Fix E2E Validation iris yaml path: should come from `<package>/06-sample-model/` not `<raw-dir>/06-sample-model/`
- [ ] Fix E2E Validation: remove `-n default` note if namespace is default


---

## Conversation: Building KServe Operator Images (25d84bea-1107-4a75-8c05-57b542b60de4)

# Updating Image Push Logic in Generator Script

[x] Separate out `--push` flag so it does not implicitly require `--build` if the image was already built.
[x] Ensure the user is not prompted to build if they only want to push.
[x] Update the logic in `generate-kserve-operator.sh` to handle separating Docker build and push.
[x] Update the logic for OLM bundle build and push similarly. 


---

## Conversation: Airgap KServe Simulation (f702480b-c307-4652-b6da-bbdf132635e1)

# Task: KServe Installation via Operator on Fresh Cluster

- [ ] environment_setup <!-- id: 0 -->
    - [ ] verify_kubectl_installation <!-- id: 1 -->
    - [x] verify_cluster_connection <!-- id: 2 -->
    - [x] setup_local_registry <!-- id: 100 -->
- [x] prerequisites_installation <!-- id: 3 -->
    - [x] install_olm <!-- id: 4 -->
    - [x] check_dependencies_status <!-- id: 5 -->
- [x] operator_installation <!-- id: 6 -->
    - [x] deploy_operator_manifests <!-- id: 7 -->
    - [x] verify_operator_running <!-- id: 8 -->
- [x] kserve_installation <!-- id: 9 -->
    - [x] create_kserve_cr <!-- id: 10 -->
    - [x] verify_kserve_components <!-- id: 11 -->
- [x] documentation <!-- id: 12 -->
    - [x] create_fresh_install_guide <!-- id: 13 -->
    - [x] update_guide_with_steps <!-- id: 14 -->
- [x] airgap_preparation <!-- id: 15 -->
    - [x] list_required_images <!-- id: 16 -->
    - [x] generate_deployment_manifest <!-- id: 17 -->
    - [x] create_airgap_guide <!-- id: 18 -->
- [x] airgap_simulation <!-- id: 19 -->
    - [x] setup_isolated_network <!-- id: 20 -->
    - [x] deploy_isolated_cluster <!-- id: 21 -->
    - [x] deploy_isolated_client <!-- id: 22 -->
    - [ ] verify_no_internet_access <!-- id: 23 -->
    - [ ] perform_full_installation <!-- id: 24 -->
- [x] teardown_airgap_env <!-- id: 25 -->


---

## Conversation: Creating OperatorHub Bundle (d6dfb99c-db87-4553-9962-acb7d43448b2)

# Tasks

- [x] Setup Air-Gapped Directory Structure <!-- id: 30 -->
    - [x] Create `kserve-raw-operator-ag` directory <!-- id: 31 -->
    - [x] Copy `.tools` and existing operator files <!-- id: 32 -->
- [x] Gather External Dependencies <!-- id: 33 -->
    - [x] Download OLM and Cert-Manager manifests locally <!-- id: 34 -->
    - [x] List all required Docker images for mirroring <!-- id: 35 -->
- [x] Implement Air-Gap Automation <!-- id: 36 -->
    - [x] Create `mirror_images.sh` for image registry migration <!-- id: 37 -->
    - [x] Update Makefile for offline tool usage <!-- id: 38 -->
- [x] Documentation <!-- id: 39 -->
    - [x] Create `Air-Gap-Setup-Guide.md` <!-- id: 40 -->
- [x] Verify local manifest integrity <!-- id: 42 -->
- [x] Prepare Customer Air-Gapped Package <!-- id: 43 -->
    - [x] Create `kserve-raw-operator-ag-customer` directory <!-- id: 44 -->
    - [x] Render final operator manifests (install.yaml) <!-- id: 45 -->
    - [x] Capture Docker image tars (~26 images) <!-- id: 49 -->
    - [x] Create customer image management scripts (save/load) <!-- id: 46 -->
    - [x] Create `Customer-Deployment-Guide.md` <!-- id: 47 -->
    - [x] Generate final ZIP bundle (including tars and .tools) <!-- id: 48 -->
    - [x] Verify local manifest integrity <!-- id: 42 -->
- [x] Create OperatorHub Bundle <!-- id: 50 -->
    - [x] Generate OLM bundle manifests using `make bundle` <!-- id: 51 -->
    - [x] Enhance ClusterServiceVersion (CSV) with OperatorHub metadata <!-- id: 52 -->
    - [x] Add operator icon and detailed description <!-- id: 53 -->
    - [x] Validate bundle using `operator-sdk bundle validate` <!-- id: 54 -->
    - [x] Build and push bundle image <!-- id: 55 -->

