#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  ISO Builder — md5sum regeneration + xorriso rebuild
# ═══════════════════════════════════════════════════════════

# regenerate_md5sums <extract_dir>
# Regenerates md5sum.txt for all files in the ISO tree
regenerate_md5sums() {
    local EXTRACT="$1"

    info "Regenerating md5sum.txt..."
    cd "$EXTRACT"

    find . -type f \
        ! -name "md5sum.txt" \
        ! -name "boot.catalog" \
        ! -path "./boot/grub/i386-pc/*" \
        ! -path "./boot/grub/efi.img" \
        ! -path "./isolinux/*" \
        | sort \
        | xargs md5sum \
        > md5sum.txt

    local count=$(wc -l < md5sum.txt | tr -d " ")
    log "md5sum.txt regenerated ($count entries)"
    cd - >/dev/null
}

# build_iso <extract_dir> <output_iso> <mbr_img> <efi_img> <eltorito_path> <volume_label>
# Builds the final ISO using xorriso
build_iso() {
    local EXTRACT="$1"
    local OUTPUT="$2"
    local MBR="$3"
    local EFI="$4"
    local ELTORITO="$5"
    local LABEL="${6:-Ubuntu-Server-Minimal-Custom}"

    info "Building ISO: $(basename "$OUTPUT")..."

    # Determine eltorito relative path (must be relative to extract root)
    local ELTORITO_REL="$ELTORITO"
    # If absolute, make relative to extract dir
    if [[ "$ELTORITO" == /* ]]; then
        ELTORITO_REL="${ELTORITO#$EXTRACT}"
    fi

    # Ensure EFI image is in the ISO tree for El Torito
    if [ ! -f "$EXTRACT/boot/grub/efi.img" ]; then
        cp "$EFI" "$EXTRACT/boot/grub/efi.img"
    fi

    xorriso -as mkisofs \
        -r \
        -V "$LABEL" \
        -o "$OUTPUT" \
        --grub2-mbr "$MBR" \
        -partition_cyl_align off \
        -partition_offset 16 \
        -b "$ELTORITO_REL" \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e "/boot/grub/efi.img" \
        -no-emul-boot \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$EFI" \
        "$EXTRACT/"

    local size=$(du -sh "$OUTPUT" | awk '{print $1}')
    log "ISO built: $size"
}

# verify_iso_md5 <iso_path>
# Mounts the built ISO and verifies md5sums
verify_iso_md5() {
    local ISO="$1"
    local VERIFY_MNT="/tmp/iso_verify"

    info "Verifying md5sum inside packed ISO..."
    mkdir -p "$VERIFY_MNT"
    mount -o loop,ro "$ISO" "$VERIFY_MNT" 2>/dev/null

    if [ -f "$VERIFY_MNT/md5sum.txt" ]; then
        cd "$VERIFY_MNT"
        local result
        if result=$(md5sum -c md5sum.txt 2>/dev/null); then
            log "md5sum verified inside packed ISO"
        else
            local failures=$(echo "$result" | grep "FAILED" | head -5)
            warn "Some md5 mismatches (likely boot-sector patched files):"
            echo "$failures" | while read -r line; do echo "    $line"; done
        fi
        cd - >/dev/null
    else
        warn "No md5sum.txt found in ISO"
    fi

    umount "$VERIFY_MNT" 2>/dev/null || true
    rmdir "$VERIFY_MNT" 2>/dev/null || true
}
