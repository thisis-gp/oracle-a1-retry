#!/usr/bin/env bash
# Retry-creates backend-vm-a1 (VM.Standard.A1.Flex, 2 OCPU / 12GB) in ap-hyderabad-1
# until Oracle has free Ampere capacity. Stops automatically on success.
#
# Prereqs:
#   1. Install OCI CLI globally:
#        curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh | bash -s -- --accept-all-defaults
#      (or: pip install --user oci-cli   /   brew install oci-cli on macOS)
#   2. Put the provided oci_api_key.pem at ~/.oci/oci_api_key.pem (chmod 600)
#   3. Put the provided oci_config at ~/.oci/config
#   4. Put cloud-init.yaml next to this script (same folder)
#
# Usage:  bash retry_create_a1.sh
set -uo pipefail

COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaao3mc7np5v3hzyqxzaewfmglopndkmchuko6gphhdevqv25es7dma"
DISPLAY_NAME="backend-vm-a1"
VCN_NAME="vcn-20260223-0816"
SUBNET_NAME="subnet-20260729-1005"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_FILE="$SCRIPT_DIR/cloud-init.yaml"

echo "Resolving availability domain, VCN, subnet, and image..."

AD=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query "data[0].name" --raw-output)
if [ -z "$AD" ]; then echo "Failed to resolve availability domain. Check your OCI CLI config."; exit 1; fi
echo "  AD: $AD"

VCN_ID=$(oci network vcn list --compartment-id "$COMPARTMENT_ID" --display-name "$VCN_NAME" --query "data[0].id" --raw-output)
if [ -z "$VCN_ID" ]; then echo "Failed to resolve VCN '$VCN_NAME'."; exit 1; fi
echo "  VCN: $VCN_ID"

SUBNET_ID=$(oci network subnet list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$SUBNET_NAME" --query "data[0].id" --raw-output)
if [ -z "$SUBNET_ID" ]; then echo "Failed to resolve subnet '$SUBNET_NAME'."; exit 1; fi
echo "  Subnet: $SUBNET_ID"

IMAGE_ID=$(oci compute image list --compartment-id "$COMPARTMENT_ID" --operating-system "Oracle Linux" --operating-system-version "9" --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC --query "data[0].id" --raw-output)
if [ -z "$IMAGE_ID" ]; then echo "Failed to resolve Oracle Linux 9 (A1-compatible) image."; exit 1; fi
echo "  Image: $IMAGE_ID"

USER_DATA_B64=$(base64 -w0 "$CLOUD_INIT_FILE" 2>/dev/null || base64 "$CLOUD_INIT_FILE")

ATTEMPT=0
while true; do
  ATTEMPT=$((ATTEMPT+1))
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$TS] Attempt #$ATTEMPT: launching $DISPLAY_NAME (2 OCPU / 12GB)..."

  OUTPUT=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD" \
    --display-name "$DISPLAY_NAME" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config '{"ocpus": 2, "memoryInGBs": 12}' \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --user-data "$USER_DATA_B64" \
    --wait-for-state RUNNING \
    --max-wait-seconds 300 2>&1)

  if echo "$OUTPUT" | grep -qi '"lifecycle-state": "RUNNING"'; then
    echo ""
    echo "SUCCESS! backend-vm-a1 is running."
    echo "$OUTPUT" | grep -A2 '"id"'
    echo ""
    echo "Public IP: check with -> oci compute instance list-vnics --instance-id <id-above> --query 'data[0].\"public-ip\"' --raw-output"
    break
  elif echo "$OUTPUT" | grep -qi "OutOfCapacity\|Out of host capacity\|out of capacity"; then
    echo "  -> Out of capacity. Retrying in 20s..."
    sleep 20
  else
    echo "  -> Unexpected error, stopping:"
    echo "$OUTPUT"
    break
  fi
done
