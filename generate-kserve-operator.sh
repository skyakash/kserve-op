#!/bin/bash
# ==============================================================================
# Script:  generate-kserve-operator.sh
# Purpose: Automatically generates a standalone Go-based Operator using
#          Operator-SDK, pre-configured to deploy KServe Raw Mode manifests.
# ==============================================================================

set -e

echo "================================================================="
echo "  KServe Raw Mode Operator Generator"
echo "================================================================="

TARGET_DIR_NAME=""
GO_MODULE=""
API_DOMAIN=""
MANIFEST_DIR=""
IMAGE_TAG=""
AUTO_PUSH=false
MULTI_PLATFORM=false
GEN_OLM_BUNDLE=false
IMAGE_PULL_SECRET=""
DOCKER_SERVER="docker.io"
DOCKER_USERNAME=""
DOCKER_PASSWORD=""
TRUST_CERT_PATH=""
# Valid values: AllNamespaces | OwnNamespace | SingleNamespace | MultiNamespace
INSTALL_MODE="OwnNamespace"
CUSTOMER_REGISTRY=""

# 1. Parse CLI Arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET_DIR_NAME="$2"; shift 2 ;;
        -c|--clean) TARGET_DIR_NAME="$2"; CLEAN_ONLY=true; shift 2 ;;
        -m|--module) GO_MODULE="$2"; shift 2 ;;
        -d|--domain) API_DOMAIN="$2"; shift 2 ;;
        -s|--source) MANIFEST_DIR="$2"; shift 2 ;;
        -i|--image) IMAGE_TAG="$2"; shift 2 ;;
        -b|--build) AUTO_BUILD=true; shift 1 ;;
        -p|--push) AUTO_PUSH=true; shift 1 ;;
        -x|--multi-platform) MULTI_PLATFORM=true; AUTO_BUILD=true; shift 1 ;;
        -o|--olm) GEN_OLM_BUNDLE=true; AUTO_BUILD=true; shift 1 ;;
        --install-mode) INSTALL_MODE="$2"; shift 2 ;;
        --customer-registry) CUSTOMER_REGISTRY="$2"; shift 2 ;;
        --pull-secret) IMAGE_PULL_SECRET="$2"; shift 2 ;;
        --docker-server) DOCKER_SERVER="$2"; shift 2 ;;
        --docker-username) DOCKER_USERNAME="$2"; shift 2 ;;
        --docker-password) DOCKER_PASSWORD="$2"; shift 2 ;;
        --cert) TRUST_CERT_PATH="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -t, --target         Target operator directory (e.g., my-kserve-operator)"
            echo "  -c, --clean          Clean the target operator directory and exit"
            echo "  -m, --module         Go module path (e.g., github.com/user/my-kserve-operator)"
            echo "  -d, --domain         API domain for Custom Resource (e.g., akashdeo.com)"
            echo "  -s, --source         Extracted KServe manifests folder (e.g., ./a-kserve-deploy)"
            echo "  -i, --image          Docker image tag (e.g., quay.io/user/kserve-raw-operator:v1)"
            echo "  -b, --build          Automatically build the Docker image without prompting"
            echo "  -p, --push           Automatically push the Docker image without prompting"
            echo "  -x, --multi-platform Build and push for multiple architectures (linux/amd64, arm64, etc.)"
            echo "  -o, --olm            Generate and build an OLM bundle for the operator (implies -b)"
            echo "  --install-mode <mode> OLM install mode: OwnNamespace (default), AllNamespaces, SingleNamespace, MultiNamespace"
            echo "  --customer-registry <prefix>  Customer private registry prefix (e.g., artifactory.example.com/myrepo)"
            echo "  --pull-secret <name> Name of an existing imagePullSecret on the cluster (injected into manager spec)"
            echo "  --docker-server <url>  Registry URL for pull secret creation (default: docker.io)"
            echo "  --docker-username <u>  Registry username — generates setup-credentials.sh in the package"
            echo "  --docker-password <p>  Registry password/token — generates setup-credentials.sh in the package"
            echo "  --cert <path>        Inject a certificate into the trusted chain (for firewall/proxy)"
            exit 0
            ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

# Validate --install-mode value
case "$INSTALL_MODE" in
    AllNamespaces|OwnNamespace|SingleNamespace|MultiNamespace) ;;
    *)
        echo "ERROR: Invalid --install-mode value '$INSTALL_MODE'."
        echo "       Valid values: AllNamespaces, OwnNamespace, SingleNamespace, MultiNamespace"
        exit 1
        ;;
esac

