# Golden Image Generator

A fully automated pipeline for building **hardened, minimal Ubuntu Server ISOs** with CIS Level 1 benchmarking, automated package analysis, and GitHub Actions integration.

---

## Overview

Golden Image Generator takes a stock Ubuntu Server ISO and produces a hardened, minimal ISO suitable for production bare-metal or VM deployments. It automates the entire process: downloading the base ISO, analyzing packages for safe removal, applying CIS Level 1 security controls, and building a bootable ISO — all through a single command or GitHub Actions workflow.

The resulting ISO boots into the standard Ubuntu installer (subiquity), but the installed system is pre-hardened with security controls baked directly into the filesystem.

---

## Features

- **Version-agnostic** — Works with Ubuntu 22.04, 24.04, 25.x, and future releases
- **CIS Level 1 benchmarking** — SSH hardening, kernel/sysctl tuning, password policies, audit rules, service masking, module blacklisting
- **Automated package analysis** — Categorizes every package as SAFE, RISKY, or CRITICAL using dependency chain analysis and dry-run removal testing
- **GitHub Actions workflow** — Three modes (analyze-only, build-only, analyze-and-build) with review/approve flow
- **Lynis-validated** — Built-in validation script with Lynis integration.
- **GRUB password protection** — PBKDF2-hashed boot password with unrestricted normal boot
- **Single source of truth** — All hardening values in one `cis-config.yml` file, editable by anyone
- **Docker-based builds** — Runs on any architecture via Docker, no root access needed on host
- **Self-hosted runner support** — Persistent ISO cache, local output, no artifact size limits
- **Clean dpkg database** — Stale package entries are purged during build.

---

## Architecture

### Build Pipeline

```
                    ┌─────────────┐
                    │  User Input │
                    │  ISO URL    │
                    │  cis-config │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ ANALYZE  │ │ ANALYZE  │ │  BUILD   │
        │  ONLY    │ │ & BUILD  │ │  ONLY    │
        └────┬─────┘ └────┬─────┘ └────┬─────┘
             │            │            │
             ▼            ▼            │
        ┌──────────────────────────┐   │
        │     PHASE 1: RESOLVE     │   │
        │  Download ISO, detect    │   │
        │  version                 │   │
        └────────────┬─────────────┘   │
                     │                 │
                     ▼                 │
        ┌──────────────────────────┐   │
        │  PHASE 2: DETECT+ANALYZE │   │
        │  Extract squashfs, list  │   │
        │  packages, categorize    │   │
        │  SAFE / RISKY / CRITICAL │   │
        └────────────┬─────────────┘   │
                     │                 │
                     ▼                 │
        ┌──────────────────────────┐   │
        │    PHASE 3: APPROVE      │   │
        │  Display results, user   │   │
        │  reviews and approves    │   │
        └──────┬─────────┬─────────┘   │
               │         │             │
          STOP ●         │             │
       (analyze-only)    │             │
                         ▼             ▼
              ┌──────────────────────────────┐
              │       PHASE 4: BUILD         │
              │  Remove packages, apply CIS  │
              │  hardening, rebuild squashfs,│
              │  generate bootable ISO       │
              └──────────────────────────────┘
                         │
                         ▼
                    ┌──────────┐
                    │  OUTPUT  │
                    │  .iso    │
                    └──────────┘
```

### Host / Docker Split

