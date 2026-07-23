#!/bin/bash
# ==============================================================================
# Script:  generate-kserve-operator.sh
# Purpose: Automatically generates a standalone Go-based Operator using
#          Operator-SDK, pre-configured to deploy KServe Raw Mode manifests.
#
# Container tool: works with EITHER docker OR podman. Auto-detected (docker
# preferred when both present); override with CONTAINER_TOOL=podman. Podman
# users: run `podman login <registry>` before any build that pushes (-p/-o/-x).
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
TRUST_CERT_PATH=""
HTTP_PROXY_URL=""
HTTPS_PROXY_URL=""
NO_PROXY_LIST=""
# Valid values: AllNamespaces | OwnNamespace | SingleNamespace | MultiNamespace
INSTALL_MODE="SingleNamespace"
CUSTOMER_REGISTRY=""
# Operator's home namespace is hardcoded to 'kserve-operator-system' in all
# generated artifacts. Customers customize at DEPLOY TIME via env vars:
#   Operator-home (Design D ns #1):
#     - OPERATOR_NAMESPACE on install-operator-deployment.sh (Option B wrapper)
#     - OPERATOR_NS on deploy-bundle.sh (Option A / OLM)
#     - SYSTEM_NS on setup-credentials.sh
#   Runtime-control (Design D ns #2):
#     - KSERVE_NS on install-operator-deployment.sh (rewrites WATCH_NAMESPACE)
#   Workload (Design D ns #3):
#     - KSERVE_WORKLOAD_NS on setup-credentials.sh (comma-separated; pull-secret
#       placement, only relevant when --customer-registry was used at build time
#       or --also-workload-ns is passed at deploy time)
# See extra-docs/design-d-three-namespace-model.md for the canonical model.

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
        --cert) TRUST_CERT_PATH="$2"; shift 2 ;;
        --http-proxy)  HTTP_PROXY_URL="$2";  shift 2 ;;
        --https-proxy) HTTPS_PROXY_URL="$2"; shift 2 ;;
        --no-proxy)    NO_PROXY_LIST="$2";   shift 2 ;;
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
            echo "  --install-mode <mode> OLM install mode: SingleNamespace (default), OwnNamespace, AllNamespaces, MultiNamespace"
            echo "  --customer-registry <prefix>  Customer private registry prefix (e.g., artifactory.example.com/myrepo)"
            echo "  --pull-secret <name> Name of an existing imagePullSecret on the cluster (injected into manager spec)"
            echo "  --cert <path>        Inject a certificate into the trusted chain (for firewall/proxy)"
            echo "  --http-proxy <url>   HTTP proxy URL for builder stage (corporate firewall)."
            echo "                       e.g. http://proxy.example.com:80"
            echo "  --https-proxy <url>  HTTPS proxy URL for builder stage."
            echo "                       Typically the SAME URL as --http-proxy."
            echo "  --no-proxy <list>    Comma-separated NO_PROXY bypass list."
            echo "                       e.g. localhost,127.0.0.1,<internal-registry-host>"
            echo "                       ALL THREE (--http-proxy + --https-proxy + --no-proxy) must"
            echo "                       be supplied together, or none. Partial use is rejected."
            echo "                       Injected as ENV in the builder stage ONLY — NOT baked"
            echo "                       into the final distroless operator image."
            echo ""
            echo "ENV:"
            echo "  CONTAINER_TOOL       docker | podman (auto-detected; docker preferred if both present)."
            echo "                       Podman uses native multi-arch (no buildx). Run '<tool> login <registry>'"
            echo "                       before any push (-p / -o / -x)."
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

# Validate proxy flags: all-or-nothing.
# If the user passes any of --http-proxy / --https-proxy / --no-proxy, they must
# pass ALL THREE. This prevents the silent-misroute footgun where (say) only
# HTTP_PROXY is set and HTTPS_PROXY is empty — Go falls back to direct, hits
# the firewall, gets a connection-reset, and the user has no idea why because
# the build "looks" proxied. Enforcing the trio up front surfaces the misuse
# at the CLI rather than 6 minutes into the docker build.
PROXY_FLAGS_SET=0
[ -n "$HTTP_PROXY_URL"  ] && PROXY_FLAGS_SET=$((PROXY_FLAGS_SET + 1))
[ -n "$HTTPS_PROXY_URL" ] && PROXY_FLAGS_SET=$((PROXY_FLAGS_SET + 1))
[ -n "$NO_PROXY_LIST"   ] && PROXY_FLAGS_SET=$((PROXY_FLAGS_SET + 1))
if [ "$PROXY_FLAGS_SET" -gt 0 ] && [ "$PROXY_FLAGS_SET" -lt 3 ]; then
    echo "ERROR: --http-proxy, --https-proxy, and --no-proxy must be supplied together (all three) or not at all."
    echo "       Currently set: ${HTTP_PROXY_URL:+--http-proxy} ${HTTPS_PROXY_URL:+--https-proxy} ${NO_PROXY_LIST:+--no-proxy}"
    echo "       Example: --http-proxy http://proxy.example.com:80 \\"
    echo "                --https-proxy http://proxy.example.com:80 \\"
    echo "                --no-proxy localhost,127.0.0.1,<internal-registry-host>"
    exit 1
fi

# Derive the OLM bundle image name from the operator image (-i flag).
# Convention: append `-bundle` to the image NAME (everything before the last
# `:` tag separator), preserving the tag. Examples:
#   registry/path/image:v1 → registry/path/image-bundle:v1   ← new (this commit)
#   localhost:5000/img:v1  → localhost:5000/img-bundle:v1    (handles port colon)
#   image (no tag)         → image-bundle
# Idiomatic OLM convention (compare quay.io/operatorhubio/<x>-bundle:v1).
# Previously the script appended `-bundle` to the tag — e.g. `:v1-bundle` —
# which conflated tag and image-name semantics and made it impossible to
# host the bundle in a separate Artifactory repo with its own auth.
if [ -n "${IMAGE_TAG}" ]; then
    if [[ "${IMAGE_TAG}" == *:* ]]; then
        BUNDLE_IMG="${IMAGE_TAG%:*}-bundle:${IMAGE_TAG##*:}"
    else
        BUNDLE_IMG="${IMAGE_TAG}-bundle"
    fi
fi

# Check if we only need to clean
if [ "$CLEAN_ONLY" = true ]; then
    if [ -z "$TARGET_DIR_NAME" ]; then
        read -rp "Enter the name of the target operator directory to clean (e.g., my-kserve-operator): " TARGET_DIR_NAME
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

# =============================================================================
# Container tool detection (docker OR podman). Runs only for real builds —
# the clean-only path above never reaches here, so `-c` needs no container tool.
#
# Honor an explicit CONTAINER_TOOL override; otherwise prefer docker, then fall
# back to podman. NOTE: a shell `alias docker=podman` does NOT work here —
# aliases aren't expanded in non-interactive scripts — so we detect a real
# binary and route through wrapper functions instead.
#
#   CONTAINER_TOOL=podman ./generate-kserve-operator.sh ...   # force podman
#
# Podman has no `buildx`; multi-arch is native via `podman build --manifest`.
# Podman also emits flat single-arch manifests by default (no BuildKit
# provenance/SBOM attestations), so the OLM-bundle flat-manifest requirement is
# satisfied without the `--provenance=false --sbom=false` flags docker needs.
# =============================================================================
if [ -n "${CONTAINER_TOOL:-}" ]; then
    command -v "${CONTAINER_TOOL}" >/dev/null 2>&1 || { echo "ERROR: CONTAINER_TOOL='${CONTAINER_TOOL}' not found in PATH."; exit 1; }
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_TOOL=docker
elif command -v podman >/dev/null 2>&1; then
    CONTAINER_TOOL=podman