# Check if we only need to clean
if [ "$CLEAN_ONLY" = true ]; then
    if [ -z "$TARGET_DIR_NAME" ]; then
        read -p "Enter the name of the target operator directory to clean (e.g., my-kserve-operator): " TARGET_DIR_NAME
    fi
    if [ -z "$TARGET_DIR_NAME" ] || [ "$TARGET_DIR_NAME" == "/" ] || [ "$TARGET_DIR_NAME" == "." ] || [ "$TARGET_DIR_NAME" == ".." ]; then 
        echo "ERROR: Invalid target directory name for clean."
        exit 1
    fi
    SCRIPT_DIR=$(pwd)
    OUTPUT_DIR="${SCRIPT_DIR}/${TARGET_DIR_NAME}"
    PACKAGE_DIR="${SCRIPT_DIR}/${TARGET_DIR_NAME}-package"
    
    echo "Cleaning generated directories..."
    if [ -d "${OUTPUT_DIR}" ]; then
        echo "Removing ${OUTPUT_DIR}..."
        rm -rf "${OUTPUT_DIR}"
    fi
    if [ -d "${PACKAGE_DIR}" ]; then
        echo "Removing ${PACKAGE_DIR}..."
        rm -rf "${PACKAGE_DIR}"
    fi
    echo "Clean complete. Exiting..."
    exit 0
fi

# 2. Gather Interactive Parameters for Missing Inputs
if [ -z "$TARGET_DIR_NAME" ]; then
    read -p "Enter the name of the target operator directory (e.g., my-kserve-operator): " TARGET_DIR_NAME
fi
if [ -z "$TARGET_DIR_NAME" ]; then echo "ERROR: Target directory name cannot be empty."; exit 1; fi

if [ -z "$GO_MODULE" ]; then
    read -p "Enter your Go module path (e.g., github.com/username/my-kserve-operator): " GO_MODULE
fi
if [ -z "$GO_MODULE" ]; then echo "ERROR: Go module path cannot be empty."; exit 1; fi

if [ -z "$API_DOMAIN" ]; then
    read -p "Enter the API domain for your Custom Resource (e.g., akashdeo.com): " API_DOMAIN
fi
if [ -z "$API_DOMAIN" ]; then echo "ERROR: API domain cannot be empty."; exit 1; fi

if [ -z "$MANIFEST_DIR" ]; then
    read -p "Enter the path to your extracted KServe manifests folder (e.g., ./a-kserve-deploy): " MANIFEST_DIR
fi
if [ ! -d "$MANIFEST_DIR" ]; then
    echo "ERROR: Could not find manifest directory at '$MANIFEST_DIR'."
    exit 1
fi

if [ -z "$IMAGE_TAG" ]; then
    read -p "Enter your target Docker image tag (e.g., quay.io/akashdeo/kserve-raw-operator:v1): " IMAGE_TAG
fi
if [ -z "$IMAGE_TAG" ]; then echo "ERROR: Docker image tag cannot be empty."; exit 1; fi

SCRIPT_DIR=$(pwd)
OUTPUT_DIR="${SCRIPT_DIR}/${TARGET_DIR_NAME}"

# Ensure operator-sdk is available
if ! command -v operator-sdk &> /dev/null; then
    # Try looking in our local tools folder first as a fallback
    if [ -f "${SCRIPT_DIR}/tools/operator-sdk" ]; then
        OPERATOR_SDK="${SCRIPT_DIR}/tools/operator-sdk"
    else
        echo "ERROR: operator-sdk command not found in PATH or in ${SCRIPT_DIR}/tools/"
        echo "Please install Operator-SDK v1.42.0+ to proceed."
        exit 1
    fi
else
    OPERATOR_SDK="operator-sdk"
fi

# Ensure yq is available (used for reliable YAML patching of OLM CSV)
if ! command -v yq &> /dev/null; then
    echo "ERROR: yq command not found in PATH."
    echo "Please install yq (https://github.com/mikefarah/yq) to proceed."
    echo "  macOS:  brew install yq"
    echo "  Linux:  snap install yq  or  wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x /usr/local/bin/yq"
    exit 1
fi

echo ""
echo "[1/4] Scaffolding new Operator SDK Project in ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

${OPERATOR_SDK} init --domain="${API_DOMAIN}" --repo="${GO_MODULE}"
${OPERATOR_SDK} create api --group="operator" --version="v1alpha1" --kind="KServeRawMode" --resource=true --controller=true

# Patch installModes in the base CSV so it is preserved as source-of-truth.
# NOTE: make bundle regenerates installModes from operator-sdk defaults (AllNamespaces=true),
# so we ALSO patch the bundle CSV after make bundle runs (see below). yq is used for
# reliable YAML surgery — awk line-counting is fragile against format changes.
echo "Configuring OLM installMode to: ${INSTALL_MODE}"
Base_CSV=$(find "${OUTPUT_DIR}/config/manifests/bases" -name "*.clusterserviceversion.yaml" 2>/dev/null | head -1)
if [ -n "$Base_CSV" ]; then
    INSTALL_MODE="${INSTALL_MODE}" yq -i '.spec.installModes[] |= (.supported = (.type == env(INSTALL_MODE)))' "$Base_CSV"
    echo "Base CSV installModes patched: only '${INSTALL_MODE}' set to supported: true"
