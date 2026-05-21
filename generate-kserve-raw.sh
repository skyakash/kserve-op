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
        echo "Pass --zip pointing to the bundled KServe source zip (e.g. kserve-release-0.16.zip)."
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
${KUSTOMIZE} build config/crd > "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml"
${KUSTOMIZE} build config/crd/full/llmisvc >> "${OUTPUT_DIR}/02-kserve-crds/kserve-crds.yaml" 2>/dev/null || true
echo "      Done."

echo "[2/4] Extracting KServe RBAC..."
mkdir -p "${OUTPUT_DIR}/03-kserve-rbac"

# KServe RBAC requires the 'kserve' namespace explicitly set in ClusterRoleBinding subjects
${KUSTOMIZE} build config/rbac > "${OUTPUT_DIR}/03-kserve-rbac/kserve-rbac-temp.yaml"

python3 -c '
import yaml
import sys

# Two RBAC fix-ups applied to the kustomize output:
#
# 1. ClusterRoleBindings cluster-scoped — the source files only set
#    subjects[].namespace explicitly for some ServiceAccounts (historically
#    kserve-controller-manager). Newer KServe versions add CRBs for
#    localmodel/llmisvc whose subjects omit the namespace; Kubernetes
#    rejects those at apply time. Default every missing ServiceAccount-
#    subject namespace to "kserve" so the runtime apply.go can rewrite
#    it to the user-chosen target namespace.
#
# 2. llmisvc-manager-role ClusterRole is missing CRD read permission.
#    The kserve/llmisvc-controller binary performs a storage-version
#    migration on startup that reads CRDs — without this permission the
#    controller pod crashloops with "customresourcedefinitions ...
#    is forbidden". Neither 0.16 nor master upstream grants this; we
#    extend the role to match the binary requirement.
CRD_PERMISSION = {
    "apiGroups": ["apiextensions.k8s.io"],
    "resources":  ["customresourcedefinitions"],
    "verbs":      ["get", "list", "watch"],
}

output = []
with open(sys.argv[1], "r") as f:
    docs = yaml.safe_load_all(f)
    for doc in docs:
        if doc:
            kind = doc.get("kind")
            name = doc.get("metadata", {}).get("name", "")

            if kind == "ClusterRoleBinding":
                for subject in doc.get("subjects", []):
                    if subject.get("kind") == "ServiceAccount" and not subject.get("namespace"):
                        subject["namespace"] = "kserve"

            elif kind == "ClusterRole" and name == "llmisvc-manager-role":
                rules = doc.setdefault("rules", [])
                already = any(
                    "apiextensions.k8s.io" in (r.get("apiGroups") or [])
                    and "customresourcedefinitions" in (r.get("resources") or [])
                    for r in rules
                )
                if not already:
                    rules.append(CRD_PERMISSION)
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
#   1. inferenceservice-config ConfigMap: force RawDeployment, disable Istio/Ingress.
#   2. Pin localmodel + llmisvc controller images to v0.16.0. KServe 0.16
#      ships these manifests with :latest, which drifts and can pull a
#      newer binary whose RBAC needs / volume expectations exceed what
#      the 0.16 manifests provide. Pinning gives reproducibility.
#   3. llmisvc-manager-role ClusterRole: add CRD read permission so the
#      llmisvc controller's startup storage-version migration succeeds.
#      Neither 0.16 nor master upstream grants this permission, but the
#      published binary requires it.
python3 -c '
import yaml
import json
import sys

# Image-tag pinning (replace :latest with :v0.16.0). Applied to every
# Deployment/DaemonSet container in the manifest.
IMAGE_PIN = {
    "kserve/kserve-controller":            "kserve/kserve-controller:v0.16.0",
    "kserve/llmisvc-controller":           "kserve/llmisvc-controller:v0.16.0",
    "kserve/kserve-localmodel-controller": "kserve/kserve-localmodel-controller:v0.16.0",
    "kserve/kserve-localmodelnode-agent":  "kserve/kserve-localmodelnode-agent:v0.16.0",
}

# storage-initializer is referenced as a string inside ConfigMap JSON
# fields (localModel.defaultJobImage and storageInitializer.image), not
# as a container image. Substituted via JSON rewrite below.
STORAGE_INITIALIZER_OLD = "kserve/storage-initializer:latest"
STORAGE_INITIALIZER_NEW = "kserve/storage-initializer:v0.16.0"

# Namespace the localmodel controller hardcodes for download Jobs and
# their bound PVCs. Upstream KServe expects the user to create this
# namespace as part of install (see test fixtures, but no manifest
# creates it). We bundle it so the operator creates it during
# InstallingCore — no extra prereq step for the user.
LOCALMODEL_JOBS_NS = {
    "apiVersion": "v1",
    "kind": "Namespace",
    "metadata": {"name": "kserve-localmodel-jobs"},
}

