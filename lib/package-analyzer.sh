#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Package Analyzer — Auto-categorize packages as
#  CRITICAL / SAFE / RISKY for removal
#  Runs INSIDE chroot of the extracted squashfs
# ═══════════════════════════════════════════════════════════

# ── Constants ─────────────────────────────────────────────

# Boot chain: packages required for the system to boot + network + SSH
# These are discovered dynamically but we seed the chains
BOOT_CHAIN_SEEDS=(
    # Init/systemd
    systemd systemd-sysv init init-system-helpers
    # Hardware
    udev kmod
    # Boot
    initramfs-tools initramfs-tools-bin initramfs-tools-core
    busybox-initramfs linux-base
    grub-common grub-efi-amd64-signed grub2-common shim-signed
    # Filesystem
    mount util-linux e2fsprogs
    # Time sync (SSL cert validation depends on correct time)
    systemd-timesyncd
    # Scripting tools used by initramfs and system scripts
    gawk
)

NETWORK_CHAIN_SEEDS=(
    iproute2 netplan.io networkd-dispatcher
    isc-dhcp-client netbase
    openssh-server openssh-client
    # wget/curl used by cloud-init, apt, snap and system scripts
    wget curl
    # GPG chain — needed for apt signature verification
    gnupg gnupg-utils gpg gpg-wks-client gpgsm keyboxd pinentry-curses
)

INSTALLER_CHAIN_SEEDS=(
    # Casper live-boot
    casper lupin-casper
    # Plymouth (needed by casper-md5check)
    plymouth libplymouth5 plymouth-theme-ubuntu-text
    # Snapd chain (subiquity runs as a snap)
    snapd dbus-user-session fuse3 libfuse3-3 squashfs-tools
    # Cloud-init (subiquity uses it)
    cloud-init
    # Apport (installer layer references it)
    apport python3-apport
    # sudo (subiquity/curtin use sudo for chroot operations)
    sudo
)

PARTITION_CHAIN_SEEDS=(
    gdisk parted fdisk e2fsprogs dosfstools lvm2
    # RAID support (subiquity can set up RAID)
    mdadm
)

PYTHON_CHAIN_SEEDS=(
    python3 python3-minimal python3.10 python3.10-minimal
    libpython3-stdlib libpython3.10-stdlib libpython3.10-minimal
)

# Console/keyboard chain — subiquity sets up keyboard during install
CONSOLE_CHAIN_SEEDS=(
    console-setup console-setup-linux
    kbd keyboard-configuration
    xkb-data iso-codes
)

# Crypto chain — subiquity supports LUKS full-disk encryption
CRYPTO_CHAIN_SEEDS=(
    cryptsetup cryptsetup-bin cryptsetup-initramfs
)

# Polkit chain — used by NetworkManager, udisks, systemd services
POLKIT_CHAIN_SEEDS=(
    polkitd pkexec
    libpolkit-agent-1-0 libpolkit-gobject-1-0
)

# ── Functions ─────────────────────────────────────────────

# get_priority <package>
get_priority() {
    dpkg-query -W -f='${Priority}' "$1" 2>/dev/null || echo "unknown"
}

# get_installed_rdeps <package>
# Returns list of installed packages that depend on this package
get_installed_rdeps() {
    local pkg="$1"
    apt-cache rdepends --installed "$pkg" 2>/dev/null \
        | tail -n +2 \
        | sed 's/^[[:space:]]*//' \
        | grep -v "^|" \
        | sort -u || true
}

# count_installed_rdeps <package>
count_installed_rdeps() {
    local rdeps
    rdeps=$(get_installed_rdeps "$1")
    if [ -z "$rdeps" ]; then
        echo 0
    else
        echo "$rdeps" | wc -l | tr -d " "
    fi
}