else
    echo "WARNING: Could not find base ClusterServiceVersion YAML to patch installModes."
fi

# Handle Trusted Chain Certificate Injection
if [ -n "$TRUST_CERT_PATH" ]; then
    # Resolve to absolute path before any 'cd' happens
    if [[ "$TRUST_CERT_PATH" != /* ]]; then
        TRUST_CERT_PATH="${SCRIPT_DIR}/${TRUST_CERT_PATH}"
    fi

    if [ ! -f "$TRUST_CERT_PATH" ]; then
        echo "ERROR: Trusted Chain Certificate file not found at '$TRUST_CERT_PATH'."
        exit 1
    fi
    CERT_FILENAME=$(basename "$TRUST_CERT_PATH")
    echo "Injecting Trusted Chain Certificate '$CERT_FILENAME' into Dockerfile..."
    cp "$TRUST_CERT_PATH" "./$CERT_FILENAME"

    # Debian/Golang style paths and commands
    CERT_DEST="/usr/local/share/ca-certificates/${CERT_FILENAME}"
    CERT_CMD="update-ca-certificates"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Inject ONLY into the builder stage (matches 'FROM golang')
        sed -i '' "/FROM golang/a \\
COPY ${CERT_FILENAME} ${CERT_DEST} \\
RUN ${CERT_CMD}
" Dockerfile
    else
        sed -i "/FROM golang/a COPY ${CERT_FILENAME} ${CERT_DEST}\nRUN ${CERT_CMD}" Dockerfile
    fi
    echo "Successfully patched Dockerfile build stage with trusted chain logic."
fi

echo ""
echo "[2/4] Copying KServe Extracted Manifests into Controller Assets..."
ASSETS_DIR="${OUTPUT_DIR}/internal/controller/assets"
mkdir -p "${ASSETS_DIR}"

# Copy all the numbered manifest directories, skipping the sample model and installer
cp -r "${SCRIPT_DIR}/${MANIFEST_DIR}/01-cert-manager" "${ASSETS_DIR}/"
cp -r "${SCRIPT_DIR}/${MANIFEST_DIR}/02-kserve-crds" "${ASSETS_DIR}/"
cp -r "${SCRIPT_DIR}/${MANIFEST_DIR}/03-kserve-rbac" "${ASSETS_DIR}/"
cp -r "${SCRIPT_DIR}/${MANIFEST_DIR}/04-kserve-core" "${ASSETS_DIR}/"
cp -r "${SCRIPT_DIR}/${MANIFEST_DIR}/05-kserve-runtimes" "${ASSETS_DIR}/"

echo ""
echo "[3/4] Writing Operator Go Source Code..."

# -----------------------------------------------------------------------------
# Render Operator Go Source Code from Templates
# -----------------------------------------------------------------------------
BASE_DIR="${SCRIPT_DIR}/kserve-operator-base"
if [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: Could not find template directory at '$BASE_DIR'."
    exit 1
fi

cp "${BASE_DIR}/kserverawmode_types.go.tmpl" "api/v1alpha1/kserverawmode_types.go"
cp "${BASE_DIR}/apply.go.tmpl" "internal/controller/apply.go"

# We replace the GO_MODULE and API_DOMAIN placeholders using sed
cp "${BASE_DIR}/kserverawmode_controller.go.tmpl" "internal/controller/kserverawmode_controller.go"

if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|REPLACE_GO_MODULE|${GO_MODULE}|g" "internal/controller/kserverawmode_controller.go"
    sed -i '' "s|REPLACE_API_DOMAIN|${API_DOMAIN}|g" "internal/controller/kserverawmode_controller.go"
else
    sed -i "s|REPLACE_GO_MODULE|${GO_MODULE}|g" "internal/controller/kserverawmode_controller.go"
    sed -i "s|REPLACE_API_DOMAIN|${API_DOMAIN}|g" "internal/controller/kserverawmode_controller.go"
fi

if [ -n "$IMAGE_PULL_SECRET" ]; then
    echo "Adding imagePullSecret '${IMAGE_PULL_SECRET}' to manager.yaml..."
    # We insert imagePullSecrets: [{name: secret}] before the 'containers:' line in config/manager/manager.yaml
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "/containers:/i \\
      imagePullSecrets: \\
      - name: ${IMAGE_PULL_SECRET} \\
" config/manager/manager.yaml
    else
        sed -i "/containers:/i \      imagePullSecrets:\n      - name: ${IMAGE_PULL_SECRET}" config/manager/manager.yaml
    fi
fi

echo ""
echo "[4/5] Generating RBAC, DeepCopy, and running 'go mod tidy'..."

make manifests
make generate
go mod tidy

echo ""
echo ""
echo "[5/5] Docker Image Actions..."

if [ "$AUTO_BUILD" = true ]; then
    BUILD_CHOICE="y"
else
    read -p "Do you want to compile and package the Docker Image now? [y/N]: " BUILD_CHOICE
fi

if [[ "$BUILD_CHOICE" =~ ^[Yy]$ ]]; then
    if [ "$MULTI_PLATFORM" = true ]; then
        echo "Running 'make docker-buildx IMG=${IMAGE_TAG}'..."
        echo "NOTE: Multi-platform build automatically pushes to the registry."
        if ! make docker-buildx IMG="${IMAGE_TAG}"; then
            echo "ERROR: Multi-platform build failed."
            exit 1
        fi
        echo "The cross-platform image '${IMAGE_TAG}' has been successfully built and pushed!"
    else
        echo "Running 'make docker-build IMG=${IMAGE_TAG}'..."
        if ! make docker-build IMG="${IMAGE_TAG}"; then
            echo "ERROR: Docker build failed."
            exit 1
        fi
        echo "The Operator container image '${IMAGE_TAG}' has been successfully built!"
    fi
else
    echo "Skipping Docker build."
fi

if [ "$MULTI_PLATFORM" != true ] && [[ "$BUILD_CHOICE" =~ ^[Yy]$ || "$AUTO_PUSH" = true ]]; then
    if [ "$AUTO_PUSH" = true ]; then
        PUSH_CHOICE="y"
    else
        echo ""
        read -p "Do you want to PUSH the image '${IMAGE_TAG}' to the registry? [y/N]: " PUSH_CHOICE
    fi
    
    if [[ "$PUSH_CHOICE" =~ ^[Yy]$ ]]; then
        echo "Running 'make docker-push IMG=${IMAGE_TAG}'..."
        if ! make docker-push IMG="${IMAGE_TAG}"; then
            echo "ERROR: Docker push failed."
            exit 1
        fi
        echo "The image has been successfully pushed!"
    fi
fi

if [ "$GEN_OLM_BUNDLE" = true ]; then
    echo ""
    echo ""
    echo "[5.5/6] Generating OLM Bundle..."
    
    echo "Configuring OLM metadata options (disabling interactive prompts)..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/generate kustomize manifests -q/generate kustomize manifests -q --interactive=false/g' Makefile
    else
        sed -i 's/generate kustomize manifests -q/generate kustomize manifests -q --interactive=false/g' Makefile
    fi

    echo "Running 'make bundle IMG=${IMAGE_TAG}'..."
    make bundle IMG="${IMAGE_TAG}"

    # IMPORTANT: 'make bundle' calls 'operator-sdk generate bundle' which regenerates
    # the installModes section from operator-sdk defaults (AllNamespaces=true), overwriting
    # the base CSV patch above. We must re-patch the final bundle CSV with yq here.
    BUNDLE_CSV=$(find "${OUTPUT_DIR}/bundle/manifests" -name "*.clusterserviceversion.yaml" 2>/dev/null | head -1)
    if [ -n "$BUNDLE_CSV" ]; then
        INSTALL_MODE="${INSTALL_MODE}" yq -i '.spec.installModes[] |= (.supported = (.type == env(INSTALL_MODE)))' "$BUNDLE_CSV"
        echo "Bundle CSV installModes patched: only '${INSTALL_MODE}' set to supported: true"
        # Verify
        echo "  Verification:"
        yq '.spec.installModes[]' "$BUNDLE_CSV"

        # If --customer-registry is set, also rewrite the operator image ref inside the bundle CSV.
        # IMPORTANT: this must happen BEFORE the bundle docker image is built, since the CSV is
        # baked into the bundle image. Without this, OLM always deploys the operator pod using
        # the original build-registry image (e.g., docker.io/...) instead of the customer registry.
        if [ -n "${CUSTOMER_REGISTRY}" ]; then
            CUST_IMAGE_SHORTNAME="${IMAGE_TAG##*/}"       # e.g. kserve-raw-operator:v200
            CUST_OPERATOR_IMAGE="${CUSTOMER_REGISTRY}/${CUST_IMAGE_SHORTNAME}"
            echo "Rewriting operator image in bundle CSV for customer registry:"
            echo "  ${IMAGE_TAG} → ${CUST_OPERATOR_IMAGE}"
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|${IMAGE_TAG}|${CUST_OPERATOR_IMAGE}|g" "$BUNDLE_CSV"
            else
                sed -i "s|${IMAGE_TAG}|${CUST_OPERATOR_IMAGE}|g" "$BUNDLE_CSV"
            fi
            echo "  Bundle CSV operator image updated."
        fi
    else
        echo "WARNING: Could not find bundle ClusterServiceVersion YAML to patch installModes."
    fi

    BUNDLE_IMG="${IMAGE_TAG}-bundle"
    
    if [[ "$BUILD_CHOICE" =~ ^[Yy]$ ]]; then
        if [ "$MULTI_PLATFORM" = true ]; then
            echo "Running multi-platform bundle build for ${BUNDLE_IMG}..."
            # We use docker buildx directly as the default Makefile doesn't have bundle-buildx
            # We need to make sure we use a canonical name if possible, but we'll stick to what user provided
            docker buildx build --push --platform=linux/arm64,linux/amd64,linux/s390x,linux/ppc64le --tag "${BUNDLE_IMG}" -f bundle.Dockerfile .
            echo "The multi-platform OLM Bundle image '${BUNDLE_IMG}' has been successfully built and pushed!"
        else
            echo "Running OLM-compatible bundle build for ${BUNDLE_IMG}..."
            # Detect the host architecture and normalise to a Docker platform string.
            # This is critical: 'docker build' (and 'make bundle-build') produce a manifest LIST
            # with BuildKit attestation data that OLM's containers/image cannot resolve to a platform.
            # Using 'docker buildx --provenance=false --sbom=false' emits a flat single-manifest image
            # that OLM accepts on both linux/amd64 (x86_64) and linux/arm64 (aarch64) hosts.
            HOST_ARCH=$(uname -m)
            case "${HOST_ARCH}" in
                x86_64)  BUNDLE_PLATFORM="linux/amd64" ;;
                aarch64) BUNDLE_PLATFORM="linux/arm64" ;;
                arm64)   BUNDLE_PLATFORM="linux/arm64" ;;
                *)       BUNDLE_PLATFORM="linux/${HOST_ARCH}" ;;
            esac
            echo "Detected host architecture: ${HOST_ARCH} → building for ${BUNDLE_PLATFORM}"
            if ! docker buildx build \
                --platform "${BUNDLE_PLATFORM}" \
                --provenance=false \
                --sbom=false \
                --push \
                -f bundle.Dockerfile \
                -t "${BUNDLE_IMG}" .; then
                echo "ERROR: OLM Bundle build failed."
                exit 1
            fi
            echo "The OLM Bundle image '${BUNDLE_IMG}' has been successfully built and pushed!"
        fi
    else
        echo "Skipping OLM Bundle image build."
    fi

    # Note: For single-platform OLM builds, the docker buildx --push above already pushed the image.
    # The separate bundle-push step is only needed for non-push local multi-platform builds (not used here).
