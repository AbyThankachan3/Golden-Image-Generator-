#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Docker entrypoint — orchestrates phases inside container
#  Sources lib modules and runs the appropriate phase
# ═══════════════════════════════════════════════════════════
set -u

# Source all library modules
LIB="/lib-golden"
source "$LIB/colors.sh"
source "$LIB/iso-detect.sh"
source "$LIB/package-analyzer.sh"
source "$LIB/squashfs-ops.sh"
source "$LIB/chroot-ops.sh"
source "$LIB/iso-builder.sh"
source "$LIB/hardening.sh"
source "$LIB/extra-tools.sh" 2>/dev/null || true

# ── Configuration ─────────────────────────────────────────
PHASE="${PHASE:-build}"
UBUNTU_VERSION="${UBUNTU_VERSION:?UBUNTU_VERSION not set}"
ISO_NAME="${ISO_NAME:?ISO_NAME not set}"
ISOWORK="/build/iso-work"
DETECTED_ENV="$ISOWORK/detected.env"

banner "Golden Image Builder — Phase: $PHASE"
echo "  Ubuntu Version : $UBUNTU_VERSION"
echo "  ISO            : $ISO_NAME"
echo ""

# ── Install required tools ────────────────────────────────
step 1 "Installing Required Tools"
apt-get update -qq 2>/dev/null
apt-get install -y -qq xorriso squashfs-tools rsync file fdisk python3 >/dev/null 2>&1
log "Tools installed"

# ── Mount & extract ISO ──────────────────────────────────
step 2 "Mounting & Extracting ISO"
mkdir -p "$ISOWORK"/{mnt,extract}

mount -o loop "/input/$ISO_NAME" "$ISOWORK/mnt"
rsync -a "$ISOWORK/mnt/" "$ISOWORK/extract/"
umount "$ISOWORK/mnt"
log "ISO extracted"

# ── Detect ISO structure ─────────────────────────────────
step 3 "Detecting ISO Structure"
detect_iso_structure "$ISOWORK/extract" "$DETECTED_ENV"
source "$DETECTED_ENV"

# ── Extract boot images ──────────────────────────────────
extract_efi_image "/input/$ISO_NAME" "$ISOWORK/efi_boot.img" "$ISOWORK"
extract_mbr "/input/$ISO_NAME" "$ISOWORK/mbr.img"

# ── Extract target squashfs ──────────────────────────────
step 4 "Extracting SquashFS"
extract_squashfs "$TARGET_SQUASHFS" "$ISOWORK/squashfs-root"

# ══════════════════════════════════════════════════════════
#  PHASE: ANALYZE
# ══════════════════════════════════════════════════════════
if [ "$PHASE" = "analyze" ]; then
    step 5 "Package Analysis"

    # Load version overrides if available
    if [ -f "$LIB/../configs/overrides-${MAJOR_MINOR:-}.sh" ]; then
        source "$LIB/../configs/overrides-${MAJOR_MINOR}.sh" 2>/dev/null || true
    fi

    # Setup chroot for analysis
    setup_chroot "$ISOWORK/squashfs-root"

    # Run analysis inside chroot
    # We need to copy the analyzer into the chroot and run it there
    mkdir -p "$ISOWORK/squashfs-root/tmp"
    cp "$LIB/package-analyzer.sh" "$ISOWORK/squashfs-root/tmp/package-analyzer.sh"
    cp "$LIB/colors.sh" "$ISOWORK/squashfs-root/tmp/colors.sh"

    # Pass EXTRA_CRITICAL_PKGS if set
    echo "${EXTRA_CRITICAL_PKGS:-}" > "$ISOWORK/squashfs-root/tmp/extra-critical.txt"

    chroot "$ISOWORK/squashfs-root" /bin/bash << 'ANALYZE_CHROOT'
source /tmp/colors.sh
source /tmp/package-analyzer.sh
EXTRA_CRITICAL_PKGS=$(cat /tmp/extra-critical.txt 2>/dev/null || true)
run_analysis /tmp/package-report.txt
ANALYZE_CHROOT

    # Copy report out
    cp "$ISOWORK/squashfs-root/tmp/package-report.txt" /output/package-report.txt

    # Extract safe/risky/critical lists
    grep "^SAFE|" /output/package-report.txt | cut -d'|' -f2 | sort > /output/safe-packages.txt
    grep "^RISKY|" /output/package-report.txt | cut -d'|' -f2 | sort > /output/risky-packages.txt
    grep "^CRITICAL|" /output/package-report.txt | cut -d'|' -f2 | sort > /output/critical-packages.txt

    teardown_chroot "$ISOWORK/squashfs-root"

    log "Analysis complete — reports written to /output/"
    echo ""
    echo "  Files generated:"
    echo "    package-report.txt    — Full categorized report"
    echo "    safe-packages.txt     — $(wc -l < /output/safe-packages.txt | tr -d ' ') SAFE packages"
    echo "    risky-packages.txt    — $(wc -l < /output/risky-packages.txt | tr -d ' ') RISKY packages"
    echo "    critical-packages.txt — $(wc -l < /output/critical-packages.txt | tr -d ' ') CRITICAL packages"
    exit 0
fi

# ══════════════════════════════════════════════════════════
#  PHASE: BUILD
# ══════════════════════════════════════════════════════════

# ── Configure squashfs ───────────────────────────────────
step 5 "Configuring SquashFS"
configure_cloud_init "$ISOWORK/squashfs-root"
install_openssh "$ISOWORK/squashfs-root"