else
    echo "ERROR: neither 'docker' nor 'podman' found in PATH. Install one, or set CONTAINER_TOOL."
    exit 1
fi
echo "Using container tool: ${CONTAINER_TOOL}"
echo "  (override with CONTAINER_TOOL=<docker|podman>; ensure you've run '${CONTAINER_TOOL} login <registry>' before a push)"

# --- Container build wrappers (docker/podman-agnostic) ----------------------

# Multi-arch build + push. Docker: buildx with an ephemeral builder. Podman:
# native --platform + --manifest, then push the assembled manifest list.
container_build_multiarch() {
    local tag="$1" dockerfile="$2" platforms="$3"
    if [ "${CONTAINER_TOOL}" = "docker" ]; then
        local builder="kserve-op-builder-$$"
        docker buildx create --name "${builder}" --use || return 1
        if ! docker buildx build --push --platform "${platforms}" --tag "${tag}" -f "${dockerfile}" .; then
            docker buildx rm "${builder}" 2>/dev/null || true
            return 1
        fi
        docker buildx rm "${builder}" 2>/dev/null || true
    else
        # Podman: build all arches into a local manifest list, then push it.
        podman manifest exists "${tag}" 2>/dev/null && podman manifest rm "${tag}"
        podman build --platform "${platforms}" --manifest "${tag}" -f "${dockerfile}" . || return 1
        podman manifest push --all "${tag}" "docker://${tag}" || return 1
    fi
}

# Single-arch flat-manifest build (and optionally push). OLM bundle needs
# a flat manifest, not a manifest list.
#
# Push semantics: this wrapper respects the global ${AUTO_PUSH} so the
# bundle's push behavior matches the operator image's push behavior — i.e.
# `-b` alone builds locally (no push for either image), `-b -p` builds AND
# pushes both. The previous behavior (bundle always pushed via buildx
# --push regardless of -p) was inconsistent and produced confusing
# half-states where the bundle CSV referenced an operator image that was
# only in the local daemon.
#
# Docker path: buildx with attestations suppressed, loaded into the local
# daemon, then optionally pushed via plain `docker push`. Two-step instead
# of `buildx --push` because BuildKit's push uses its own HTTP client that
# does NOT reliably honor the host's NO_PROXY env var — customers behind
# corporate firewalls have seen `--push` route auth-token requests through
# the corp proxy (503 HTML page) even when the registry was in NO_PROXY.
# The docker daemon honors /etc/systemd/system/docker.service.d/http-proxy.conf
# and ~/.docker/config.json's proxies block, so `docker push` reliably
# routes to internal registries direct. The --load step is safe because
# we build for the host arch only (BUNDLE_PLATFORM = uname -m).
container_build_singlearch_flat() {
    local tag="$1" dockerfile="$2" platform="$3"
    if [ "${CONTAINER_TOOL}" = "docker" ]; then
        docker buildx build --platform "${platform}" --provenance=false --sbom=false --load \
            -f "${dockerfile}" -t "${tag}" . || return 1
        if [ "${AUTO_PUSH}" = "true" ]; then
            docker push "${tag}" || return 1
        fi
    else
        podman build --platform "${platform}" -f "${dockerfile}" -t "${tag}" . || return 1
        if [ "${AUTO_PUSH}" = "true" ]; then
            podman push "${tag}" "docker://${tag}" || return 1
        fi
    fi
}

# Remote image existence check (post-push verification). Prefer skopeo (most
# reliable cross-tool remote inspector); fall back to the tool's own
# `manifest inspect`.
container_remote_image_exists() {
    local tag="$1"
    if command -v skopeo >/dev/null 2>&1; then
        skopeo inspect "docker://${tag}" >/dev/null 2>&1
    else
        "${CONTAINER_TOOL}" manifest inspect "${tag}" >/dev/null 2>&1
    fi
}

# 2. Gather Interactive Parameters for Missing Inputs
if [ -z "$TARGET_DIR_NAME" ]; then
    read -rp "Enter the name of the target operator directory (e.g., my-kserve-operator): " TARGET_DIR_NAME
fi
if [ -z "$TARGET_DIR_NAME" ]; then echo "ERROR: Target directory name cannot be empty."; exit 1; fi

if [ -z "$GO_MODULE" ]; then
    read -rp "Enter your Go module path (e.g., github.com/username/my-kserve-operator): " GO_MODULE
fi
if [ -z "$GO_MODULE" ]; then echo "ERROR: Go module path cannot be empty."; exit 1; fi

if [ -z "$API_DOMAIN" ]; then
    read -rp "Enter the API domain for your Custom Resource (e.g., akashdeo.com): " API_DOMAIN
fi
if [ -z "$API_DOMAIN" ]; then echo "ERROR: API domain cannot be empty."; exit 1; fi

if [ -z "$MANIFEST_DIR" ]; then
    read -rp "Enter the path to your extracted KServe manifests folder (e.g., ./a-kserve-deploy): " MANIFEST_DIR
fi
if [ ! -d "$MANIFEST_DIR" ]; then
    echo "ERROR: Could not find manifest directory at '$MANIFEST_DIR'."
    exit 1
fi

if [ -z "$IMAGE_TAG" ]; then
    read -rp "Enter your target Docker image tag (e.g., quay.io/akashdeo/kserve-raw-operator:v1): " IMAGE_TAG
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