fi

echo ""
echo ""
echo "[6/6] Generating Standalone Deployment Package..."
cd "${OUTPUT_DIR}"

# Ensure the kustomize binary is downloaded into bin/ via the Makefile
make kustomize

PACKAGE_DIR="${SCRIPT_DIR}/${TARGET_DIR_NAME}-package"
if [ -d "${PACKAGE_DIR}" ]; then
    echo "Directory ${PACKAGE_DIR} already exists. Cleaning it up..."
    rm -rf "${PACKAGE_DIR}"
fi
mkdir -p "${PACKAGE_DIR}"

# Run Kustomize to build the full operator deployment bundle natively, overriding the image
cd config/manager && ../../bin/kustomize edit set image controller="${IMAGE_TAG}"
cd ../../
bin/kustomize build config/default > "${PACKAGE_DIR}/operator-deployment.yaml"

# If a customer registry is provided, rewrite all image references in the deployment
# manifests so the customer pulls from their own private registry, not the build registry.
# The image name and tag are preserved; only the registry prefix is swapped.
if [ -n "${CUSTOMER_REGISTRY}" ]; then
    IMAGE_SHORTNAME="${IMAGE_TAG##*/}"          # e.g. kserve-raw-operator:v1
    CUSTOMER_IMAGE="${CUSTOMER_REGISTRY}/${IMAGE_SHORTNAME}"
    BUNDLE_SHORTNAME="${IMAGE_TAG##*/}-bundle"  # e.g. kserve-raw-operator:v1-bundle
    CUSTOMER_BUNDLE="${CUSTOMER_REGISTRY}/${BUNDLE_SHORTNAME}"

    echo "Rewriting image references for customer registry: ${CUSTOMER_REGISTRY}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|${IMAGE_TAG}|${CUSTOMER_IMAGE}|g" "${PACKAGE_DIR}/operator-deployment.yaml"
    else
        sed -i "s|${IMAGE_TAG}|${CUSTOMER_IMAGE}|g" "${PACKAGE_DIR}/operator-deployment.yaml"
    fi

    # Generate mirror-images.sh — customer runs this once to copy images from the
    # source registry into their private registry using skopeo.
    # Only the operator and bundle images are mirrored; no FBC/catalog image is needed
    # because 'operator-sdk run bundle' creates a temporary catalog automatically.
    cat > "${PACKAGE_DIR}/mirror-images.sh" <<'MIRROR_EOF'
