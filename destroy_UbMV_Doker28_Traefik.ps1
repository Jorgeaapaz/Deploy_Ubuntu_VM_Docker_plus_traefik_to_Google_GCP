# ============================================================
# Google Cloud VM Teardown — Ubuntu 24.04 + Docker 28 + Traefik v3.3
# Removes VM, all attached disks (Docker volumes + Traefik certs included),
# SSH firewall rule, and HTTP/HTTPS firewall rule.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Load configuration from .env (must match deploy_UbMV_Doker28_Traefik.ps1) ---
$_envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $_envFile)) {
    Write-Error ".env not found at: $_envFile`nCopy .env.example to .env and fill in your values."
    exit 1
}
Get-Content $_envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        Set-Variable -Name $matches[1] -Value $matches[2]
    }
}
$DISK_NAME = $VM_NAME   # GCP names the boot disk after the VM by default

Write-Host "`n=== Google Cloud Teardown (Ubuntu + Docker 28 + Traefik v3.3) ===" -ForegroundColor Red
Write-Host "Project : $PROJECT"
Write-Host "VM Name : $VM_NAME"
Write-Host "Zone    : $ZONE"
Write-Host ""
Write-Host "Resources to be permanently deleted:" -ForegroundColor Yellow
Write-Host "  - VM instance '$VM_NAME' with all attached disks"
Write-Host "    (includes Docker containers, named volumes, and Traefik Let's Encrypt certs)"
Write-Host "  - Firewall rule: $FW_RULE_SSH  (port 22)"
Write-Host "  - Firewall rule: $FW_RULE_WEB  (ports 80, 443)"
Write-Host ""

$confirm = Read-Host "Permanently delete all resources listed above? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Aborted." -ForegroundColor Yellow
    exit 0
}

# --- 1. Delete VM instance (with all disks — includes Docker + Traefik data) -
Write-Host "[1/4] Deleting VM instance '$VM_NAME' and all attached disks..." -ForegroundColor Yellow

$existingVm = gcloud compute instances list `
    --filter="name=$VM_NAME AND zone:$ZONE" `
    --format="value(name)" 2>$null

if ($existingVm -eq $VM_NAME) {
    gcloud compute instances delete $VM_NAME `
        --project=$PROJECT `
        --zone=$ZONE `
        --delete-disks=all `
        --quiet
    Write-Host "      VM and all disks deleted (Docker volumes and Traefik certs removed)." -ForegroundColor Green
} else {
    Write-Host "      VM '$VM_NAME' not found, skipping." -ForegroundColor Gray
}

# --- 2. Orphaned boot disk safety net ----------------------------------------
Write-Host "[2/4] Checking for orphaned boot disk '$DISK_NAME'..." -ForegroundColor Yellow

$existingDisk = gcloud compute disks list `
    --filter="name=$DISK_NAME AND zone:$ZONE" `
    --format="value(name)" 2>$null

if ($existingDisk -eq $DISK_NAME) {
    gcloud compute disks delete $DISK_NAME `
        --project=$PROJECT `
        --zone=$ZONE `
        --quiet
    Write-Host "      Orphaned disk deleted." -ForegroundColor Green
} else {
    Write-Host "      No orphaned disk found." -ForegroundColor Gray
}

# --- 3. Delete SSH firewall rule ---------------------------------------------
Write-Host "[3/4] Deleting SSH firewall rule '$FW_RULE_SSH'..." -ForegroundColor Yellow

$existingFwSsh = gcloud compute firewall-rules list `
    --filter="name=$FW_RULE_SSH" `
    --format="value(name)" 2>$null

if ($existingFwSsh -eq $FW_RULE_SSH) {
    gcloud compute firewall-rules delete $FW_RULE_SSH `
        --project=$PROJECT `
        --quiet
    Write-Host "      SSH firewall rule deleted." -ForegroundColor Green
} else {
    Write-Host "      Rule '$FW_RULE_SSH' not found, skipping." -ForegroundColor Gray
}

# --- 4. Delete HTTP/HTTPS firewall rule --------------------------------------
Write-Host "[4/4] Deleting HTTP/HTTPS firewall rule '$FW_RULE_WEB'..." -ForegroundColor Yellow

$existingFwWeb = gcloud compute firewall-rules list `
    --filter="name=$FW_RULE_WEB" `
    --format="value(name)" 2>$null

if ($existingFwWeb -eq $FW_RULE_WEB) {
    gcloud compute firewall-rules delete $FW_RULE_WEB `
        --project=$PROJECT `
        --quiet
    Write-Host "      HTTP/HTTPS firewall rule deleted." -ForegroundColor Green
} else {
    Write-Host "      Rule '$FW_RULE_WEB' not found, skipping." -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Teardown Complete ===" -ForegroundColor Green
Write-Host "All VM, Docker, and Traefik infrastructure has been removed."
Write-Host ""
