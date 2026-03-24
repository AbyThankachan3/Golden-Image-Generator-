#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  Golden Image Builder — Version-Agnostic Ubuntu ISO Builder
#
#  Usage:
#    ./golden-image-builder.sh 22.04.5
#    ./golden-image-builder.sh --analyze-only 24.04.1
#    ./golden-image-builder.sh --packages-file my-list.txt 22.04.5
#    ./golden-image-builder.sh --auto-approve 22.04.5
#    ./golden-image-builder.sh --url https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Resolve paths ─────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/config.sh"

# ── Defaults ──────────────────────────────────────────────
OUTPUT_DIR="$PROJECT_DIR/output"
CACHE_DIR="$PROJECT_DIR/cache"
PACKAGES_FILE=""
CUSTOM_URL=""
ANALYZE_ONLY=false
AUTO_APPROVE=false
VERSION=""

# Hardening flags (all default to false — opt-in)
HARDENING_LAYER1_ENABLE=false
HARDENING_LAYER2_ENABLE=false
HARDENING_LAYER3_ENABLE=false

# ── CLI Parsing ───────────────────────────────────────────
usage() {
    cat << EOF
${BOLD}Golden Image Builder — Version-Agnostic Ubuntu ISO Builder${NC}

${BOLD}Usage:${NC}
  $0 [OPTIONS] <version>

${BOLD}Arguments:${NC}
  <version>              Ubuntu version (e.g., 22.04.5, 24.04.1, 24.04)

${BOLD}Options:${NC}
  --url <url>            Provide ISO URL directly (skip version resolution)
  --packages-file <f>    Use a pre-made package removal list (skip analysis)
  --analyze-only         Run package analysis, print report, and exit
  --auto-approve         Skip interactive approval (use all SAFE packages)
  --output-dir <dir>     Output directory (default: ./output)
  --cache-dir <dir>      ISO cache directory (default: ./cache)
  --harden-packages      Install encryption packages (cryptsetup, clevis) in squashfs
  --harden-configs       Write SSH/sysctl hardening config files in squashfs
  --harden-cis           Apply CIS Level 1 controls in squashfs (no first-boot needed)
  --harden-all           Enable all three hardening layers
  --output-name <name>   Custom output ISO filename
  -h, --help             Show this help

${BOLD}Examples:${NC}
  $0 22.04.5                                    # Interactive: analyze → approve → build
  $0 --analyze-only 24.04.1                     # Just analyze packages
  $0 --auto-approve 22.04.5                     # Auto-approve SAFE packages
  $0 --packages-file packages-to-remove-4.txt 22.04.5  # Use existing list
  $0 --packages-file safe-packages.txt --harden-all 22.04.5  # Build with full hardening
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url)          CUSTOM_URL="$2"; shift 2 ;;
        --packages-file) PACKAGES_FILE="$2"; shift 2 ;;
        --analyze-only) ANALYZE_ONLY=true; shift ;;
        --auto-approve) AUTO_APPROVE=true; shift ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --cache-dir)    CACHE_DIR="$2"; shift 2 ;;
        --harden-packages) HARDENING_LAYER1_ENABLE=true; shift ;;
        --harden-configs)  HARDENING_LAYER2_ENABLE=true; shift ;;
        --harden-cis)      HARDENING_LAYER3_ENABLE=true; shift ;;
        --harden-all)      HARDENING_LAYER1_ENABLE=true; HARDENING_LAYER2_ENABLE=true; HARDENING_LAYER3_ENABLE=true; shift ;;
        --output-name)  OUTPUT_NAME="$2"; shift 2 ;;
        -h|--help)      usage ;;
        -*)             die "Unknown option: $1" ;;
        *)              VERSION="$1"; shift ;;
    esac
done

# Validate we have either a version or URL
if [ -z "$VERSION" ] && [ -z "$CUSTOM_URL" ]; then
    err "Missing required argument: <version> or --url"
    echo "  Run '$0 --help' for usage."
    exit 1