#!/bin/bash
# =============================================================================
# mirror-images.sh — Mirror operator images to your private registry
#
# MODES:
#   Default (online)  — direct registry-to-registry copy via skopeo.
#                       Requires network access to BOTH source and dest.
#
#   --archive         — Save source images as tar archives in ./images/
#                       for offline shipping to an air-gapped environment.
#
#   --load            — Load tar archives from ./images/ and push them
#                       to the destination registry. Run on the customer
#                       machine after transferring the archives.
#
# CREDENTIALS:
#   --dest-user <u>   — Destination registry username
#   --dest-pass <p>   — Destination registry password / token
#                       (prompted interactively if not provided)
#
# Requires: skopeo  (brew install skopeo  /  sudo dnf install -y skopeo)
# =============================================================================
set -e

SRC_OPERATOR="__SRC_OPERATOR__"
DST_OPERATOR="__DST_OPERATOR__"
SRC_BUNDLE="__SRC_BUNDLE__"
DST_BUNDLE="__DST_BUNDLE__"

MODE="online"
DEST_USER=""
DEST_PASS=""

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)    MODE="archive"; shift ;;
        --load)       MODE="load"; shift ;;
        --dest-user)  DEST_USER="$2"; shift 2 ;;
        --dest-pass)  DEST_PASS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Prompt for credentials if not provided (not needed for --archive only)