```
┌─────────────────────────────────┐
│         HOST                    │
│                                 │
│  golden-image-builder.sh        │
│  ├── Download ISO → cache/      │
│  ├── Launch Docker container    │
│  └── Copy output ISO            │
│                                 │
│  ┌───────────────────────────┐  │
│  │     DOCKER CONTAINER      │  │
│  │     (ubuntu:22.04/24.04)  │  │
│  │                           │  │
│  │  ├── Extract ISO          │  │
│  │  ├── Extract squashfs     │  │
│  │  ├── Remove packages      │  │
│  │  ├── Apply hardening      │  │
│  │  ├── Rebuild squashfs     │  │
│  │  └── Build ISO (xorriso)  │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

---

## Project Structure

```
GoldenImageProject/
├── golden-image-builder.sh          # Main entry point
├── cis-config.yml                   # CIS hardening values (single source of truth)
├── approved-lists/                  # User-approved package removal lists (per version)
│   ├── approved-packages-22.04.5.txt
│   ├── approved-packages-24.04.4.txt
│   └── approved-packages-25.10.txt
│
├── lib/                             # Core library modules
│   ├── config.sh                    # Version detection, ISO download, overrides
│   ├── iso-detect.sh                # ISO structure detection (squashfs layers, EFI)
│   ├── package-analyzer.sh          # Package categorization (SAFE/RISKY/CRITICAL)
│   ├── chroot-ops.sh                # Chroot setup, package removal, safety gates
│   ├── squashfs-ops.sh              # SquashFS extract/rebuild operations
│   ├── iso-builder.sh               # Final ISO assembly (xorriso, EFI, MBR)
│   ├── hardening.sh                 # All 3 hardening layers
│   ├── cis-config-generator.sh      # Generates config files from cis-config.yml
│   ├── docker-entrypoint.sh         # Docker container entry point
│   ├── docker-entrypoint-analyze.sh # Analysis-only Docker entry point
│   └── validation-generator.sh      # Auto-generates validation script
│
├── hardening/                       # Static hardening config files (fallback)
│   ├── configs/
│   │   ├── 99-hardening-ssh.conf    # SSH server hardening
│   │   ├── 99-hardening-sysctl.conf # Kernel/network sysctl values
│   │   ├── 99-coredump.conf         # Core dump disable
│   │   ├── CIS.conf                 # Kernel module blacklist
│   │   ├── 50-cis.rules             # Audit rules
│   │   ├── issue.txt                # Login banner (console)
│   │   └── issue.net.txt            # Login banner (SSH)
│   └── secrets/
│       └── grub-password.hash       # GRUB PBKDF2 hash (gitignored)
│
├── .github/
│   ├── workflows/
│   │   └── build-golden-image.yml   # GitHub Actions workflow
│   └── scripts/
│       └── generate-grub-hash.sh    # GRUB hash generation for CI
│
└── output/                          # Build output (gitignored)
    ├── golden-ubuntu-minimal-*.iso  # Built ISO
    ├── validate-golden-image.sh     # Auto-generated validation script
    ├── safe-packages-*.txt          # Analysis results
    ├── critical-packages-*.txt
    ├── risky-packages-*.txt
    └── package-report-*.txt
```

---

## Quick Start

### Prerequisites

- **Docker Desktop**  with at least 10GB free disk space
- **Git** and a GitHub account
- **Self-hosted GitHub Actions runner** (for CI/CD workflow)

### 1. Clone the Repository

```bash
git clone https://github.com/AbyThankachan3/Golden-Image-Generator-.git
cd Golden-Image-Generator-
```

### 2. Set Up GRUB Password

**For GitHub Actions:**
1. Go to repo **Settings** → **Secrets and variables** → **Actions**
2. Add repository secret: `GRUB_PASSWORD` = your chosen password
3. The workflow automatically generates the PBKDF2 hash during build
4. To change the password, update the repository secret

**For local builds:**
No manual setup needed. On first run with `--harden-all`, the script automatically:
1. Detects that `hardening/secrets/grub-password.hash` is missing or empty
2. Prompts you to enter and confirm a GRUB password
3. Generates the PBKDF2 hash via Docker
4. Saves it to `hardening/secrets/grub-password.hash` (gitignored)
5. Reuses the saved hash on all subsequent builds

To change the GRUB password, simply empty the hash file and re-run build script.


### 3. Build Your First ISO

**Via GitHub Actions:**
1. Go to **Actions** → **Build Golden Image ISO** → **Run workflow**
2. Enter ISO URL: `https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso`
3. Select mode: `analyze-and-build`
4. Check **Enable CIS Level 1 hardening**
5. Click **Run workflow**

**Via Command Line:**
```bash
./golden-image-builder.sh --auto-approve --harden-all \
  --url https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso
```

---

## Usage

### GitHub Actions Workflow

The workflow provides three modes:

| Mode | What it does | When to use |
|------|-------------|-------------|
| `analyze-only` | Downloads ISO, analyzes packages, displays results in summary | First run — review what will be removed |
| `build-only` | Builds ISO using existing `approved-packages-{VERSION}.txt` | After reviewing and approving the package list |
| `analyze-and-build` | Analyzes then builds in one run | Quick builds with auto-approved safe packages |

#### Workflow Inputs

| Input | Required | Description |
|-------|----------|-------------|
| ISO URL | Yes | Full download URL for the Ubuntu ISO |
| Mode | Yes | `analyze-only`, `build-only`, or `analyze-and-build` |
| Enable hardening | Yes | Toggle CIS Level 1 hardening on/off |
| Output filename | No | Custom ISO filename (auto-generated if blank) |
| Output path | No | Local path to save ISO (default: `~/GoldenImages/`) |
| Storage | Yes | `local` (default), `azure-blob`, or `s3` |

#### Typical Workflow

```
1. Run analyze-only
   └── Review safe-packages-24.04.4.txt in the summary
   └── Review CIS hardening values in the summary