fi

# ── Export for Docker ─────────────────────────────────────
export PROJECT_DIR OUTPUT_DIR CACHE_DIR

# ══════════════════════════════════════════════════════════
#  PHASE 1: RESOLVE
# ══════════════════════════════════════════════════════════
banner "Golden Image Builder"

echo -e "  ${BOLD}Phase 1: Resolve${NC}"

if [ -n "$CUSTOM_URL" ]; then
    resolve_version "" "$CUSTOM_URL"
else
    resolve_version "$VERSION"
fi

echo -e "  Version    : ${BOLD}$FULL_VERSION${NC}"
echo -e "  ISO        : $ISO_NAME"
echo -e "  Docker     : $DOCKER_BASE"
echo -e "  Output     : $OUTPUT_DIR"
echo ""

# Export resolved vars for docker-runner
export FULL_VERSION MAJOR_MINOR ISO_NAME ISO_URL DOCKER_BASE

# Load version overrides on the host side too
load_overrides "$PROJECT_DIR/configs"

# ── GRUB Password Handling (dual mode) ────────────────────
# Only when Layer 2 (configs) is enabled
GRUB_HASH_FILE="$PROJECT_DIR/hardening/secrets/grub-password.hash"
if [ "$HARDENING_LAYER2_ENABLE" = "true" ]; then
    if [ -f "$GRUB_HASH_FILE" ] && [ -s "$GRUB_HASH_FILE" ]; then
        echo -e "  ${GREEN}✔${NC}  Using existing GRUB password hash"
    else
        echo ""
        echo -e "  ${BOLD}GRUB Password Setup${NC}"
        echo -e "  No GRUB password hash found at: hardening/secrets/grub-password.hash"
        echo ""
        printf "  Enter GRUB password (hidden): "
        read -rs GRUB_PASS_1
        echo ""
        printf "  Confirm GRUB password: "
        read -rs GRUB_PASS_2
        echo ""

        if [ -z "$GRUB_PASS_1" ]; then
            echo -e "  ${YELLOW}⚠${NC}  Empty password — skipping GRUB password protection"
        elif [ "$GRUB_PASS_1" != "$GRUB_PASS_2" ]; then
            die "Passwords do not match"
        else
            echo -e "  Generating GRUB PBKDF2 hash (via Docker)..."
            # grub-mkpasswd-pbkdf2 is Linux-only, run inside Docker
            GRUB_HASH=$(echo -e "${GRUB_PASS_1}\n${GRUB_PASS_1}" | \
                docker run --rm -i --platform linux/amd64 "${DOCKER_BASE}" \
                bash -c "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq grub-common >/dev/null 2>&1 && grub-mkpasswd-pbkdf2 2>/dev/null" | \
                grep "^PBKDF2" | sed 's/.*is //')

            if [ -n "$GRUB_HASH" ]; then
                mkdir -p "$(dirname "$GRUB_HASH_FILE")"
                echo "$GRUB_HASH" > "$GRUB_HASH_FILE"
                # Ensure .gitignore exists for secrets dir
                if [ ! -f "$PROJECT_DIR/hardening/secrets/.gitignore" ]; then
                    echo -e "*\n!.gitignore" > "$PROJECT_DIR/hardening/secrets/.gitignore"
                fi
                echo -e "  ${GREEN}✔${NC}  GRUB password hash generated and saved"
            else
                warn "Could not generate GRUB hash — GRUB password will be skipped"
            fi
        fi
        # Clear password from memory
        unset GRUB_PASS_1 GRUB_PASS_2
        echo ""
    fi
fi

# Download ISO
mkdir -p "$CACHE_DIR" "$OUTPUT_DIR"
download_iso "$CACHE_DIR"

# Validate Docker
if ! docker info &>/dev/null; then
    die "Docker is not running. Please start Docker first."
fi