if [[ "${MODE}" != "archive" ]]; then
    if [[ -z "${DEST_USER}" ]]; then
        read -rp "Destination registry username: " DEST_USER
    fi
    if [[ -z "${DEST_PASS}" ]]; then
        read -rsp "Destination registry password/token: " DEST_PASS; echo
    fi
fi

DEST_CREDS_ARG=""
[[ -n "${DEST_USER}" ]] && DEST_CREDS_ARG="--dest-creds ${DEST_USER}:${DEST_PASS}"

case "${MODE}" in
  archive)
    echo "Saving images to ./images/ (for offline transfer)..."
    mkdir -p images
    echo "  Saving operator image..."
    skopeo copy --override-os linux docker://${SRC_OPERATOR} oci-archive:images/operator.tar
    echo "  Saving OLM bundle image..."
    skopeo copy --override-os linux docker://${SRC_BUNDLE} oci-archive:images/bundle.tar
    echo ""
    echo "Done. Transfer the 'images/' directory to the customer machine, then run:"
    echo "  bash mirror-images.sh --load --dest-user <user> --dest-pass <token>"
    ;;

  load)
    echo "Loading and pushing images from ./images/ to destination registry..."
    echo "  Pushing operator image to ${DST_OPERATOR}..."
    skopeo copy --override-os linux ${DEST_CREDS_ARG} oci-archive:images/operator.tar docker://${DST_OPERATOR}
    echo "  Pushing OLM bundle image to ${DST_BUNDLE}..."
    skopeo copy --override-os linux ${DEST_CREDS_ARG} oci-archive:images/bundle.tar docker://${DST_BUNDLE}
    echo ""
    echo "Done. Images are now available in the destination registry."
    ;;

  online)
    echo "Mirroring images directly between registries..."
    echo "  Mirroring operator image..."
    skopeo copy --override-os linux ${DEST_CREDS_ARG} docker://${SRC_OPERATOR} docker://${DST_OPERATOR}
    if skopeo inspect --override-os linux docker://${SRC_BUNDLE} &>/dev/null; then
        echo "  Mirroring OLM bundle image..."
        skopeo copy --override-os linux ${DEST_CREDS_ARG} docker://${SRC_BUNDLE} docker://${DST_BUNDLE}
    fi
    echo ""
    echo "Done. All images are now available in the destination registry."
    ;;
