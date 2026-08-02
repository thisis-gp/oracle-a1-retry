# Retry-creates backend-vm-a1 (VM.Standard.A1.Flex, 2 OCPU / 12GB) in ap-hyderabad-1
# until Oracle has free Ampere capacity. Stops automatically on success.
#
# Prereqs (run once):
#   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#   Invoke-WebRequest https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1 -OutFile install.ps1
#   .\install.ps1 -AcceptAllDefaults
#   (close and reopen PowerShell so 'oci' is on PATH)
#   mkdir $env:USERPROFILE\.oci -Force
#   Copy-Item oci_api_key.pem $env:USERPROFILE\.oci\oci_api_key.pem
#   Copy-Item oci_config $env:USERPROFILE\.oci\config
#
# Usage:  .\retry_create_a1.ps1

$ErrorActionPreference = "Continue"

$CompartmentId = "ocid1.tenancy.oc1..aaaaaaaao3mc7np5v3hzyqxzaewfmglopndkmchuko6gphhdevqv25es7dma"
$DisplayName   = "backend-vm-a1"
$VcnName       = "vcn-20260223-0816"
$SubnetName    = "subnet-20260729-1005"
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$CloudInitFile = Join-Path $ScriptDir "cloud-init.yaml"

Write-Host "Resolving availability domain, VCN, subnet, and image..."

$AD = (oci iam availability-domain list --compartment-id $CompartmentId --query "data[0].name" --raw-output)
if (-not $AD) { Write-Host "Failed to resolve availability domain. Check your OCI CLI config."; exit 1 }
Write-Host "  AD: $AD"

$VcnId = (oci network vcn list --compartment-id $CompartmentId --display-name $VcnName --query "data[0].id" --raw-output)
if (-not $VcnId) { Write-Host "Failed to resolve VCN '$VcnName'."; exit 1 }
Write-Host "  VCN: $VcnId"

$SubnetId = (oci network subnet list --compartment-id $CompartmentId --vcn-id $VcnId --display-name $SubnetName --query "data[0].id" --raw-output)
if (-not $SubnetId) { Write-Host "Failed to resolve subnet '$SubnetName'."; exit 1 }
Write-Host "  Subnet: $SubnetId"

$ImageId = (oci compute image list --compartment-id $CompartmentId --operating-system "Oracle Linux" --operating-system-version "9" --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC --query "data[0].id" --raw-output)
if (-not $ImageId) { Write-Host "Failed to resolve Oracle Linux 9 (A1-compatible) image."; exit 1 }
Write-Host "  Image: $ImageId"

$Attempt = 0
while ($true) {
    $Attempt++
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] Attempt #${Attempt}: launching $DisplayName (2 OCPU / 12GB)..."

    $Output = oci compute instance launch `
        --compartment-id $CompartmentId `
        --availability-domain $AD `
        --display-name $DisplayName `
        --shape "VM.Standard.A1.Flex" `
        --shape-config '{\"ocpus\": 2, \"memoryInGBs\": 12}' `
        --image-id $ImageId `
        --subnet-id $SubnetId `
        --assign-public-ip true `
        --user-data-file $CloudInitFile `
        --wait-for-state RUNNING `
        --max-wait-seconds 300 2>&1 | Out-String

    if ($Output -match '"lifecycle-state":\s*"RUNNING"') {
        Write-Host ""
        Write-Host "SUCCESS! backend-vm-a1 is running."
        Write-Host $Output
        break
    }
    elseif ($Output -match "OutOfCapacity|Out of host capacity|out of capacity") {
        Write-Host "  -> Out of capacity. Retrying in 60s..."
        Start-Sleep -Seconds 60
    }
    elseif ($Output -match "TooManyRequests|Too many requests|\b429\b") {
        Write-Host "  -> Rate limited (429). Backing off 120s..."
        Start-Sleep -Seconds 120
    }
    else {
        # Transient (network timeout, 5xx, throttle). Request is well-formed
        # (resources resolved, launch reached Oracle), so retry rather than quit.
        Write-Host "  -> Transient error, retrying in 60s:"
        Write-Host $Output
        Start-Sleep -Seconds 60
    }
}
