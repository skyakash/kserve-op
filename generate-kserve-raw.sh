#!/bin/bash
# ==============================================================================
# Script:  generate-kserve-raw.sh
# Purpose: Automatically generates a standalone "manual deployment" directory
#          from the KServe source code. It configures KServe for RAW deployment
#          mode and isolates the necessary manifests into a deployable structure.
# ==============================================================================

set -e

# Parse arguments
TARGET_DIR_NAME=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET_DIR_NAME="$2"; shift 2 ;;
        -c|--clean) TARGET_DIR_NAME="$2"; CLEAN_ONLY=true; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -t, --target <name>  Target extraction directory name (e.g., c-kserve-raw)"
            echo "  -c, --clean <name>   Clean the target extraction directory and exit"
            echo "  -h, --help           Display this help message"
            exit 0
            ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR=$(pwd)

if [ "$CLEAN_ONLY" = true ]; then
    if [ -z "$TARGET_DIR_NAME" ]; then
        read -p "Enter the name of the target directory to clean (e.g., my-kserve-deploy): " TARGET_DIR_NAME
    fi
    if [ -z "$TARGET_DIR_NAME" ] || [ "$TARGET_DIR_NAME" == "/" ] || [ "$TARGET_DIR_NAME" == "." ] || [ "$TARGET_DIR_NAME" == ".." ]; then
        echo "ERROR: Invalid target directory name for clean."
        exit 1
    fi
    OUTPUT_DIR="${SCRIPT_DIR}/${TARGET_DIR_NAME}"
    echo "Cleaning generated directories..."
    if [ -d "${OUTPUT_DIR}" ]; then
        echo "Removing ${OUTPUT_DIR}..."
        rm -rf "${OUTPUT_DIR}"
    fi
    echo "Clean complete. Exiting..."
    exit 0
fi

if [ -z "$TARGET_DIR_NAME" ]; then
    read -p "Enter the name of the target directory to create (e.g., my-kserve-deploy): " TARGET_DIR_NAME
fi

if [ -z "$TARGET_DIR_NAME" ]; then
    echo "ERROR: Target directory name cannot be empty."
    exit 1
fi

OUTPUT_DIR="${SCRIPT_DIR}/${TARGET_DIR_NAME}"

# We assume kserve-master is heavily cloned right next to this script in the workspace
KSERVE_SOURCE="${SCRIPT_DIR}/kserve-master"

if [ ! -d "${KSERVE_SOURCE}" ]; then
    echo "ERROR: Could not find the KServe source repository at ${KSERVE_SOURCE}"
    echo "Please ensure 'kserve-master' exists in the same directory as this script."
    exit 1
fi

KUSTOMIZE="kustomize"

echo "================================================================="
echo "  KServe Raw Mode Extractor"
echo "  Source : ${KSERVE_SOURCE}"
echo "  Target : ${OUTPUT_DIR}"
echo "================================================================="

# Clean previous build if it exists
if [ -d "${OUTPUT_DIR}" ]; then
    echo "Directory ${OUTPUT_DIR} already exists. Cleaning it up..."
    rm -rf "${OUTPUT_DIR}"
fi

mkdir -p "${OUTPUT_DIR}"

# Jump into KServe source to run localized Kustomize builds
pushd "${KSERVE_SOURCE}" > /dev/null

echo "[1/5] Extracting Cert-Manager..."
mkdir -p "${OUTPUT_DIR}/01-cert-manager"
curl -sLk "https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml" > "${OUTPUT_DIR}/01-cert-manager/cert-manager.yaml"
echo "      Done."

echo "[2/5] Extracting KServe CRDs..."
mkdir -p "${OUTPUT_DIR}/02-kserve-crds"
${KUSTOMIZE} build config/crd > "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml"
${KUSTOMIZE} build config/crd/full/llmisvc >> "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml" 2>/dev/null || true
echo "      Done."

echo "[3/5] Extracting KServe RBAC..."
mkdir -p "${OUTPUT_DIR}/03-kserve-rbac"

# KServe RBAC requires the 'kserve' namespace explicitly set in ClusterRoleBinding subjects
${KUSTOMIZE} build config/rbac > "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml"

python3 -c '
import yaml
import sys