esac
MIRROR_EOF
    # Inject image references (these are generator-time values, not runtime shell vars)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' \
            -e "s|__SRC_OPERATOR__|${IMAGE_TAG}|g" \
            -e "s|__DST_OPERATOR__|${CUSTOMER_IMAGE}|g" \
            -e "s|__SRC_BUNDLE__|${IMAGE_TAG}-bundle|g" \
            -e "s|__DST_BUNDLE__|${CUSTOMER_BUNDLE}|g" \
            "${PACKAGE_DIR}/mirror-images.sh"
    else
        sed -i \
            -e "s|__SRC_OPERATOR__|${IMAGE_TAG}|g" \
            -e "s|__DST_OPERATOR__|${CUSTOMER_IMAGE}|g" \
            -e "s|__SRC_BUNDLE__|${IMAGE_TAG}-bundle|g" \
            -e "s|__DST_BUNDLE__|${CUSTOMER_BUNDLE}|g" \
            "${PACKAGE_DIR}/mirror-images.sh"
    fi
    chmod +x "${PACKAGE_DIR}/mirror-images.sh"
    echo "Generated mirror-images.sh — customer runs this with skopeo before deploying."

    # Generate deploy-bundle.sh — customer-facing install script with two paths:
    # OPTION A: OLM via 'operator-sdk run bundle' — uses the bundle image directly.
    #   operator-sdk creates a temporary CatalogSource under the hood automatically.
    #   No opm, no FBC image, and no CatalogSource YAML needed by the customer.
    # OPTION B: Direct 'kubectl apply' — no OLM required at all.
    if [ "${GEN_OLM_BUNDLE}" = true ]; then
        cat > "${PACKAGE_DIR}/deploy-bundle.sh" <<DEPLOY_EOF
#!/bin/bash
# =============================================================================
# deploy-bundle.sh — Install the KServe Raw Operator
#
# OPTION A — OLM bundle install (recommended when OLM is available)
#   Uses 'operator-sdk run bundle' which automatically creates a temporary
#   CatalogSource on the cluster. No opm, no FBC image, no CatalogSource
#   YAML needed.
#   Prerequisites: OLM installed (operator-sdk olm install)
#   To uninstall: operator-sdk cleanup ${TARGET_DIR_NAME}
#
# OPTION B — Direct manifest install (no OLM required)
#   Standard kubectl apply. Simpler but bypasses OLM lifecycle management.
#
# Usage: bash deploy-bundle.sh [pull-secret-name]
# =============================================================================

BUNDLE_IMAGE="${CUSTOMER_BUNDLE}"
PULL_SECRET="\${1:-}"

echo "================================================================="
echo " KServe Raw Operator — Deployment"
echo "================================================================="
echo "  A) OLM bundle  : operator-sdk run bundle (recommended)"
echo "  B) Direct YAML : kubectl apply -f operator-deployment.yaml"
echo "================================================================="
read -p "Enter choice [A/B]: " CHOICE

case "$(echo "\${CHOICE}" | tr '[:lower:]' '[:upper:]')" in
  A)
    echo ""
    echo "Installing via OLM bundle: \${BUNDLE_IMAGE}"
    if [ -n "\${PULL_SECRET}" ]; then
        operator-sdk run bundle "\${BUNDLE_IMAGE}" --pull-secret-name "\${PULL_SECRET}"
    else
        operator-sdk run bundle "\${BUNDLE_IMAGE}"
    fi
    echo ""
    echo "Operator installed via OLM."
    echo "To uninstall: operator-sdk cleanup ${TARGET_DIR_NAME}"
    ;;
  B)
    echo ""
    echo "Installing via direct manifest..."
    kubectl apply -f operator-deployment.yaml
    echo ""
    echo "Operator deployed. Apply your CR when ready:"
    echo "  kubectl apply -f kserve-rawmode.yaml"
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac
DEPLOY_EOF
        chmod +x "${PACKAGE_DIR}/deploy-bundle.sh"
        echo "Generated deploy-bundle.sh — customer runs this to install via OLM bundle or direct manifest."
    fi
fi

# Generate a sample Custom Resource to easily test the deployment later
cp "${SCRIPT_DIR}/kserve-operator-base/kserve-rawmode.yaml.tmpl" "${PACKAGE_DIR}/kserve-rawmode.yaml"

# Dynamically replace 'API_DOMAIN' with whatever domain the user inputted
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/API_DOMAIN/${API_DOMAIN}/g" "${PACKAGE_DIR}/kserve-rawmode.yaml"
else
    sed -i "s/API_DOMAIN/${API_DOMAIN}/g" "${PACKAGE_DIR}/kserve-rawmode.yaml"
fi

# Copy the Iris test payload from the raw source if it exists
if [ -d "${SCRIPT_DIR}/${MANIFEST_DIR}/06-sample-model" ]; then
    cp -r "${SCRIPT_DIR}/${MANIFEST_DIR}/06-sample-model" "${PACKAGE_DIR}/"
fi

# Generate User-Facing README.md from template
cp "${SCRIPT_DIR}/kserve-operator-base/package-readme.md.tmpl" "${PACKAGE_DIR}/README.md"
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/TARGET_DIR_NAME/${TARGET_DIR_NAME}/g" "${PACKAGE_DIR}/README.md"
else
    sed -i "s/TARGET_DIR_NAME/${TARGET_DIR_NAME}/g" "${PACKAGE_DIR}/README.md"
