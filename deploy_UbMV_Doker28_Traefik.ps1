# ============================================================
# Google Cloud VM Deployment — Ubuntu 24.04 + Docker 28 + Traefik v3.3
# Machine : N2 Custom - 4 vCPUs / 16 GB RAM
# OS      : Ubuntu 24.04.4 LTS (Noble)
# Zone    : us-south1-c  |  Region: us-south1
# Traefik : v3.3, wildcard cert *.deviaaps.com via Cloudflare DNS-01
# ============================================================

# --- Configuration -----------------------------------------------------------
$PROJECT       = "YOUR_GCP_PROJECT_ID"
$ZONE          = "us-south1-c"
$VM_NAME       = "ubuntu-vm-docker28"
$MACHINE_TYPE  = "n2-custom-4-16384"   # 4 vCPUs, 16 384 MB RAM
$IMAGE_FAMILY  = "ubuntu-2404-lts-amd64"
$IMAGE_PROJECT = "ubuntu-os-cloud"
$DISK_SIZE     = "50GB"
$DISK_TYPE     = "pd-ssd"
$NETWORK_TAG   = "ssh-server"
$FW_RULE_SSH   = "allow-ssh-external"
$FW_RULE_WEB   = "allow-http-https-external"
$SSH_KEY_FILE  = "YOUR_SSH_KEY_PATH.pub"
$SSH_KEY_PRIV  = "YOUR_SSH_KEY_PATH"
$SSH_USERNAME  = "gcvmuser"
$TRAEFIK_DIR   = "/home/gcvmuser/traefik"
$ADMIN_PASS    = "YOUR_ADMIN_PASSWORD"
$CF_TOKEN      = "YOUR_CLOUDFLARE_API_TOKEN"

$SCRIPT_DIR = $PSScriptRoot

# --- Validate prerequisites --------------------------------------------------
if (-not (Test-Path $SSH_KEY_FILE)) {
    Write-Error "SSH public key not found at: $SSH_KEY_FILE"
    exit 1
}
if (-not (Test-Path "$SCRIPT_DIR\docker-compose.yml")) {
    Write-Error "docker-compose.yml not found in: $SCRIPT_DIR"
    exit 1
}

$SSH_PUB_KEY  = (Get-Content $SSH_KEY_FILE -Raw).Trim()
$SSH_METADATA = "${SSH_USERNAME}:${SSH_PUB_KEY}"

Write-Host "`n=== Google Cloud Deployment (Ubuntu 24.04 + Docker 28 + Traefik v3.3) ===" -ForegroundColor Cyan
Write-Host "Project : $PROJECT"
Write-Host "VM Name : $VM_NAME"
Write-Host "Machine : $MACHINE_TYPE"
Write-Host "Zone    : $ZONE"
Write-Host "Domain  : *.deviaaps.com"
Write-Host "User    : $SSH_USERNAME"
Write-Host ""

# --- 1. Set active project ---------------------------------------------------
Write-Host "[1/7] Setting active project..." -ForegroundColor Yellow
gcloud config set project $PROJECT

