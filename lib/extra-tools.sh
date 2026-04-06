#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Extra Tools Installer
#  Reads extra-tools.yml and installs tools into squashfs chroot
#
#  Runs AFTER package removal, BEFORE CIS hardening
#  All downloads happen in the Docker container (has network)
#  then files are copied into the chroot
#
#  Environment variable:
#    INSTALL_TOOLS_ENABLE=true — enables this module
# ═══════════════════════════════════════════════════════════

EXTRA_TOOLS_CONFIG="${EXTRA_TOOLS_CONFIG:-/extra-tools/extra-tools.yml}"

# ── YAML parser helpers (simple key-value extraction) ─────

# get_yaml_list <section> — returns list items (- item)
_get_list() {
    local section="$1"
    awk "/^${section}:/{f=1;next} f && /^[a-z_]+:/{exit} f && /^  - /" "$EXTRA_TOOLS_CONFIG" 2>/dev/null \
        | sed 's/^  - //' | sed 's/[[:space:]]*$//' | grep -v '^$'
}

# get_block_field <section_index> <field> — get field from nth block in a section
_get_block_field() {
    local section="$1" index="$2" field="$3"
    awk -v sec="$section" -v idx="$index" -v fld="$field" '
        /^[a-z_]+:/ { cs = $0; gsub(/:.*/, "", cs); block_count = 0 }
        cs == sec && /^  - name:/ { block_count++ }
        cs == sec && block_count == idx && $0 ~ "^    " fld ":" {
            v = $0
            gsub(/^[^:]+:[[:space:]]*/, "", v)
            gsub(/^"/, "", v); gsub(/"$/, "", v)
            gsub(/^'\''/, "", v); gsub(/'\''$/, "", v)
            print v; exit
        }
    ' "$EXTRA_TOOLS_CONFIG" 2>/dev/null
}

# Count blocks in a section
_count_blocks() {
    local section="$1"
    awk -v sec="$section" '
        /^[a-z_]+:/ { cs = $0; gsub(/:.*/, "", cs) }
        cs == sec && /^  - name:/ { count++ }
        END { print count+0 }
    ' "$EXTRA_TOOLS_CONFIG" 2>/dev/null
}

# Get list of URLs from a deb_packages block
_get_deb_urls() {
    local section="$1" index="$2"
    awk -v sec="$section" -v idx="$index" '
        /^[a-z_]+:/ { cs = $0; gsub(/:.*/, "", cs); block_count = 0 }
        cs == sec && /^  - name:/ { block_count++ }
        cs == sec && block_count == idx && /^      - "/ {
            v = $0; gsub(/^[[:space:]]*- "/, "", v); gsub(/"$/, "", v)
            print v
        }
    ' "$EXTRA_TOOLS_CONFIG" 2>/dev/null
}

