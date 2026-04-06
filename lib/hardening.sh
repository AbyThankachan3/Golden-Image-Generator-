#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Hardening Module — ALL hardening applied in squashfs chroot
#  No first-boot script needed. Installed system boots hardened.
#
#  Three layers (all opt-in):
#    Layer 1: Install security packages (chroot apt install)
#    Layer 2: Write config files + GRUB password (chroot)
#    Layer 3: Apply CIS Level 1 controls (chroot file writes)
#
#  Environment variables:
#    HARDENING_LAYER1_ENABLE=true  — security packages
#    HARDENING_LAYER2_ENABLE=true  — config files + GRUB
#    HARDENING_LAYER3_ENABLE=true  — CIS Level 1 controls
# ═══════════════════════════════════════════════════════════

HARDENING_DIR="${HARDENING_DIR:-/hardening}"
CIS_CONFIG="${CIS_CONFIG:-/cis-config/cis-config.yml}"

# Source the config generator
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cis-config-generator.sh" 2>/dev/null || \
    source "/lib-golden/cis-config-generator.sh" 2>/dev/null || true

# ══════════════════════════════════════════════════════════
#  Layer 1: Install security packages in chroot
# ══════════════════════════════════════════════════════════
harden_install_packages() {
    local ROOT="$1"

    if [ "${HARDENING_LAYER1_ENABLE:-false}" != "true" ]; then
        return 0
    fi

    info "Installing security packages in squashfs..."

    # Packages for LUKS full-disk encryption support
    local CRYPTO_PKGS=(
        cryptsetup
        cryptsetup-initramfs
        initramfs-tools
    )

    # Clevis packages for automated LUKS unlocking (TPM2, Tang)
    local CLEVIS_PKGS=(
        clevis
        clevis-luks
        clevis-tpm2
        clevis-initramfs
    )

    # Security tools (Lynis suggestions)
    local SECURITY_PKGS=(
        auditd                  # ACCT-9628: audit daemon
        fail2ban                # DEB-0880: brute-force protection
        rkhunter                # HRDN-7230: malware scanner
        aide                    # FINT-4350: file integrity
        libpam-pwquality        # AUTH-9262: password strength
        libpam-tmpdir           # DEB-0280: tmpdir isolation
        needrestart             # DEB-0831: restart detection after upgrades
    )

    # Copy host resolv.conf for DNS resolution during apt operations
    local RESOLV_BACKUP=""
    if [ -f "$ROOT/etc/resolv.conf" ]; then
        RESOLV_BACKUP=$(cat "$ROOT/etc/resolv.conf")
    fi
    cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

    # Update apt cache inside chroot
    chroot "$ROOT" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq" 2>/dev/null || true

    # Install all packages
    local installed=0
    local failed=0
    local skipped=0
    for pkg in "${CRYPTO_PKGS[@]}" "${CLEVIS_PKGS[@]}" "${SECURITY_PKGS[@]}"; do
        if chroot "$ROOT" dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            skipped=$((skipped + 1))
            continue  # Already installed
        fi
        if chroot "$ROOT" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends $pkg" >/dev/null 2>&1; then
            installed=$((installed + 1))
        else
            warn "Could not install $pkg"
            failed=$((failed + 1))
        fi
    done

    # Clean apt cache to avoid bloating squashfs
    chroot "$ROOT" apt-get clean 2>/dev/null || true
    chroot "$ROOT" bash -c 'rm -rf /var/lib/apt/lists/*' 2>/dev/null || true

    # ALWAYS restore the standard systemd-resolved symlink
    # The backup may contain Docker's resolv.conf which would break DNS on the installed system
    rm -f "$ROOT/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

    log "Security packages: $installed installed, $skipped already present, $failed failed"
}