2. (Optional) Edit the package list
   └── Download safe-packages from artifacts
   └── Remove packages you want to keep
   └── Push as approved-packages-24.04.4.txt to repo root

3. Run build-only (or analyze-and-build)
   └── ISO built at ~/GoldenImages/golden-ubuntu-minimal-24.04.4.iso
   └── Validation script at ~/GoldenImages/validate-golden-image.sh
```

### Command Line Usage

```bash
# Analyze only — see what packages can be removed
./golden-image-builder.sh --analyze-only --url https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso

# Build with auto-approved safe packages + full hardening
./golden-image-builder.sh --auto-approve --harden-all --url https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso

# Build with custom package list
./golden-image-builder.sh --packages-file approved-packages-24.04.4.txt --harden-all --url https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso

# Build with custom output directory and cache
./golden-image-builder.sh --auto-approve --harden-all \
  --output-dir ./output \
  --cache-dir ~/GoldenImages/cache \
  --url https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso
```

#### CLI Options

| Option | Description |
|--------|-------------|
| `--url <url>` | ISO download URL (version auto-detected from filename) |
| `--auto-approve` | Skip manual approval, use auto-detected safe packages |
| `--harden-all` | Apply all 3 hardening layers |
| `--analyze-only` | Run analysis only, don't build |
| `--packages-file <file>` | Use custom package removal list |
| `--output-dir <dir>` | Output directory (default: `./output`) |
| `--cache-dir <dir>` | ISO cache directory (default: `./cache`) |

---

## Customization

### CIS Hardening Values (`cis-config.yml`)

This file is the **single source of truth** for all hardening. Edit values here and the build generates all config files from it.

<details>
<summary><b>SSH Hardening</b></summary>

```yaml
ssh:
  MACs: "umac-128-etm@openssh.com,hmac-sha2-256-etm@openssh.com,..."
  Ciphers: "aes128-ctr,aes192-ctr,aes256-ctr,..."
  PermitRootLogin: "no"
  PasswordAuthentication: "no"
  MaxAuthTries: 3
  MaxSessions: 2
  LogLevel: "VERBOSE"
  # ... and more
```
</details>

<details>
<summary><b>Password Policy</b></summary>

```yaml
pw_policy:
  PASS_MAX_DAYS: 365
  PASS_MIN_DAYS: 1
  PASS_WARN_AGE: 7
  minlen: 14
  dcredit: -1        # require 1 digit
  ucredit: -1        # require 1 uppercase
  ocredit: -1        # require 1 special char
  lcredit: -1        # require 1 lowercase
  UMASK: "027"
```
</details>

<details>
<summary><b>Kernel Hardening</b></summary>

```yaml
kernel:
  dmesg_restrict: 1
  randomize_va_space: 2      # ASLR full
  kptr_restrict: 2
  sysrq: 0                  # disable magic SysRq
  unprivileged_bpf_disabled: 1
  perf_event_paranoid: 3
```
</details>

<details>
<summary><b>Network Hardening</b></summary>

```yaml
network:
  accept_redirects: 0
  send_redirects: 0
  tcp_syncookies: 1
  log_martians: 1
  rp_filter: 1
  ip_forward: 0
```
</details>

<details>
<summary><b>Services Masked</b></summary>

```yaml
services_masked:
  - avahi-daemon
  - cups
  - isc-dhcp-server
  - nfs-server
  - rpcbind
  - vsftpd
  - apache2
  - snmpd
  - squid
```
</details>

<details>
<summary><b>Kernel Modules Disabled</b></summary>

```yaml
modules_disabled:
  - cramfs, freevxfs, jffs2, hfs, hfsplus, udf    # Filesystems
  - dccp, sctp, rds, tipc                           # Network protocols
  - usb-storage, firewire-ohci, thunderbolt         # USB/FireWire
```
</details>

### Package Removal Lists

After running `analyze-only`, review the generated `safe-packages-{VERSION}.txt` and create your approved list:

```bash
# Copy the safe list to approved-lists folder
cp safe-packages-24.04.4.txt approved-lists/approved-packages-24.04.4.txt

# Edit — remove any packages you want to KEEP
vim approved-lists/approved-packages-24.04.4.txt