# ══════════════════════════════════════════════════════════
#  Main installer function
# ══════════════════════════════════════════════════════════
install_extra_tools() {
    local ROOT="$1"

    if [ "${INSTALL_TOOLS_ENABLE:-false}" != "true" ]; then
        return 0
    fi

    if [ ! -f "$EXTRA_TOOLS_CONFIG" ]; then
        warn "extra-tools.yml not found at $EXTRA_TOOLS_CONFIG — skipping extra tools"
        return 0
    fi

    info "Installing extra tools from extra-tools.yml..."

    # Copy host resolv.conf for DNS resolution
    cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

    # ── 1. APT Packages ──────────────────────────────────
    local apt_pkgs
    apt_pkgs=$(_get_list "apt_packages")
    if [ -n "$apt_pkgs" ]; then
        info "Installing APT packages..."
        chroot "$ROOT" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq" 2>/dev/null || true

        local apt_installed=0
        local apt_failed=0
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if chroot "$ROOT" dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                continue  # Already installed
            fi
            if chroot "$ROOT" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends $pkg" >/dev/null 2>&1; then
                apt_installed=$((apt_installed + 1))
            else
                warn "Could not install APT package: $pkg"
                apt_failed=$((apt_failed + 1))
            fi
        done <<< "$apt_pkgs"
        log "APT packages: $apt_installed installed, $apt_failed failed"
    fi

    # ── 2. Binary Tools ──────────────────────────────────
    local bin_count
    bin_count=$(_count_blocks "binary_tools")
    if [ "$bin_count" -gt 0 ]; then
        info "Installing binary tools..."
        local bin_installed=0
        local bin_failed=0

        for i in $(seq 1 "$bin_count"); do
            local name url url_cmd url_tpl dest extract extract_path install_cmd
            name=$(_get_block_field "binary_tools" "$i" "name")
            url=$(_get_block_field "binary_tools" "$i" "url")
            url_cmd=$(_get_block_field "binary_tools" "$i" "url_command")
            url_tpl=$(_get_block_field "binary_tools" "$i" "url_template")
            dest=$(_get_block_field "binary_tools" "$i" "dest")
            extract=$(_get_block_field "binary_tools" "$i" "extract")
            extract_path=$(_get_block_field "binary_tools" "$i" "extract_path")
            install_cmd=$(_get_block_field "binary_tools" "$i" "install_command")

            [ -z "$name" ] && continue
            echo -n "  Installing $name... "

            # Skip if already installed
            if [ -f "$ROOT$dest" ] 2>/dev/null; then
                echo "already present"
                continue
            fi

            # Handle install_command (e.g., az-cli)
            if [ -n "$install_cmd" ]; then
                if chroot "$ROOT" bash -c "$install_cmd" >/dev/null 2>&1; then
                    echo "OK"
                    bin_installed=$((bin_installed + 1))
                else
                    echo "FAILED"
                    bin_failed=$((bin_failed + 1))
                fi
                continue
            fi

            # Resolve dynamic URL
            if [ -n "$url_cmd" ] && [ -n "$url_tpl" ]; then
                local version
                version=$(eval "$url_cmd" 2>/dev/null)
                url=$(echo "$url_tpl" | sed "s|{VERSION}|$version|g")
            elif [ -n "$url_cmd" ] && [ -z "$url" ]; then
                url=$(eval "$url_cmd" 2>/dev/null)
            fi

            if [ -z "$url" ]; then
                echo "FAILED (no URL)"
                bin_failed=$((bin_failed + 1))
                continue
            fi

            # Download
            local tmpfile="/tmp/tool-download-$$"
            if ! curl -fsSL --connect-timeout 15 --retry 3 -o "$tmpfile" "$url" 2>/dev/null; then
                echo "FAILED (download)"
                rm -f "$tmpfile"
                bin_failed=$((bin_failed + 1))
                continue
            fi

            # Extract or copy
            local dest_dir
            dest_dir=$(dirname "$ROOT$dest")
            mkdir -p "$dest_dir"

            if [ "$extract" = "true" ]; then
                local extract_dir="/tmp/extract-$$"
                mkdir -p "$extract_dir"

                if file "$tmpfile" | grep -q "gzip"; then
                    tar xzf "$tmpfile" -C "$extract_dir" 2>/dev/null
                elif file "$tmpfile" | grep -q "XZ\|xz"; then
                    tar xJf "$tmpfile" -C "$extract_dir" 2>/dev/null
                else
                    tar xf "$tmpfile" -C "$extract_dir" 2>/dev/null
                fi

                if [ -n "$extract_path" ]; then
                    # Specific file from archive
                    cp "$extract_dir/$extract_path" "$ROOT$dest" 2>/dev/null || \
                    find "$extract_dir" -name "$(basename "$extract_path")" -exec cp {} "$ROOT$dest" \; 2>/dev/null
                else
                    # Find the binary (same name as tool)
                    local found_bin
                    found_bin=$(find "$extract_dir" -name "$name" -type f 2>/dev/null | head -1)
                    if [ -n "$found_bin" ]; then
                        cp "$found_bin" "$ROOT$dest"
                    else
                        # Single file in archive
                        found_bin=$(find "$extract_dir" -type f -executable 2>/dev/null | head -1)
                        [ -n "$found_bin" ] && cp "$found_bin" "$ROOT$dest"
                    fi
                fi
                rm -rf "$extract_dir"
            else
                cp "$tmpfile" "$ROOT$dest"
            fi

            rm -f "$tmpfile"

            if [ -f "$ROOT$dest" ]; then
                chmod +x "$ROOT$dest"
                chown root:root "$ROOT$dest"
                echo "OK"
                bin_installed=$((bin_installed + 1))
            else
                echo "FAILED (install)"
                bin_failed=$((bin_failed + 1))
            fi
        done
        log "Binary tools: $bin_installed installed, $bin_failed failed"
    fi

    # ── 3. Deb Packages ──────────────────────────────────
    local deb_count
    deb_count=$(_count_blocks "deb_packages")
    if [ "$deb_count" -gt 0 ]; then
        info "Installing .deb packages..."
        local deb_installed=0
        local deb_failed=0

        for i in $(seq 1 "$deb_count"); do
            local name
            name=$(_get_block_field "deb_packages" "$i" "name")
            [ -z "$name" ] && continue
            echo -n "  Installing $name... "

            local urls
            urls=$(_get_deb_urls "deb_packages" "$i")
            local all_ok=true

            while IFS= read -r deb_url; do
                [ -z "$deb_url" ] && continue
                local deb_file="/tmp/$(basename "$deb_url")"
                if curl -fsSL --connect-timeout 15 -o "$ROOT$deb_file" "$deb_url" 2>/dev/null; then
                    chroot "$ROOT" bash -c "export DEBIAN_FRONTEND=noninteractive; dpkg -i $deb_file 2>/dev/null || apt-get install -f -y 2>/dev/null" >/dev/null 2>&1
                    rm -f "$ROOT$deb_file"
                else
                    all_ok=false
                fi
            done <<< "$urls"

            if [ "$all_ok" = true ]; then
                echo "OK"
                deb_installed=$((deb_installed + 1))
            else
                echo "FAILED"
                deb_failed=$((deb_failed + 1))
            fi
        done
        log "Deb packages: $deb_installed installed, $deb_failed failed"
    fi

    # ── 4. Enable Services ───────────────────────────────
    local services
    services=$(_get_list "services_enabled")
    if [ -n "$services" ]; then
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            # Create enable symlink (no systemd needed in chroot)
            local svc_unit="$ROOT/lib/systemd/system/${svc}.service"
            local svc_wants="$ROOT/etc/systemd/system/multi-user.target.wants/${svc}.service"
            if [ -f "$svc_unit" ] && [ ! -e "$svc_wants" ]; then
                mkdir -p "$(dirname "$svc_wants")"
                ln -sf "/lib/systemd/system/${svc}.service" "$svc_wants"
            fi
        done <<< "$services"
        log "Services enabled: $(echo "$services" | tr '\n' ' ')"
    fi

    # ── 5. Hold Packages ─────────────────────────────────
    local hold_pkgs
    hold_pkgs=$(_get_list "packages_hold")
    if [ -n "$hold_pkgs" ]; then
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            chroot "$ROOT" apt-mark hold "$pkg" 2>/dev/null || true
        done <<< "$hold_pkgs"
        log "Packages held: $(echo "$hold_pkgs" | tr '\n' ' ')"
    fi

    # ── 6. Clean up ──────────────────────────────────────
    chroot "$ROOT" apt-get clean 2>/dev/null || true
    chroot "$ROOT" bash -c 'rm -rf /var/lib/apt/lists/*' 2>/dev/null || true

    # Restore resolv.conf symlink
    rm -f "$ROOT/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

    log "Extra tools installation complete"
}
