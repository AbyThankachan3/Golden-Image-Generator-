#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Validation Script Generator
#  Produces a validate-golden-image.sh with dynamic lists
# ═══════════════════════════════════════════════════════════

# generate_validation <removed_pkgs_file> <remaining_pkgs_file> <output_script> <version>
generate_validation() {
    local REMOVED_FILE="$1"
    local REMAINING_FILE="$2"
    local OUTPUT="$3"
    local VERSION="$4"

    info "Generating validation script..."

    # Build removed packages array string
    local REMOVED_ARRAY=""
    while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ "$pkg" =~ ^#.*$ ]] && continue
        [ -z "$pkg" ] && continue
        REMOVED_ARRAY="${REMOVED_ARRAY}    $pkg\n"
    done < "$REMOVED_FILE"

    local REMOVED_COUNT=$(grep -v '^#' "$REMOVED_FILE" | grep -v '^$' | wc -l | tr -d " ")

    # Build allowlist from remaining packages (group into patterns)
    local ALLOWLIST=""
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        ALLOWLIST="${ALLOWLIST}    \"$pkg\"\n"
    done < "$REMAINING_FILE"

    # Use the template if available, otherwise generate inline
    local TPL="/lib-golden/templates/validate-golden-image.tpl.sh"
    if [ -f "$TPL" ]; then
        # Template-based generation
        sed \
            -e "s/%%VERSION%%/$VERSION/g" \
            -e "s/%%REMOVED_COUNT%%/$REMOVED_COUNT/g" \
            "$TPL" > "$OUTPUT"

        # Replace placeholder blocks (multi-line, use a different approach)
        # For REMOVED_LIST: write to temp then insert
        local REMOVED_TEMP=$(mktemp)
        grep -v '^#' "$REMOVED_FILE" | grep -v '^$' | sed 's/^[[:space:]]*//' | \
            while IFS= read -r pkg; do echo "    $pkg"; done > "$REMOVED_TEMP"

        # Use python3 for reliable multi-line replacement
        python3 -c "
import sys
with open('$OUTPUT', 'r') as f:
    content = f.read()
with open('$REMOVED_TEMP', 'r') as f:
    removed = f.read().strip()
content = content.replace('%%REMOVED_LIST%%', removed)
with open('$OUTPUT', 'w') as f:
    f.write(content)
" 2>/dev/null || true

        rm -f "$REMOVED_TEMP"
    else
        # Inline generation (fallback)
        generate_validation_inline "$REMOVED_FILE" "$REMAINING_FILE" "$OUTPUT" "$VERSION" "$REMOVED_COUNT"
    fi

    chmod +x "$OUTPUT"
    log "Validation script generated: $(basename "$OUTPUT") ($REMOVED_COUNT packages tracked)"
}