# ══════════════════════════════════════════════════════════
#  If --packages-file provided, skip analysis → go to build
# ══════════════════════════════════════════════════════════
if [ -n "$PACKAGES_FILE" ]; then
    if [ ! -f "$PACKAGES_FILE" ]; then
        die "Packages file not found: $PACKAGES_FILE"
    fi

    echo -e "  ${BOLD}Skipping analysis — using provided package list: $(basename "$PACKAGES_FILE")${NC}"
    PKG_COUNT=$(grep -v '^#' "$PACKAGES_FILE" | grep -v '^$' | wc -l | tr -d " ")
    echo -e "  Packages to remove: $PKG_COUNT"
    echo ""

    # Go straight to build
    info "Phase 4: Build"

    # Show hardening status
    if [ "$HARDENING_LAYER1_ENABLE" = "true" ] || [ "$HARDENING_LAYER2_ENABLE" = "true" ] || [ "$HARDENING_LAYER3_ENABLE" = "true" ]; then
        echo -e "  ${BOLD}Hardening:${NC}"
        [ "$HARDENING_LAYER1_ENABLE" = "true" ] && echo "    ✔ Encryption packages (cryptsetup, clevis)"
        [ "$HARDENING_LAYER2_ENABLE" = "true" ] && echo "    ✔ SSH/sysctl config hardening"
        [ "$HARDENING_LAYER3_ENABLE" = "true" ] && echo "    ✔ CIS Level 1 controls (in squashfs)"
        echo ""
    fi

    docker run --rm \
        --platform linux/amd64 \
        --privileged \
        -e "PHASE=build" \
        -e "UBUNTU_VERSION=${FULL_VERSION}" \
        -e "MAJOR_MINOR=${MAJOR_MINOR}" \
        -e "ISO_NAME=${ISO_NAME}" \
        -e "HARDENING_LAYER1_ENABLE=${HARDENING_LAYER1_ENABLE}" \
        -e "HARDENING_LAYER2_ENABLE=${HARDENING_LAYER2_ENABLE}" \
        -e "HARDENING_LAYER3_ENABLE=${HARDENING_LAYER3_ENABLE}" \
        -e "HARDENING_CIS_REPO=${HARDENING_CIS_REPO:-}" \
        -e "HARDENING_CIS_BRANCH=${HARDENING_CIS_BRANCH:-main}" \
        -v "${CACHE_DIR}:/input:ro" \
        -v "${OUTPUT_DIR}:/output" \
        -v "${PROJECT_DIR}/lib:/lib-golden:ro" \
        -v "${PROJECT_DIR}/configs:/lib-golden/../configs:ro" \
        -v "${PROJECT_DIR}/hardening:/hardening:ro" \
        -v "$(realpath "$PACKAGES_FILE"):/tmp/approved-packages.txt:ro" \
        "${DOCKER_BASE}" \
        /bin/bash /lib-golden/docker-entrypoint.sh

    echo ""
    banner "BUILD COMPLETE"
    echo -e "  ${GREEN}✅ ISO: ${OUTPUT_DIR}/golden-ubuntu-minimal-${FULL_VERSION}.iso${NC}"
    exit 0
fi

# ══════════════════════════════════════════════════════════
#  PHASE 2: DETECT + ANALYZE (Docker invocation #1)
# ══════════════════════════════════════════════════════════
echo -e "  ${BOLD}Phase 2: Detect + Analyze${NC}"
echo ""

docker run --rm \
    --platform linux/amd64 \
    --privileged \
    -e "PHASE=analyze" \
    -e "UBUNTU_VERSION=${FULL_VERSION}" \
    -e "MAJOR_MINOR=${MAJOR_MINOR}" \
    -e "ISO_NAME=${ISO_NAME}" \
    -v "${CACHE_DIR}:/input:ro" \
    -v "${OUTPUT_DIR}:/output" \
    -v "${PROJECT_DIR}/lib:/lib-golden:ro" \
    -v "${PROJECT_DIR}/configs:/configs:ro" \
    "${DOCKER_BASE}" \
    /bin/bash /lib-golden/docker-entrypoint.sh

