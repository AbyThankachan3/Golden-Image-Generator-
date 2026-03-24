#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Version resolution & configuration
#  Given a version string, derives ISO URL, Docker base, etc.
# ═══════════════════════════════════════════════════════════

# resolve_version <version> [--url <url>]
# Sets global variables: ISO_NAME, ISO_URL, DOCKER_BASE, MAJOR_MINOR, FULL_VERSION
resolve_version() {
    local version="$1"
    local custom_url="${2:-}"

    # If custom URL provided, derive version from filename
    if [ -n "$custom_url" ]; then
        ISO_URL="$custom_url"
        ISO_NAME=$(basename "$custom_url")
        # Extract version from filename: ubuntu-24.04.1-live-server-amd64.iso
        FULL_VERSION=$(echo "$ISO_NAME" | sed -n 's/ubuntu-\([0-9.]*\)-live-server.*/\1/p')
        if [ -z "$FULL_VERSION" ]; then
            die "Cannot parse version from URL: $custom_url"
        fi
        MAJOR_MINOR="${FULL_VERSION%.*}"
        # If version is just major.minor (e.g., 22.04), use as-is
        if [[ "$FULL_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
            MAJOR_MINOR="$FULL_VERSION"
        fi
        DOCKER_BASE="ubuntu:${MAJOR_MINOR}"
        return 0
    fi

    # Validate version format
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        die "Invalid version format: '$version' (expected: 22.04 or 22.04.5)"
    fi

    # Parse major.minor
    if [[ "$version" =~ ^([0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
        MAJOR_MINOR="${BASH_REMATCH[1]}"
        FULL_VERSION="$version"
    else
        # Just major.minor given, use as-is (no point release)
        MAJOR_MINOR="$version"
        FULL_VERSION="$version"
    fi

    # Construct ISO name and URL
    ISO_NAME="ubuntu-${FULL_VERSION}-live-server-amd64.iso"
    DOCKER_BASE="ubuntu:${MAJOR_MINOR}"

    # Try releases.ubuntu.com first, fallback to cdimage.ubuntu.com
    local url_primary="https://releases.ubuntu.com/${FULL_VERSION}/${ISO_NAME}"
    local url_fallback="https://cdimage.ubuntu.com/ubuntu-server/releases/${FULL_VERSION}/release/${ISO_NAME}"

    ISO_URL="$url_primary"
    ISO_URL_FALLBACK="$url_fallback"
}

# download_iso <cache_dir>
# Downloads ISO to cache directory if not present
download_iso() {
    local cache_dir="$1"
    local iso_path="${cache_dir}/${ISO_NAME}"

    if [ -f "$iso_path" ]; then
        log "ISO already cached — ${ISO_NAME}"
        return 0
    fi

    info "Downloading ${ISO_NAME}..."
    echo -e "  URL: ${ISO_URL}"
    mkdir -p "$cache_dir"

    # Try primary URL
    if curl -fSL --progress-bar --connect-timeout 15 --retry 3 \
        -o "${iso_path}.tmp" "$ISO_URL"; then
        mv "${iso_path}.tmp" "$iso_path"
        log "Downloaded from: ${ISO_URL}"
        return 0
    fi

    # Try fallback URL (only if set — not set when --url is used)
    if [ -n "${ISO_URL_FALLBACK:-}" ]; then
        warn "Primary URL failed, trying cdimage.ubuntu.com..."
        echo -e "  URL: ${ISO_URL_FALLBACK}"
        if curl -fSL --progress-bar --connect-timeout 15 --retry 3 \
            -o "${iso_path}.tmp" "$ISO_URL_FALLBACK"; then
            mv "${iso_path}.tmp" "$iso_path"
            ISO_URL="$ISO_URL_FALLBACK"
            log "Downloaded from: ${ISO_URL_FALLBACK}"
            return 0
        fi
    fi

    rm -f "${iso_path}.tmp"
    die "Failed to download ISO from both URLs:\n  Primary:  ${ISO_URL}\n  Fallback: ${ISO_URL_FALLBACK:-none}"
}

# load_overrides <configs_dir>
# Sources version-specific override file if it exists
load_overrides() {
    local configs_dir="$1"
    local override_file="${configs_dir}/overrides-${MAJOR_MINOR}.sh"

    if [ -f "$override_file" ]; then
        info "Loading version overrides: $(basename "$override_file")"
        source "$override_file"
    fi
}