# generate_validation_inline — generates complete script without template
generate_validation_inline() {
    local REMOVED_FILE="$1"
    local REMAINING_FILE="$2"
    local OUTPUT="$3"
    local VERSION="$4"
    local REMOVED_COUNT="$5"

    # Build the removed list for embedding
    local REMOVED_ITEMS=""
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ "$line" =~ ^#.*$ ]] && continue
        [ -z "$line" ] && continue
        REMOVED_ITEMS="${REMOVED_ITEMS}    ${line}\n"
    done < "$REMOVED_FILE"

    cat > "$OUTPUT" << 'SCRIPT_HEADER'
#!/usr/bin/env bash
# Auto-generated Golden Image Validation Script
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; RECOMMENDATIONS=()
pass()  { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}[PASS]${NC} $1"; }
warn()  { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}[FAIL]${NC} $1"; }
info()  { echo -e "  ${CYAN}[INFO]${NC} $1"; }
header(){ echo ""; echo -e "${BOLD}${MAGENTA}═══ $1 ═══${NC}"; }
rec()   { RECOMMENDATIONS+=("$1"); }

[ "$(id -u)" -ne 0 ] && echo -e "${RED}ERROR: Run as root${NC}" && exit 1
[ -f /etc/os-release ] && . /etc/os-release && OS_DESC="${PRETTY_NAME:-unknown}" || OS_DESC="unknown"

echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     Golden Image Validation & Hardening Check            ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo -e "  Date     : $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Hostname : $(hostname)"
echo -e "  OS       : ${OS_DESC}"
echo -e "  Kernel   : $(uname -r)"
echo ""

header "SECTION A: MINIMALITY CHECKS"

echo ""; echo -e "  ${BOLD}A1. Total Package Count${NC}"
PKG_COUNT=$(dpkg-query -f '${Status}\n' -W 2>/dev/null | grep -c "install ok installed" || echo 0)
info "Installed packages: ${PKG_COUNT}"
if [ "$PKG_COUNT" -lt 350 ]; then pass "Minimal — ${PKG_COUNT} packages (under 350)"
elif [ "$PKG_COUNT" -lt 450 ]; then warn "Moderate — ${PKG_COUNT} packages (350-450 range)"
else fail "Bloated — ${PKG_COUNT} packages (over 450)"; fi

SCRIPT_HEADER

    # Write the A8 section with embedded removed list
    cat >> "$OUTPUT" << REMOVED_SECTION
echo ""; echo -e "  \${BOLD}A8. Removed Packages Verification\${NC}"
info "Checking that packages from removal list are not installed..."
REMOVED_LIST=(
$(printf "%s\n" "$REMOVED_ITEMS")
)

STILL_PRESENT=""
for pkg in "\${REMOVED_LIST[@]}"; do
    if dpkg-query -W -f='\${Status}' "\$pkg" 2>/dev/null | grep -q "install ok installed"; then
        STILL_PRESENT="\${STILL_PRESENT}\${pkg}\n"
    fi
done

if [ -z "\$STILL_PRESENT" ] || [ "\$(echo -e "\$STILL_PRESENT" | grep -c . || echo 0)" -eq 0 ]; then
    pass "All $REMOVED_COUNT packages from removal list are confirmed absent"
else
    PRESENT_COUNT=\$(echo -e "\$STILL_PRESENT" | grep -c . || echo 0)
    fail "\${PRESENT_COUNT} package(s) from removal list are STILL installed:"
    echo -e "\$STILL_PRESENT" | while read -r pkg; do [ -n "\$pkg" ] && echo "         - \$pkg"; done
    rec "Remove remaining packages: apt-get remove --purge <packages>"
fi
REMOVED_SECTION

    # Append hardening checks if hardening was enabled
    if [ "${HARDENING_LAYER2_ENABLE:-false}" = "true" ] || [ "${HARDENING_LAYER3_ENABLE:-false}" = "true" ]; then
        cat >> "$OUTPUT" << 'HARDENING_CHECKS'

header "SECTION D: HARDENING CHECKS"

echo ""; echo -e "  ${BOLD}D1. SSH Hardening Config${NC}"
if [ -f /etc/ssh/sshd_config.d/00-hardening-ssh.conf ]; then
    pass "SSH hardening config present (/etc/ssh/sshd_config.d/00-hardening-ssh.conf)"
    if grep -q "MACs" /etc/ssh/sshd_config.d/00-hardening-ssh.conf 2>/dev/null; then
        pass "SSH MACs hardening configured"
    else
        warn "SSH MACs not found in hardening config"
    fi
else
    warn "SSH hardening config not found"
    rec "SSH hardening config should be at /etc/ssh/sshd_config.d/00-hardening-ssh.conf"
fi

echo ""; echo -e "  ${BOLD}D2. Sysctl Hardening${NC}"
if [ -f /etc/sysctl.d/99-hardening-sysctl.conf ]; then
    pass "Sysctl hardening config present"
    # Check if values are actually active
    ICMP_REDIRECT=$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null || echo "N/A")
    if [ "$ICMP_REDIRECT" = "0" ]; then
        pass "ICMP redirects disabled (active)"
    else
        warn "ICMP redirects = $ICMP_REDIRECT (should be 0 — may need reboot or sysctl --system)"
    fi
else
    warn "Sysctl hardening config not found"
    rec "Sysctl hardening config should be at /etc/sysctl.d/99-hardening-sysctl.conf"
fi

echo ""; echo -e "  ${BOLD}D3. GRUB Password${NC}"
if [ -f /etc/grub.d/40_custom ] && grep -q "superusers" /etc/grub.d/40_custom 2>/dev/null; then
    pass "GRUB password protection configured"
else
    warn "GRUB password not configured"
    rec "GRUB password should be set in /etc/grub.d/40_custom"
fi

