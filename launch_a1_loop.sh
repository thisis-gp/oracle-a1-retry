#!/usr/bin/env bash
# Continuous A1 launch loop for CI. Runs for a time budget (< GitHub's 6h job cap),
# attempting every 60s. Writes success.marker and exits 0 on success. On budget
# exhaustion exits 0 so the workflow can re-dispatch itself (continuous coverage).
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

COMPARTMENT="ocid1.tenancy.oc1..aaaaaaaao3mc7np5v3hzyqxzaewfmglopndkmchuko6gphhdevqv25es7dma"
AD="qnjs:AP-HYDERABAD-1-AD-1"
SUBNET="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaahsdq4gvnywyeez3vvtjd2nspngitol2jsnz2wet5gfe5lbxc2egq"
IMAGE="ocid1.image.oc1.ap-hyderabad-1.aaaaaaaagqegg2yv5hyhlr4u4i4et4zkhptmejhmr3povoyw4rx4nrb2dnyq"
NAME="backend-vm-a1"

DEADLINE=$(( $(date +%s) + 20400 ))   # ~5h40m, safely under the 6h job limit
attempt=0

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  attempt=$((attempt+1))
  ts=$(date -u +%H:%M:%S)

  # Guard: never create a second instance.
  existing=$(oci compute instance list --compartment-id "$COMPARTMENT" \
    --display-name "$NAME" \
    --query "length(data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'])" \
    --raw-output 2>/dev/null || echo 0)
  if [ "${existing:-0}" != "0" ]; then
    echo "[$ts] #$attempt $NAME already exists ($existing). Done."
    echo "already-exists" > success.marker; exit 0
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

  if [ $rc -eq 0 ] && echo "$out" | grep -q '"id": *"ocid1.instance'; then
    echo "[$ts] #$attempt SUCCESS - launch accepted"; echo "$out"
    echo "success" > success.marker; exit 0
  elif echo "$out" | grep -qiE "OutOfCapacity|Out of host capacity|out of capacity"; then
    echo "[$ts] #$attempt out of capacity; sleep 90"; sleep 90
  elif echo "$out" | grep -qiE "TooManyRequests|Too many requests|\b429\b"; then
    echo "[$ts] #$attempt rate limited; sleep 300"; sleep 300
  else
    echo "[$ts] #$attempt transient error; sleep 90:"; echo "$out"; sleep 90
  fi
done

echo "Time budget reached after $attempt attempts. Workflow will re-dispatch."
exit 0