# Pin the operator's runtime namespace to 'kserve-operator-system' (canonical
# Design C default). This flows through kustomize build into every namespace-
# bearing manifest in operator-deployment.yaml (Namespace + SA + RBAC +
# Service + Deployment). Customers customize at DEPLOY TIME via env vars on
# the helper scripts — see the OPERATOR_NAMESPACE / OPERATOR_NS / SYSTEM_NS /
# KSERVE_NS / KSERVE_WORKLOAD_NS env vars in install-operator-deployment.sh /
# deploy-bundle.sh / setup-credentials.sh. Design D three-namespace model
# (operator-home + runtime-control + workload): see
# extra-docs/design-d-three-namespace-model.md.
KUSTOMIZATION_FILE="config/default/kustomization.yaml"
if [ -f "${KUSTOMIZATION_FILE}" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^namespace: .*$|namespace: kserve-operator-system|" "${KUSTOMIZATION_FILE}"
    else
        sed -i "s|^namespace: .*$|namespace: kserve-operator-system|" "${KUSTOMIZATION_FILE}"
    fi
    echo "Kustomize namespace pinned to: kserve-operator-system"
else
    echo "WARNING: ${KUSTOMIZATION_FILE} not found — kustomize namespace will use operator-sdk default."
fi

# Inject WATCH_NAMESPACE env var into the manager container via downward API.
# OLM annotates the Pod with 'olm.targetNamespaces' based on the OperatorGroup's
# targetNamespaces; reading it lets the controller's auto-init create the default
# CR in the right namespace. Without this, auto-init falls back to "kserve" and
# fails when the user picks a different namespace name (e.g. my-kserve).
MANAGER_FILE="config/manager/manager.yaml"
if [ -f "${MANAGER_FILE}" ]; then
    python3 - <<'PY'
import yaml, sys
path = "config/manager/manager.yaml"
with open(path) as f:
    docs = list(yaml.safe_load_all(f))
patched = False
env_var = {
    "name": "WATCH_NAMESPACE",
    "valueFrom": {
        "fieldRef": {
            "fieldPath": "metadata.annotations['olm.targetNamespaces']"
        }
    },
}
for doc in docs:
    if not doc or doc.get("kind") != "Deployment":
        continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c.get("name") != "manager":
            continue
        existing = c.get("env") or []
        existing = [e for e in existing if e.get("name") != "WATCH_NAMESPACE"]
        existing.append(env_var)
        c["env"] = existing
        patched = True
if not patched:
    sys.exit("ERROR: did not find a manager container in manager.yaml to patch")
with open(path, "w") as f:
    yaml.safe_dump_all(docs, f, default_flow_style=False, sort_keys=False)
print("Injected WATCH_NAMESPACE env var (downward API) into manager container.")
PY
else
    echo "WARNING: ${MANAGER_FILE} not found — WATCH_NAMESPACE will not be injected."
fi

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

# Handle Build-Time HTTP/HTTPS Proxy Injection (builder stage only — same
# scope guarantee as --cert: never baked into the final distroless image).
# Validation above ensures all three flags are present together; this block
# only runs when the user has explicitly opted in.
if [ -n "$HTTP_PROXY_URL" ] && [ -n "$HTTPS_PROXY_URL" ] && [ -n "$NO_PROXY_LIST" ]; then
    echo "Injecting HTTP_PROXY='${HTTP_PROXY_URL}' HTTPS_PROXY='${HTTPS_PROXY_URL}' NO_PROXY='${NO_PROXY_LIST}' into Dockerfile builder stage..."

    # Cross-platform Dockerfile rewrite via Python (avoids BSD vs GNU sed
    # incompatibilities for multi-line inserts). Inserts six ENV lines
    # immediately after `FROM golang...AS builder`. Both UPPERCASE and
    # lowercase variants are set because Go's net/http honors UPPERCASE
    # but git/curl and some auxiliary tools look at lowercase first.
    python3 - "$HTTP_PROXY_URL" "$HTTPS_PROXY_URL" "$NO_PROXY_LIST" <<'PY'
import re, sys
http_proxy, https_proxy, no_proxy = sys.argv[1], sys.argv[2], sys.argv[3]
block = (
    f"ENV HTTP_PROXY={http_proxy}\n"
    f"ENV HTTPS_PROXY={https_proxy}\n"
    f"ENV NO_PROXY={no_proxy}\n"
    f"ENV http_proxy={http_proxy}\n"
    f"ENV https_proxy={https_proxy}\n"
    f"ENV no_proxy={no_proxy}\n"
)
with open("Dockerfile") as f:
    content = f.read()
# Insert immediately after the line that starts with `FROM golang`
# (case-insensitive `AS builder`). Anchored to `FROM golang` to avoid
# touching the final distroless stage.
new_content, count = re.subn(
    r"(^FROM golang[^\n]*\n)",
    r"\1" + block,
    content,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    sys.exit("ERROR: did not find 'FROM golang' line in Dockerfile to inject proxy ENV.")
with open("Dockerfile", "w") as f:
    f.write(new_content)
PY
    echo "Successfully patched Dockerfile builder stage with proxy ENV directives."
fi

echo ""
echo "[2/4] Copying KServe Extracted Manifests into Controller Assets..."
ASSETS_DIR="${OUTPUT_DIR}/internal/controller/assets"
mkdir -p "${ASSETS_DIR}"

# Copy all the numbered manifest directories.
# NOTE: 01-cert-manager is intentionally excluded — cert-manager is now a
# cluster pre-requisite that must be installed before deploying the operator.
# The operator validates its presence at reconcile time and fails with a
# clear error if it is absent.
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
    read -rp "Do you want to compile and package the Docker Image now? [y/N]: " BUILD_CHOICE
fi

if [[ "$BUILD_CHOICE" =~ ^[Yy]$ ]]; then
    if [ "$MULTI_PLATFORM" = true ]; then
        echo "Running multi-platform operator image build for ${IMAGE_TAG}..."
        echo "NOTE: Multi-platform build automatically pushes to the registry."
        # Multi-arch build+push via the container-tool-agnostic wrapper:
        #   docker → buildx with an ephemeral builder
        #   podman → native `podman build --manifest` + `podman manifest push`
        # We call the wrapper directly (not 'make docker-buildx') because the
        # Makefile target uses a '-' prefix that silently swallows push errors,
        # and its `$(CONTAINER_TOOL) buildx` line breaks on podman.
        if ! container_build_multiarch "${IMAGE_TAG}" Dockerfile "linux/arm64,linux/amd64"; then
            echo "ERROR: Multi-platform operator image build/push failed."
            exit 1
        fi
        echo "The cross-platform operator image '${IMAGE_TAG}' has been successfully built and pushed!"
        # Verify it's actually on the registry
        echo "Verifying push (remote manifest inspect)..."
        if ! container_remote_image_exists "${IMAGE_TAG}"; then
            echo "ERROR: Image ${IMAGE_TAG} not found on registry after push. Something went wrong."
            exit 1
        fi
        echo "Verification passed: ${IMAGE_TAG} is available on the registry."

    else
        echo "Running 'make docker-build IMG=${IMAGE_TAG} CONTAINER_TOOL=${CONTAINER_TOOL}'..."
        if ! make docker-build IMG="${IMAGE_TAG}" CONTAINER_TOOL="${CONTAINER_TOOL}"; then
            echo "ERROR: Container image build failed."
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
    elif [ "$AUTO_BUILD" = true ]; then
        # -b was given without -p. Non-interactive run — skip push silently,
        # don't try to read from a potentially closed stdin. (Fixes Issue #8:
        # the previous `read -p` here returned non-zero on non-TTY stdin and
        # set -e killed the script before the OLM-bundle block could run.)
        PUSH_CHOICE="n"
        echo "Skipping image push (pass -p to push automatically)."
    else
        echo ""
        read -rp "Do you want to PUSH the image '${IMAGE_TAG}' to the registry? [y/N]: " PUSH_CHOICE
    fi

    if [[ "$PUSH_CHOICE" =~ ^[Yy]$ ]]; then
        echo "Running 'make docker-push IMG=${IMAGE_TAG} CONTAINER_TOOL=${CONTAINER_TOOL}'..."
        if ! make docker-push IMG="${IMAGE_TAG}" CONTAINER_TOOL="${CONTAINER_TOOL}"; then
            echo "ERROR: Container image push failed."
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

    # Re-patch the base CSV after 'make bundle' since it may have been regenerated.
    echo "Configuring OLM installMode in Base_CSV to: ${INSTALL_MODE}"
    Base_CSV=$(find "${OUTPUT_DIR}/config/manifests/bases" -name "*.clusterserviceversion.yaml" 2>/dev/null | head -1)
    if [ -n "$Base_CSV" ]; then
        INSTALL_MODE="${INSTALL_MODE}" yq -i '.spec.installModes[] |= (.supported = (.type == env(INSTALL_MODE)))' "$Base_CSV"
        echo "Base CSV installModes patched: only '${INSTALL_MODE}' set to supported: true"
        # Verify
        echo "  Verification: Base_CSV"
        yq '.spec.installModes[]' "$Base_CSV"

        # If --customer-registry is set, also rewrite the operator image ref inside the base CSV.
        if [ -n "${CUSTOMER_REGISTRY}" ]; then
            CUST_IMAGE_SHORTNAME="${IMAGE_TAG##*/}"       # e.g. kserve-raw-operator:v200
            CUST_OPERATOR_IMAGE="${CUSTOMER_REGISTRY}/${CUST_IMAGE_SHORTNAME}"
            echo "Rewriting operator image in base CSV for customer registry:"
            echo "  ${IMAGE_TAG} → ${CUST_OPERATOR_IMAGE}"
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|${IMAGE_TAG}|${CUST_OPERATOR_IMAGE}|g" "$Base_CSV"
            else
                sed -i "s|${IMAGE_TAG}|${CUST_OPERATOR_IMAGE}|g" "$Base_CSV"
            fi
            echo "  Base CSV operator image updated."
        fi
    else
        echo "WARNING: Could not find base ClusterServiceVersion YAML to patch installModes."
    fi

    # BUNDLE_IMG was derived globally near the top of the script (search for
    # "Derive the OLM bundle image name"). Pattern: image-name has -bundle
    # appended; tag preserved as-is.

    if [[ "$BUILD_CHOICE" =~ ^[Yy]$ ]]; then
        if [ "$MULTI_PLATFORM" = true ]; then
            echo "Running multi-platform bundle build for ${BUNDLE_IMG}..."
            # Multi-arch bundle build+push via the container-tool-agnostic wrapper
            # (the default Makefile has no bundle-buildx target).
            if ! container_build_multiarch "${BUNDLE_IMG}" bundle.Dockerfile "linux/arm64,linux/amd64,linux/s390x,linux/ppc64le"; then
                echo "ERROR: Multi-platform OLM Bundle build/push failed."
                exit 1
            fi
            echo "The multi-platform OLM Bundle image '${BUNDLE_IMG}' has been successfully built and pushed!"
        else
            echo "Running OLM-compatible bundle build for ${BUNDLE_IMG}..."
            # OLM's containers/image cannot resolve a manifest LIST carrying
            # BuildKit attestation data to a platform — it needs a FLAT
            # single-manifest image. On docker this means buildx with
            # --provenance=false --sbom=false; on podman a plain build already
            # emits a flat manifest. The container_build_singlearch_flat wrapper
            # handles both. Build for the host arch.
            HOST_ARCH=$(uname -m)
            case "${HOST_ARCH}" in
                x86_64)  BUNDLE_PLATFORM="linux/amd64" ;;
                aarch64) BUNDLE_PLATFORM="linux/arm64" ;;
                arm64)   BUNDLE_PLATFORM="linux/arm64" ;;
                *)       BUNDLE_PLATFORM="linux/${HOST_ARCH}" ;;
            esac
            echo "Detected host architecture: ${HOST_ARCH} → building for ${BUNDLE_PLATFORM}"
            if ! container_build_singlearch_flat "${BUNDLE_IMG}" bundle.Dockerfile "${BUNDLE_PLATFORM}"; then
                echo "ERROR: OLM Bundle build failed."
                exit 1
            fi
            if [ "${AUTO_PUSH}" = "true" ]; then
                echo "The OLM Bundle image '${BUNDLE_IMG}' has been successfully built and pushed!"
            else
                echo "The OLM Bundle image '${BUNDLE_IMG}' built locally. Pass -p to also push to the registry."
                echo "  (Without -p, neither the operator image nor the bundle is pushed — they're local-only.)"
            fi
        fi
    else
        echo "Skipping OLM Bundle image build."
    fi

    # Note: For single-platform OLM builds, the wrapper's --push above already pushed the image.
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
    # New (matches BUNDLE_IMG global): `-bundle` appended to image NAME
    # before the tag — e.g. kserve-raw-operator-bundle:v1
    BUNDLE_SHORTNAME="${BUNDLE_IMG##*/}"
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
# CREDENTIALS (destination registry):
#   --user <u>        — Destination registry username
#   --pass <p>        — Destination registry password / token
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
        --archive)  MODE="archive"; shift ;;
        --load)     MODE="load"; shift ;;
        --user)     DEST_USER="$2"; shift 2 ;;
        --pass)     DEST_PASS="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Prompt for credentials if not provided (not needed for --archive only).