# llmisvc CRD read permission (binary requires it at startup).
CRD_PERMISSION = {
    "apiGroups": ["apiextensions.k8s.io"],
    "resources":  ["customresourcedefinitions"],
    "verbs":      ["get", "list", "watch"],
}

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
        # Enable the LocalModelCache auto-injection. Upstream default is
        # false, which silently disables the URI-match-and-rewrite that
        # ties an InferenceService to a cached PVC. With enabled=true,
        # ISVCs whose storageUri matches an existing LocalModelCache get
        # the cached PVC mounted automatically.
        if "localModel" in doc.get("data", {}):
            lm_cfg = json.loads(doc["data"]["localModel"])
            lm_cfg["enabled"] = True
            doc["data"]["localModel"] = json.dumps(lm_cfg, indent=4)
        # Pin storage-initializer:latest -> :v0.16.0 inside the JSON-blob
        # ConfigMap fields that reference it (localModel.defaultJobImage,
        # storageInitializer.image). String replace is safe because the
        # source uses the exact "kserve/storage-initializer:latest" form.
        for k, v in doc.get("data", {}).items():
            if isinstance(v, str) and STORAGE_INITIALIZER_OLD in v:
                doc["data"][k] = v.replace(STORAGE_INITIALIZER_OLD, STORAGE_INITIALIZER_NEW)

    elif kind == "ClusterRole" and name == "llmisvc-manager-role":
        rules = doc.setdefault("rules", [])
        already = any(
            "apiextensions.k8s.io" in (r.get("apiGroups") or [])
            and "customresourcedefinitions" in (r.get("resources") or [])
            for r in rules
        )
        if not already:
            rules.append(CRD_PERMISSION)

    if kind in ("Deployment", "DaemonSet"):
        for c in doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
            pin_image(c)

    output.append(doc)

# Append the kserve-localmodel-jobs Namespace if not already present.
# (Idempotent: a future upstream that ships this Namespace will skip the append.)
has_lm_jobs_ns = any(
    d for d in output
    if d and d.get("kind") == "Namespace"
    and d.get("metadata", {}).get("name") == "kserve-localmodel-jobs"
)
if not has_lm_jobs_ns:
    output.append(LOCALMODEL_JOBS_NS)

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

# LocalModelCache sample — exercises the local-model caching feature
# introduced in 0.16. Requires at least one node labeled
# kserve/localmodel=worker so the agent DaemonSet can schedule there.
# Two flavours generated:
#   * Online: sourceModelUri is gs:// (needs internet egress at download
#     time only — predictor pods read from the cache PVC afterwards).
#   * Air-gapped (s3://): a self-contained Minio-backed recipe under the
#     airgap-localmodelcache/ subdirectory — see its README for the full
#     apply walkthrough. The previous pvc://-based "offline" samples were
#     removed because KServe v0.16.0's LocalModelCache download path does
#     NOT support pvc:// (only s3://, gs://, http(s)://, abfs://).
cp "${SCRIPT_DIR}/kserve-raw-base/localmodelcache-nodegroup-sample.yaml.tmpl"           "${OUTPUT_DIR}/06-sample-model/localmodelcache-nodegroup.yaml"
cp "${SCRIPT_DIR}/kserve-raw-base/localmodelcache-sample.yaml.tmpl"                     "${OUTPUT_DIR}/06-sample-model/localmodelcache.yaml"
cp "${SCRIPT_DIR}/kserve-raw-base/localmodelcache-isvc-sample.yaml.tmpl"                "${OUTPUT_DIR}/06-sample-model/localmodelcache-isvc.yaml"
cp "${SCRIPT_DIR}/kserve-raw-base/chown-hostpath-helper-sample.yaml.tmpl"               "${OUTPUT_DIR}/06-sample-model/chown-hostpath-helper.yaml"
cp -R "${SCRIPT_DIR}/kserve-raw-base/airgap-localmodelcache"                            "${OUTPUT_DIR}/06-sample-model/airgap-localmodelcache"
echo "      Generated localmodelcache (online + airgap) sample manifests."

# llmisvc smoke-test sample — minimal LLMInferenceService that exercises
# the llmisvc-controller-manager's reconcile path (Deployment + Service
# creation) without loading a real model. See the YAML header for
# production-mode instructions (Gateway API CRD prereq + real model URI).
cp "${SCRIPT_DIR}/kserve-raw-base/llmisvc-sample.yaml.tmpl" "${OUTPUT_DIR}/06-sample-model/llmisvc-smoke.yaml"
echo "      Generated llmisvc-smoke.yaml."

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