# --- 2. Firewall: SSH (port 22) ----------------------------------------------
Write-Host "[2/7] Checking SSH firewall rule '$FW_RULE_SSH'..." -ForegroundColor Yellow
$existingFwSsh = gcloud compute firewall-rules describe $FW_RULE_SSH --format="value(name)" 2>$null
if ($LASTEXITCODE -eq 0 -and $existingFwSsh -eq $FW_RULE_SSH) {
    Write-Host "      Firewall rule already exists, skipping." -ForegroundColor Gray
} else {
    gcloud compute firewall-rules create $FW_RULE_SSH `
        --project=$PROJECT `
        --direction=INGRESS `
        --priority=1000 `
        --network=default `
        --action=ALLOW `
        --rules=tcp:22 `
        --source-ranges=0.0.0.0/0 `
        --target-tags=$NETWORK_TAG `
        --description="Allow SSH from anywhere to VMs tagged ssh-server"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create SSH firewall rule."; exit 1 }
    Write-Host "      SSH firewall rule created." -ForegroundColor Green
}

# --- 3. Firewall: HTTP/HTTPS (ports 80, 443) ---------------------------------
Write-Host "[3/7] Checking HTTP/HTTPS firewall rule '$FW_RULE_WEB'..." -ForegroundColor Yellow
$existingFwWeb = gcloud compute firewall-rules describe $FW_RULE_WEB --format="value(name)" 2>$null
if ($LASTEXITCODE -eq 0 -and $existingFwWeb -eq $FW_RULE_WEB) {
    Write-Host "      Firewall rule already exists, skipping." -ForegroundColor Gray
} else {
    gcloud compute firewall-rules create $FW_RULE_WEB `
        --project=$PROJECT `
        --direction=INGRESS `
        --priority=1000 `
        --network=default `
        --action=ALLOW `
        "--rules=tcp:80,tcp:443" `
        --source-ranges=0.0.0.0/0 `
        --target-tags=$NETWORK_TAG `
        --description="Allow HTTP/HTTPS from anywhere to VMs tagged ssh-server"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create HTTP/HTTPS firewall rule."; exit 1 }
    Write-Host "      HTTP/HTTPS firewall rule created." -ForegroundColor Green
}

# --- 4. Prepare Docker 28 startup script (LF line endings) -------------------
Write-Host "[4/7] Preparing Docker 28 startup script..." -ForegroundColor Yellow
$STARTUP_SCRIPT_PATH = "$env:TEMP\docker28-startup.sh"
$STARTUP_SCRIPT = @'
#!/bin/bash
set -euo pipefail
exec > /var/log/docker28-install.log 2>&1

echo "=== Docker 28 Installation Started: $(date) ==="

apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apache2-utils

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y

DOCKER_VER=$(apt-cache madison docker-ce | grep "5:28\." | head -1 | awk '{print $3}' | tr -d ' ')
if [ -n "$DOCKER_VER" ]; then
    echo "Pinning Docker CE to version: $DOCKER_VER"
    apt-get install -y \
        "docker-ce=$DOCKER_VER" \
        "docker-ce-cli=$DOCKER_VER" \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
else
    echo "Docker 28.x not found in repo; installing latest Docker CE"
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable docker
systemctl start docker

if ! id gcvmuser &>/dev/null; then
    useradd -m -s /bin/bash gcvmuser
fi
usermod -aG docker gcvmuser

echo ""
echo "=== Docker 28 Installation Complete: $(date) ==="
docker --version
systemctl is-active docker
echo "gcvmuser groups: $(id gcvmuser)"
'@
$SCRIPT_LF = $STARTUP_SCRIPT -replace "`r`n", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($STARTUP_SCRIPT_PATH, $SCRIPT_LF, $utf8NoBom)
Write-Host "      Startup script written to: $STARTUP_SCRIPT_PATH" -ForegroundColor Gray

# --- 5. Create VM instance ---------------------------------------------------
Write-Host "[5/7] Checking VM instance '$VM_NAME'..." -ForegroundColor Yellow
$existingVm = gcloud compute instances describe $VM_NAME --zone=$ZONE --format="value(name)" 2>$null
if ($LASTEXITCODE -eq 0 -and $existingVm -eq $VM_NAME) {
    Write-Host "      VM '$VM_NAME' already exists, skipping creation." -ForegroundColor Gray
} else {
    Write-Host "      Creating VM (Docker 28 will install in background, ~90 sec)..." -ForegroundColor Yellow
    gcloud compute instances create $VM_NAME `
        --project=$PROJECT `
        --zone=$ZONE `
        --machine-type=$MACHINE_TYPE `
        --image-family=$IMAGE_FAMILY `
        --image-project=$IMAGE_PROJECT `
        --boot-disk-size=$DISK_SIZE `
        --boot-disk-type=$DISK_TYPE `
        --tags=$NETWORK_TAG `
        --metadata="ssh-keys=$SSH_METADATA" `
        --metadata-from-file="startup-script=$STARTUP_SCRIPT_PATH"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create VM."; exit 1 }
    Write-Host "      VM created. Docker installing in background..." -ForegroundColor Green
}

