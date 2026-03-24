#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  CIS Config Generator
#  Reads cis-config.yml and generates all hardening config files
#  into a target directory. These generated files are then
#  copied into the squashfs by hardening.sh.
#
#  If cis-config.yml is missing, returns 1 (caller uses static files)
# ═══════════════════════════════════════════════════════════

# get_val <key_path> — extract value from cis-config.yml
# key_path format: "section.key" e.g. "ssh.MaxAuthTries"
get_val() {
    local section="${1%%.*}"
    local key="${1#*.}"
    awk -v sec="$section" -v k="$key" '
        /^[a-z_]+:/ { cs = $0; gsub(/:.*/, "", cs) }
        cs == sec && $0 ~ "^  " k ":" {
            v = $0
            gsub(/^[^:]+:[[:space:]]*/, "", v)
            gsub(/^"/, "", v); gsub(/"$/, "", v)
            gsub(/^'\''/, "", v); gsub(/'\''$/, "", v)
            gsub(/[[:space:]]*#.*$/, "", v)
            print v; exit
        }
    ' "$CIS_YAML" 2>/dev/null
}

# get_list <section> — returns newline-separated list items (- item)
get_list() {
    local section="$1"
    awk -v sec="$section" '
        /^[a-z_]+:/ { cs = $0; gsub(/:.*/, "", cs) }
        cs == sec && /^  - / {
            v = $0; gsub(/^  - /, "", v); gsub(/[[:space:]]*$/, "", v)
            print v
        }
    ' "$CIS_YAML" 2>/dev/null
}

# get_inline_list <section> — returns items from inline YAML array [a, b, c]
get_inline_list() {
    local section="$1"
    awk -v sec="$section" '
        /^[a-z_]+:/ && $0 ~ sec ":" && /\[/ {
            v = $0; gsub(/^[^[]*\[/, "", v); gsub(/\].*$/, "", v)
            gsub(/,/, "\n", v); print v
        }
    ' "$CIS_YAML" 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | grep -v '^$'
}

# ══════════════════════════════════════════════════════════
#  Main: generate_configs_from_yaml <yaml_path> <output_dir>
# ══════════════════════════════════════════════════════════
generate_configs_from_yaml() {
    CIS_YAML="$1"
    local OUT="$2"

    if [ ! -f "$CIS_YAML" ]; then
        return 1
    fi

    mkdir -p "$OUT"

    # ── SSH config ────────────────────────────────────────
    {
        echo "# SSH Hardening — generated from cis-config.yml"
        echo ""

        # Read crypto settings (MACs, Ciphers, KexAlgorithms)
        local macs ciphers kex
        macs=$(get_val "ssh.MACs")
        ciphers=$(get_val "ssh.Ciphers")
        kex=$(get_val "ssh.KexAlgorithms")
        [ -n "$macs" ] && echo "MACs $macs"
        [ -n "$ciphers" ] && echo "Ciphers $ciphers"
        [ -n "$kex" ] && echo "KexAlgorithms $kex"
        echo ""

        # Read all key-value SSH settings
        local ssh_keys="PermitRootLogin PasswordAuthentication PermitEmptyPasswords X11Forwarding LoginGraceTime MaxAuthTries MaxSessions AllowTcpForwarding AllowAgentForwarding Compression TCPKeepAlive ClientAliveCountMax ClientAliveInterval LogLevel Banner"
        for k in $ssh_keys; do
            local v
            v=$(get_val "ssh.$k")
            [ -n "$v" ] && echo "$k $v"
        done
    } > "$OUT/99-hardening-ssh.conf"

    # ── Sysctl config ─────────────────────────────────────
    {
        echo "# Kernel & Network Hardening — generated from cis-config.yml"
        echo ""

        # Network values
        local ar sr sar ts lm rf
        ar=$(get_val "network.accept_redirects")
        sr=$(get_val "network.send_redirects")
        sar=$(get_val "network.accept_source_route")
        ts=$(get_val "network.tcp_syncookies")
        lm=$(get_val "network.log_martians")
        rf=$(get_val "network.rp_filter")

        [ -n "$ar" ] && {
            echo "net.ipv4.conf.all.accept_redirects = $ar"
            echo "net.ipv4.conf.default.accept_redirects = $ar"
            echo "net.ipv4.conf.all.secure_redirects = $ar"
            echo "net.ipv4.conf.default.secure_redirects = $ar"
            echo "net.ipv6.conf.all.accept_redirects = $ar"
            echo "net.ipv6.conf.default.accept_redirects = $ar"
        }
        [ -n "$sr" ] && {
            echo "net.ipv4.conf.all.send_redirects = $sr"
            echo "net.ipv4.conf.default.send_redirects = $sr"
        }
        [ -n "$sar" ] && {
            echo "net.ipv4.conf.all.accept_source_route = $sar"
            echo "net.ipv4.conf.default.accept_source_route = $sar"
            echo "net.ipv6.conf.all.accept_source_route = $sar"
            echo "net.ipv6.conf.default.accept_source_route = $sar"
        }
        [ -n "$ts" ] && echo "net.ipv4.tcp_syncookies = $ts"
        [ -n "$lm" ] && {
            echo "net.ipv4.conf.all.log_martians = $lm"
            echo "net.ipv4.conf.default.log_martians = $lm"
        }
        echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"
        echo "net.ipv4.icmp_ignore_bogus_error_responses = 1"
        [ -n "$rf" ] && {
            echo "net.ipv4.conf.all.rp_filter = $rf"
            echo "net.ipv4.conf.default.rp_filter = $rf"
        }

        echo ""

        # Kernel values
        local keys="dmesg_restrict randomize_va_space kptr_restrict ldisc_autoload perf_event_paranoid sysrq unprivileged_bpf_disabled bpf_jit_harden"
        local sysctl_map="dmesg_restrict:kernel.dmesg_restrict randomize_va_space:kernel.randomize_va_space kptr_restrict:kernel.kptr_restrict ldisc_autoload:dev.tty.ldisc_autoload perf_event_paranoid:kernel.perf_event_paranoid sysrq:kernel.sysrq unprivileged_bpf_disabled:kernel.unprivileged_bpf_disabled bpf_jit_harden:net.core.bpf_jit_harden"

        for entry in $sysctl_map; do
            local yaml_key="${entry%%:*}"
            local sysctl_key="${entry#*:}"
            local v
            v=$(get_val "kernel.$yaml_key")
            [ -n "$v" ] && echo "$sysctl_key = $v"
        done

        # Fixed values (always set, not configurable)
        echo "fs.protected_hardlinks = 1"
        echo "fs.protected_symlinks = 1"
        echo "fs.protected_fifos = 2"
        echo "fs.suid_dumpable = 0"
        echo ""
        echo "# kernel.modules_disabled = 1 intentionally NOT set (breaks k8s + module loading)"
    } > "$OUT/99-hardening-sysctl.conf"

    # ── Password quality ──────────────────────────────────
    {
        echo "# Password Quality — generated from cis-config.yml"
        local pw_keys="minlen dcredit ucredit ocredit lcredit maxrepeat maxsequence minclass usercheck dictcheck"
        for k in $pw_keys; do
            local v
            v=$(get_val "password_policy.$k")
            [ -n "$v" ] && echo "$k = $v"
        done
    } > "$OUT/pwquality.conf"

    # ── Core dump ─────────────────────────────────────────
    {
        echo "# Core dump disabled — generated from cis-config.yml"
        echo "* hard core 0"
    } > "$OUT/99-coredump.conf"

    # ── Modprobe blacklist ────────────────────────────────
    {
        echo "# CIS Module Blacklist — generated from cis-config.yml"
        echo ""
        # Try block list format first, then inline format
        local modules
        modules=$(get_list "modules_disabled")
        if [ -z "$modules" ]; then
            modules=$(get_inline_list "modules_disabled")
        fi
        if [ -n "$modules" ]; then
            echo "$modules" | while IFS= read -r mod; do
                [ -z "$mod" ] && continue
                echo "install $mod /bin/true"
                echo "blacklist $mod"
            done
        fi
    } > "$OUT/CIS.conf"

    # ── Login banners ─────────────────────────────────────
    # Read from YAML or use default
    local banner_text
    banner_text=$(get_val "banners.text")
    if [ -z "$banner_text" ]; then
        banner_text='*******************************************************************************
*                           AUTHORIZED ACCESS ONLY                            *
*                                                                             *
* This system is for authorized use only. All activity is monitored and       *
* recorded. Unauthorized access or use is prohibited and may result in        *
* disciplinary action, civil, or criminal penalties.                          *
*                                                                             *
* By accessing this system, you consent to monitoring and recording.          *
*******************************************************************************'
    fi
    echo "$banner_text" > "$OUT/issue.txt"
    echo "$banner_text" > "$OUT/issue.net.txt"

    # ── Audit rules ───────────────────────────────────────
    # Audit rules are complex — always copy from static file if exists
    # (too complex for YAML key-value format)
    if [ -f "${HARDENING_DIR:-/hardening}/configs/50-cis.rules" ]; then
        cp "${HARDENING_DIR:-/hardening}/configs/50-cis.rules" "$OUT/50-cis.rules"
    fi

    # ── Sudoers ───────────────────────────────────────────
    {
        echo "# Sudoers hardening — generated from cis-config.yml"
        echo "Defaults use_pty"
        echo "Defaults timestamp_timeout=5"
        echo 'Defaults logfile="/var/log/sudo.log"'
    } > "$OUT/99-cis-sudoers"

    # ── Journald ──────────────────────────────────────────
    {
        echo "[Journal]"
        echo "Storage=persistent"
        echo "Compress=yes"
        echo "ForwardToSyslog=yes"
    } > "$OUT/99-cis-journald.conf"

    return 0
}