output = []
with open(sys.argv[1], "r") as f:
    docs = yaml.safe_load_all(f)
    for doc in docs:
        if doc:
            if doc.get("kind") == "ClusterRoleBinding":
                for subject in doc.get("subjects", []):
                    if subject.get("kind") == "ServiceAccount" and subject.get("name") == "kserve-controller-manager":
                        subject["namespace"] = "kserve"
        output.append(doc)

with open(sys.argv[2], "w") as f:
    yaml.safe_dump_all(output, f)
' "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml" "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac.yaml"

rm "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml"
echo "      Done."

echo "[4/5] Extracting KServe Core & Patching for Raw Mode..."
mkdir -p "${OUTPUT_DIR}/04-kserve-core"

# To get the core manifests, we build the default Kustomize overlay
${KUSTOMIZE} build config/default > "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"

# We must explicitly add the configmap baseline because it is not bundled by default
echo "---" >> "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"
${KUSTOMIZE} build config/configmap >> "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"

# We must explicitly add the selfsigned-issuer because config/default drops it
echo "---" >> "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"
${KUSTOMIZE} build config/certmanager >> "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"

# CRITICAL: We must modify the inferenceservice-config ConfigMap inline to force RawDeployment mode
# and remove all Istio/KNative references from the ingress config.
python3 -c '
import yaml
import json
import sys

output = []
with open(sys.argv[1], "r") as f:
    docs = yaml.safe_load_all(f)
    for doc in docs:
        if doc and doc.get("kind") == "ConfigMap" and doc.get("metadata", {}).get("name") == "inferenceservice-config":
            # Force RawDeployment mode
            if "deploy" in doc.get("data", {}):
                deploy_cfg = json.loads(doc["data"]["deploy"])
                deploy_cfg["defaultDeploymentMode"] = "RawDeployment"
                doc["data"]["deploy"] = json.dumps(deploy_cfg, indent=4)

            # Patch ingress: disable Istio VirtualService creation and clear ingressClassName
            # NOTE: gateway fields (ingressGateway, localGateway, etc.) cannot be removed
            # because KServe validates their presence at startup.
            if "ingress" in doc.get("data", {}):
                ingress_cfg = json.loads(doc["data"]["ingress"])
                ingress_cfg["disableIstioVirtualHost"] = True
                ingress_cfg["ingressClassName"] = ""
                ingress_cfg["disableIngressCreation"] = True
                doc["data"]["ingress"] = json.dumps(ingress_cfg, indent=4)

        output.append(doc)

with open(sys.argv[2], "w") as f:
    yaml.safe_dump_all(output, f)
' "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml" "${OUTPUT_DIR}/04-kserve-core/kserve-core.yaml"

rm "${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"
echo "      Done."

echo "[5/5] Extracting KServe ClusterServingRuntimes..."
mkdir -p "${OUTPUT_DIR}/05-kserve-runtimes"
${KUSTOMIZE} build config/runtimes > "${OUTPUT_DIR}/05-kserve-runtimes/kserve-cluster-resources.yaml"
echo "      Done."

popd > /dev/null

echo "-----------------------------------------------------------------"
echo " Creating Sample Inference Service"
echo "-----------------------------------------------------------------"
mkdir -p "${OUTPUT_DIR}/06-sample-model"

cp "${SCRIPT_DIR}/kserve-raw-base/sklearn-iris.yaml.tmpl" "${OUTPUT_DIR}/06-sample-model/sklearn-iris.yaml"

cp "${SCRIPT_DIR}/kserve-raw-base/iris-input.json.tmpl" "${OUTPUT_DIR}/06-sample-model/iris-input.json"
echo "      Generated sklearn-iris.yaml and iris-input.json."

echo "-----------------------------------------------------------------"
echo " Creating Installer Script (install.sh)"
echo "-----------------------------------------------------------------"

cp "${SCRIPT_DIR}/kserve-raw-base/install.sh.tmpl" "${OUTPUT_DIR}/install.sh"

chmod +x "${OUTPUT_DIR}/install.sh"

echo "-----------------------------------------------------------------"
echo " Creating README.md"
echo "-----------------------------------------------------------------"

cp "${SCRIPT_DIR}/kserve-raw-base/README.md.tmpl" "${OUTPUT_DIR}/README.md"
echo "      Generated fully documented README.md."
echo "Success! The manual deployment package has been generated at:"
echo "  -> ${OUTPUT_DIR}"
