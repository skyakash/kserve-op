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
ZIP_PATH=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET_DIR_NAME="$2"; shift 2 ;;
        -z|--zip)    ZIP_PATH="$2"; shift 2 ;;
        -c|--clean)  TARGET_DIR_NAME="$2"; CLEAN_ONLY=true; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -t, --target <name>  Target extraction directory name (e.g., c-kserve-raw)"
            echo "  -z, --zip <path>     Path to KServe source zip (extracted to ./kserve-source/)."
            echo "                       Required when ./kserve-source/ does not already exist."
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

# KServe source lives in a generic kserve-source/ directory.
# If it does not exist, auto-extract it from the zip passed via -z/--zip.
# The zip is expected to contain a single top-level directory (e.g.
# kserve-release-0.16/, kserve-master/) which is renamed to kserve-source/.
KSERVE_SOURCE="${SCRIPT_DIR}/kserve-source"

if [ ! -d "${KSERVE_SOURCE}" ]; then
    if [ -z "${ZIP_PATH}" ]; then
        echo "ERROR: ${KSERVE_SOURCE} not found and no -z/--zip <path> provided."
        echo "Pass --zip pointing to the bundled KServe source zip (e.g. kserve-release-0.17.zip)."
        exit 1
    fi
    if [ ! -f "${ZIP_PATH}" ]; then
        echo "ERROR: Zip file not found at ${ZIP_PATH}"
        exit 1
    fi

    echo "Extracting ${ZIP_PATH} -> ${KSERVE_SOURCE}/ ..."
    EXTRACT_TMP="${SCRIPT_DIR}/.kserve-source-extract.$$"
    trap 'rm -rf "${EXTRACT_TMP}"' EXIT
    mkdir -p "${EXTRACT_TMP}"
    unzip -q "${ZIP_PATH}" -d "${EXTRACT_TMP}"

    # Expect a single top-level dir inside the zip
    INNER_COUNT=$(find "${EXTRACT_TMP}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    if [ "${INNER_COUNT}" != "1" ]; then
        echo "ERROR: Expected exactly one top-level directory in ${ZIP_PATH}, found ${INNER_COUNT}."
        exit 1
    fi
    INNER_DIR=$(find "${EXTRACT_TMP}" -mindepth 1 -maxdepth 1 -type d)
    mv "${INNER_DIR}" "${KSERVE_SOURCE}"
    rm -rf "${EXTRACT_TMP}"
    trap - EXIT
    echo "      Done."
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

# Cert-manager is a cluster prerequisite (not bundled).
# Directory numbering intentionally starts at 02 — slot 01 is reserved
# for cert-manager, which the user installs themselves.

echo "[1/4] Extracting KServe CRDs..."
mkdir -p "${OUTPUT_DIR}/02-kserve-crds"
${KUSTOMIZE} build config/crd > "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml.raw"
# Note: previously also appended config/crd/full/llmisvc — dropped entirely
# along with the llmisvc-controller-manager removal (project scope narrowed to
# core InferenceService only).
#
# Filter llmisvc + localmodel CRDs from the kserve-source output. Keyed on
# kind + metadata.name. Idempotent across upstream version bumps; if a future
# release renames these CRDs, add the new names to DROP_KINDS_NAMES.
python3 -c '
import sys, yaml
DROP = {
    "CustomResourceDefinition": {
        "llminferenceservices.serving.kserve.io",
        "llminferenceserviceconfigs.serving.kserve.io",
        "localmodelcaches.serving.kserve.io",
        "localmodelnodes.serving.kserve.io",
        "localmodelnodegroups.serving.kserve.io",
    },
}
def keep(d):
    if not isinstance(d, dict): return True
    k = d.get("kind"); n = (d.get("metadata") or {}).get("name", "")
    return n not in DROP.get(k, set())
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and keep(d)]
yaml.safe_dump_all(docs, open(sys.argv[2], "w"))
' "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml.raw" "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml"
rm "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml.raw"
echo "      Done."

echo "[2/4] Extracting KServe RBAC..."
mkdir -p "${OUTPUT_DIR}/03-kserve-rbac"

# KServe RBAC requires the 'kserve' namespace explicitly set in ClusterRoleBinding subjects
${KUSTOMIZE} build config/rbac > "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml"

python3 -c '
import yaml
import sys

