#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  SquashFS operations — extract and rebuild
# ═══════════════════════════════════════════════════════════

# extract_squashfs <squashfs_path> <output_dir>
extract_squashfs() {
    local SQ_PATH="$1"
    local OUT_DIR="$2"

    info "Extracting squashfs: $(basename "$SQ_PATH")..."
    rm -rf "$OUT_DIR"
    unsquashfs -d "$OUT_DIR" "$SQ_PATH"
    log "SquashFS extracted to $(basename "$OUT_DIR")"
}

# rebuild_squashfs <root_dir> <output_squashfs_path>
rebuild_squashfs() {
    local ROOT_DIR="$1"
    local SQ_OUT="$2"

    info "Rebuilding squashfs (xz compression)..."
    rm -f "$SQ_OUT"
    mksquashfs "$ROOT_DIR" "$SQ_OUT" -comp xz -noappend
    local size=$(du -sh "$SQ_OUT" | awk '{print $1}')
    log "SquashFS rebuilt: $size"
}

# generate_manifest <root_dir> <manifest_path>
generate_manifest() {
    local ROOT_DIR="$1"
    local MANIFEST="$2"

    chroot "$ROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$MANIFEST"
    local count=$(wc -l < "$MANIFEST" | tr -d " ")
    log "Manifest generated: $count packages"
}

# generate_size_file <root_dir> <size_path>
generate_size_file() {
    local ROOT_DIR="$1"
    local SIZE_FILE="$2"

    du -sx --block-size=1 "$ROOT_DIR" | cut -f1 > "$SIZE_FILE"
    log "Size file generated: $(cat "$SIZE_FILE") bytes"
}

# create_empty_squashfs <output_path>
# Creates a minimal empty squashfs (for unused layers)
create_empty_squashfs() {
    local SQ_OUT="$1"
    local TMPDIR=$(mktemp -d)
    mkdir -p "$TMPDIR/empty"
    mksquashfs "$TMPDIR/empty" "$SQ_OUT" -comp xz -noappend 2>/dev/null
    rm -rf "$TMPDIR"
    log "Empty squashfs placeholder created: $(basename "$SQ_OUT")"
}