# If stdin isn't a terminal (CI, automation, a non-interactive shell), `read`
# hits EOF immediately and fails under `set -e`, killing the script silently
# with no output. Detect that case explicitly and fail loudly instead.
if [[ "${MODE}" != "archive" ]]; then
    if [[ ( -z "${DEST_USER}" || -z "${DEST_PASS}" ) && ! -t 0 ]]; then
        echo "ERROR: --user/--pass not provided and stdin is not a terminal (non-interactive run)." >&2
        echo "       Pass credentials explicitly: bash mirror-images.sh --${MODE} --user <user> --pass <token>" >&2
        exit 1
    fi
    if [[ -z "${DEST_USER}" ]]; then
        read -rp "Registry username: " DEST_USER
    fi
    if [[ -z "${DEST_PASS}" ]]; then
        read -rsp "Registry password/token: " DEST_PASS; echo
    fi
fi

# DEST_CREDS_ARG is deliberately word-split (not quoted) at each use below:
# it must expand to two argv entries ("--dest-creds" and "user:pass") for
# skopeo. Quoting it would pass both as one argument and break the flag.
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
    echo "Done. Transfer the 'images/' directory and this package folder to the customer machine, then run:"
    echo "  bash mirror-images.sh --load --user <user> --pass <token>"
    ;;

  load)
    echo "Loading and pushing images from ./images/ to destination registry..."
    echo "  Pushing operator image to ${DST_OPERATOR}..."
    # shellcheck disable=SC2086
    skopeo copy --override-os linux ${DEST_CREDS_ARG} oci-archive:images/operator.tar docker://${DST_OPERATOR}
    echo "  Pushing OLM bundle image to ${DST_BUNDLE}..."
    # shellcheck disable=SC2086
    skopeo copy --override-os linux ${DEST_CREDS_ARG} oci-archive:images/bundle.tar docker://${DST_BUNDLE}
    echo ""
    echo "Done. Images are now available in the destination registry."
    ;;

  online)
    echo "Mirroring images directly between registries..."
    echo "  Mirroring operator image..."
    # shellcheck disable=SC2086
    skopeo copy --override-os linux ${DEST_CREDS_ARG} docker://${SRC_OPERATOR} docker://${DST_OPERATOR}
    if skopeo inspect --override-os linux docker://${SRC_BUNDLE} &>/dev/null; then
        echo "  Mirroring OLM bundle image..."
        # shellcheck disable=SC2086
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
            -e "s|__SRC_BUNDLE__|${BUNDLE_IMG}|g" \
            -e "s|__DST_BUNDLE__|${CUSTOMER_BUNDLE}|g" \
            "${PACKAGE_DIR}/mirror-images.sh"
    else
        sed -i \
            -e "s|__SRC_OPERATOR__|${IMAGE_TAG}|g" \
            -e "s|__DST_OPERATOR__|${CUSTOMER_IMAGE}|g" \
            -e "s|__SRC_BUNDLE__|${BUNDLE_IMG}|g" \
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
#   Uses 'operator-sdk run bundle --install-mode SingleNamespace=<ns>' which
#   automatically creates the OperatorGroup with the right targetNamespaces
#   and a temporary CatalogSource on the cluster. No opm, no FBC image, no
#   manual OperatorGroup yaml needed.
#   Prerequisites:
#     - OLM installed (operator-sdk olm install)
#     - Operator's home namespace created (default 'kserve-operator-system';
#       override at deploy time via OPERATOR_NS env var)
#     - The KServe target namespace (default 'kserve') created
#   To uninstall: operator-sdk cleanup ${TARGET_DIR_NAME} -n \${OPERATOR_NS}
#
# OPTION B — Direct manifest install (no OLM required)
#   Standard kubectl apply. Simpler but bypasses OLM lifecycle management.
#   Requires the same two namespaces above.
#
# Usage:
#   bash deploy-bundle.sh [pull-secret-name]
#
# Environment variables:
#   OPERATOR_NS  Operator's home namespace (default 'kserve-operator-system').
#                Override at deploy time:
#                  OPERATOR_NS=my-ops bash deploy-bundle.sh
#   KSERVE_NS    KServe target namespace (default: 'kserve'). Override to
#                install KServe into a custom-named namespace.
# =============================================================================
set -e

BUNDLE_IMAGE="${CUSTOMER_BUNDLE}"
OPERATOR_NS="\${OPERATOR_NS:-kserve-operator-system}"
KSERVE_NS="\${KSERVE_NS:-kserve}"
PULL_SECRET="\${1:-}"