# is_installed <package>
is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# build_critical_set
# Builds the full critical package set and stores in CRITICAL_PKGS associative array
build_critical_set() {
    declare -gA CRITICAL_PKGS
    declare -gA CRITICAL_REASON

    echo "  Building critical package set..."

    # Layer 1: dpkg priority required + important
    local count=0
    while IFS=' ' read -r pkg prio; do
        [ -z "$pkg" ] && continue
        CRITICAL_PKGS[$pkg]=1
        CRITICAL_REASON[$pkg]="dpkg priority $prio"
        count=$((count + 1))
    done < <(dpkg-query -W -f='${Package} ${Priority}\n' 2>/dev/null | grep -E ' required$')
    echo "    Layer 1 (priority required): $count packages"

    # Layer 2-6: Chain seeds (all chains)
    local chain_count=0
    for pkg in "${BOOT_CHAIN_SEEDS[@]}" "${NETWORK_CHAIN_SEEDS[@]}" \
               "${INSTALLER_CHAIN_SEEDS[@]}" "${PARTITION_CHAIN_SEEDS[@]}" \
               "${PYTHON_CHAIN_SEEDS[@]}" "${CONSOLE_CHAIN_SEEDS[@]}" \
               "${CRYPTO_CHAIN_SEEDS[@]}" "${POLKIT_CHAIN_SEEDS[@]}"; do
        if is_installed "$pkg" && [ -z "${CRITICAL_PKGS[$pkg]+x}" ]; then
            CRITICAL_PKGS[$pkg]=1
            CRITICAL_REASON[$pkg]="boot/network/installer chain"
            chain_count=$((chain_count + 1))
        fi
    done
    echo "    Layer 2-6 (chain seeds): $chain_count additional packages"

    # Layer 7: Extra critical from version overrides
    if [ -n "${EXTRA_CRITICAL_PKGS:-}" ]; then
        local extra_count=0
        for pkg in $EXTRA_CRITICAL_PKGS; do
            if is_installed "$pkg" && [ -z "${CRITICAL_PKGS[$pkg]+x}" ]; then
                CRITICAL_PKGS[$pkg]=1
                CRITICAL_REASON[$pkg]="version-specific override"
                extra_count=$((extra_count + 1))
            fi
        done
        echo "    Layer 7 (version overrides): $extra_count additional packages"
    fi

    # Layer 7b: Pattern-based protection — never remove packages matching these patterns
    # Any package with "systemd" in its name is critical (systemd-resolved, libnss-systemd, etc.)
    local pattern_count=0
    local CRITICAL_PATTERNS=("systemd" "libnss-" "libpam-" "grub-" "linux-image" "linux-headers" "linux-modules" "curl" "wget" "lshw" "openssh")
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        [ -n "${CRITICAL_PKGS[$pkg]+x}" ] && continue  # already marked
        for pattern in "${CRITICAL_PATTERNS[@]}"; do
            if [[ "$pkg" == *"$pattern"* ]]; then
                CRITICAL_PKGS[$pkg]=1
                CRITICAL_REASON[$pkg]="pattern match: *${pattern}*"
                pattern_count=$((pattern_count + 1))
                break
            fi
        done
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null)
    echo "    Layer 7b (pattern protection): $pattern_count additional packages"

    # Layer 8: BFS expansion — add dependencies of critical packages transitively
    # Loop until no new packages are added (converges when all transitive deps are marked)
    local dep_count=0
    local bfs_changed=1
    local bfs_pass=0
    while [ "$bfs_changed" -eq 1 ]; do
        bfs_changed=0
        bfs_pass=$((bfs_pass + 1))
        local snapshot=("${!CRITICAL_PKGS[@]}")
        for pkg in "${snapshot[@]}"; do
            local deps
            deps=$(apt-cache depends "$pkg" 2>/dev/null \
                | grep -E "^\s*(Depends|Pre-Depends):" \
                | awk '{print $2}' \
                | grep -v "^<" || true)
            for dep in $deps; do
                if is_installed "$dep" && [ -z "${CRITICAL_PKGS[$dep]+x}" ]; then
                    CRITICAL_PKGS[$dep]=1
                    CRITICAL_REASON[$dep]="transitive dep of critical $pkg (pass $bfs_pass)"
                    dep_count=$((dep_count + 1))
                    bfs_changed=1
                fi
            done
        done
    done
    echo "    Layer 8 (BFS dep expansion, $bfs_pass passes): $dep_count additional packages"

    echo "    Total critical: ${#CRITICAL_PKGS[@]} packages"
}