# ── Check analysis results ───────────────────────────────
if [ ! -f "$OUTPUT_DIR/package-report.txt" ]; then
    die "Analysis failed — no report generated"
fi

SAFE_COUNT=$(wc -l < "$OUTPUT_DIR/safe-packages.txt" | tr -d " ")
RISKY_COUNT=$(wc -l < "$OUTPUT_DIR/risky-packages.txt" | tr -d " ")
CRITICAL_COUNT=$(wc -l < "$OUTPUT_DIR/critical-packages.txt" | tr -d " ")

echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PACKAGE ANALYSIS RESULTS${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}${BOLD}SAFE to remove:${NC}     ${SAFE_COUNT} packages"
echo -e "  ${YELLOW}${BOLD}RISKY (review):${NC}     ${RISKY_COUNT} packages"
echo -e "  ${RED}${BOLD}CRITICAL (keep):${NC}    ${CRITICAL_COUNT} packages"
echo ""

# Show SAFE packages
echo -e "  ${BOLD}SAFE packages (will be removed):${NC}"
cat "$OUTPUT_DIR/safe-packages.txt" | while IFS= read -r pkg; do
    echo "    - $pkg"
done
echo ""

# Show RISKY packages
if [ "$RISKY_COUNT" -gt 0 ]; then
    echo -e "  ${BOLD}RISKY packages (NOT removed by default — review in package-report.txt):${NC}"
    head -20 "$OUTPUT_DIR/risky-packages.txt" | while IFS= read -r pkg; do
        # Get the reason from the report
        REASON=$(grep "^RISKY|${pkg}|" "$OUTPUT_DIR/package-report.txt" 2>/dev/null | cut -d'|' -f5 | head -1)
        echo -e "    - $pkg  ${YELLOW}($REASON)${NC}"
    done
    [ "$RISKY_COUNT" -gt 20 ] && echo "    ... and $((RISKY_COUNT - 20)) more (see package-report.txt)"
    echo ""
fi

# ── Analyze-only mode: stop here ─────────────────────────
if [ "$ANALYZE_ONLY" = true ]; then
    echo -e "  ${BOLD}Reports saved to:${NC}"
    echo "    $OUTPUT_DIR/package-report.txt"
    echo "    $OUTPUT_DIR/safe-packages.txt"
    echo "    $OUTPUT_DIR/risky-packages.txt"
    echo "    $OUTPUT_DIR/critical-packages.txt"
    echo ""
    echo "  To build with the safe list:"
    echo "    $0 --packages-file $OUTPUT_DIR/safe-packages.txt $FULL_VERSION"
    exit 0
fi

# ══════════════════════════════════════════════════════════
#  PHASE 3: APPROVE
# ══════════════════════════════════════════════════════════
APPROVED_FILE="$OUTPUT_DIR/approved-packages.txt"

if [ "$AUTO_APPROVE" = true ]; then
    echo -e "  ${BOLD}Auto-approving all ${SAFE_COUNT} SAFE packages${NC}"
    cp "$OUTPUT_DIR/safe-packages.txt" "$APPROVED_FILE"
else
    echo -e "${BOLD}  Approve removal of ${SAFE_COUNT} SAFE packages?${NC}"
    echo ""
    echo "    [Y] Yes — proceed with all SAFE packages"
    echo "    [e] Edit — open list in \$EDITOR for adjustment"
    echo "    [n] No — abort"
    echo ""
    printf "  Choice [Y/e/n]: "
    read -r CHOICE

    case "${CHOICE:-Y}" in
        [Yy]|"")
            cp "$OUTPUT_DIR/safe-packages.txt" "$APPROVED_FILE"
            echo -e "  ${GREEN}✔  Approved${NC}"
            ;;
        [Ee])
            cp "$OUTPUT_DIR/safe-packages.txt" "$APPROVED_FILE"
            "${EDITOR:-nano}" "$APPROVED_FILE"
            EDITED_COUNT=$(grep -v '^#' "$APPROVED_FILE" | grep -v '^$' | wc -l | tr -d " ")
            echo -e "  ${GREEN}✔  Approved (edited: ${EDITED_COUNT} packages)${NC}"
            ;;
        [Nn])
            echo -e "  ${YELLOW}Aborted by user${NC}"
            exit 0
            ;;
        *)
            die "Invalid choice: $CHOICE"
            ;;
    esac