echo "================================================================="
echo " KServe Raw Operator — Deployment"
echo "================================================================="
echo "  Bundle image     : \${BUNDLE_IMAGE}"
echo "  Operator ns      : \${OPERATOR_NS}"
echo "  KServe target ns : \${KSERVE_NS}"
echo "================================================================="
echo "  A) OLM bundle  : operator-sdk run bundle (recommended)"
echo "  B) Direct YAML : kubectl apply -f operator-deployment.yaml"
echo "================================================================="
read -rp "Enter choice [A/B]: " CHOICE

case "\$(echo "\${CHOICE}" | tr '[:lower:]' '[:upper:]')" in
  A)
    echo ""
    echo "Installing via OLM bundle: \${BUNDLE_IMAGE}"
    echo "  --namespace=\${OPERATOR_NS}"
    echo "  --install-mode=SingleNamespace=\${KSERVE_NS}"
    if [ -n "\${PULL_SECRET}" ]; then
        operator-sdk run bundle "\${BUNDLE_IMAGE}" \\
            --namespace "\${OPERATOR_NS}" \\
            --install-mode "SingleNamespace=\${KSERVE_NS}" \\
            --pull-secret-name "\${PULL_SECRET}"
    else
        operator-sdk run bundle "\${BUNDLE_IMAGE}" \\
            --namespace "\${OPERATOR_NS}" \\
            --install-mode "SingleNamespace=\${KSERVE_NS}"
    fi
    echo ""
    echo "Operator installed via OLM into '\${OPERATOR_NS}'."
    echo "To uninstall: operator-sdk cleanup ${TARGET_DIR_NAME} -n \${OPERATOR_NS}"
    ;;
  B)
    echo ""
    echo "Installing via direct manifest..."
    kubectl apply -f operator-deployment.yaml
    echo ""
    echo "Operator deployed. The operator auto-creates the KServeRawMode CR"
    echo "in '\${KSERVE_NS}'; no manual 'kubectl apply -f kserve-rawmode.yaml' needed."
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
#                               [--server docker.io] [--also-workload-ns]
#
#   Interactive (prompted if args not provided):
#     bash setup-credentials.sh
#
# Design D — three-namespace model (see extra-docs/design-d-three-namespace-model.md):
#   1. Operator-home          ($SYSTEM_NS)            — operator pod + RBAC + pull secret
#   2. Runtime-control        (KServe controllers)    — controllers + webhooks + CR
#   3. Workload ns(es)        ($KSERVE_WORKLOAD_NS)   — InferenceServices, predictor pods
#
# This script only manages secret placement; the operator-install step creates ns #2.
#
# Namespace lifecycle:
#   default                       — always exists (the default workload ns)
#   $SYSTEM_NS                    — created by user before running this script
#   $KSERVE_WORKLOAD_NS (each)    — created by user before running this script
#   olm, operators                — created by: operator-sdk olm install
#   cert-manager                  — created by the user when installing cert-manager
# =============================================================================
set -e

SECRET_NAME="__SECRET_NAME__"
DOCKER_SERVER="docker.io"
DOCKER_USERNAME=""
DOCKER_PASSWORD=""

# Generator-time switch: did this package get built with --customer-registry?
# If true, the package's image refs point to a private registry; workload-ns
# pull secrets are needed so predictor pods can pull predictor-runtime images.
# If false, the package uses public Docker Hub images; workload-ns pull secrets
# are NOT created (over-provisioning to public-image-only namespaces).
# Customer can force-enable with --also-workload-ns regardless of this flag.
CUSTOMER_REGISTRY_ENABLED="__CUSTOMER_REGISTRY_ENABLED__"
ALSO_WORKLOAD_NS=false

# Operator's home namespace (Design D ns #1). Default 'kserve-operator-system';
# customer overrides at runtime via SYSTEM_NS env var
# (e.g. SYSTEM_NS=my-ops bash setup-credentials.sh ...).
SYSTEM_NS="${SYSTEM_NS:-kserve-operator-system}"

# Workload namespace(s) (Design D ns #3). Comma-separated; default 'default'.
# Override via KSERVE_WORKLOAD_NS env var:
#   KSERVE_WORKLOAD_NS=team-fraud bash setup-credentials.sh ...                # single team
#   KSERVE_WORKLOAD_NS=team-a,team-b,team-c bash setup-credentials.sh ...      # multi-team
KSERVE_WORKLOAD_NS="${KSERVE_WORKLOAD_NS:-default}"
IFS=',' read -ra WORKLOAD_NSES <<<"$KSERVE_WORKLOAD_NS"

# Parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)    DOCKER_USERNAME="$2"; shift 2 ;;
        --pass)    DOCKER_PASSWORD="$2"; shift 2 ;;
        --server)  DOCKER_SERVER="$2"; shift 2 ;;
        --also-workload-ns)
            # Force pull-secret creation in every workload ns even when the
            # package was built without --customer-registry. Use this if your
            # predictor images come from a private registry but you didn't
            # build with --customer-registry rewriting.
            ALSO_WORKLOAD_NS=true; shift ;;
        --non-olm)
            # DEPRECATED: kept as a silent no-op for backwards compatibility.
            # The script's namespace footprint is governed by Design D + the
            # --customer-registry build-time flag, NOT by deploy mode (OLM vs
            # direct). Safe to drop --non-olm from invocations.
            shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: bash setup-credentials.sh [OPTIONS]

OPTIONS:
  --user <username>          Registry username (prompts if not given)
  --pass <password>          Registry password/token (prompts if not given)
  --server <registry>        Registry host (default: docker.io)
  --also-workload-ns         Force pull-secret in workload ns(es) even when
                             package was built without --customer-registry
                             (use if predictor images are private)
  -h, --help                 Show this help and exit

SECRET NAME:
  The pull secret is always named 'dockerhub-creds' (set at build time via
  --pull-secret, default 'dockerhub-creds'). Pass this name to
  --pull-secret-name when running the operator bundle or deployment.