# ══════════════════════════════════════════════════════════
#  Layer 2: Write hardening configs + GRUB password
# ══════════════════════════════════════════════════════════
harden_write_configs() {
    local ROOT="$1"

    if [ "${HARDENING_LAYER2_ENABLE:-false}" != "true" ]; then
        return 0
    fi

    info "Writing hardening config files into squashfs..."

    # Try to generate configs from cis-config.yml (single source of truth)
    local CONFIG_SRC="$HARDENING_DIR/configs"
    local GENERATED_DIR="/tmp/generated-hardening-configs"
    if type generate_configs_from_yaml &>/dev/null && [ -f "$CIS_CONFIG" ]; then
        if generate_configs_from_yaml "$CIS_CONFIG" "$GENERATED_DIR"; then
            CONFIG_SRC="$GENERATED_DIR"
            log "Config files generated from cis-config.yml"
        else
            warn "Failed to generate from cis-config.yml — using static configs"
        fi
    fi

    # ── SSH hardening (all 13 Lynis SSH-7408 findings) ────
    local SSH_CONF="$CONFIG_SRC/99-hardening-ssh.conf"
    if [ -f "$SSH_CONF" ]; then
        mkdir -p "$ROOT/etc/ssh/sshd_config.d"
        cp "$SSH_CONF" "$ROOT/etc/ssh/sshd_config.d/99-hardening-ssh.conf"
        chmod 600 "$ROOT/etc/ssh/sshd_config.d/99-hardening-ssh.conf"
        # Also tighten sshd_config permissions
        chmod 600 "$ROOT/etc/ssh/sshd_config" 2>/dev/null || true
        log "SSH hardening config installed (13 settings)"
    else
        warn "SSH hardening config not found: $SSH_CONF"
    fi

    # ── Sysctl hardening (all Lynis KRNL-6000 values) ────
    local SYSCTL_CONF="$CONFIG_SRC/99-hardening-sysctl.conf"
    if [ -f "$SYSCTL_CONF" ]; then
        mkdir -p "$ROOT/etc/sysctl.d"
        cp "$SYSCTL_CONF" "$ROOT/etc/sysctl.d/99-hardening-sysctl.conf"
        chmod 644 "$ROOT/etc/sysctl.d/99-hardening-sysctl.conf"
        log "Sysctl hardening config installed (all Lynis KRNL-6000 values)"
    else
        warn "Sysctl hardening config not found: $SYSCTL_CONF"
    fi

    # ── Core dump disable (Lynis KRNL-5820) ──────────────
    local COREDUMP_CONF="$CONFIG_SRC/99-coredump.conf"
    if [ -f "$COREDUMP_CONF" ]; then
        mkdir -p "$ROOT/etc/security/limits.d"
        cp "$COREDUMP_CONF" "$ROOT/etc/security/limits.d/99-coredump.conf"
        chmod 644 "$ROOT/etc/security/limits.d/99-coredump.conf"
        log "Core dump disabled"
    fi

    # ── Modprobe blacklist (CIS filesystems + Lynis NETW-3200 protocols) ──
    local CIS_MODPROBE="$CONFIG_SRC/CIS.conf"
    if [ -f "$CIS_MODPROBE" ]; then
        mkdir -p "$ROOT/etc/modprobe.d"
        cp "$CIS_MODPROBE" "$ROOT/etc/modprobe.d/CIS.conf"
        chmod 644 "$ROOT/etc/modprobe.d/CIS.conf"
        local count
        count=$(grep -c "^install.*bin/true" "$CIS_MODPROBE" 2>/dev/null || echo 0)
        log "CIS modprobe blacklist installed ($count modules disabled)"
    fi

    # ── Audit rules (CIS 4.1) ────────────────────────────
    local AUDIT_RULES="$CONFIG_SRC/50-cis.rules"
    if [ -f "$AUDIT_RULES" ]; then
        mkdir -p "$ROOT/etc/audit/rules.d"
        cp "$AUDIT_RULES" "$ROOT/etc/audit/rules.d/50-cis.rules"
        chmod 640 "$ROOT/etc/audit/rules.d/50-cis.rules"
        local rule_count
        rule_count=$(grep -c "^-" "$AUDIT_RULES" 2>/dev/null || echo 0)
        log "CIS audit rules installed ($rule_count rules)"
    fi

    # ── Login banners (Lynis BANN-7126/7130) ─────────────
    local ISSUE="$CONFIG_SRC/issue.txt"
    local ISSUE_NET="$CONFIG_SRC/issue.net.txt"
    if [ -f "$ISSUE" ]; then
        cp "$ISSUE" "$ROOT/etc/issue"
        chmod 644 "$ROOT/etc/issue"
        log "Login banner (/etc/issue) installed"
    fi
    if [ -f "$ISSUE_NET" ]; then
        cp "$ISSUE_NET" "$ROOT/etc/issue.net"
        chmod 644 "$ROOT/etc/issue.net"
        log "Network banner (/etc/issue.net) installed"
    fi

    # ── Password quality (CIS 5.3.1) ─────────────────────
    local PWQUALITY="$CONFIG_SRC/pwquality.conf"
    if [ -f "$PWQUALITY" ]; then
        mkdir -p "$ROOT/etc/security"
        cp "$PWQUALITY" "$ROOT/etc/security/pwquality.conf"
        chmod 644 "$ROOT/etc/security/pwquality.conf"
        log "Password quality rules installed (CIS 5.3.1)"
    fi

    # ── Sudoers hardening (CIS 5.5) ───────────────────────
    local SUDOERS_CIS="$CONFIG_SRC/99-cis-sudoers"
    if [ -f "$SUDOERS_CIS" ]; then
        mkdir -p "$ROOT/etc/sudoers.d"
        cp "$SUDOERS_CIS" "$ROOT/etc/sudoers.d/99-cis-hardening"
        chmod 440 "$ROOT/etc/sudoers.d/99-cis-hardening"
        log "Sudoers hardening installed (use_pty, timeout, logging)"
    fi

    # ── Journald hardening (CIS 4.2) ──────────────────────
    local JOURNALD_CIS="$CONFIG_SRC/99-cis-journald.conf"
    if [ -f "$JOURNALD_CIS" ]; then
        mkdir -p "$ROOT/etc/systemd/journald.conf.d"
        cp "$JOURNALD_CIS" "$ROOT/etc/systemd/journald.conf.d/99-cis.conf"
        chmod 644 "$ROOT/etc/systemd/journald.conf.d/99-cis.conf"
        log "Journald hardening installed (persistent logs, compression)"
    fi

    # ── Cron/at allow files (CIS 5.1.8) ───────────────────
    echo "root" > "$ROOT/etc/cron.allow"
    chmod 640 "$ROOT/etc/cron.allow"
    echo "root" > "$ROOT/etc/at.allow"
    chmod 640 "$ROOT/etc/at.allow"
    # Remove deny files if they exist (allow takes precedence, deny is less secure)
    rm -f "$ROOT/etc/cron.deny" "$ROOT/etc/at.deny" 2>/dev/null || true
    log "Cron/at access restricted to root only (CIS 5.1.8)"

    # ── GRUB password (Lynis BOOT-5122) ──────────────────
    local GRUB_HASH_FILE="$HARDENING_DIR/secrets/grub-password.hash"
    if [ -f "$GRUB_HASH_FILE" ]; then
        local GRUB_HASH
        GRUB_HASH=$(cat "$GRUB_HASH_FILE" | tr -d '\n')
        if [ -n "$GRUB_HASH" ]; then
            # Write GRUB password to 40_custom with --unrestricted baked in
            # The trick: set superusers AND mark all entries unrestricted
            # so normal boot works, but GRUB editing requires password
            mkdir -p "$ROOT/etc/grub.d"
            cat > "$ROOT/etc/grub.d/40_custom" << GRUBEOF
#!/bin/sh
exec tail -n +3 \$0
# GRUB password — Golden Image hardening
# Boot is allowed without password. Editing GRUB requires "admin" credentials.
set superusers="admin"
password_pbkdf2 admin ${GRUB_HASH}
GRUBEOF
            chmod 755 "$ROOT/etc/grub.d/40_custom"

            # Patch 10_linux CLASS variable to add --unrestricted
            # This makes menuentry lines include --unrestricted so boot doesn't need password
            # NOTE: subiquity reinstalls grub packages during install which may overwrite 10_linux
            # So we also create a dpkg hook to re-apply the patch after any grub package update
            local GRUB_10_LINUX="$ROOT/etc/grub.d/10_linux"
            local PATCHED_10_LINUX=false
            if [ -f "$GRUB_10_LINUX" ]; then
                # Match the CLASS= line regardless of exact whitespace
                if grep -qE '^CLASS="--class gnu-linux --class gnu --class os"' "$GRUB_10_LINUX"; then
                    sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' "$GRUB_10_LINUX"
                    PATCHED_10_LINUX=true
                    log "GRUB 10_linux patched with --unrestricted"
                fi
            fi

            # KEY FIX: Create /etc/grub.d/09_unrestricted_patch
            # This runs BEFORE 10_linux during every update-grub call.
            # It patches 10_linux's CLASS variable to include --unrestricted.
            # This survives subiquity reinstalling GRUB packages because:
            # - subiquity overwrites 10_linux but NOT 09_unrestricted_patch
            # - subiquity runs update-grub after install → 09 patches 10 → grub.cfg is correct
            cat > "$ROOT/etc/grub.d/09_unrestricted_patch" << 'PATCH_SCRIPT'
#!/bin/sh
# Auto-patch 10_linux to add --unrestricted before it generates menu entries.
# This ensures normal boot never requires GRUB password (only editing does).
# Runs during update-grub since grub.d scripts execute in numeric order.
LINUX_SCRIPT="/etc/grub.d/10_linux"
if [ -f "$LINUX_SCRIPT" ] && ! grep -q 'unrestricted' "$LINUX_SCRIPT" 2>/dev/null; then
    sed -i 's/CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' "$LINUX_SCRIPT" 2>/dev/null || true
fi
PATCH_SCRIPT
            chmod 755 "$ROOT/etc/grub.d/09_unrestricted_patch"
            log "GRUB 09_unrestricted_patch installed (auto-patches 10_linux during update-grub)"

            # NOTE: DPkg::Post-Invoke hook removed — it had APT config syntax issues
            # that broke apt_pkg.init_config() → crashed subiquity.
            # The 09_unrestricted_patch script above handles all cases:
            # it runs before 10_linux during every update-grub call,
            # so even if subiquity reinstalls GRUB, the next update-grub re-patches it.

            log "GRUB password protection configured (boot=unrestricted, edit=password required)"
        fi
    else
        info "No GRUB password hash found — skipping GRUB password protection"
    fi
}

