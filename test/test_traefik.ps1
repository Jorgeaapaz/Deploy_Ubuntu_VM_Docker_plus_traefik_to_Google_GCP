# ============================================================
# Traefik v3.3 Validation Test Runner
# Uploads test_traefik_vm.sh to the GCP VM and runs it.
# Usage: .\test\test_traefik.ps1
# ============================================================

# --- Load configuration from .env (one level up, in project root) ------------
$_envFile = Join-Path (Split-Path $PSScriptRoot) ".env"
if (-not (Test-Path $_envFile)) {
    Write-Error ".env not found at: $_envFile`nCopy .env.example to .env and fill in your values."
    exit 1
}
Get-Content $_envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        Set-Variable -Name $matches[1] -Value $matches[2]
    }
}
$SSH_USER   = $SSH_USERNAME   # alias used in this script
$SCRIPT_DIR = $PSScriptRoot
$BASH_SCRIPT = Join-Path $SCRIPT_DIR "test_traefik_vm.sh"
$REMOTE_PATH = "/tmp/test_traefik_vm.sh"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Traefik v3.3 Validation - Remote Test Runner" -ForegroundColor Cyan
Write-Host "  VM      : $VM_NAME ($ZONE)" -ForegroundColor Cyan
Write-Host "  Project : $PROJECT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Verify local bash script exists
if (-not (Test-Path $BASH_SCRIPT)) {
    Write-Error "Test script not found: $BASH_SCRIPT"
    exit 1
}

# Re-encode as UTF-8 No BOM + LF (required for bash on Linux)
Write-Host "[1/3] Preparing test script (UTF-8 / LF)..." -ForegroundColor Yellow
$tmpPath = "$env:TEMP\test_traefik_vm.sh"
$content = Get-Content $BASH_SCRIPT -Raw
$contentLF = $content -replace "`r`n", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmpPath, $contentLF, $utf8NoBom)
Write-Host "      Temp file: $tmpPath" -ForegroundColor Gray

# Upload to VM
Write-Host "[2/3] Uploading test script to VM..." -ForegroundColor Yellow
gcloud compute scp `
    $tmpPath `
    "${SSH_USER}@${VM_NAME}:${REMOTE_PATH}" `
    --zone=$ZONE --project=$PROJECT --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upload test script to VM."
    exit 1
}
Write-Host "      Uploaded to ${REMOTE_PATH}" -ForegroundColor Gray

# Execute on VM
Write-Host "[3/3] Running tests on VM..." -ForegroundColor Yellow
Write-Host ""
$runCmd = "chmod +x " + $REMOTE_PATH + "; bash " + $REMOTE_PATH
gcloud compute ssh "${SSH_USER}@${VM_NAME}" `
    --zone=$ZONE --project=$PROJECT --quiet `
    "--command=$runCmd"

$exitCode = $LASTEXITCODE

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "All tests passed." -ForegroundColor Green
} else {
    Write-Host "${exitCode} tests failed. Review output above." -ForegroundColor Red
}

exit $exitCode