# Push to repo for build-only mode
git add approved-lists/approved-packages-24.04.4.txt
git commit -m "Approved package list for 24.04.4"
git push
```

### Protected Packages

The analyzer automatically protects these patterns from removal:

| Pattern | Protects |
|---------|----------|
| `systemd` | `systemd-resolved`, `systemd-timesyncd`, etc. |
| `linux-` | `linux-generic`, `linux-image-*`, `linux-tools-*`, etc. |
| `sudo` | `sudo`, `sudo-rs` |
| `perl` | `perl`, `perl-modules-*`, `libperl*` |
| `curl` | `curl`, `libcurl*` |
| `openssh` | `openssh-server`, `openssh-client` |
| `grub-` | `grub-common`, `grub-efi-*` |
| `coreutils` | `coreutils`, `coreutils-from-uutils`, `rust-coreutils` |
| `busybox` | `busybox-static` |
| `zstd` | `zstd`, `libzstd*` |
| `needrestart` | `needrestart` |

---

## Hardening Details

### Layer 1: Security Packages

Installed into the squashfs for immediate availability:

| Package | Purpose |
|---------|---------|
| `auditd` | System audit logging |
| `fail2ban` | Brute-force protection |
| `rkhunter` | Rootkit scanner |
| `aide` | File integrity monitoring |
| `libpam-pwquality` | Password strength enforcement |
| `libpam-tmpdir` | Per-session temp directories |
| `needrestart` | Restart notifications after upgrades |
| `cryptsetup` | LUKS disk encryption support |
| `clevis-luks` / `clevis-tpm2` | Automated LUKS unlocking |

### Layer 2: Configuration Hardening

Config files written directly into the squashfs:

| Config File | What it does |
|-------------|-------------|
| `sshd_config.d/99-hardening-ssh.conf` | Restricts ciphers, MACs, disables root login, TCP forwarding |
| `sysctl.d/99-hardening-sysctl.conf` | ASLR, dmesg restrict, ICMP hardening, SYN cookies |
| `security/limits.d/99-coredump.conf` | Disables core dumps |
| `modprobe.d/CIS.conf` | Blacklists 13 unnecessary kernel modules |
| `audit/rules.d/50-cis.rules` | 33 audit rules (logins, file changes, permissions) |
| `issue` / `issue.net` | Legal warning banners |
| `security/pwquality.conf` | Password complexity requirements |
| `sudoers.d/99-cis-hardening` | use_pty, timestamp_timeout, logging |
| `systemd/journald.conf.d/99-cis.conf` | Persistent logs, compression |
| `cron.allow` / `at.allow` | Root-only cron/at access |
| `grub.d/40_custom` | GRUB password (PBKDF2) |
| `grub.d/09_unrestricted_patch` | Normal boot without password, edit requires password |

### Layer 3: CIS Level 1 Controls (chroot)

Applied directly in the squashfs chroot:

| Control | Details |
|---------|---------|
| Password aging | `PASS_MAX_DAYS=365`, `PASS_MIN_DAYS=1`, `PASS_WARN_AGE=7` |
| Session timeout | `TMOUT=900` (15 min, readonly) |
| Umask | `027` in `/etc/profile`, `/etc/bash.bashrc`, `/etc/login.defs` |
| File permissions | `/etc/shadow` 640, `/etc/gshadow` 640, SSH keys 600 |
| Cron restriction | `/etc/crontab` 700, `cron.d/` 700, `cron.daily/` 700 |
| su restriction | `/etc/pam.d/su` — only `sudo`/`wheel` group |
| Service masking | 13 unnecessary services disabled |
| Network sysctl | IPv6 redirects, source routing, martian logging |

---

## Validation

Every build generates a `validate-golden-image.sh` script tailored to the specific build. It checks:

### Section A: Minimality
- Total package count
- Removed packages verification (confirms all listed packages are absent)

### Section B: Security
- SSH hardening (PermitRootLogin, PasswordAuth, MaxAuthTries, etc.)
- Firewall status
- Root account locked
- Kernel hardening (ASLR, SYN cookies, dmesg restrict, etc.)

### Section C: Lynis Audit
- Temporarily installs Lynis, runs 200+ security checks
- Extracts hardening score, warnings, and suggestions
- Removes Lynis completely after audit (zero trace)

### Section D: Hardening Verification
- SSH config file present
- Sysctl config present and active
- GRUB password configured
- CIS filesystem module blacklist present
- Audit rules present and active

### Running Validation

```bash
# Copy to the installed VM
scp validate-golden-image.sh user@vm-ip:~/

