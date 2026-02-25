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

# 1. Parse CLI Arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET_DIR_NAME="$2"; shift 2 ;;
        -m|--module) GO_MODULE="$2"; shift 2 ;;
        -d|--domain) API_DOMAIN="$2"; shift 2 ;;
        -s|--source) MANIFEST_DIR="$2"; shift 2 ;;
        -i|--image) IMAGE_TAG="$2"; shift 2 ;;
        -b|--build) AUTO_BUILD=true; shift 1 ;;
        -p|--push) AUTO_PUSH=true; shift 1 ;;
        -x|--multi-platform) MULTI_PLATFORM=true; AUTO_BUILD=true; shift 1 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -t, --target         Target operator directory (e.g., my-kserve-operator)"
            echo "  -m, --module         Go module path (e.g., github.com/user/my-kserve-operator)"
            echo "  -d, --domain         API domain for Custom Resource (e.g., akashdeo.com)"
            echo "  -s, --source         Extracted KServe manifests folder (e.g., ./a-kserve-deploy)"
            echo "  -i, --image          Docker image tag (e.g., quay.io/user/kserve-raw-operator:v1)"
            echo "  -b, --build          Automatically build the Docker image without prompting"
            echo "  -p, --push           Automatically push the Docker image without prompting"
            echo "  -x, --multi-platform Build and push for multiple architectures (linux/amd64, arm64, etc.)"
            exit 0
            ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

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
        echo "Please install Operator-SDK v1.33+ to proceed."
        exit 1
    fi
else
    OPERATOR_SDK="operator-sdk"
fi

echo ""
echo "[1/4] Scaffolding new Operator SDK Project in ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

${OPERATOR_SDK} init --domain="${API_DOMAIN}" --repo="${GO_MODULE}"
${OPERATOR_SDK} create api --group="operator" --version="v1alpha1" --kind="KServeRawMode" --resource=true --controller=true

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
        make docker-buildx IMG="${IMAGE_TAG}"
        echo "The cross-platform image '${IMAGE_TAG}' has been successfully built and pushed!"
    else
        echo "Running 'make docker-build IMG=${IMAGE_TAG}'..."
        make docker-build IMG="${IMAGE_TAG}"
        echo "The Operator container image '${IMAGE_TAG}' has been successfully built!"
        
        if [ "$AUTO_PUSH" = true ]; then
            PUSH_CHOICE="y"
        else
            echo ""
            read -p "Do you want to PUSH the newly built image to the registry '${IMAGE_TAG}'? [y/N]: " PUSH_CHOICE
        fi
        
        if [[ "$PUSH_CHOICE" =~ ^[Yy]$ ]]; then
            echo "Running 'make docker-push IMG=${IMAGE_TAG}'..."
            make docker-push IMG="${IMAGE_TAG}"
            echo "The image has been successfully pushed!"
        fi
    fi
else
    echo "Skipping Docker build."
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

# Generate a sample Custom Resource to easily test the deployment later
cp "${SCRIPT_DIR}/kserve-operator-base/kserverawmode-sample.yaml.tmpl" "${PACKAGE_DIR}/kserverawmode-sample.yaml"

# Dynamically replace 'API_DOMAIN' with whatever domain the user inputted
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/API_DOMAIN/${API_DOMAIN}/g" "${PACKAGE_DIR}/kserverawmode-sample.yaml"
else
    sed -i "s/API_DOMAIN/${API_DOMAIN}/g" "${PACKAGE_DIR}/kserverawmode-sample.yaml"
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
echo "================================================================="
