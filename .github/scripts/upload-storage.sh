#!/usr/bin/env bash
# Upload golden image ISO to Azure Blob Storage only
# Usage: upload-storage.sh azure
set -euo pipefail

STORAGE_TYPE="${1:-}"
ISO_DIR="${ISO_DIR:-./output}"

# Validate storage type
if [ "$STORAGE_TYPE" != "azure" ]; then
    echo "::error::Only 'azure' storage type is supported"
    exit 1
fi

# Find ISO file
ISO_FILE=$(ls ${ISO_DIR}/*.iso 2>/dev/null | head -1)
if [ -z "$ISO_FILE" ]; then
    echo "::error::No ISO file found in ${ISO_DIR}"
    exit 1
fi

ISO_NAME=$(basename "$ISO_FILE")
ISO_SIZE=$(du -sh "$ISO_FILE" | awk '{print $1}')

# Azure upload
if [ -z "${AZURE_STORAGE_ACCOUNT:-}" ]; then
    echo "::error::AZURE_STORAGE_ACCOUNT is not set"
    exit 1
fi

CONTAINER="${AZURE_CONTAINER:-admin-golden-image-iso}"

echo "Uploading ${ISO_NAME} (${ISO_SIZE}) to Azure Blob: ${CONTAINER}/"

az storage blob upload \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --container-name "${CONTAINER}" \
    --file "${ISO_FILE}" \
    --name "${ISO_NAME}" \
    --overwrite \
    --no-progress 2>&1 || {
    echo "::error::Azure upload failed"
    exit 1
}

echo "ISO uploaded: ${CONTAINER}/${ISO_NAME}"