echo ""; echo -e "  ${BOLD}D4. CIS Filesystem Hardening${NC}"
if [ -f /etc/modprobe.d/CIS.conf ]; then
    DISABLED_FS=$(grep -c "^install.*bin/true" /etc/modprobe.d/CIS.conf 2>/dev/null || echo 0)
    pass "CIS filesystem module blacklist present ($DISABLED_FS modules disabled)"
else
    warn "CIS filesystem hardening not found (/etc/modprobe.d/CIS.conf)"
fi

echo ""; echo -e "  ${BOLD}D5. Audit Rules${NC}"
if [ -f /etc/audit/rules.d/50-cis.rules ]; then
    RULE_COUNT=$(grep -c "^-" /etc/audit/rules.d/50-cis.rules 2>/dev/null || echo 0)
    pass "CIS audit rules present ($RULE_COUNT rules)"
else
    warn "CIS audit rules not found"
    rec "Install auditd and configure audit rules for CIS compliance"
fi

HARDENING_CHECKS
    fi

    # Append security checks (static — version-independent)
    cat >> "$OUTPUT" << 'SECURITY_CHECKS'

header "SECTION B: SECURITY CHECKS"

echo ""; echo -e "  ${BOLD}B1. SSH Hardening${NC}"
check_ssh() {
    local setting="$1" expected="$2" label="$3"
    local value=""
    # sshd -T shows the EFFECTIVE config (all files merged) — most reliable
    if command -v sshd &>/dev/null; then
        value=$(sshd -T 2>/dev/null | grep -i "^${setting} " | awk '{print $2}' | head -1)
    fi
    # Fallback: read config files manually (drop-ins override main config)
    if [ -z "$value" ]; then
        # Read main config first
        if [ -f /etc/ssh/sshd_config ]; then
            local v=$(grep -i "^${setting}" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
            [ -n "$v" ] && value="$v"
        fi
        # Drop-in configs override main — read last (highest number wins)
        for conf in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$conf" ] || continue
            local v=$(grep -i "^${setting}" "$conf" 2>/dev/null | tail -1 | awk '{print $2}')
            [ -n "$v" ] && value="$v"
        done
    fi
    [ -z "$value" ] && { info "${label}: not set (using default)"; return; }
    local vl=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    local el=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
    [ "$vl" = "$el" ] && pass "${label} = ${value}" || warn "${label} = ${value} (recommended: ${expected})"
}
check_ssh "PermitRootLogin" "no" "PermitRootLogin"
check_ssh "PasswordAuthentication" "no" "PasswordAuthentication"
check_ssh "PermitEmptyPasswords" "no" "PermitEmptyPasswords"
check_ssh "X11Forwarding" "no" "X11Forwarding"
check_ssh "MaxAuthTries" "3" "MaxAuthTries"

echo ""; echo -e "  ${BOLD}B2. Firewall Status${NC}"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "active"; then
    pass "UFW firewall is active"
else
    warn "No firewall is active"
    rec "Enable firewall: apt install ufw && ufw allow 22/tcp && ufw enable"
fi

echo ""; echo -e "  ${BOLD}B3. Root Account${NC}"
ROOT_STATUS=$(passwd -S root 2>/dev/null | awk '{print $2}')
case "$ROOT_STATUS" in
    L) pass "Root account is locked" ;;
    P) warn "Root account has a password set"; rec "Lock root: passwd -l root" ;;
    *) info "Root account status: ${ROOT_STATUS}" ;;
esac

echo ""; echo -e "  ${BOLD}B4. Kernel Hardening${NC}"
check_sysctl() {
    local param="$1" expected="$2" label="${3:-$1}"
    local procpath="/proc/sys/$(echo "$param" | tr '.' '/')"
    local actual=""; [ -r "$procpath" ] && actual=$(cat "$procpath" 2>/dev/null | tr -d " ")
    [ -z "$actual" ] && actual=$(sysctl -n "$param" 2>/dev/null | tr -d " " || echo "N/A")
    [ "$actual" = "$expected" ] && pass "${label} = ${actual}" || warn "${label} = ${actual} (recommended: ${expected})"
}
check_sysctl "kernel.randomize_va_space" "2" "ASLR"
check_sysctl "net.ipv4.conf.all.send_redirects" "0" "IPv4 send_redirects"
check_sysctl "net.ipv4.conf.all.accept_redirects" "0" "IPv4 accept_redirects"
check_sysctl "net.ipv4.tcp_syncookies" "1" "TCP SYN cookies"
check_sysctl "fs.protected_hardlinks" "1" "Protected hardlinks"
check_sysctl "fs.protected_symlinks" "1" "Protected symlinks"
check_sysctl "kernel.dmesg_restrict" "1" "dmesg restricted"