ENV VARS:
  SYSTEM_NS                  Operator's home ns (Design D #1).
                             Default: kserve-operator-system.
  KSERVE_WORKLOAD_NS         Workload ns(es) (Design D #3). Comma-separated.
                             Default: default.
                             Examples:
                               KSERVE_WORKLOAD_NS=team-fraud
                               KSERVE_WORKLOAD_NS=team-a,team-b,team-c

DESIGN D — pull-secret placement:
  Always:   $SYSTEM_NS (operator + bundle pods pull from here)
  If built with --customer-registry  OR  --also-workload-ns is passed:
            also created in each $KSERVE_WORKLOAD_NS ns.
  Otherwise: workload ns gets no pull secret (public images don't need one).

See extra-docs/design-d-three-namespace-model.md for the architecture rationale.

DEPRECATED FLAGS (silently ignored):
  --non-olm                  No-op. Footprint is governed by Design D,
                             not deploy mode.
USAGE
            exit 0 ;;
        *) echo "Unknown arg: $1"; echo "Try: bash setup-credentials.sh --help"; exit 1 ;;
    esac
done

# Decide whether workload ns(es) need the pull secret.
NEED_WORKLOAD_SECRET=false
if [[ "${CUSTOMER_REGISTRY_ENABLED}" == "true" || "${ALSO_WORKLOAD_NS}" == "true" ]]; then
    NEED_WORKLOAD_SECRET=true
fi

# Prompt interactively if not provided
if [[ -z "${DOCKER_USERNAME}" ]]; then
    read -rp "Registry username: " DOCKER_USERNAME
fi
if [[ -z "${DOCKER_PASSWORD}" ]]; then
    read -rsp "Registry password/token: " DOCKER_PASSWORD; echo
fi

# Pre-flight: validate required cluster prerequisites BEFORE creating any secrets.
# Fails fast with a clear list of what's missing so the user can fix and re-run.
#
# Design D (per extra-docs/design-d-three-namespace-model.md): pull secret lands
# in SYSTEM_NS always; in each KSERVE_WORKLOAD_NS when needed. Fail-fast on each
# missing ns — auto-create is intentionally avoided (catches typos; lets OPA /
# Kyverno admission policies enforce per-ns labels the user wants).
echo "Pre-flight checks..." >&2
MISSING=()

# 1. cert-manager is a hard prerequisite for the operator (validated at reconcile
#    time too — we surface it here for a clearer earlier signal).
if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    MISSING+=("cert-manager — CRD certificates.cert-manager.io not registered")
fi

# 2. The operator's system namespace must already exist so kubectl create secret
#    has a target.
if ! kubectl get ns "${SYSTEM_NS}" >/dev/null 2>&1; then
    MISSING+=("namespace '${SYSTEM_NS}' — required for the operator pull secret")
fi

# 3. Each workload namespace must exist when we're going to land a secret there.
if [[ "${NEED_WORKLOAD_SECRET}" == "true" ]]; then
    for ns in "${WORKLOAD_NSES[@]}"; do
        if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
            MISSING+=("namespace '${ns}' — workload ns required when --customer-registry was used (or --also-workload-ns is set)")
        fi
    done
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "" >&2
    echo "❌ Prerequisites not met:" >&2
    for item in "${MISSING[@]}"; do
        echo "   - ${item}" >&2
    done
    echo "" >&2
    echo "Fix the missing items below, then re-run this script." >&2
    echo "" >&2
    echo "   # cert-manager (cluster prerequisite — pinned stable release):" >&2
    echo "   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml" >&2
    echo "   kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s" >&2
    echo "" >&2
    echo "   # Operator pod's home namespace (Design D #1, always required):" >&2
    echo "   kubectl create namespace ${SYSTEM_NS}" >&2
    echo "" >&2
    echo "   # KServe runtime-control namespace (Design D #2, created at operator-install time):" >&2
    echo "   kubectl create namespace kserve   # or your custom name (KSERVE_NS at install-operator-deployment.sh time)" >&2
    echo "" >&2
    if [[ "${NEED_WORKLOAD_SECRET}" == "true" ]]; then
        echo "   # Workload namespace(s) (Design D #3, where your InferenceServices live):" >&2
        for ns in "${WORKLOAD_NSES[@]}"; do
            echo "   kubectl create namespace ${ns}" >&2
        done
        echo "" >&2
    fi
    echo "   # If using OLM (Option A in QUICK_START.md Step 4):" >&2
    echo "   operator-sdk olm install   # creates 'olm' + 'operators' ns automatically" >&2
    exit 1
fi

echo "   ✅ cert-manager CRD registered" >&2
echo "   ✅ namespace '${SYSTEM_NS}' exists" >&2
if [[ "${NEED_WORKLOAD_SECRET}" == "true" ]]; then
    for ns in "${WORKLOAD_NSES[@]}"; do
        echo "   ✅ workload namespace '${ns}' exists" >&2
    done
fi
echo "" >&2

create_secret() {
    local ns=$1
    echo "Creating pull secret '${SECRET_NAME}' in namespace '${ns}'..." >&2
    kubectl create secret docker-registry "${SECRET_NAME}" \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${DOCKER_USERNAME}" \
        --docker-password="${DOCKER_PASSWORD}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

# Design D pull-secret placement (see ADR for rationale):
#   SYSTEM_NS         — always (operator + bundle CatalogSource pods)
#   WORKLOAD_NS(ES)   — only when CUSTOMER_REGISTRY_ENABLED=true OR --also-workload-ns
#                       (predictor pods only need pull secrets for private images)
SECRET_NSES=("${SYSTEM_NS}")
if [[ "${NEED_WORKLOAD_SECRET}" == "true" ]]; then
    SECRET_NSES+=("${WORKLOAD_NSES[@]}")
fi

# Dedup (e.g. KSERVE_WORKLOAD_NS=default + SYSTEM_NS=default would collide).
# Use a linear-scan O(n^2) dedup so this stays compatible with bash 3.2
# (macOS default) — associative arrays (declare -A) are bash 4+ only.
UNIQUE_NSES=()
for ns in "${SECRET_NSES[@]}"; do
    skip=false
    for existing in "${UNIQUE_NSES[@]:-}"; do
        if [[ "${existing}" == "${ns}" ]]; then
            skip=true
            break
        fi
    done
    [[ "${skip}" == "false" ]] && UNIQUE_NSES+=("${ns}")
done

for ns in "${UNIQUE_NSES[@]}"; do
    create_secret "${ns}"
done

echo "" >&2
echo "✅ Pull secret '${SECRET_NAME}' created in: ${UNIQUE_NSES[*]}." >&2
if [[ "${NEED_WORKLOAD_SECRET}" != "true" ]]; then
    echo "   (Workload ns skipped — package uses public images. Pass --also-workload-ns or rebuild with --customer-registry if predictors need pull access.)" >&2
fi
echo "" >&2
echo "Next: deploy the operator (Step 4 in QUICK_START.md):" >&2
echo "   # Option A — OLM bundle (recommended):" >&2
echo "   bash deploy-bundle.sh ${SECRET_NAME}      # interactive helper (only if --customer-registry was used)" >&2
echo "   # ─ or ─" >&2
echo "   operator-sdk run bundle <bundle-image> \\" >&2
echo "       --namespace ${SYSTEM_NS} \\" >&2
echo "       --install-mode SingleNamespace=<your-kserve-ns> \\" >&2
echo "       --pull-secret-name ${SECRET_NAME}" >&2
echo "" >&2
echo "   # Option B — direct manifest (no OLM):" >&2
echo "   bash install-operator-deployment.sh   # wrapper rewrites namespaces from env vars" >&2
CREDS_EOF
# Inject generator-time secret name and customer-registry flag.
# (SYSTEM_NS is inlined as 'kserve-operator-system' directly in the heredoc;
# KSERVE_WORKLOAD_NS defaults to 'default' inline; both customer-overridable
# at runtime via env vars.)
CUSTOMER_REGISTRY_FLAG="false"
if [ -n "${CUSTOMER_REGISTRY}" ]; then
    CUSTOMER_REGISTRY_FLAG="true"
fi
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|__SECRET_NAME__|${SECRET_NAME}|g" "${PACKAGE_DIR}/setup-credentials.sh"
    sed -i '' "s|__CUSTOMER_REGISTRY_ENABLED__|${CUSTOMER_REGISTRY_FLAG}|g" "${PACKAGE_DIR}/setup-credentials.sh"
else
    sed -i "s|__SECRET_NAME__|${SECRET_NAME}|g" "${PACKAGE_DIR}/setup-credentials.sh"
    sed -i "s|__CUSTOMER_REGISTRY_ENABLED__|${CUSTOMER_REGISTRY_FLAG}|g" "${PACKAGE_DIR}/setup-credentials.sh"
fi
chmod +x "${PACKAGE_DIR}/setup-credentials.sh"
echo "Generated setup-credentials.sh in the customer package (credentials provided at runtime — not embedded)."

# Generate install-operator-deployment.sh — pure deploy-time namespace-rewrite
# wrapper for Option B (kubectl apply -f operator-deployment.yaml). Mirrors
# the install.sh Python-YAML-walk pattern from kserve-raw-base/install.sh.tmpl
# (Issue #1 fix). The baked default in operator-deployment.yaml is
# 'kserve-operator-system'; customers customize at deploy time via the
# OPERATOR_NAMESPACE and/or KSERVE_NS env vars on this script.
cat > "${PACKAGE_DIR}/install-operator-deployment.sh" <<'INSTALL_OP_EOF'
#!/bin/bash
# =============================================================================
# install-operator-deployment.sh — Option B (direct manifest) installer with
# pure deploy-time namespace selection.
#
# Wraps `kubectl apply -f operator-deployment.yaml` with a Python YAML rewrite
# step so the operator can be deployed into ANY namespace at deploy time —
# without needing to regenerate the package. Mirrors install.sh's pattern
# from kserve-raw-base for KServe manifests.
#
# Usage:
#   bash install-operator-deployment.sh
#       Install into the baked-in default namespace (no rewrite).
#
#   OPERATOR_NAMESPACE=my-ops bash install-operator-deployment.sh
#       Install operator into 'my-ops' (or any other namespace) at deploy
#       time. The script rewrites every namespace reference in
#       operator-deployment.yaml before applying.
#
#   KSERVE_NS=servewell bash install-operator-deployment.sh
#       Tell the operator to watch 'servewell' (instead of the default
#       'kserve') for KServeRawMode CRs + install KServe runtime there.
#       The script rewrites the Deployment's WATCH_NAMESPACE env var from
#       the OLM-downward-API source to a hardcoded literal value. Useful
#       for non-OLM (Option B) deploys that want a custom KServe namespace.
#
#   OPERATOR_NAMESPACE=my-ops KSERVE_NS=servewell bash install-operator-deployment.sh
#       Both overrides combined. Operator lands in 'my-ops'; CR + KServe
#       runtime land in 'servewell'. Make sure both namespaces exist.
#
#   bash install-operator-deployment.sh --dry-run
#       Print the rewritten YAML to stdout instead of applying.
#
# Prerequisites:
#   - kubectl (any recent version)
#   - cert-manager installed in the cluster
#   - python3 + PyYAML on the machine running the script
#   - The target namespace either pre-created OR will be created by this
#     script's apply step (operator-deployment.yaml includes a Namespace
#     resource).
#
# Categories rewritten (smaller than install.sh's set because operator-
# deployment.yaml has no cert-manager Certificates, no webhook configs,
# no inject-ca-from annotations):
#   - Namespace.metadata.name (rename the Namespace resource itself)
#   - metadata.namespace on SA, Role, RoleBinding, Service, Deployment
#   - subjects[].namespace on (Cluster)RoleBinding
#
# When OPERATOR_NAMESPACE is unset OR matches the baked default, no rewrite
# happens — stdin/stdout passes through verbatim. Byte-equivalent to
# `kubectl apply -f operator-deployment.yaml` in that case.
# =============================================================================
set -e

OPERATOR_NS_DEFAULT="kserve-operator-system"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-${OPERATOR_NS_DEFAULT}}"
# KSERVE_NS, if set, rewrites the Deployment's WATCH_NAMESPACE env var to
# point at the user's chosen KServe target namespace. Empty (the default)
# means leave WATCH_NAMESPACE alone — operator uses its fallback of "kserve".
KSERVE_NS="${KSERVE_NS:-}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '3,40p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $1"; echo "Try: bash install-operator-deployment.sh --help"; exit 1 ;;
    esac
done

# Pre-flight
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_FILE="${SCRIPT_DIR}/operator-deployment.yaml"

if [ ! -f "${YAML_FILE}" ]; then
    echo "ERROR: ${YAML_FILE} not found." >&2
    exit 1
fi

echo "Pre-flight: checking python3 + PyYAML..." >&2
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found on PATH." >&2
    exit 1
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "ERROR: Python 'PyYAML' module is required but not importable." >&2
    echo "       Install: pip3 install --user PyYAML" >&2
    exit 1
fi
echo "      python3 + PyYAML detected." >&2

if [ "${DRY_RUN}" != true ]; then
    echo "Pre-flight: checking cert-manager..." >&2
    if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        echo "ERROR: cert-manager is not installed in this cluster." >&2
        echo "       Install it before re-running this script." >&2
        exit 1
    fi
    echo "      cert-manager detected." >&2
fi

echo "Target operator namespace: ${OPERATOR_NAMESPACE} (baked default: ${OPERATOR_NS_DEFAULT})" >&2
if [ -n "${KSERVE_NS}" ]; then
    echo "Target KServe namespace:    ${KSERVE_NS} (rewriting WATCH_NAMESPACE env var)" >&2
fi

# Rewrite + apply in one pipeline. The Python source is passed via -c so
# the YAML stream stays on stdin.
rewrite_ns() {
    OPERATOR_NS_BAKED="${OPERATOR_NS_DEFAULT}" \
    OPERATOR_NS_TARGET="${OPERATOR_NAMESPACE}" \
    KSERVE_NS_TARGET="${KSERVE_NS}" \
    python3 -c "$(cat <<'PY_EOF'
import os, sys, yaml

BAKED      = os.environ["OPERATOR_NS_BAKED"]
TARGET     = os.environ["OPERATOR_NS_TARGET"]
KSERVE_NS  = os.environ.get("KSERVE_NS_TARGET", "")

def rewrite_watch_namespace(doc):
    # In the operator Deployment, locate the WATCH_NAMESPACE env entry
    # and replace its valueFrom (downward-API OLM annotation) with a
    # hardcoded value. Only invoked when KSERVE_NS is set.
    if doc.get("kind") != "Deployment":
        return
    spec = doc.get("spec") or {}
    tmpl = spec.get("template") or {}
    pspec = tmpl.get("spec") or {}
    for c in pspec.get("containers") or []:
        if not isinstance(c, dict):
            continue
        envs = c.get("env") or []
        for entry in envs:
            if isinstance(entry, dict) and entry.get("name") == "WATCH_NAMESPACE":
                # Drop valueFrom (downward-API OLM annotation), set literal.
                entry.pop("valueFrom", None)
                entry["value"] = KSERVE_NS

def rewrite_doc(doc):
    if not isinstance(doc, dict):
        return doc

    kind = doc.get("kind")
    meta = doc.get("metadata") or {}

    # 1. Namespace resource: rename via metadata.name
    if kind == "Namespace" and meta.get("name") == BAKED:
        meta["name"] = TARGET
        doc["metadata"] = meta

    # 2. Namespaced resources: rewrite metadata.namespace
    if meta.get("namespace") == BAKED:
        meta["namespace"] = TARGET
        doc["metadata"] = meta

    # 3. (Cluster)RoleBinding subjects[].namespace
    if kind in ("ClusterRoleBinding", "RoleBinding"):
        for subj in doc.get("subjects") or []:
            if isinstance(subj, dict) and subj.get("namespace") == BAKED:
                subj["namespace"] = TARGET

    # 4. Deployment WATCH_NAMESPACE env var (only if KSERVE_NS set)
    if KSERVE_NS:
        rewrite_watch_namespace(doc)

    return doc

# Short-circuit: TARGET == BAKED AND KSERVE_NS unset → no rewrite at all.
# stdin → stdout verbatim.
if TARGET == BAKED and not KSERVE_NS:
    sys.stdout.write(sys.stdin.read())
    sys.exit(0)

docs = list(yaml.safe_load_all(sys.stdin))
out  = [rewrite_doc(d) for d in docs if d is not None]
yaml.safe_dump_all(out, sys.stdout, default_flow_style=False, sort_keys=False)
PY_EOF
)"
}

