#!/usr/bin/env bash
# Parse workflow inputs for package lists
# Handles both real newlines and literal \n from GitHub UI
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"

# ── Package removal list ──────────────────────────────────────
if [ -n "${PACKAGE_REMOVAL_LIST:-}" ]; then
    echo "Processing user-provided package removal list..."

    # Handle both real newlines and literal \n
    echo "$PACKAGE_REMOVAL_LIST" | \
        sed 's/\\n/\n/g' | \
        sed 's/,/\n/g' | \
        sed 's/^[[:space:]]*//' | \
        sed 's/[[:space:]]*$//' | \
        grep -v '^$' | \
        grep -v '^#' | \
        sort -u > "${OUTPUT_DIR}/user-packages.txt"

    COUNT=$(wc -l < "${OUTPUT_DIR}/user-packages.txt" | tr -d ' ')
    echo "Package removal list: ${COUNT} packages written to ${OUTPUT_DIR}/user-packages.txt"
else
    echo "No package removal list provided — will use auto-detection"
fi

# ── Extra packages to keep ────────────────────────────────────
if [ -n "${EXTRA_PACKAGES_KEEP:-}" ]; then
    echo "Processing extra packages to protect..."

    # Convert to space-separated for EXTRA_CRITICAL_PKGS env var
    EXTRA=$(echo "$EXTRA_PACKAGES_KEEP" | \
        sed 's/\\n/ /g' | \
        sed 's/,/ /g' | \
        tr '\n' ' ' | \
        sed 's/^[[:space:]]*//' | \
        sed 's/[[:space:]]*$//')

    echo "Extra protected packages: ${EXTRA}"

    # Export for the build script
    echo "EXTRA_CRITICAL_PKGS=${EXTRA}" >> "${GITHUB_ENV:-/dev/null}"
else
    echo "No extra packages to protect"
fi