# ══════════════════════════════════════════════════════════
#  SECTION C: LYNIS COMPREHENSIVE SECURITY AUDIT
# ══════════════════════════════════════════════════════════
header "SECTION C: LYNIS SECURITY AUDIT (200+ checks)"

LYNIS_SCORE="N/A"
LYNIS_WARNINGS=0
LYNIS_SUGGESTIONS=0
LYNIS_INSTALLED_BY_US=false

# Check if lynis is already installed
if command -v lynis &>/dev/null; then
    info "Lynis already installed: $(lynis --version 2>/dev/null | head -1)"
else
    echo -e "  ${CYAN}[INFO]${NC} Installing Lynis temporarily for audit..."
    export DEBIAN_FRONTEND=noninteractive

    # Record package state before install
    PKGS_BEFORE=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)

    apt-get update -qq >/dev/null 2>&1
    if apt-get install -y -qq lynis >/dev/null 2>&1; then
        LYNIS_INSTALLED_BY_US=true
        info "Lynis installed successfully"
    else
        warn "Could not install Lynis — skipping comprehensive audit"
        rec "Install manually: apt-get install lynis && lynis audit system"
    fi
fi

if command -v lynis &>/dev/null; then
    echo ""
    info "Running Lynis audit (this may take 1-2 minutes)..."
    echo ""

    # Run Lynis audit
    LYNIS_REPORT="/tmp/lynis-report-$$.log"
    LYNIS_DATA="/tmp/lynis-data-$$.dat"

    lynis audit system --no-colors --quick \
        --report-file "$LYNIS_REPORT" \
        --log-file "$LYNIS_DATA" \
        >/dev/null 2>&1 || true

    # Extract hardening index
    if [ -f "$LYNIS_REPORT" ]; then
        LYNIS_SCORE=$(grep "hardening_index=" "$LYNIS_REPORT" 2>/dev/null | cut -d'=' -f2 | head -1)
        LYNIS_WARNINGS=$(grep -c "^warning\[\]=" "$LYNIS_REPORT" 2>/dev/null || echo 0)
        LYNIS_SUGGESTIONS=$(grep -c "^suggestion\[\]=" "$LYNIS_REPORT" 2>/dev/null || echo 0)
    fi

    # Parse Lynis score
    if [ -n "$LYNIS_SCORE" ] && [ "$LYNIS_SCORE" != "N/A" ]; then
        echo -e "  ${BOLD}Lynis Hardening Index: ${LYNIS_SCORE}/100${NC}"
        echo ""

        if [ "$LYNIS_SCORE" -ge 80 ]; then
            pass "Lynis hardening index: ${LYNIS_SCORE}/100 (Excellent)"
        elif [ "$LYNIS_SCORE" -ge 65 ]; then
            warn "Lynis hardening index: ${LYNIS_SCORE}/100 (Good — room for improvement)"
        elif [ "$LYNIS_SCORE" -ge 50 ]; then
            warn "Lynis hardening index: ${LYNIS_SCORE}/100 (Moderate — needs hardening)"
            rec "Review Lynis suggestions: grep 'suggestion' /tmp/lynis-report.log"
        else
            fail "Lynis hardening index: ${LYNIS_SCORE}/100 (Low — significant hardening needed)"
            rec "Run: lynis audit system --no-colors | less"
        fi

        info "Lynis found ${LYNIS_WARNINGS} warnings, ${LYNIS_SUGGESTIONS} suggestions"
    else
        warn "Could not extract Lynis hardening score"
    fi

    # Extract and display top warnings
    if [ -f "$LYNIS_REPORT" ] && [ "$LYNIS_WARNINGS" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}Top Lynis Warnings:${NC}"
        grep "^warning\[\]=" "$LYNIS_REPORT" 2>/dev/null | head -10 | while IFS= read -r line; do
            # Format: warning[]=WARNING_ID|description|details|severity
            MSG=$(echo "$line" | cut -d'|' -f2)
            [ -n "$MSG" ] && echo -e "    ${YELLOW}⚠${NC}  $MSG"
        done
    fi

    # Extract top suggestions
    if [ -f "$LYNIS_REPORT" ] && [ "$LYNIS_SUGGESTIONS" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}Top Lynis Suggestions (first 10):${NC}"
        grep "^suggestion\[\]=" "$LYNIS_REPORT" 2>/dev/null | head -10 | while IFS= read -r line; do
            MSG=$(echo "$line" | cut -d'|' -f2)
            [ -n "$MSG" ] && echo -e "    ${CYAN}→${NC}  $MSG"
        done
        if [ "$LYNIS_SUGGESTIONS" -gt 10 ]; then
            echo -e "    ... and $((LYNIS_SUGGESTIONS - 10)) more suggestions"
        fi
    fi

    # Cleanup Lynis report files
    rm -f "$LYNIS_REPORT" "$LYNIS_DATA" 2>/dev/null

    # Uninstall Lynis if we installed it
    if [ "$LYNIS_INSTALLED_BY_US" = true ]; then
        echo ""
        info "Removing Lynis (installed temporarily for audit)..."
        apt-get remove --purge -y lynis >/dev/null 2>&1 || true
        apt-get autoremove --purge -y >/dev/null 2>&1 || true
        apt-get clean >/dev/null 2>&1 || true

        # Verify it's gone
        if command -v lynis &>/dev/null; then
            warn "Lynis removal incomplete"
        else
            info "Lynis removed — system is clean"
        fi

        # Verify no extra packages left behind
        PKGS_AFTER=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
        NEW_PKGS=$(comm -13 <(echo "$PKGS_BEFORE") <(echo "$PKGS_AFTER") 2>/dev/null || true)
        if [ -n "$NEW_PKGS" ]; then
            info "Cleaning leftover dependencies..."
            for pkg in $NEW_PKGS; do
                apt-get remove --purge -y "$pkg" >/dev/null 2>&1 || true
            done
            apt-get autoremove --purge -y >/dev/null 2>&1 || true
        fi
    fi