if [ "${DRY_RUN}" = true ]; then
    rewrite_ns < "${YAML_FILE}"
else
    rewrite_ns < "${YAML_FILE}" | kubectl apply -f -
    echo "" >&2
    echo "✅ Operator deployment applied to namespace: ${OPERATOR_NAMESPACE}" >&2
    if [ -n "${KSERVE_NS}" ]; then
        echo "✅ Operator will watch KServe target namespace: ${KSERVE_NS}" >&2
        echo "   (Make sure '${KSERVE_NS}' namespace exists before the auto-init retries exhaust.)" >&2
    fi
    echo "" >&2
    echo "Verify the operator pod is running:" >&2
    echo "  kubectl get pods -n ${OPERATOR_NAMESPACE}" >&2
fi
INSTALL_OP_EOF
chmod +x "${PACKAGE_DIR}/install-operator-deployment.sh"
echo "Generated install-operator-deployment.sh — Option B deploy-time namespace rewrite wrapper."

# Generate enable-ingress.sh — wraps the ConfigMap patch + controller restart
# needed to flip KServe from Standard-no-Ingress mode (default) to
# create-Ingress-via-<class> mode. Always generated; only relevant if the
# user wants external URLs via an ingress controller (nginx, haproxy, etc.).
cat > "${PACKAGE_DIR}/enable-ingress.sh" <<'INGRESS_EOF'
#!/bin/bash
# =============================================================================
# enable-ingress.sh — enable Kubernetes Ingress creation in KServe
#
# Patches inferenceservice-config so KServe creates Ingress resources for
# InferenceServices. By default KServe in Raw mode disables this — you only
# need this script if you want external-URL access via an ingress controller
# (nginx, haproxy, traefik, etc.).
#
# Usage:
#   bash enable-ingress.sh                      # default: ns=kserve, class=nginx
#   KSERVE_NS=my-kserve bash enable-ingress.sh  # custom KServe ns
#   bash enable-ingress.sh --class haproxy      # custom ingress class
#
# Prerequisites:
#   - KServe is installed in $KSERVE_NS (CR phase Ready, controller pod up)
#   - Your chosen ingress controller is installed and registered as an
#     IngressClass on the cluster
#
# After running:
#   Existing InferenceServices were created without an Ingress and need to
#   be recreated to pick up the new config:
#     kubectl delete isvc <name>
#     kubectl apply -f <isvc-yaml>
# =============================================================================
set -e

