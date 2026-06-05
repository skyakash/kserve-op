#!/bin/bash
# =============================================================================
# check-build-prereqs.sh
#
# Purpose: pre-flight check for the BUILD-SIDE toolchain. Verifies every tool
# the generator scripts (generate-kserve-raw.sh + generate-kserve-operator.sh)
# use is present and meets the minimum version documented in QUICK_START.md
# § Validated toolchain versions.
#
# Severity levels:
#   REQUIRED    (red ✗)   missing or below floor will cause a build failure
#   RECOMMENDED (yellow ⚠) older may surface edge-case bugs
#   OPTIONAL    (green ✓)  reported as info, no floor enforced
#
# Exit codes:
#   0 = safe to run the generator scripts
#   1 = at least one REQUIRED check failed; fix before building
#
# Deploy-side prereqs (cert-manager, OLM, etc.) are NOT checked here. Those
# are handled by the customer-facing scripts in the generated package
# (setup-credentials.sh, install.sh, install-operator-deployment.sh).
#
# Customer-registry-only tools (skopeo) are reported but not required by
# default — they only matter when generate-kserve-operator.sh is invoked
# with --customer-registry. Pass --customer-registry to this script to
# elevate skopeo to REQUIRED.
# =============================================================================

set -u

# ---- Args ----------------------------------------------------------------
NEED_SKOPEO=0
for a in "$@"; do
    case "$a" in
        --customer-registry) NEED_SKOPEO=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $a"; exit 2 ;;
    esac
done

# ---- Color codes ---------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=""; YELLOW=""; GREEN=""; DIM=""; NC=""
fi

FAIL=0
WARN=0

# ---- Version comparison helper -------------------------------------------
# Returns 0 if $1 >= $2 (semver), 1 otherwise.
ver_ge() {
    [ "$1" = "$2" ] && return 0
    local lowest
    lowest=$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)
    [ "$lowest" = "$2" ]
}

# ---- Check helpers -------------------------------------------------------
check_required() {
    local name="$1" min="$2" actual="$3"
    if [ -z "$actual" ]; then
        printf "  ${RED}✗ %-12s NOT INSTALLED (need ≥%s)${NC}\n" "$name" "$min"
        FAIL=$((FAIL + 1))
        return
    fi
    if ver_ge "$actual" "$min"; then
        printf "  ${GREEN}✓ %-12s %-12s${NC} (need ≥%s)\n" "$name" "$actual" "$min"
    else
        printf "  ${RED}✗ %-12s %-12s TOO OLD${NC} (need ≥%s)\n" "$name" "$actual" "$min"
        FAIL=$((FAIL + 1))
    fi
}

check_recommended() {
    local name="$1" min="$2" actual="$3"
    if [ -z "$actual" ]; then
        printf "  ${YELLOW}⚠ %-12s NOT INSTALLED (recommend ≥%s)${NC}\n" "$name" "$min"
        WARN=$((WARN + 1))
        return
    fi
    if ver_ge "$actual" "$min"; then
        printf "  ${GREEN}✓ %-12s %-12s${NC} (recommend ≥%s)\n" "$name" "$actual" "$min"
    else
        printf "  ${YELLOW}⚠ %-12s %-12s${NC} (recommend ≥%s; older may bite)\n" "$name" "$actual" "$min"
        WARN=$((WARN + 1))
    fi
}

report_optional() {
    local name="$1" actual="$2" note="${3:-}"
    if [ -z "$actual" ]; then
        printf "  ${DIM}- %-12s not installed%s${NC}\n" "$name" "${note:+ — $note}"
    else
        printf "  ${GREEN}✓ %-12s %-12s${NC}${note:+ ${DIM}($note)${NC}}\n" "$name" "$actual"
    fi
}

# ---- Probe each tool's version --------------------------------------------
GO_V=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
OSDK_V=$(operator-sdk version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/v//')
DOCKER_V=$(docker version --format '{{.Client.Version}}' 2>/dev/null)
PODMAN_V=$(podman --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
PYTHON_V=$(python3 --version 2>/dev/null | awk '{print $2}')
PYYAML_V=$(python3 -c 'import yaml; print(yaml.__version__)' 2>/dev/null)
YQ_V=$(yq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
KUSTOMIZE_V=$(kustomize version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/v//')
KUBECTL_V=$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/v//')
SKOPEO_V=$(skopeo --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

echo "Build-side prereq check"
echo "======================="
echo
echo "REQUIRED (failures block the build):"
check_required "operator-sdk" "1.42" "$OSDK_V"
check_required "PyYAML"       "5.1"  "$PYYAML_V"
check_required "yq"           "4.0"  "$YQ_V"
check_required "kustomize"    "5.0"  "$KUSTOMIZE_V"
# A container tool — docker OR podman — is required
if [ -z "$DOCKER_V" ] && [ -z "$PODMAN_V" ]; then
    printf "  ${RED}✗ %-12s NEITHER docker NOR podman installed${NC} (need one)\n" "container"
    FAIL=$((FAIL + 1))
else
    found="docker $DOCKER_V"
    [ -z "$DOCKER_V" ] && found="podman $PODMAN_V"
    [ -n "$DOCKER_V" ] && [ -n "$PODMAN_V" ] && found="docker $DOCKER_V + podman $PODMAN_V"
    printf "  ${GREEN}✓ %-12s %s${NC}\n" "container" "$found"
fi
# skopeo is required only when --customer-registry is in the workflow
if [ "$NEED_SKOPEO" = "1" ]; then
    check_required "skopeo" "1.0" "$SKOPEO_V"
fi

echo
echo "RECOMMENDED (older may surface edge-case bugs):"
check_recommended "Go"      "1.21" "$GO_V"
check_recommended "Python"  "3.7"  "$PYTHON_V"
check_recommended "kubectl" "1.24" "$KUBECTL_V"

echo
echo "OPTIONAL (informational):"
report_optional "make" "$(make --version 2>/dev/null | head -1 | awk '{print $NF}')"
if [ "$NEED_SKOPEO" != "1" ]; then
    report_optional "skopeo" "$SKOPEO_V" "only needed for --customer-registry"
fi

echo
echo "======================="
if [ "$FAIL" -gt 0 ]; then
    printf "${RED}✗ %d REQUIRED check(s) failed. Fix before running the build scripts.${NC}\n" "$FAIL"
    echo "  See QUICK_START.md § Validated toolchain versions for upgrade commands per platform."
    [ "$WARN" -gt 0 ] && printf "${YELLOW}⚠ %d RECOMMENDED check(s) also warned.${NC}\n" "$WARN"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    printf "${YELLOW}⚠ %d RECOMMENDED check(s) below floor. Build will likely work but watch for edge cases.${NC}\n" "$WARN"
    exit 0
else
    printf "${GREEN}✓ All build-side prereqs OK. Safe to run generate-kserve-raw.sh and generate-kserve-operator.sh.${NC}\n"
    exit 0
fi
