#!/usr/bin/env bash
# Upload golden image ISO to cloud storage
# Usage: upload-storage.sh <azure|s3>
set -euo pipefail

STORAGE_TYPE="${1:-}"
ISO_DIR="${ISO_DIR:-./ output}"

# Find ISO file
ISO_FILE=$(ls ${ISO_DIR}/*.iso 2>/dev/null | head -1)
if [ -z "$ISO_FILE" ]; then
    echo "::error::No ISO file found in ${ISO_DIR}"
    exit 1
fi

ISO_NAME=$(basename "$ISO_FILE")
ISO_SIZE=$(du -sh "$ISO_FILE" | awk '{print $1}')

# Also upload validation script if it exists
VALIDATE_FILE="${ISO_DIR}/validate-golden-image.sh"

case "$STORAGE_TYPE" in
    azure)
        if [ -z "${AZURE_CONNECTION_STRING:-}" ]; then
            echo "::error::AZURE_CONNECTION_STRING is not set"
            exit 1
        fi
        CONTAINER="${AZURE_CONTAINER:-golden-images}"

        echo "Uploading ${ISO_NAME} (${ISO_SIZE}) to Azure Blob: ${CONTAINER}/"

        az storage blob upload \
            --connection-string "${AZURE_CONNECTION_STRING}" \
            --container-name "${CONTAINER}" \
            --file "${ISO_FILE}" \
            --name "${ISO_NAME}" \
            --overwrite \
            --no-progress 2>&1 || {
            echo "::error::Azure upload failed"
            exit 1
        }

        echo "ISO uploaded: ${CONTAINER}/${ISO_NAME}"

        # Upload validation script
        if [ -f "$VALIDATE_FILE" ]; then
            az storage blob upload \
                --connection-string "${AZURE_CONNECTION_STRING}" \
                --container-name "${CONTAINER}" \
                --file "${VALIDATE_FILE}" \
                --name "validate-golden-image.sh" \
                --overwrite \
                --no-progress 2>&1 || true
            echo "Validation script uploaded: ${CONTAINER}/validate-golden-image.sh"
        fi
        ;;

    s3)
        if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
            echo "::error::AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set"
            exit 1
        fi
        BUCKET="${S3_BUCKET:-golden-images}"
        ENDPOINT_FLAG=""
        if [ -n "${S3_ENDPOINT:-}" ]; then
            ENDPOINT_FLAG="--endpoint-url ${S3_ENDPOINT}"
        fi

        echo "Uploading ${ISO_NAME} (${ISO_SIZE}) to s3://${BUCKET}/"

        aws s3 cp "${ISO_FILE}" "s3://${BUCKET}/${ISO_NAME}" ${ENDPOINT_FLAG} || {
            echo "::error::S3 upload failed"
            exit 1
        }

        echo "ISO uploaded: s3://${BUCKET}/${ISO_NAME}"

        # Upload validation script
        if [ -f "$VALIDATE_FILE" ]; then
            aws s3 cp "${VALIDATE_FILE}" "s3://${BUCKET}/validate-golden-image.sh" ${ENDPOINT_FLAG} || true
            echo "Validation script uploaded: s3://${BUCKET}/validate-golden-image.sh"
        fi
        ;;

    *)
        echo "::error::Unknown storage type: ${STORAGE_TYPE}. Use 'azure' or 's3'"
        exit 1
        ;;
esac

echo "Upload complete."