KSERVE_NS="${KSERVE_NS:-kserve}"
INGRESS_CLASS="nginx"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --class) INGRESS_CLASS="$2"; shift 2 ;;
        --ns)    KSERVE_NS="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,24p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $1"; echo "Usage: bash enable-ingress.sh [--class <name>] [--ns <kserve-ns>]"; exit 1 ;;
    esac
done

if ! kubectl get cm inferenceservice-config -n "${KSERVE_NS}" >/dev/null 2>&1; then
    echo "❌ ConfigMap inferenceservice-config not found in namespace '${KSERVE_NS}'."
    echo "   Has KServe been installed there?  Check: kubectl get kserverawmode -A"
    exit 1
fi

echo "Patching inferenceservice-config in '${KSERVE_NS}':"
echo "  ingressClassName       = ${INGRESS_CLASS}"
echo "  disableIngressCreation = false"

# The 'ingress' field is a JSON-encoded string inside the ConfigMap — parse,
# modify, re-serialize. --force-conflicts takes ownership from the operator's
# SSA field manager.
kubectl get cm inferenceservice-config -n "${KSERVE_NS}" -o json \
  | INGRESS_CLASS="${INGRESS_CLASS}" python3 -c "
import json, sys, os
cm = json.load(sys.stdin)
ing = json.loads(cm['data']['ingress'])
ing['ingressClassName'] = os.environ['INGRESS_CLASS']
ing['disableIngressCreation'] = False
cm['data']['ingress'] = json.dumps(ing)
cm['metadata'].pop('managedFields', None)
print(json.dumps(cm))
" | kubectl apply --server-side --force-conflicts -f - >/dev/null

echo "Restarting kserve-controller-manager..."
kubectl rollout restart deployment kserve-controller-manager -n "${KSERVE_NS}" >/dev/null
kubectl wait --for=condition=Ready pods -l control-plane=kserve-controller-manager -n "${KSERVE_NS}" --timeout=120s

# Webhook race workaround (closes Issue #7 from extra-docs/0.16-test-report.md):
# kubectl wait Ready flips on the controller pod's HTTP /healthz probe (port 8081),
# but the webhook HTTPS server on port 9443 takes several seconds longer to start
# listening. A kubectl apply of an InferenceService in that window fails with
# "context deadline exceeded" from the defaulting webhook. We probe the webhook
# Service's TLS endpoint directly from inside the cluster (via an ephemeral curl
# Pod) until it answers, with a bounded timeout. --insecure because the cert is
# self-signed by cert-manager; we're proving TLS-handshake completes, not
# verifying identity.
echo "Probing webhook TLS endpoint..."
PROBE_NAME="kserve-webhook-probe-$$"
# Single-quoted heredoc-style script body below is intentional: it's the
# in-cluster probe Pod's own shell script, not local bash — quoting protects
# its $i/$(seq...) syntax from expanding on the host before kubectl ships it.
# shellcheck disable=SC2016
if ! kubectl run -n "${KSERVE_NS}" "${PROBE_NAME}" \
        --image=curlimages/curl:8.10.1 \
        --restart=Never \
        --quiet \
        --attach \
        --rm \
        --image-pull-policy=IfNotPresent \
        --command -- sh -c '
            set -eu
            for i in $(seq 1 30); do
                if curl --silent --insecure --output /dev/null \
                        --max-time 3 \
                        https://kserve-webhook-server-service:443/ ; then
                    echo "  webhook responsive after attempt ${i}/30"
                    exit 0
                fi
                sleep 2
            done
            echo "  ERROR: webhook did not respond to 30 probes over ~60 seconds" >&2
            exit 1
        ' ; then
    echo "❌ Webhook is not responsive after rollout. Re-run enable-ingress.sh, or"
    echo "   inspect: kubectl logs -n ${KSERVE_NS} deploy/kserve-controller-manager"
    exit 1
fi

echo ""
echo "✅ KServe Ingress creation enabled (class: ${INGRESS_CLASS}, ns: ${KSERVE_NS})."
echo ""
echo "Existing InferenceServices need to be recreated to pick up the new config:"
echo "   kubectl delete isvc <name>"
echo "   kubectl apply -f <isvc-yaml>"
INGRESS_EOF
chmod +x "${PACKAGE_DIR}/enable-ingress.sh"
echo "Generated enable-ingress.sh — customer runs this to enable external-URL access via an ingress controller."


if [ "$GEN_OLM_BUNDLE" = true ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|<your-bundle-image>|${BUNDLE_IMG}|g" "${PACKAGE_DIR}/README.md"
    else
        sed -i "s|<your-bundle-image>|${BUNDLE_IMG}|g" "${PACKAGE_DIR}/README.md"
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
    if [ -n "${CUSTOMER_REGISTRY}" ]; then
        echo "To deploy via OLM (customer-registry flow):"
        echo "  1. cd ${PACKAGE_DIR##*/}"
        echo "  2. bash mirror-images.sh --archive             # then transfer to customer site"
        echo "  3. bash mirror-images.sh --load --user <u> --pass <t>"
        echo "  4. bash setup-credentials.sh --user <u> --pass <t>"
        echo "  5. bash deploy-bundle.sh dockerhub-creds       # interactive helper"
        echo ""
        echo "  …or run operator-sdk directly against the customer registry:"
        echo "  operator-sdk run bundle ${CUSTOMER_BUNDLE} \\"
        echo "    --namespace kserve-operator-system \\"
        echo "    --install-mode SingleNamespace=kserve \\"
        echo "    --pull-secret-name dockerhub-creds"
    else
        echo "To deploy via OLM, execute the following command:"
        echo "  operator-sdk run bundle ${BUNDLE_IMG} \\"
        echo "    --namespace kserve-operator-system \\"
        echo "    --install-mode SingleNamespace=kserve"
    fi
fi
echo "================================================================="
