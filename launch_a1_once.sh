#!/usr/bin/env bash
# One A1 launch attempt, for CI/cron. The scheduler handles repeating.
# Exit 0 on success OR expected transient (capacity/429) so scheduled runs stay
# green (GitHub only emails on red). Exit 1 only on a genuinely unexpected error.
set -uo pipefail

COMPARTMENT="ocid1.tenancy.oc1..aaaaaaaao3mc7np5v3hzyqxzaewfmglopndkmchuko6gphhdevqv25es7dma"
AD="qnjs:AP-HYDERABAD-1-AD-1"
SUBNET="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaahsdq4gvnywyeez3vvtjd2nspngitol2jsnz2wet5gfe5lbxc2egq"
IMAGE="ocid1.image.oc1.ap-hyderabad-1.aaaaaaaagqegg2yv5hyhlr4u4i4et4zkhptmejhmr3povoyw4rx4nrb2dnyq"
NAME="backend-vm-a1"

# Guard: don't create a second instance if one already exists (any non-terminated state).
existing=$(oci compute instance list --compartment-id "$COMPARTMENT" \
  --display-name "$NAME" \
  --query "length(data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
  --raw-output 2>/dev/null || echo 0)
if [ "${existing:-0}" != "0" ]; then
  echo "already-exists" > success.marker
  echo "::notice::$NAME already exists ($existing non-terminated). Nothing to do."
  exit 0
fi

out=$(oci compute instance launch \
  --compartment-id "$COMPARTMENT" \
  --availability-domain "$AD" \
  --display-name "$NAME" \
  --shape "VM.Standard.A1.Flex" \
  --shape-config '{"ocpus": 2, "memoryInGBs": 12}' \
  --image-id "$IMAGE" \
  --subnet-id "$SUBNET" \
  --assign-public-ip true \
  --user-data-file cloud-init.yaml 2>&1)
rc=$?
echo "$out"

if [ $rc -eq 0 ] && echo "$out" | grep -q '"id": *"ocid1.instance'; then
  echo "success" > success.marker
  echo "::notice::SUCCESS - $NAME launch accepted (provisioning)."
  exit 0
elif echo "$out" | grep -qiE "OutOfCapacity|Out of host capacity|out of capacity"; then
  echo "Out of capacity - will retry next run."; exit 0
elif echo "$out" | grep -qiE "TooManyRequests|Too many requests|\b429\b"; then
  echo "Rate limited - will retry next run."; exit 0
else
  echo "::error::Unexpected error launching $NAME"; exit 1
fi
