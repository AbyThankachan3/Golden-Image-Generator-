#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Chroot operations — bind mounts, teardown, package removal
# ═══════════════════════════════════════════════════════════

# setup_chroot <root_dir>
# Binds kernel filesystems for chroot
setup_chroot() {
    local ROOT="$1"

    mount --bind /proc    "$ROOT/proc"
    mount --bind /sys     "$ROOT/sys"
    mount --bind /dev     "$ROOT/dev"
    mount --bind /dev/pts "$ROOT/dev/pts"

    # Copy DNS config so apt/network operations work inside chroot
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
    fi

    log "Chroot bind mounts established"
}

# teardown_chroot <root_dir>
# Safely unmounts all bind mounts
teardown_chroot() {
    local ROOT="$1"

    for mnt in proc sys dev/pts dev; do
        local TARGET="$ROOT/$mnt"
        if mountpoint -q "$TARGET" 2>/dev/null; then
            umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
        fi
    done

    # Restore standard systemd-resolved symlink for resolv.conf
    # Without this, the squashfs gets repacked with Docker's resolv.conf
    # which breaks DNS during installer boot
    # Use rm + ln (not ln -sf) because ln -sf can silently fail on Docker overlay
    rm -f "$ROOT/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
    if [ -L "$ROOT/etc/resolv.conf" ]; then
        log "resolv.conf symlink restored"
    else
        warn "Failed to restore resolv.conf symlink — DNS may not work during install"
    fi

    log "Chroot bind mounts released"
}

# configure_cloud_init <root_dir>
# Writes bare-metal cloud-init config (no datasource wait)
configure_cloud_init() {
    local ROOT="$1"
    mkdir -p "$ROOT/etc/cloud/cloud.cfg.d"
    cat > "$ROOT/etc/cloud/cloud.cfg.d/99-bare-metal.cfg" << 'CLOUDCFG'
datasource_list: [None]
datasource:
  None:
    userdata_raw: ''
CLOUDCFG
    log "Cloud-init configured for bare metal (datasource: None)"
}

# install_openssh <root_dir>
# Checks if openssh-server is present; skips if not (subiquity installs it from ISO pool)
install_openssh() {
    local ROOT="$1"

    if chroot "$ROOT" dpkg -l openssh-server 2>/dev/null | grep -q "^ii"; then
        log "openssh-server already present in squashfs"
    else
        log "openssh-server not in squashfs — OK, subiquity installs it from ISO pool during OS installation"
    fi
}