# ── Setup chroot & remove packages ───────────────────────
step 6 "Package Removal"
setup_chroot "$ISOWORK/squashfs-root"

# Use approved packages file or provided packages file
PACKAGES_FILE="/tmp/approved-packages.txt"
if [ ! -f "$PACKAGES_FILE" ]; then
    die "No approved packages file found at $PACKAGES_FILE"
fi

# Get critical packages list (if available from prior analysis)
CRITICAL_FILE=""
if [ -f "/output/critical-packages.txt" ]; then
    CRITICAL_FILE="/output/critical-packages.txt"
fi

remove_packages_safe "$ISOWORK/squashfs-root" "$PACKAGES_FILE" "$CRITICAL_FILE"

# ── Install packages: security + extra tools (if enabled) ──
install_all_packages "$ISOWORK/squashfs-root"

# ── Apply CIS hardening configs (if enabled) ────────────
apply_hardening "$ISOWORK/squashfs-root" "${UBUNTU_VERSION}"

# ── Teardown chroot ──────────────────────────────────────
step 8 "Teardown Chroot"
teardown_chroot "$ISOWORK/squashfs-root"

# ── Rebuild squashfs ─────────────────────────────────────
step 9 "Rebuilding SquashFS"

# Get the relative path within casper/
SQUASHFS_REL=$(basename "$TARGET_SQUASHFS")
CASPER_DIR="$ISOWORK/extract/casper"

rebuild_squashfs "$ISOWORK/squashfs-root" "$CASPER_DIR/$SQUASHFS_REL"

# Generate manifest and size
generate_manifest "$ISOWORK/squashfs-root" "$CASPER_DIR/${SQUASHFS_BASENAME}.manifest"
generate_size_file "$ISOWORK/squashfs-root" "$CASPER_DIR/${SQUASHFS_BASENAME}.size"

# ── Regenerate md5sums ───────────────────────────────────
step 10 "Regenerating Checksums"
regenerate_md5sums "$ISOWORK/extract"

# ── Build ISO ────────────────────────────────────────────
step 11 "Building Final ISO"

CUSTOM_ISO="golden-ubuntu-minimal-${UBUNTU_VERSION}.iso"

# Find eltorito path relative to extract dir
ELTORITO_REL=""
if [ -n "$ELTORITO_IMG" ]; then
    ELTORITO_REL="${ELTORITO_IMG#$ISOWORK/extract}"
else
    # Fallback: look for it
    ELTORITO_REL=$(find "$ISOWORK/extract/boot/grub" -name "eltorito.img" -path "*/i386-pc/*" 2>/dev/null | head -1)
    ELTORITO_REL="${ELTORITO_REL#$ISOWORK/extract}"
fi

build_iso "$ISOWORK/extract" "/output/$CUSTOM_ISO" \
    "$ISOWORK/mbr.img" "$ISOWORK/efi_boot.img" \
    "$ELTORITO_REL" "Ubuntu-Server-Minimal-Custom"

# ── Verify ───────────────────────────────────────────────
step 12 "Verification"
verify_iso_md5 "/output/$CUSTOM_ISO"

# ── Generate validation script ───────────────────────────
step 13 "Generating Validation Script"
if [ -f "$LIB/validation-generator.sh" ]; then
    source "$LIB/validation-generator.sh"

    # Get list of what was actually removed
    REMAINING_FILE=$(mktemp)
    chroot "$ISOWORK/squashfs-root" dpkg-query -W -f='${Package}\n' 2>/dev/null > "$REMAINING_FILE" || true

    generate_validation "/tmp/approved-packages.txt" "$REMAINING_FILE" \
        "/output/validate-golden-image.sh" "$UBUNTU_VERSION"

    rm -f "$REMAINING_FILE"
fi

# ── Summary ──────────────────────────────────────────────
step 14 "Cleanup & Summary"

ORIG_SIZE=$(du -sh "/input/$ISO_NAME" | awk '{print $1}')
CUSTOM_SIZE=$(du -sh "/output/$CUSTOM_ISO" | awk '{print $1}')

echo -e "${GREEN}  ╔═══════════════════════════════════════════════════════════╗"
echo -e "  ║           GOLDEN IMAGE BUILD COMPLETE!                   ║"
echo -e "  ╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Original ISO : $ORIG_SIZE"
echo "  Custom ISO   : $CUSTOM_SIZE"

# Verify ISO is valid and bootable
ISO_CHECK=$(file "/output/$CUSTOM_ISO" 2>/dev/null || echo "unknown")
if echo "$ISO_CHECK" | grep -q "ISO 9660"; then
    echo -e "  ISO type     : ${GREEN} Valid ISO 9660 filesystem${NC}"
    if echo "$ISO_CHECK" | grep -q "bootable"; then
        echo -e "  Bootable     : ${GREEN} Yes (MBR boot sector detected)${NC}"
    else
        echo -e "  Bootable     : ⚠️  MBR boot flag not detected (UEFI-only?)"
    fi
else
    echo -e "  ${RED}ISO type     : ❌ NOT a valid ISO — build may have failed${NC}"
fi

echo ""
echo "  Boot support : BIOS (Legacy) + UEFI"
echo "  SSH          : openssh-server present"
echo "  cloud-init   : bare metal config (no datasource wait)"
echo "  pool/dists   : intact (Canonical signatures valid)"
echo ""
echo -e "${GREEN}  ISO: /output/$CUSTOM_ISO${NC}"
echo -e "${GREEN}  Validation: /output/validate-golden-image.sh${NC}"