# Run on the VM
ssh user@vm-ip 'sudo bash ~/validate-golden-image.sh'
```

### Expected Scores

| Metric | Target | Achieved |
|--------|--------|----------|
| Validation score | 90%+ | 90% (20 PASS, 5 WARN, 0 FAIL) |
| Lynis hardening index | 80+ | 84/100 |
| Package count | Under 350 | ~280-330 depending on version |

---

## Troubleshooting

<details>
<summary><b>DNS not working during installation (mirror test fails)</b></summary>

**Symptom:** `Temporary failure resolving 'archive.ubuntu.com'` during ISO installation.

**Cause:** `/etc/resolv.conf` symlink was not properly restored in the squashfs.

**Fix:** The builder now restores the symlink in `teardown_chroot()`. If you still see this, switch to installer shell (Alt+F2) and run:
```bash
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```
Then switch back (Alt+F1) and retry.
</details>

<details>
<summary><b>GRUB password loop (can't boot normally)</b></summary>

**Symptom:** GRUB asks for username/password just to boot (not just to edit).

**Cause:** The `--unrestricted` flag wasn't applied to GRUB menu entries.

**Fix:** The builder now uses `09_unrestricted_patch` which auto-patches `10_linux` during every `update-grub`. Normal boot should work without password; only pressing `e` to edit requires credentials.
</details>

<details>
<summary><b>Docker disk space error during build</b></summary>

**Symptom:** `xorriso: FAILURE: Image size exceeds free space on media`

**Cause:** Docker's internal filesystem is full.

**Fix:**
```bash
docker system prune -a --volumes
```
If persistent, increase Docker Desktop disk: **Settings** → **Resources** → **Disk image size** → 20GB+.
</details>

<details>
<summary><b>dpkg warnings about missing files list</b></summary>

**Symptom:** `dpkg: warning: files list file for package 'xxx' missing` during `apt-get update` on installed system.

**Cause:** Stale dpkg entries from removed packages.

**Fix:** The builder now purges stale dpkg entries after package removal. For existing installs:
```bash
sudo dpkg --purge $(dpkg --get-selections | grep "deinstall" | awk '{print $1}') 2>/dev/null
```
</details>

<details>
<summary><b>SSH connection fails with "Corrupted MAC"</b></summary>

**Symptom:** `Corrupted MAC on input. message authentication code incorrect`

**Cause:** Client SSH doesn't support the restricted MACs in our hardening config.

**Fix:** Update your SSH client, or edit `cis-config.yml` to add your client's supported MAC:
```yaml
ssh:
  MACs: "umac-128-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
```
</details>

---

## File Reference

| File | Description |
|------|-------------|
| `golden-image-builder.sh` | Main entry point — orchestrates download, Docker launch, and output |
| `cis-config.yml` | Single source of truth for all CIS hardening values |
| `lib/config.sh` | Version resolution, ISO download, override loading |
| `lib/iso-detect.sh` | Detects squashfs layers, EFI partition, ISO structure |
| `lib/package-analyzer.sh` | Analyzes packages: SAFE/RISKY/CRITICAL categorization |
| `lib/chroot-ops.sh` | Chroot setup/teardown, package removal with safety gates |
| `lib/squashfs-ops.sh` | Extract and rebuild squashfs filesystem |
| `lib/iso-builder.sh` | Assembles final ISO with xorriso (BIOS + UEFI boot) |
| `lib/hardening.sh` | Applies all 3 hardening layers to squashfs |
| `lib/cis-config-generator.sh` | Reads `cis-config.yml` and generates config files |
| `lib/docker-entrypoint.sh` | Docker container entry point for build phase |
| `lib/docker-entrypoint-analyze.sh` | Docker container entry point for analyze phase |
| `lib/validation-generator.sh` | Generates the validation script with embedded package lists |
| `hardening/configs/*.conf` | Static hardening config files (fallback if cis-config.yml missing) |
| `hardening/secrets/grub-password.hash` | GRUB password hash (gitignored) |
| `.github/workflows/build-golden-image.yml` | GitHub Actions workflow definition |
| `.github/scripts/generate-grub-hash.sh` | Generates GRUB PBKDF2 hash in CI |

---

## Important Note

All package removal, hardening, and CIS benchmarking modifications described above are applied exclusively to the **`ubuntu-server-minimal`** squashfs layer within the ISO. Other squashfs layers (such as `ubuntu-server`, installer components, and snap packages) remain untouched. This ensures the subiquity installer functions correctly while the installed system receives all minimality and security hardening.

---

## Documentation

Find the detailed documentation at: [GoldenImage](https://www.notion.so/Golden-Image-Admin-Server-32f2f2e2f62a8082a5e6ed4bc30919e4?source=copy_link)

---

## License

This project is for internal use only.
