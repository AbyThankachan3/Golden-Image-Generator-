#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Auto-detect ISO structure (squashfs, kernels, boot images)
#  Runs inside Docker after ISO is mounted
# ═══════════════════════════════════════════════════════════

# detect_iso_structure <mount_point> <output_env_file>
# Discovers all paths dynamically, writes to a sourceable env file
detect_iso_structure() {
    local MP="$1"
    local OUT="$2"

    info "Auto-detecting ISO structure..."

    # ── 1. Find target squashfs (the one we modify) ──
    local TARGET_SQUASHFS=""

    # Strategy A: Parse install-sources.yaml for id: ubuntu-server-minimal
    if [ -f "$MP/casper/install-sources.yaml" ]; then
        # Look for the path after "id: ubuntu-server-minimal"
        TARGET_SQUASHFS=$(awk '
            /^-/ { id=""; path="" }
            /id:/ { id=$2 }
            /path:/ { path=$2 }
            id=="ubuntu-server-minimal" && path!="" { print path; exit }
        ' "$MP/casper/install-sources.yaml")
        if [ -n "$TARGET_SQUASHFS" ] && [ -f "$MP/casper/$TARGET_SQUASHFS" ]; then
            TARGET_SQUASHFS="$MP/casper/$TARGET_SQUASHFS"
        else
            TARGET_SQUASHFS=""
        fi
    fi

    # Strategy B: Known naming patterns
    if [ -z "$TARGET_SQUASHFS" ]; then
        for candidate in \
            "$MP/casper/ubuntu-server-minimal.squashfs" \
            "$MP/casper/minimal.squashfs" \
            "$MP/casper/filesystem.squashfs"; do
            if [ -f "$candidate" ]; then
                TARGET_SQUASHFS="$candidate"
                break
            fi
        done
    fi

    # Strategy C: Smallest non-installer squashfs
    if [ -z "$TARGET_SQUASHFS" ]; then
        TARGET_SQUASHFS=$(find "$MP/casper" -maxdepth 1 -name "*.squashfs" \
            ! -name "*installer*" ! -name "*.ubuntu-server.squashfs" \
            -printf '%s %p\n' 2>/dev/null | sort -n | head -1 | awk '{print $2}')
    fi

    [ -z "$TARGET_SQUASHFS" ] && die "Cannot find target squashfs in ISO"
    log "Target squashfs: $(basename "$TARGET_SQUASHFS")"

    # ── 2. List all squashfs layers (we don't touch these) ──
    local ALL_SQUASHFS=$(find "$MP/casper" -maxdepth 1 -name "*.squashfs" 2>/dev/null | sort)
    local OTHER_SQUASHFS=$(echo "$ALL_SQUASHFS" | grep -v "$(basename "$TARGET_SQUASHFS")" || true)

    # ── 3. Find the ubuntu-server overlay squashfs (installer layer) ──
    local INSTALLER_SQUASHFS=""
    for sq in $ALL_SQUASHFS; do
        local bn=$(basename "$sq")
        # Match patterns like: ubuntu-server-minimal.ubuntu-server.squashfs
        if echo "$bn" | grep -qE "\.ubuntu-server\.squashfs$"; then
            INSTALLER_SQUASHFS="$sq"
            break
        fi
    done

    # ── 4. Find kernel paths ──
    local KERNELS=$(find "$MP/casper" -maxdepth 1 \( -name "vmlinuz" -o -name "vmlinuz.*" -o -name "hwe-vmlinuz" -o -name "hwe-vmlinuz.*" \) 2>/dev/null | sort)
    local INITRDS=$(find "$MP/casper" -maxdepth 1 \( -name "initrd" -o -name "initrd.*" -o -name "hwe-initrd" -o -name "hwe-initrd.*" \) 2>/dev/null | sort)
    local HAS_HWE="no"
    echo "$KERNELS" | grep -q "hwe-" && HAS_HWE="yes"

    # ── 5. Find boot images ──
    local ELTORITO_IMG=$(find "$MP/boot/grub" -name "eltorito.img" -path "*/i386-pc/*" 2>/dev/null | head -1)
    local EFI_IMG_INTERNAL=$(find "$MP/boot/grub" -name "efi.img" 2>/dev/null | head -1)
    local HAS_ISOLINUX="no"
    [ -d "$MP/isolinux" ] && HAS_ISOLINUX="yes"

    # ── 6. Read disk info ──
    local DISK_INFO=$(cat "$MP/.disk/info" 2>/dev/null || echo "unknown")

    # ── 7. Get squashfs basename (used for manifest, size, etc.) ──
    local SQUASHFS_BASENAME=$(basename "$TARGET_SQUASHFS" .squashfs)

    # ── 8. Check for grub.cfg ──
    local GRUB_CFG=""
    for gc in "$MP/boot/grub/grub.cfg" "$MP/grub/grub.cfg"; do
        [ -f "$gc" ] && GRUB_CFG="$gc" && break
    done

    # ── Write detected values ──
    # Collapse multi-line variables (from find output) to colon-delimited single lines
    local ALL_SQUASHFS_FLAT KERNELS_FLAT INITRDS_FLAT
    ALL_SQUASHFS_FLAT=$(printf '%s' "$ALL_SQUASHFS" | tr '\n' ':' | sed 's/:$//')
    KERNELS_FLAT=$(printf '%s' "$KERNELS" | tr '\n' ':' | sed 's/:$//')
    INITRDS_FLAT=$(printf '%s' "$INITRDS" | tr '\n' ':' | sed 's/:$//')

    {
        echo "# Auto-detected ISO structure — $(date '+%Y-%m-%d %H:%M:%S')"
        printf 'TARGET_SQUASHFS=%q\n'       "$TARGET_SQUASHFS"
        printf 'SQUASHFS_BASENAME=%q\n'     "$SQUASHFS_BASENAME"
        printf 'INSTALLER_SQUASHFS=%q\n'    "${INSTALLER_SQUASHFS:-}"
        printf 'ALL_SQUASHFS=%q\n'          "$ALL_SQUASHFS_FLAT"
        printf 'KERNELS=%q\n'               "$KERNELS_FLAT"
        printf 'INITRDS=%q\n'               "$INITRDS_FLAT"
        printf 'HAS_HWE=%q\n'              "$HAS_HWE"
        printf 'ELTORITO_IMG=%q\n'          "${ELTORITO_IMG:-}"
        printf 'EFI_IMG_INTERNAL=%q\n'      "${EFI_IMG_INTERNAL:-}"
        printf 'HAS_ISOLINUX=%q\n'          "$HAS_ISOLINUX"
        printf 'GRUB_CFG=%q\n'              "${GRUB_CFG:-}"
        printf 'DISK_INFO=%q\n'             "$DISK_INFO"
    } > "$OUT"

    log "ISO structure detected ($(echo "$ALL_SQUASHFS" | wc -l | tr -d ' ') squashfs layers, HWE=$HAS_HWE)"
}

# extract_efi_image <iso_path> <output_efi_path> <workdir>
# Extracts EFI boot image using 3-method fallback
extract_efi_image() {
    local ISO_PATH="$1"
    local EFI_OUT="$2"
    local WORKDIR="$3"

    info "Extracting EFI boot image..."
    local EFI_EXTRACTED=0

    # Method 1: xorriso extraction
    if command -v xorriso &>/dev/null; then
        if xorriso -osirrox on -indev "$ISO_PATH" \
            -extract /boot/grub/efi.img "$EFI_OUT" 2>/dev/null; then
            EFI_EXTRACTED=1
            log "EFI image extracted via xorriso"
        fi
    fi

    # Method 2: Copy from extracted ISO tree
    if [ "$EFI_EXTRACTED" -eq 0 ] && [ -f "$WORKDIR/extract/boot/grub/efi.img" ]; then
        cp "$WORKDIR/extract/boot/grub/efi.img" "$EFI_OUT"
        EFI_EXTRACTED=1
        log "EFI image copied from ISO tree"
    fi

    # Method 3: fdisk-based extraction (most reliable)
    if [ "$EFI_EXTRACTED" -eq 0 ]; then
        local EFI_LINE=$(fdisk -l "$ISO_PATH" 2>/dev/null | grep -i "EFI System" || true)
        if [ -n "$EFI_LINE" ]; then
            local EFI_START=$(echo "$EFI_LINE" | awk '{if($2=="*") print $3; else print $2}')
            local EFI_SECTORS=$(echo "$EFI_LINE" | awk '{if($2=="*") print $5; else print $4}')
            if [ -n "$EFI_START" ] && [ -n "$EFI_SECTORS" ]; then
                dd if="$ISO_PATH" bs=512 skip="$EFI_START" count="$EFI_SECTORS" \
                    of="$EFI_OUT" status=none 2>/dev/null
                EFI_EXTRACTED=1
                log "EFI image extracted via fdisk (sector ${EFI_START}, ${EFI_SECTORS} sectors)"
            fi
        fi
    fi

    [ "$EFI_EXTRACTED" -eq 0 ] && die "Failed to extract EFI boot image"

    # Verify it's a valid FAT filesystem
    local EFI_TYPE=$(file "$EFI_OUT" 2>/dev/null)
    if echo "$EFI_TYPE" | grep -qi "FAT"; then
        log "EFI image verified as FAT filesystem"
    elif mount -o loop,ro "$EFI_OUT" /tmp/efi_check 2>/dev/null; then
        umount /tmp/efi_check 2>/dev/null || true
        log "EFI image is mountable — proceeding"
    else
        warn "EFI image type uncertain: $EFI_TYPE (proceeding anyway)"
    fi
}

# extract_mbr <iso_path> <output_mbr_path>
extract_mbr() {
    local ISO_PATH="$1"
    local MBR_OUT="$2"
    dd if="$ISO_PATH" bs=1 count=432 of="$MBR_OUT" status=none 2>/dev/null
    log "MBR boot code extracted (432 bytes)"
}