$EXTERNAL_IP = gcloud compute instances describe $VM_NAME `
    --project=$PROJECT `
    --zone=$ZONE `
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
Write-Host "      External IP: $EXTERNAL_IP" -ForegroundColor Cyan

# --- 6. Wait for Docker to be ready (polls SSH + Docker) ---------------------
Write-Host "[6/7] Waiting for Docker to be ready (up to 5 min)..." -ForegroundColor Yellow
$maxWait  = 300
$elapsed  = 0
$dockerOK = $false

while ($elapsed -lt $maxWait) {
    Start-Sleep -Seconds 20
    $elapsed += 20
    Write-Host "      Polling Docker... ($elapsed/$maxWait s)" -ForegroundColor Gray

    $result = gcloud compute ssh "${SSH_USERNAME}@${VM_NAME}" `
        --zone=$ZONE `
        --project=$PROJECT `
        --quiet `
        --command="docker info > /dev/null 2>&1 && echo DOCKER_READY || echo DOCKER_NOT_READY" `
        2>$null

    if ($result -match "DOCKER_READY") {
        $dockerOK = $true
        Write-Host "      Docker is ready!" -ForegroundColor Green
        break
    }
}

if (-not $dockerOK) {
    Write-Warning "Docker did not become ready within $maxWait seconds."
    Write-Host "  Check progress via SSH:"
    Write-Host "  ssh -i $SSH_KEY_PRIV ${SSH_USERNAME}@${EXTERNAL_IP}"
    Write-Host "  tail -f /var/log/docker28-install.log"
    exit 1
}

# --- 7. Set up Traefik v3.3 on the VM ----------------------------------------
Write-Host "[7/7] Deploying Traefik v3.3..." -ForegroundColor Yellow

# Build Traefik setup shell script (placeholders replaced before writing)
$TRAEFIK_SETUP_TEMPLATE = @'
#!/bin/bash
set -euo pipefail

echo "=== Traefik Setup Started: $(date) ===" | tee /tmp/traefik-setup.log

mkdir -p __TRAEFIK_DIR__
cd __TRAEFIK_DIR__

# Generate SHA1 hash for Traefik dashboard basic auth (SHA1 avoids $ chars that confuse docker compose)
HASH=$(htpasswd -nbs admin '__ADMIN_PASS__' | tr -d '\n')
echo "Dashboard auth hash generated" | tee -a /tmp/traefik-setup.log

# Create .env for docker-compose variable substitution
printf 'CF_DNS_API_TOKEN=__CF_TOKEN__\n'           > .env
printf 'CF_API_TOKEN=__CF_TOKEN__\n'               >> .env
printf 'TRAEFIK_DASHBOARD_AUTH=%s\n' "$HASH"       >> .env
echo "Created .env file" | tee -a /tmp/traefik-setup.log

# Start all services
docker compose up -d
echo "" | tee -a /tmp/traefik-setup.log
echo "=== Services Status ===" | tee -a /tmp/traefik-setup.log
docker compose ps | tee -a /tmp/traefik-setup.log
echo "" | tee -a /tmp/traefik-setup.log
echo "=== Traefik Setup Complete: $(date) ===" | tee -a /tmp/traefik-setup.log
echo "Dashboard : https://traefik.deviaaps.com  (admin / __ADMIN_PASS__)" | tee -a /tmp/traefik-setup.log
echo "Test svc  : https://whoami.deviaaps.com" | tee -a /tmp/traefik-setup.log
'@