# remove_packages_safe <root_dir> <packages_file> <critical_list>
# Removes packages with safety gates (dry-run + autoremove check)
remove_packages_safe() {
    local ROOT="$1"
    local PKG_FILE="$2"
    local CRITICAL_FILE="${3:-}"

    # Copy files into chroot
    cp "$PKG_FILE" "$ROOT/tmp/packages-to-remove.list"
    [ -n "$CRITICAL_FILE" ] && cp "$CRITICAL_FILE" "$ROOT/tmp/critical-packages.list"

    info "Running package removal with safety gates..."

    chroot "$ROOT" /bin/bash << 'CHROOT_REMOVAL'
#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Read package list (skip comments and empty lines)
PACKAGES=$(grep -v '^#' /tmp/packages-to-remove.list | grep -v '^$' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '+')

# Read critical packages
CRITICAL=""
if [ -f /tmp/critical-packages.list ]; then
    CRITICAL=$(cat /tmp/critical-packages.list | tr '\n' ' ')
fi

# Build critical set for quick lookup
declare -A IS_CRITICAL
for cpkg in $CRITICAL; do
    IS_CRITICAL[$cpkg]=1
done

# Mark protected packages as manual
PROTECT_PKGS="cloud-init apport python3-apport openssh-server netplan.io iproute2 systemd networkd-dispatcher python3 python3-minimal snapd dbus-user-session fuse3 squashfs-tools gdisk"
for pkg in $PROTECT_PKGS; do
    apt-mark manual "$pkg" 2>/dev/null || true
done
echo -e "${GREEN}  [OK]Protected packages marked as manual${NC}"

# Filter to only installed packages
INSTALLED_PKGS=""
SKIP_COUNT=0
for pkg in $PACKAGES; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        INSTALLED_PKGS="$INSTALLED_PKGS $pkg"
    else
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
done
INSTALLED_PKGS=$(echo "$INSTALLED_PKGS" | xargs)

if [ -z "$INSTALLED_PKGS" ]; then
    echo -e "${YELLOW}  [WARN]No packages from list are installed — nothing to remove${NC}"
    exit 0
fi

INST_COUNT=$(echo "$INSTALLED_PKGS" | wc -w)
echo -e "  Found $INST_COUNT installed packages to remove ($SKIP_COUNT not installed — skipped)"

# ── SAFETY GATE 1: Dry-run batch removal ──
echo -e "\n  ${YELLOW}Safety Gate 1: Dry-run removal...${NC}"
DRY_RUN=$(apt-get remove --purge --dry-run $INSTALLED_PKGS 2>/dev/null || true)
WOULD_REMOVE=$(echo "$DRY_RUN" | grep "^Remv " | awk '{print $2}' | sort -u || true)

CRITICAL_HIT=""
if [ -n "$WOULD_REMOVE" ]; then
    for removed_pkg in $WOULD_REMOVE; do
        if [ -n "${IS_CRITICAL[$removed_pkg]+x}" ]; then
            CRITICAL_HIT="$CRITICAL_HIT $removed_pkg"
        fi
    done
fi

if [ -n "$CRITICAL_HIT" ]; then
    echo -e "  ${RED}[FAIL]  ABORT: Dry-run would remove critical packages:${NC}"
    for pkg in $CRITICAL_HIT; do
        echo -e "    ${RED}- $pkg${NC}"
    done
    exit 1
fi
echo -e "  ${GREEN}[OK]  Dry-run safe — no critical packages affected${NC}"

# ── Actual removal (one-by-one for safety) ──
echo -e "\n  Removing packages..."
REMOVED=0
FAILED=0
for pkg in $INSTALLED_PKGS; do
    if apt-get remove --purge -y "$pkg" >/dev/null 2>&1; then
        REMOVED=$((REMOVED + 1))
    else
        echo -e "  ${YELLOW}[WARN] Could not remove: $pkg${NC}"
        FAILED=$((FAILED + 1))
    fi
done
echo -e "  ${GREEN}[OK] Removed: $REMOVED  |  Failed: $FAILED${NC}"

# ── SAFETY GATE 2: Dry-run autoremove ──
echo -e "\n  ${YELLOW}Safety Gate 2: Checking autoremove...${NC}"
AUTO_DRY=$(apt-get autoremove --dry-run 2>/dev/null || true)
AUTO_REMOVE=$(echo "$AUTO_DRY" | grep "^Remv " | awk '{print $2}' | sort -u || true)

AUTO_CRITICAL=""
if [ -n "$AUTO_REMOVE" ]; then
    for removed_pkg in $AUTO_REMOVE; do
        if [ -n "${IS_CRITICAL[$removed_pkg]+x}" ]; then
            AUTO_CRITICAL="$AUTO_CRITICAL $removed_pkg"
        fi
    done
fi

if [ -n "$AUTO_CRITICAL" ]; then
    echo -e "  ${YELLOW}⚠  Skipping autoremove — would remove critical:${NC}"
    for pkg in $AUTO_CRITICAL; do
        echo -e "    ${YELLOW}- $pkg${NC}"
    done
else
    AUTO_COUNT=$(echo "$AUTO_REMOVE" | grep -c . 2>/dev/null || echo 0)
    if [ "$AUTO_COUNT" -gt 0 ]; then
        echo -e "  Autoremove will clean $AUTO_COUNT orphaned packages"
        apt-get autoremove --purge -y >/dev/null 2>&1
        echo -e "  ${GREEN}[OK] Autoremove complete${NC}"
    else
        echo -e "  ${GREEN}[OK] No orphaned packages to autoremove${NC}"
    fi
fi

# ── Cleanup ──
apt-get clean 2>/dev/null
rm -rf /var/lib/apt/lists/* /tmp/*.deb 2>/dev/null

# ── Purge stale dpkg entries ──
# Packages removed from squashfs leave ghost entries in /var/lib/dpkg/status
# marked as "deinstall" or "purge". These cause "files list file missing" warnings
# when apt runs on the installed system. Clean them here.
STALE_PKGS=$(dpkg --get-selections 2>/dev/null | grep -E "deinstall|purge" | awk '{print $1}')
if [ -n "$STALE_PKGS" ]; then
    STALE_COUNT=$(echo "$STALE_PKGS" | wc -l | tr -d ' ')
    dpkg --purge $STALE_PKGS 2>/dev/null || true
    for pkg in $STALE_PKGS; do
        rm -f /var/lib/dpkg/info/${pkg}.* 2>/dev/null
    done
    echo -e "  ${GREEN}[OK]${NC}  Cleaned ${STALE_COUNT} stale dpkg entries (no warnings on installed system)"
fi

FINAL_COUNT=$(dpkg-query -f '${Status}\n' -W 2>/dev/null | grep -c "install ok installed")
echo -e "\n  ${GREEN}[OK]  Final package count: $FINAL_COUNT${NC}"
CHROOT_REMOVAL

    log "Package removal complete"
}