fi

echo ""
echo ""
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
SCORE_NUM=$((PASS_COUNT * 2 + WARN_COUNT))
SCORE_DEN=$((TOTAL * 2))
[ "$SCORE_DEN" -gt 0 ] && SCORE_PCT=$((SCORE_NUM * 100 / SCORE_DEN)) || SCORE_PCT=0

echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║           GOLDEN IMAGE VALIDATION REPORT                 ║${NC}"
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}${BOLD}${PASS_COUNT} PASS${NC}  |  ${YELLOW}${BOLD}${WARN_COUNT} WARN${NC}  |  ${RED}${BOLD}${FAIL_COUNT} FAIL${NC}"
echo -e "  Score: ${BOLD}${SCORE_PCT}%${NC} (${SCORE_NUM}/${SCORE_DEN})"
if [ "$LYNIS_SCORE" != "N/A" ] && [ -n "$LYNIS_SCORE" ]; then
    echo -e "  Lynis: ${BOLD}${LYNIS_SCORE}/100${NC}"
fi
echo ""
if [ "${#RECOMMENDATIONS[@]}" -gt 0 ]; then
    echo -e "  ${BOLD}TOP RECOMMENDATIONS:${NC}"
    idx=1
    for r in "${RECOMMENDATIONS[@]}"; do
        echo -e "  ${idx}. ${r}"; idx=$((idx + 1)); [ "$idx" -gt 10 ] && break
    done
    echo ""
fi
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -le 5 ]; then
    echo -e "  ${GREEN}${BOLD}VERDICT: Image is well-hardened and minimal.${NC}"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}VERDICT: Image is functional but has hardening gaps.${NC}"
else
    echo -e "  ${RED}${BOLD}VERDICT: Image has security issues that should be addressed.${NC}"
fi
echo ""
SECURITY_CHECKS

    # ── Section E: Extra Tools Verification (dynamic from extra-tools.yml) ──
    local TOOLS_YAML="/extra-tools/extra-tools.yml"
    if [ "${INSTALL_TOOLS_ENABLE:-false}" = "true" ] && [ -f "$TOOLS_YAML" ]; then
        cat >> "$OUTPUT" << 'TOOLS_HEADER'