# analyze_packages <output_report_file>
# Categorizes all installed packages and writes report
analyze_packages() {
    local REPORT="$1"
    local SAFE_COUNT=0
    local RISKY_COUNT=0
    local CRITICAL_COUNT=0
    local TOTAL=0

    echo ""
    echo "  Analyzing all installed packages..."

    # Get all installed packages
    local ALL_INSTALLED=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
    TOTAL=$(echo "$ALL_INSTALLED" | wc -l | tr -d " ")

    # Write report header
    cat > "$REPORT" << EOF
# Golden Image Package Analysis Report
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Total installed packages: $TOTAL
# Format: CATEGORY|package|priority|rdeps|reason
EOF

    # Process each package
    local processed=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        processed=$((processed + 1))

        # Show progress every 50 packages
        if [ $((processed % 50)) -eq 0 ]; then
            printf "\r    Analyzed %d/%d packages..." "$processed" "$TOTAL"
        fi

        local priority=$(get_priority "$pkg")
        local rdep_count=$(count_installed_rdeps "$pkg")

        # Check if in critical set
        if [ -n "${CRITICAL_PKGS[$pkg]+x}" ]; then
            echo "CRITICAL|$pkg|$priority|$rdep_count|${CRITICAL_REASON[$pkg]}" >> "$REPORT"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
            continue
        fi

        # Check if removal would cascade to critical packages
        local dry_output=$(apt-get remove --dry-run "$pkg" 2>/dev/null || true)
        local would_remove=$(echo "$dry_output" | grep "^Remv " | awk '{print $2}' | sort -u || true)
        local critical_cascade=""
        if [ -n "$would_remove" ]; then
            for removed_pkg in $would_remove; do
                if [ -n "${CRITICAL_PKGS[$removed_pkg]+x}" ]; then
                    critical_cascade="${critical_cascade}${removed_pkg} "
                fi
            done
        fi

        if [ -n "$critical_cascade" ]; then
            # Removing this cascades to critical → mark as CRITICAL
            CRITICAL_PKGS[$pkg]=1
            CRITICAL_REASON[$pkg]="removal cascades to: $critical_cascade"
            echo "CRITICAL|$pkg|$priority|$rdep_count|removal cascades to: $critical_cascade" >> "$REPORT"
            CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
        elif [ "$rdep_count" -gt 5 ]; then
            # Many reverse deps → RISKY
            local rdep_names=$(get_installed_rdeps "$pkg" | head -5 | tr '\n' ' ')
            echo "RISKY|$pkg|$priority|$rdep_count|$rdep_count rdeps: $rdep_names" >> "$REPORT"
            RISKY_COUNT=$((RISKY_COUNT + 1))
        elif [ "$priority" = "standard" ] && [ "$rdep_count" -gt 2 ]; then
            # Standard priority with some rdeps → RISKY
            echo "RISKY|$pkg|$priority|$rdep_count|standard priority, $rdep_count rdeps" >> "$REPORT"
            RISKY_COUNT=$((RISKY_COUNT + 1))
        else
            # Safe to remove
            echo "SAFE|$pkg|$priority|$rdep_count|no critical cascade" >> "$REPORT"
            SAFE_COUNT=$((SAFE_COUNT + 1))
        fi
    done <<< "$ALL_INSTALLED"

    printf "\r    Analyzed %d/%d packages — done.          \n" "$TOTAL" "$TOTAL"

    # Write summary to end of report
    cat >> "$REPORT" << EOF

# ═══ SUMMARY ═══
# CRITICAL: $CRITICAL_COUNT (must keep)
# SAFE: $SAFE_COUNT (can remove)
# RISKY: $RISKY_COUNT (needs review)
# TOTAL: $TOTAL
EOF

    echo ""
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║ CRITICAL (must keep): $CRITICAL_COUNT"
    echo "  ║ SAFE (can remove):    $SAFE_COUNT"
    echo "  ║ RISKY (needs review): $RISKY_COUNT"
    echo "  ║ TOTAL:                $TOTAL"
    echo "  ╚═══════════════════════════════════════════════════╝"
}

# extract_safe_list <report_file> <output_list_file>
# Extracts just the SAFE package names from the report
extract_safe_list() {
    local REPORT="$1"
    local OUTPUT="$2"
    grep "^SAFE|" "$REPORT" | cut -d'|' -f2 | sort > "$OUTPUT"
    local count=$(wc -l < "$OUTPUT" | tr -d " ")
    echo "  Extracted $count SAFE packages to $(basename "$OUTPUT")"
}

# extract_risky_list <report_file> <output_list_file>
extract_risky_list() {
    local REPORT="$1"
    local OUTPUT="$2"
    grep "^RISKY|" "$REPORT" | cut -d'|' -f2 | sort > "$OUTPUT"
}

# extract_critical_list <report_file> <output_list_file>
extract_critical_list() {
    local REPORT="$1"
    local OUTPUT="$2"
    grep "^CRITICAL|" "$REPORT" | cut -d'|' -f2 | sort > "$OUTPUT"
}

# run_analysis <report_output_path>
# Main entry point — call this from the chroot
run_analysis() {
    local REPORT="$1"
    build_critical_set
    analyze_packages "$REPORT"
}