# Two RBAC transformations applied to the kustomize output:
#
# 1. Drop llmisvc + localmodel RBAC objects entirely (the controllers
#    themselves are dropped from the build — see core step).
#
# 2. ClusterRoleBindings cluster-scoped — the source files only set
#    subjects[].namespace explicitly for some ServiceAccounts (historically
#    kserve-controller-manager). Newer KServe versions may add CRBs with
#    subjects omitting the namespace; Kubernetes rejects those at apply
#    time. Default every missing ServiceAccount-subject namespace to
#    "kserve" so the runtime apply.go can rewrite it to the user-chosen
#    target namespace.
DROP = {
    "ClusterRole": {
        "llmisvc-manager-role",
        "kserve-localmodel-manager-role",
        "kserve-localmodelnode-agent-role",
    },
    "ClusterRoleBinding": {
        "llmisvc-manager-rolebinding",
        "kserve-localmodel-manager-rolebinding",
        "kserve-localmodelnode-agent-rolebinding",
    },
    "ServiceAccount": {
        "llmisvc-controller-manager",
        "kserve-localmodel-controller-manager",
        "kserve-localmodelnode-agent",
    },
    "Role": {"llmisvc-leader-election-role"},
    "RoleBinding": {"llmisvc-leader-election-rolebinding"},
}

def drop(doc):
    if not isinstance(doc, dict): return False
    k = doc.get("kind"); n = (doc.get("metadata") or {}).get("name", "")
    return n in DROP.get(k, set())

output = []
with open(sys.argv[1], "r") as f:
    docs = yaml.safe_load_all(f)
    for doc in docs:
        if doc and not drop(doc):
            kind = doc.get("kind")
            if kind == "ClusterRoleBinding":
                for subject in doc.get("subjects", []):
                    if subject.get("kind") == "ServiceAccount" and not subject.get("namespace"):
                        subject["namespace"] = "kserve"
            output.append(doc)

with open(sys.argv[2], "w") as f:
    yaml.safe_dump_all(output, f)
' "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml" "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac.yaml"

rm "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml"
echo "      Done."

echo "[3/4] Extracting KServe Core & Patching for Raw Mode..."
mkdir -p "${OUTPUT_DIR}/04-kserve-core"

# To get the core manifests, we build the default Kustomize overlay
CORE_TMP="${OUTPUT_DIR}/04-kserve-core/kserve-core-temp.yaml"
${KUSTOMIZE} build config/default > "${CORE_TMP}"

# Some KServe versions (master) leave configmap and certmanager OUT of
# config/default; others (release-0.16+) include them already. Append only
# if not already present, to avoid duplicate ConfigMaps/Issuers.
if ! grep -q "^  name: inferenceservice-config$" "${CORE_TMP}"; then
    echo "---" >> "${CORE_TMP}"
    ${KUSTOMIZE} build config/configmap >> "${CORE_TMP}"
fi

if ! grep -q "^kind: Issuer$" "${CORE_TMP}"; then
    echo "---" >> "${CORE_TMP}"
    ${KUSTOMIZE} build config/certmanager >> "${CORE_TMP}"
fi

# Post-processing on the kustomize output:
#   1. Drop llmisvc + localmodel resources entirely (their controllers are
#      removed from project scope).
#   2. inferenceservice-config ConfigMap: force RawDeployment, disable Istio/Ingress.
#   3. Pin the kserve-controller image to v0.17.0. KServe 0.17 ships :latest,
#      which drifts; pinning gives reproducibility.
python3 -c '
import yaml
import json
import sys