fi

echo ""

# ══════════════════════════════════════════════════════════
#  PHASE 4: BUILD (Docker invocation #2)
# ══════════════════════════════════════════════════════════
echo -e "  ${BOLD}Phase 4: Build${NC}"
echo ""

# Show hardening status
if [ "$HARDENING_LAYER1_ENABLE" = "true" ] || [ "$HARDENING_LAYER2_ENABLE" = "true" ] || [ "$HARDENING_LAYER3_ENABLE" = "true" ]; then
    echo -e "  ${BOLD}Hardening:${NC}"
    [ "$HARDENING_LAYER1_ENABLE" = "true" ] && echo "    ✔ Encryption packages (cryptsetup, clevis)"
    [ "$HARDENING_LAYER2_ENABLE" = "true" ] && echo "    ✔ SSH/sysctl config hardening"
    [ "$HARDENING_LAYER3_ENABLE" = "true" ] && echo "    ✔ CIS Level 1 controls (in squashfs)"
    echo ""
fi

docker run --rm \
    --platform linux/amd64 \
    --privileged \
    -e "PHASE=build" \
    -e "UBUNTU_VERSION=${FULL_VERSION}" \
    -e "MAJOR_MINOR=${MAJOR_MINOR}" \
    -e "ISO_NAME=${ISO_NAME}" \
    -e "HARDENING_LAYER1_ENABLE=${HARDENING_LAYER1_ENABLE}" \
    -e "HARDENING_LAYER2_ENABLE=${HARDENING_LAYER2_ENABLE}" \
    -e "HARDENING_LAYER3_ENABLE=${HARDENING_LAYER3_ENABLE}" \
    -e "HARDENING_CIS_REPO=${HARDENING_CIS_REPO:-}" \
    -e "HARDENING_CIS_BRANCH=${HARDENING_CIS_BRANCH:-main}" \
    -v "${CACHE_DIR}:/input:ro" \
    -v "${OUTPUT_DIR}:/output" \
    -v "${PROJECT_DIR}/lib:/lib-golden:ro" \
    -v "${PROJECT_DIR}/configs:/configs:ro" \
    -v "${PROJECT_DIR}/hardening:/hardening:ro" \
    -v "${PROJECT_DIR}/cis-config.yml:/cis-config/cis-config.yml:ro" \
    -v "$(realpath "$APPROVED_FILE"):/tmp/approved-packages.txt:ro" \
    "${DOCKER_BASE}" \
    /bin/bash /lib-golden/docker-entrypoint.sh

# Rename output if custom name provided
ISO_DEFAULT="${OUTPUT_DIR}/golden-ubuntu-minimal-${FULL_VERSION}.iso"
if [ -n "${OUTPUT_NAME:-}" ] && [ -f "$ISO_DEFAULT" ]; then
    mv "$ISO_DEFAULT" "${OUTPUT_DIR}/${OUTPUT_NAME}"
    ISO_FINAL="${OUTPUT_DIR}/${OUTPUT_NAME}"
else
    ISO_FINAL="$ISO_DEFAULT"
fi

echo ""
banner "BUILD COMPLETE"
echo -e "  ${GREEN}✅ ISO:        ${ISO_FINAL}${NC}"
echo -e "  ${GREEN}✅ Validation: ${OUTPUT_DIR}/validate-golden-image.sh${NC}"
echo ""
echo "  To validate after installing:"
echo "    scp ${OUTPUT_DIR}/validate-golden-image.sh user@vm:~/"
echo "    ssh user@vm 'sudo bash ~/validate-golden-image.sh'"