header "SECTION E: EXTRA TOOLS VERIFICATION"

TOOLS_HEADER

        # APT packages check
        local apt_pkgs
        apt_pkgs=$(awk '/^apt_packages:/{f=1;next} f && /^[a-z_]+:/{exit} f && /^  - /' "$TOOLS_YAML" | sed 's/^  - //' | grep -v '^$')
        if [ -n "$apt_pkgs" ]; then
            echo 'echo ""; echo -e "  ${BOLD}E1. APT Packages${NC}"' >> "$OUTPUT"
            while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                cat >> "$OUTPUT" << APTEOF
if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    pass "$pkg installed"
else
    fail "$pkg NOT installed"
fi
APTEOF
            done <<< "$apt_pkgs"
        fi

        # Binary tools check
        local bin_count
        bin_count=$(awk '/^binary_tools:/{f=1;next} f && /^[a-z_]+:/{exit} f && /^  - name:/{c++} END{print c+0}' "$TOOLS_YAML")
        if [ "$bin_count" -gt 0 ]; then
            echo 'echo ""; echo -e "  ${BOLD}E2. Binary Tools${NC}"' >> "$OUTPUT"
            awk '/^binary_tools:/{f=1;next} f && /^[a-z_]+:/{exit} f' "$TOOLS_YAML" | while IFS= read -r line; do
                local name dest
                if echo "$line" | grep -q "name:"; then
                    name=$(echo "$line" | sed 's/.*name:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g")
                fi
                if echo "$line" | grep -q "dest:"; then
                    dest=$(echo "$line" | sed 's/.*dest:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g")
                    cat >> "$OUTPUT" << BINEOF
if [ -x "$dest" ]; then
    pass "$name present at $dest"
else
    fail "$name NOT found at $dest"
fi
BINEOF
                fi
            done
        fi

        # Services enabled check
        local services
        services=$(awk '/^services_enabled:/{f=1;next} f && /^[a-z_]+:/{exit} f && /^  - /' "$TOOLS_YAML" | sed 's/^  - //' | grep -v '^$')
        if [ -n "$services" ]; then
            echo 'echo ""; echo -e "  ${BOLD}E3. Services Enabled${NC}"' >> "$OUTPUT"
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                cat >> "$OUTPUT" << SVCEOF
if systemctl is-enabled "$svc" 2>/dev/null | grep -q "enabled"; then
    pass "$svc service enabled"
else
    warn "$svc service NOT enabled"
fi
SVCEOF
            done <<< "$services"
        fi

        # Packages held check
        local hold_pkgs
        hold_pkgs=$(awk '/^packages_hold:/{f=1;next} f && /^[a-z_]+:/{exit} f && /^  - /' "$TOOLS_YAML" | sed 's/^  - //' | grep -v '^$')
        if [ -n "$hold_pkgs" ]; then
            echo 'echo ""; echo -e "  ${BOLD}E4. Packages Held${NC}"' >> "$OUTPUT"
            while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                cat >> "$OUTPUT" << HOLDEOF
if apt-mark showhold 2>/dev/null | grep -q "^${pkg}\$"; then
    pass "$pkg is held"
else
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        warn "$pkg installed but NOT held"
        rec "Run: apt-mark hold $pkg"
    else
        info "$pkg not installed yet (hold applies after k8s setup)"
    fi
fi
HOLDEOF
            done <<< "$hold_pkgs"
        fi

        # Deb packages check
        local deb_names
        deb_names=$(awk '/^deb_packages:/{f=1;next} f && /^[a-z_]+:/{exit} f && /name:/' "$TOOLS_YAML" | sed 's/.*name:[[:space:]]*//' | sed 's/"//g' | grep -v '^$')
        if [ -n "$deb_names" ]; then
            echo 'echo ""; echo -e "  ${BOLD}E5. Custom Deb Packages${NC}"' >> "$OUTPUT"
            while IFS= read -r name; do
                [ -z "$name" ] && continue
                cat >> "$OUTPUT" << DEBEOF
# Check if $name tools are available
if command -v "$name" &>/dev/null; then
    pass "$name tools available"
else
    warn "$name tools not found in PATH (may need specific binary check)"
fi
DEBEOF
            done <<< "$deb_names"
        fi
    fi

    chmod +x "$OUTPUT"
}