# ══════════════════════════════════════════════════════════
#  Layer 3: CIS Level 1 controls — all in chroot
# ══════════════════════════════════════════════════════════
harden_cis_controls() {
    local ROOT="$1"

    if [ "${HARDENING_LAYER3_ENABLE:-false}" != "true" ]; then
        return 0
    fi

    info "Applying CIS Level 1 controls in squashfs chroot..."

    # Read values from cis-config.yml or use defaults
    local PASS_MAX PASS_MIN PASS_WARN UMASK_VAL SHA_ROUNDS TMOUT_VAL
    if type get_val &>/dev/null && [ -f "$CIS_CONFIG" ]; then
        PASS_MAX=$(get_val "pw_policy.PASS_MAX_DAYS")
        PASS_MIN=$(get_val "pw_policy.PASS_MIN_DAYS")
        PASS_WARN=$(get_val "pw_policy.PASS_WARN_AGE")
        UMASK_VAL=$(get_val "pw_policy.UMASK")
        SHA_ROUNDS=$(get_val "pw_policy.SHA_CRYPT_MIN_ROUNDS")
        TMOUT_VAL=$(get_val "session.TMOUT")
    fi
    PASS_MAX="${PASS_MAX:-365}"
    PASS_MIN="${PASS_MIN:-1}"
    PASS_WARN="${PASS_WARN:-7}"
    UMASK_VAL="${UMASK_VAL:-027}"
    SHA_ROUNDS="${SHA_ROUNDS:-65536}"
    TMOUT_VAL="${TMOUT_VAL:-900}"

    # ── Password policies (Lynis AUTH-9229/9230/9282) ────
    local LOGIN_DEFS="$ROOT/etc/login.defs"
    if [ -f "$LOGIN_DEFS" ]; then
        sed -i "s/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   $PASS_MAX/" "$LOGIN_DEFS"
        sed -i "s/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   $PASS_MIN/" "$LOGIN_DEFS"
        sed -i "s/^PASS_WARN_AGE.*/PASS_WARN_AGE   $PASS_WARN/" "$LOGIN_DEFS"
        sed -i "s/^UMASK.*/UMASK           $UMASK_VAL/" "$LOGIN_DEFS"

        if ! grep -q "^SHA_CRYPT_MIN_ROUNDS" "$LOGIN_DEFS"; then
            echo "" >> "$LOGIN_DEFS"
            echo "# CIS Hardening — password hashing rounds" >> "$LOGIN_DEFS"
            echo "SHA_CRYPT_MIN_ROUNDS $SHA_ROUNDS" >> "$LOGIN_DEFS"
            echo "SHA_CRYPT_MAX_ROUNDS $SHA_ROUNDS" >> "$LOGIN_DEFS"
        fi

        log "Password policies configured (aging + umask + hashing rounds)"
    fi

    # ── Default umask in shell profiles ───────────────────
    local BASHRC="$ROOT/etc/bash.bashrc"
    if [ -f "$BASHRC" ] && ! grep -q "^umask $UMASK_VAL" "$BASHRC"; then
        echo "" >> "$BASHRC"
        echo "# CIS Hardening — restrict default umask" >> "$BASHRC"
        echo "umask $UMASK_VAL" >> "$BASHRC"
    fi

    local PROFILE="$ROOT/etc/profile"
    if [ -f "$PROFILE" ] && ! grep -q "^umask $UMASK_VAL" "$PROFILE"; then
        echo "" >> "$PROFILE"
        echo "# CIS Hardening — restrict default umask" >> "$PROFILE"
        echo "umask $UMASK_VAL" >> "$PROFILE"
    fi

    # ── Session timeout (CIS 5.4.5) ──────────────────────
    mkdir -p "$ROOT/etc/profile.d"
    cat > "$ROOT/etc/profile.d/99-cis-timeout.sh" << TMOUT_EOF
# CIS Hardening — auto-logout idle sessions
readonly TMOUT=$TMOUT_VAL
export TMOUT
TMOUT_EOF
    chmod 644 "$ROOT/etc/profile.d/99-cis-timeout.sh"
    log "Session timeout configured (TMOUT=900)"

    # ── File permissions (Lynis FILE-7524 + CIS 6.1) ─────
    chmod 644 "$ROOT/etc/passwd" 2>/dev/null || true
    chmod 640 "$ROOT/etc/shadow" 2>/dev/null || true
    chmod 644 "$ROOT/etc/group" 2>/dev/null || true
    chmod 640 "$ROOT/etc/gshadow" 2>/dev/null || true

    # SSH host key permissions
    find "$ROOT/etc/ssh" -name 'ssh_host_*_key' -exec chmod 600 {} \; 2>/dev/null || true
    find "$ROOT/etc/ssh" -name 'ssh_host_*_key.pub' -exec chmod 644 {} \; 2>/dev/null || true
    log "Critical file permissions set"

    # ── Cron restrictions (CIS 5.1) ──────────────────────
    for dir in crontab cron.hourly cron.daily cron.weekly cron.monthly cron.d; do
        [ -e "$ROOT/etc/$dir" ] && chmod 700 "$ROOT/etc/$dir" 2>/dev/null || true
    done
    log "Cron access restricted"

    # ── Restrict su access (CIS 5.6) ────────────────────
    # Ensure only members of 'wheel' or 'sudo' group can use su
    local PAM_SU="$ROOT/etc/pam.d/su"
    if [ -f "$PAM_SU" ]; then
        if grep -q "^#.*pam_wheel.so" "$PAM_SU"; then
            sed -i 's/^#\s*auth\s*required\s*pam_wheel.so/auth required pam_wheel.so/' "$PAM_SU"
            log "su access restricted to wheel/sudo group"
        fi
    fi

    # ── Disable unused services via symlink (no systemd needed) ──
    # Read service list from YAML or use defaults
    local MASK_SERVICES=()
    if type get_list &>/dev/null && [ -f "$CIS_CONFIG" ]; then
        local svc_list
        svc_list=$(get_list "services_masked")
        if [ -z "$svc_list" ]; then
            svc_list=$(get_inline_list "services_masked")
        fi
        if [ -n "$svc_list" ]; then
            while IFS= read -r s; do
                [ -n "$s" ] && MASK_SERVICES+=("$s")
            done <<< "$svc_list"
        fi
    fi
    # Default if YAML didn't provide list
    if [ ${#MASK_SERVICES[@]} -eq 0 ]; then
        MASK_SERVICES=(avahi-daemon cups isc-dhcp-server slapd nfs-server
            rpcbind bind9 vsftpd apache2 dovecot snmpd squid)
    fi
    for svc in "${MASK_SERVICES[@]}"; do
        local svc_file="$ROOT/etc/systemd/system/${svc}.service"
        if [ ! -e "$svc_file" ]; then
            # Create mask symlink only if the service exists in system catalog
            if [ -f "$ROOT/lib/systemd/system/${svc}.service" ] || \
               [ -f "$ROOT/usr/lib/systemd/system/${svc}.service" ]; then
                ln -sf /dev/null "$svc_file" 2>/dev/null || true
            fi
        fi
    done
    log "Unnecessary services masked"

    # ── Additional CIS network hardening sysctl ──────────
    # These go in a separate file to avoid conflicts with Layer 2 sysctl
    cat > "$ROOT/etc/sysctl.d/99-cis-network.conf" << 'CIS_NET_EOF'
# CIS additional network hardening
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
CIS_NET_EOF
    chmod 644 "$ROOT/etc/sysctl.d/99-cis-network.conf"
    log "CIS network sysctl configured"

    # ── /etc/motd cleanup ────────────────────────────────
    [ ! -f "$ROOT/etc/motd" ] && touch "$ROOT/etc/motd"
    chmod 644 "$ROOT/etc/motd" 2>/dev/null || true

    # ── Restrict /etc/sudoers.d permissions (Lynis warning) ──
    chmod 750 "$ROOT/etc/sudoers.d" 2>/dev/null || true

    log "CIS Level 1 controls applied in chroot"
}

# ══════════════════════════════════════════════════════════
#  Package installation orchestrator (runs BEFORE hardening)
# ══════════════════════════════════════════════════════════
install_all_packages() {
    local ROOT="$1"

    local any_install=false
    [ "${HARDENING_LAYER1_ENABLE:-false}" = "true" ] && any_install=true
    [ "${INSTALL_TOOLS_ENABLE:-false}" = "true" ] && any_install=true

    if [ "$any_install" = "false" ]; then
        return 0
    fi

    step "6.5" "Installing Packages"

    # Security packages (Layer 1)
    harden_install_packages "$ROOT"

    # Extra tools (kubectl, docker, helm, etc.)
    if type install_extra_tools &>/dev/null; then
        install_extra_tools "$ROOT"
    fi

    log "All package installations complete"
}

# ══════════════════════════════════════════════════════════
#  Hardening orchestrator (runs AFTER all installations)
# ══════════════════════════════════════════════════════════
apply_hardening() {
    local ROOT="$1"
    local VERSION="${2:-}"

    local any_enabled=false
    [ "${HARDENING_LAYER2_ENABLE:-false}" = "true" ] && any_enabled=true
    [ "${HARDENING_LAYER3_ENABLE:-false}" = "true" ] && any_enabled=true

    if [ "$any_enabled" = "false" ]; then
        return 0
    fi

    step "7" "Applying CIS Hardening"
    harden_write_configs "$ROOT"
    harden_cis_controls "$ROOT"

    local summary=""
    [ "${HARDENING_LAYER2_ENABLE:-false}" = "true" ] && summary="${summary}configs+grub "
    [ "${HARDENING_LAYER3_ENABLE:-false}" = "true" ] && summary="${summary}cis-level1 "

    log "CIS hardening applied: ${summary}"
}
