#!/bin/bash
# =============================================================================
# print-build-versions.sh
#
# Purpose: print the version of every tool the builder scripts use.
#
# Use cases:
#   - Attach to a bug report / Slack message about a build failure.
#   - Side-by-side diff against the known-good versions documented in
#     QUICK_START.md "Validated toolchain versions (known-good for ...)".
#
# This is a passive dump — it does NOT fail on missing or old versions.
# For a smart pass/fail pre-flight gate, see check-build-prereqs.sh.
# =============================================================================

# Helper — print "label: value" with NOT INSTALLED fallback
probe() {
    local label="$1"; shift
    local out
    if ! command -v "$1" >/dev/null 2>&1; then
        printf "  %-14s NOT INSTALLED\n" "${label}:"
        return
    fi
    out=$("$@" 2>&1 | head -1)
    printf "  %-14s %s\n" "${label}:" "${out}"
}

echo "=== build-side toolchain (compare against QUICK_START.md § Validated toolchain) ==="
probe "Go"           go version
probe "operator-sdk" operator-sdk version
probe "Docker"       docker --version
probe "Podman"       podman --version
probe "Python"       python3 --version
# PyYAML needs a -c invocation (not --version)
if python3 -c 'import yaml' >/dev/null 2>&1; then
    printf "  %-14s %s\n" "PyYAML:" "$(python3 -c 'import yaml; print(yaml.__version__)')"
else
    printf "  %-14s %s\n" "PyYAML:" "NOT INSTALLED"
fi
probe "yq"           yq --version
probe "kustomize"    kustomize version
probe "kubectl"      kubectl version --client
probe "skopeo"       skopeo --version
probe "make"         make --version

echo
echo "=== os ==="
printf "  %-14s %s\n" "uname:" "$(uname -a)"
if [ -f /etc/os-release ]; then
    name=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
    [ -n "$name" ] && printf "  %-14s %s\n" "distro:" "$name"
fi
if [ "$(uname)" = "Darwin" ]; then
    printf "  %-14s %s\n" "macOS:" "$(sw_vers -productVersion 2>/dev/null) $(sw_vers -buildVersion 2>/dev/null)"
fi
