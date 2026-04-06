#!/usr/bin/env bash
# Display CIS Level 1 hardening values in GitHub Actions logs
# Uses collapsible sections (::group::) for readability
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-.}"
CIS_CONFIG="${REPO_ROOT}/cis-config.yml"
HARDENING_DIR="${REPO_ROOT}/hardening/configs"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     CIS Level 1 Hardening — Values Being Applied         ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# ── SSH Hardening ──────────────────────────────────────────────
echo "::group::SSH Hardening (hardening/configs/00-hardening-ssh.conf)"
if [ -f "${HARDENING_DIR}/00-hardening-ssh.conf" ]; then
    grep -v '^#' "${HARDENING_DIR}/00-hardening-ssh.conf" | grep -v '^$' | while IFS= read -r line; do
        echo "  $line"
    done
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Kernel Hardening ──────────────────────────────────────────
echo "::group::Kernel & Network Hardening (hardening/configs/99-hardening-sysctl.conf)"
if [ -f "${HARDENING_DIR}/99-hardening-sysctl.conf" ]; then
    grep -v '^#' "${HARDENING_DIR}/99-hardening-sysctl.conf" | grep -v '^$' | while IFS= read -r line; do
        echo "  $line"
    done
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Password Policy ───────────────────────────────────────────
echo "::group::Password Policy (hardening/configs/pwquality.conf)"
if [ -f "${HARDENING_DIR}/pwquality.conf" ]; then
    grep -v '^#' "${HARDENING_DIR}/pwquality.conf" | grep -v '^$' | while IFS= read -r line; do
        echo "  $line"
    done
else
    echo "  (file not found)"
fi
echo ""
echo "  Additional policies applied in chroot:"
echo "    PASS_MAX_DAYS = 365"
echo "    PASS_MIN_DAYS = 1"
echo "    PASS_WARN_AGE = 7"
echo "    SHA_CRYPT_MIN_ROUNDS = 65536"
echo "    UMASK = 027"
echo "::endgroup::"

# ── Session ───────────────────────────────────────────────────
echo "::group::Session Timeout"
echo "  TMOUT = 900 (15 minutes, readonly)"
echo "::endgroup::"

# ── Core Dump ─────────────────────────────────────────────────
echo "::group::Core Dump Protection (hardening/configs/99-coredump.conf)"
if [ -f "${HARDENING_DIR}/99-coredump.conf" ]; then
    grep -v '^#' "${HARDENING_DIR}/99-coredump.conf" | grep -v '^$' | while IFS= read -r line; do
        echo "  $line"
    done
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Audit Rules ───────────────────────────────────────────────
echo "::group::Audit Rules (hardening/configs/50-cis.rules)"
if [ -f "${HARDENING_DIR}/50-cis.rules" ]; then
    RULE_COUNT=$(grep -c '^-' "${HARDENING_DIR}/50-cis.rules" 2>/dev/null || echo 0)
    echo "  ${RULE_COUNT} audit rules configured"
    echo "  Categories: time-change, identity, system-locale, logins, session,"
    echo "              permission-modification, delete, actions, modules"
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Filesystem Module Blacklist ───────────────────────────────
echo "::group::Disabled Kernel Modules (hardening/configs/CIS.conf)"
if [ -f "${HARDENING_DIR}/CIS.conf" ]; then
    grep '^install' "${HARDENING_DIR}/CIS.conf" | awk '{print "  " $2}' | sort
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Sudoers Hardening ─────────────────────────────────────────
echo "::group::Sudoers Hardening (hardening/configs/99-cis-sudoers)"
if [ -f "${HARDENING_DIR}/99-cis-sudoers" ]; then
    grep -v '^#' "${HARDENING_DIR}/99-cis-sudoers" | grep -v '^$' | while IFS= read -r line; do
        echo "  $line"
    done
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Journald ──────────────────────────────────────────────────
echo "::group::Journald Hardening (hardening/configs/99-cis-journald.conf)"
if [ -f "${HARDENING_DIR}/99-cis-journald.conf" ]; then
    grep -v '^#' "${HARDENING_DIR}/99-cis-journald.conf" | grep -v '^$' | grep -v '^\[' | while IFS= read -r line; do
        echo "  $line"
    done
else
    echo "  (file not found)"
fi
echo "::endgroup::"

# ── Login Banners ─────────────────────────────────────────────
echo "::group::Login Banners"
echo "  /etc/issue:     Legal warning banner (AUTHORIZED ACCESS ONLY)"
echo "  /etc/issue.net: Network login banner (same)"
echo "::endgroup::"

# ── GRUB ──────────────────────────────────────────────────────
echo "::group::GRUB Bootloader"
echo "  Password protection: ENABLED (PBKDF2)"
echo "  Boot without password: YES (--unrestricted)"
echo "  Edit GRUB entries: REQUIRES password (username: admin)"
echo "::endgroup::"

# ── Services Masked ───────────────────────────────────────────
echo "::group::Services Masked (disabled)"
echo "  avahi-daemon, cups, isc-dhcp-server, slapd, nfs-server,"
echo "  rpcbind, bind9, vsftpd, apache2, dovecot, snmpd, squid,"
echo "  xinetd"
echo "::endgroup::"

# ── Packages Installed ────────────────────────────────────────
echo "::group::Security Packages Installed"
echo "  cryptsetup, cryptsetup-initramfs, clevis-luks, clevis-tpm2"
echo "  auditd, fail2ban, rkhunter, aide"
echo "  libpam-pwquality, libpam-tmpdir, needrestart"
echo "::endgroup::"

echo ""
echo "To customize these values, edit files under hardening/configs/"
echo "and cis-config.yml in the repo root."
echo ""