fi

# Generate setup-credentials.sh — always generated.
# Credentials are provided at runtime (CLI args or interactive prompt).
# This ensures no credentials are embedded in the generated package.
SECRET_NAME="${IMAGE_PULL_SECRET:-dockerhub-creds}"
cat > "${PACKAGE_DIR}/setup-credentials.sh" <<'CREDS_EOF'
#!/bin/bash
# =============================================================================
# setup-credentials.sh — Create registry pull secrets on the cluster
#
# Run this ONCE before deploying the operator.
#
# USAGE:
#   With CLI args:
#     bash setup-credentials.sh --user <registry-user> --pass <token> \
#                               [--server docker.io]
#
#   Interactive (prompted if args not provided):
#     bash setup-credentials.sh
#
# Namespace lifecycle:
#   default          — always exists
#   *-system         — created by: kubectl apply -f operator-deployment.yaml
#   olm, operators   — created by: operator-sdk olm install
#   kserve           — created automatically by the operator reconcile loop
# =============================================================================
set -e

SECRET_NAME="__SECRET_NAME__"
DOCKER_SERVER="docker.io"
DOCKER_USERNAME=""
DOCKER_PASSWORD=""
SYSTEM_NS="__SYSTEM_NS__"

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)   DOCKER_USERNAME="$2"; shift 2 ;;
        --pass)   DOCKER_PASSWORD="$2"; shift 2 ;;
        --server) DOCKER_SERVER="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Prompt interactively if not provided
if [[ -z "${DOCKER_USERNAME}" ]]; then
    read -rp "Registry username: " DOCKER_USERNAME
fi
if [[ -z "${DOCKER_PASSWORD}" ]]; then
    read -rsp "Registry password/token: " DOCKER_PASSWORD; echo
fi

create_secret() {
    local ns=$1
    echo "Creating pull secret '${SECRET_NAME}' in namespace '${ns}'..."
    kubectl create secret docker-registry "${SECRET_NAME}" \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${DOCKER_USERNAME}" \
        --docker-password="${DOCKER_PASSWORD}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

# Always-available namespace
create_secret default

# Operator system namespace (only present for direct manifest deploy)
if kubectl get ns "${SYSTEM_NS}" &>/dev/null; then
    create_secret "${SYSTEM_NS}"
else
    echo "Namespace '${SYSTEM_NS}' not found — apply operator-deployment.yaml first to create it (direct deploy only)."
fi

# OLM namespaces — present after 'operator-sdk olm install'
for ns in olm operators; do
    if kubectl get ns "${ns}" &>/dev/null; then
        create_secret "${ns}"
    else
        echo "Namespace '${ns}' not found — run 'operator-sdk olm install' first if using OLM bundle deploy."
    fi
done

echo ""
echo "Pull secret '${SECRET_NAME}' configured."
echo "Namespaces 'kserve' and 'cert-manager' are created automatically by the operator — no action needed."
CREDS_EOF
# Inject generator-time values (secret name, system namespace)
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' \
        -e "s|__SECRET_NAME__|${SECRET_NAME}|g" \
        -e "s|__SYSTEM_NS__|${TARGET_DIR_NAME}-system|g" \
        "${PACKAGE_DIR}/setup-credentials.sh"
else
    sed -i \
        -e "s|__SECRET_NAME__|${SECRET_NAME}|g" \
        -e "s|__SYSTEM_NS__|${TARGET_DIR_NAME}-system|g" \
        "${PACKAGE_DIR}/setup-credentials.sh"
fi
chmod +x "${PACKAGE_DIR}/setup-credentials.sh"
echo "Generated setup-credentials.sh in the customer package (credentials provided at runtime — not embedded)."


if [ "$GEN_OLM_BUNDLE" = true ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|<your-bundle-image-tag>|${IMAGE_TAG}-bundle|g" "${PACKAGE_DIR}/README.md"
    else
        sed -i "s|<your-bundle-image-tag>|${IMAGE_TAG}-bundle|g" "${PACKAGE_DIR}/README.md"
    fi
fi

echo "Successfully extracted deployment manifests and created the customer package."

echo ""
echo "================================================================="
echo "Success! The Operator SDK Project has been generated at:"
echo "  -> ${OUTPUT_DIR}"
echo ""
echo "The Customer-Facing Operator Package has been created at:"
echo "  -> ${PACKAGE_DIR}"
echo ""
echo "You can share the '${TARGET_DIR_NAME}-package' folder for immediate deployment!"

if [ "$GEN_OLM_BUNDLE" = true ]; then
    echo ""
    echo "To deploy via OLM, execute the following command:"
    echo "  operator-sdk run bundle ${IMAGE_TAG}-bundle"
fi
echo "================================================================="