# Drop llmisvc + localmodel resources from the core manifest. Filter by
# kind + metadata.name. If upstream renames any of these in a future
# release, add the new names here.
DROP = {
    # CRDs (also emitted into 04-kserve-core/ by kustomize default).
    "CustomResourceDefinition": {
        "llminferenceservices.serving.kserve.io",
        "llminferenceserviceconfigs.serving.kserve.io",
        "localmodelcaches.serving.kserve.io",
        "localmodelnodes.serving.kserve.io",
        "localmodelnodegroups.serving.kserve.io",
    },
    "ServiceAccount": {
        "llmisvc-controller-manager",
        "kserve-localmodel-controller-manager",
        "kserve-localmodelnode-agent",
    },
    "Deployment": {
        "llmisvc-controller-manager",
        "kserve-localmodel-controller-manager",
    },
    "DaemonSet": {"kserve-localmodelnode-agent"},
    "Service": {
        "llmisvc-controller-manager-service",
        "llmisvc-webhook-server-service",
    },
    "Certificate": {"llmisvc-serving-cert"},
    "ValidatingWebhookConfiguration": {
        "llminferenceservice.serving.kserve.io",
        "llminferenceserviceconfig.serving.kserve.io",
        "localmodelcache.serving.kserve.io",
    },
    "ConfigMap": {"kserve-config-llm-decode-template"},
    # Upstream ships bundled LLMInferenceServiceConfig CR instances as
    # serving presets/templates. With the LLMInferenceServiceConfig CRD
    # removed, these CR instances cannot be applied; drop ALL of them
    # regardless of name. The "*" sentinel means "match any name".
    "LLMInferenceServiceConfig": {"*"},
    "Namespace": {"kserve-localmodel-jobs"},
    "Role": {"llmisvc-leader-election-role"},
    "RoleBinding": {"llmisvc-leader-election-rolebinding"},
    # Upstream names ClusterRoles `*-manager-role` (not `*-controller-manager`);
    # both naming families re-emit here from kustomize config/default.
    "ClusterRole": {
        "llmisvc-manager-role",
        "kserve-localmodel-manager-role",
        "kserve-localmodelnode-agent-role",
    },
    "ClusterRoleBinding": {
        "llmisvc-manager-rolebinding",
        "kserve-localmodel-manager-rolebinding",
        "kserve-localmodelnode-agent-rolebinding",
    },
}

def drop(doc):
    if not isinstance(doc, dict): return False
    k = doc.get("kind"); n = (doc.get("metadata") or {}).get("name", "")
    drop_set = DROP.get(k, set())
    return "*" in drop_set or n in drop_set

# Image-tag pinning (replace :latest with :v0.17.0). With llmisvc + localmodel
# gone, only the core kserve-controller image needs pinning.
IMAGE_PIN = {
    "kserve/kserve-controller": "kserve/kserve-controller:v0.17.0",
}

STORAGE_INITIALIZER_OLD = "kserve/storage-initializer:latest"
STORAGE_INITIALIZER_NEW = "kserve/storage-initializer:v0.17.0"

def pin_image(container):
    img = container.get("image", "")
    for repo, pinned in IMAGE_PIN.items():
        if img.startswith(repo + ":") or img == repo:
            container["image"] = pinned
            return

output = []
with open(sys.argv[1], "r") as f:
    docs = list(yaml.safe_load_all(f))

for doc in docs:
    if not doc:
        output.append(doc); continue
    if drop(doc):
        continue

    kind = doc.get("kind")
    name = doc.get("metadata", {}).get("name", "")

    if kind == "ConfigMap" and name == "inferenceservice-config":
        if "deploy" in doc.get("data", {}):
            deploy_cfg = json.loads(doc["data"]["deploy"])
            deploy_cfg["defaultDeploymentMode"] = "RawDeployment"
            doc["data"]["deploy"] = json.dumps(deploy_cfg, indent=4)
        if "ingress" in doc.get("data", {}):
            ingress_cfg = json.loads(doc["data"]["ingress"])
            ingress_cfg["disableIstioVirtualHost"] = True
            ingress_cfg["ingressClassName"] = ""
            ingress_cfg["disableIngressCreation"] = True
            doc["data"]["ingress"] = json.dumps(ingress_cfg, indent=4)
        # NOTE: localModel.enabled patch removed along with localmodel
        # controller removal. Storage-initializer image string-replace
        # (in storageInitializer.image / localModel.defaultJobImage JSON
        # fields) stays because the core storage-initializer is still
        # used by every InferenceService for model fetching.
        for k, v in doc.get("data", {}).items():
            if isinstance(v, str) and STORAGE_INITIALIZER_OLD in v:
                doc["data"][k] = v.replace(STORAGE_INITIALIZER_OLD, STORAGE_INITIALIZER_NEW)

    if kind in ("Deployment", "DaemonSet"):
        for c in doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
            pin_image(c)

    output.append(doc)

with open(sys.argv[2], "w") as f:
    yaml.safe_dump_all(output, f)
' "${CORE_TMP}" "${OUTPUT_DIR}/04-kserve-core/kserve-core.yaml"

rm "${CORE_TMP}"
echo "      Done."

echo "[4/4] Extracting KServe ClusterServingRuntimes..."
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

# Note: LocalModelCache + LLMInferenceService sample manifests were removed
# along with the localmodel + llmisvc controllers — project scope narrowed
# to core InferenceService serving only. The corresponding sample templates
# in kserve-raw-base/ have also been deleted. If a future contributor needs
# to re-introduce these samples, they should also revert the corresponding
# filter additions in generate-kserve-raw.sh.

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