$TRAEFIK_SETUP = $TRAEFIK_SETUP_TEMPLATE `
    -replace '__TRAEFIK_DIR__', $TRAEFIK_DIR `
    -replace '__ADMIN_PASS__',  $ADMIN_PASS `
    -replace '__CF_TOKEN__',    $CF_TOKEN

$TRAEFIK_SETUP_PATH = "$env:TEMP\traefik-setup.sh"
$SETUP_LF = $TRAEFIK_SETUP -replace "`r`n", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($TRAEFIK_SETUP_PATH, $SETUP_LF, $utf8NoBom)

# Create the remote traefik directory
Write-Host "      Creating traefik directory on VM..." -ForegroundColor Gray
gcloud compute ssh "${SSH_USERNAME}@${VM_NAME}" `
    --zone=$ZONE --project=$PROJECT --quiet `
    --command="mkdir -p $TRAEFIK_DIR"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create remote traefik directory."; exit 1 }

# Upload docker-compose.yml
Write-Host "      Uploading docker-compose.yml..." -ForegroundColor Gray
gcloud compute scp `
    "$SCRIPT_DIR\docker-compose.yml" `
    "${SSH_USERNAME}@${VM_NAME}:${TRAEFIK_DIR}/docker-compose.yml" `
    --zone=$ZONE --project=$PROJECT --quiet
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to SCP docker-compose.yml."; exit 1 }

# Upload setup script
Write-Host "      Uploading setup script..." -ForegroundColor Gray
gcloud compute scp `
    $TRAEFIK_SETUP_PATH `
    "${SSH_USERNAME}@${VM_NAME}:/tmp/traefik-setup.sh" `
    --zone=$ZONE --project=$PROJECT --quiet
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to SCP traefik-setup.sh."; exit 1 }

# Execute setup script on VM
Write-Host "      Running Traefik setup (may take ~30s for image pull)..." -ForegroundColor Gray
gcloud compute ssh "${SSH_USERNAME}@${VM_NAME}" `
    --zone=$ZONE --project=$PROJECT --quiet `
    --command="chmod +x /tmp/traefik-setup.sh && /tmp/traefik-setup.sh"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Traefik setup may have encountered issues."
    Write-Host "  Check the log: ssh -i $SSH_KEY_PRIV ${SSH_USERNAME}@${EXTERNAL_IP} -- ""cat /tmp/traefik-setup.log"""
    exit 1
}

# --- Final summary -----------------------------------------------------------
Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "External IP : $EXTERNAL_IP"
Write-Host ""
Write-Host "IMPORTANT - Add these DNS A records in Cloudflare (zone: deviaaps.com):" -ForegroundColor Yellow
Write-Host "  traefik.deviaaps.com  -> $EXTERNAL_IP"
Write-Host "  whoami.deviaaps.com   -> $EXTERNAL_IP"
Write-Host "  (or wildcard: *.deviaaps.com -> $EXTERNAL_IP)"
Write-Host ""
Write-Host "Services:" -ForegroundColor Cyan
Write-Host "  Traefik Dashboard : https://traefik.deviaaps.com  (admin / $ADMIN_PASS)"
Write-Host "  Test Service      : https://whoami.deviaaps.com"
Write-Host ""
Write-Host "SSH access:" -ForegroundColor Cyan
Write-Host "  ssh -i $SSH_KEY_PRIV ${SSH_USERNAME}@${EXTERNAL_IP}"
Write-Host ""
Write-Host "Monitor Docker install log:" -ForegroundColor Cyan
Write-Host "  gcloud compute ssh ${SSH_USERNAME}@${VM_NAME} --zone=$ZONE --command=""tail -f /var/log/docker28-install.log"""
Write-Host ""
Write-Host "Monitor Traefik setup log:" -ForegroundColor Cyan
Write-Host "  gcloud compute ssh ${SSH_USERNAME}@${VM_NAME} --zone=$ZONE --command=""cat /tmp/traefik-setup.log"""
Write-Host ""
Write-Host "To destroy all infrastructure run:" -ForegroundColor Cyan
Write-Host "  .\destroy_UbMV_Doker28_Traefik.ps1"
Write-Host ""
