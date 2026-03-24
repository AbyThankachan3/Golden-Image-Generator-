#!/usr/bin/env bash
# Generate GRUB PBKDF2 hash from plaintext password
# Used by GitHub Actions workflow — never run manually
set -euo pipefail

if [ -z "${GRUB_PASSWORD:-}" ]; then
    echo "::error::GRUB_PASSWORD environment variable is not set"
    exit 1
fi

# Mask password in GitHub Actions logs
echo "::add-mask::${GRUB_PASSWORD}"

echo "Generating GRUB PBKDF2 hash..."

HASH=$(echo -e "${GRUB_PASSWORD}\n${GRUB_PASSWORD}" | \
    docker run --rm -i ubuntu:22.04 bash -c \
    "apt-get update -qq >/dev/null 2>&1 && \
     apt-get install -y -qq grub-common >/dev/null 2>&1 && \
     grub-mkpasswd-pbkdf2 2>/dev/null" | \
    grep "^PBKDF2" | sed 's/.*is //')

if [ -z "$HASH" ]; then
    echo "::error::Failed to generate GRUB PBKDF2 hash"
    exit 1
fi

mkdir -p hardening/secrets
echo "$HASH" > hardening/secrets/grub-password.hash
echo "GRUB hash generated successfully"
