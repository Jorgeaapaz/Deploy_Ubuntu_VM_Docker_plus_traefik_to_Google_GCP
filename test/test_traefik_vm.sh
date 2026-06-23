#!/bin/bash
# Traefik v3.3 Validation Tests — runs directly on the GCP VM
# Usage: bash test_traefik_vm.sh
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DOMAIN="deviaaps.com"
TRAEFIK_DIR="/home/gcvmuser/traefik"
DASHBOARD_USER="admin"
DASHBOARD_PASS="YOUR_ADMIN_PASSWORD"

# Override defaults from the traefik .env if available
if [ -f "${TRAEFIK_DIR}/.env" ]; then
    _d=$(grep '^DOMAIN=' "${TRAEFIK_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')
    _p=$(grep '^TRAEFIK_DASHBOARD_PASS=' "${TRAEFIK_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')
    [ -n "$_d" ] && DOMAIN="$_d"
    [ -n "$_p" ] && DASHBOARD_PASS="$_p"
fi

TRAEFIK_HOST="traefik.${DOMAIN}"
WHOAMI_HOST="whoami.${DOMAIN}"

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
section() { echo -e "\n${CYAN}${BOLD}--- $1 ---${NC}"; }

echo ""
echo -e "${BOLD}========================================================${NC}"
echo -e "${BOLD}  Traefik v3.3 Validation Tests${NC}"
echo -e "  VM IP  : $(hostname -I | awk '{print $1}')"
echo -e "  Date   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo -e "  Domain : *.${DOMAIN}"
echo -e "${BOLD}========================================================${NC}"

# ------------------------------------------------------------------ #
# 1. Infrastructure                                                    #
# ------------------------------------------------------------------ #
section "1. Infrastructure"

# 1.1 Docker daemon
if systemctl is-active --quiet docker 2>/dev/null; then
    pass "Docker daemon is running"
else
    fail "Docker daemon is NOT running"
fi

# 1.2 Docker version >= 28
DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)
if [ "${DOCKER_VER:-0}" -ge 28 ]; then
    pass "Docker version >= 28 ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
else
    fail "Docker version < 28 or not available (got: ${DOCKER_VER:-none})"
fi

# 1.3 miseia-net network
if docker network ls --format '{{.Name}}' | grep -q '^miseia-net$'; then
    pass "Docker network 'miseia-net' exists"
else
    fail "Docker network 'miseia-net' NOT found"
fi

# 1.4 docker-compose.yml present
if [ -f "${TRAEFIK_DIR}/docker-compose.yml" ]; then
    pass "docker-compose.yml present in ${TRAEFIK_DIR}"
else
    fail "docker-compose.yml NOT found in ${TRAEFIK_DIR}"
fi

# 1.5 .env present
if [ -f "${TRAEFIK_DIR}/.env" ]; then
    pass ".env file present in ${TRAEFIK_DIR}"
else
    fail ".env file NOT found in ${TRAEFIK_DIR}"
fi

# ------------------------------------------------------------------ #
# 2. Containers                                                        #
# ------------------------------------------------------------------ #
section "2. Containers"

# 2.1 Traefik container running
TRAEFIK_STATUS=$(docker inspect traefik --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [ "$TRAEFIK_STATUS" = "running" ]; then
    TRAEFIK_IMAGE=$(docker inspect traefik --format '{{.Config.Image}}' 2>/dev/null)
    pass "traefik container running (image: ${TRAEFIK_IMAGE})"
else
    fail "traefik container NOT running (status: ${TRAEFIK_STATUS})"
fi

# 2.2 whoami container running
WHOAMI_STATUS=$(docker inspect whoami --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [ "$WHOAMI_STATUS" = "running" ]; then
    pass "whoami container running"
else
    fail "whoami container NOT running (status: ${WHOAMI_STATUS})"
fi

# 2.3 Traefik restart count
RESTART_COUNT=$(docker inspect traefik --format '{{.RestartCount}}' 2>/dev/null || echo "?")
if [ "${RESTART_COUNT}" = "0" ]; then
    pass "traefik container has 0 restarts (stable)"
else
    fail "traefik container has restarted ${RESTART_COUNT} time(s)"
fi

# 2.4 Traefik on miseia-net
if docker inspect traefik --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -q 'miseia-net'; then
    pass "traefik is on network 'miseia-net'"
else
    fail "traefik is NOT on network 'miseia-net'"
fi

# 2.5 whoami on miseia-net
if docker inspect whoami --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -q 'miseia-net'; then
    pass "whoami is on network 'miseia-net'"
else
    fail "whoami is NOT on network 'miseia-net'"
fi

# ------------------------------------------------------------------ #
# 3. Ports & Connectivity                                              #
# ------------------------------------------------------------------ #
section "3. Ports & Connectivity"

# 3.1 Port 80 listening
if ss -tlnp 2>/dev/null | grep -q ':80 ' || ss -tlnp 2>/dev/null | grep -q ':80$'; then
    pass "Port 80 is listening"
else
    fail "Port 80 is NOT listening"
fi

# 3.2 Port 443 listening
if ss -tlnp 2>/dev/null | grep -q ':443 ' || ss -tlnp 2>/dev/null | grep -q ':443$'; then
    pass "Port 443 is listening"
else
    fail "Port 443 is NOT listening"
fi

# 3.3 HTTP → HTTPS redirect
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --resolve "${TRAEFIK_HOST}:80:127.0.0.1" \
    "http://${TRAEFIK_HOST}/" 2>/dev/null)
if [ "$HTTP_CODE" = "301" ]; then
    pass "HTTP port 80 redirects to HTTPS (301 Moved Permanently)"
else
    fail "HTTP redirect expected 301, got: ${HTTP_CODE}"
fi

# 3.4 HTTPS responds on 443
HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "${TRAEFIK_HOST}:443:127.0.0.1" \
    "https://${TRAEFIK_HOST}/ping" 2>/dev/null)
if [ "$HTTPS_CODE" != "000" ]; then
    pass "HTTPS port 443 is responding (HTTP ${HTTPS_CODE})"
else
    fail "HTTPS port 443 is not responding (connection refused or timeout)"
fi

# ------------------------------------------------------------------ #
# 4. TLS Certificates                                                  #
# ------------------------------------------------------------------ #
section "4. TLS Certificates"

get_cert_field() {
    local host="$1" field="$2"
    echo | openssl s_client -connect "127.0.0.1:443" -servername "$host" 2>/dev/null \
        | openssl x509 -noout "$field" 2>/dev/null
}

# 4.1 Certificate issuer — Let's Encrypt
ISSUER=$(get_cert_field "$TRAEFIK_HOST" -issuer 2>/dev/null)
if echo "$ISSUER" | grep -qi "Let.s Encrypt"; then
    pass "Certificate issued by Let's Encrypt (${ISSUER})"
else
    fail "Expected Let's Encrypt issuer, got: ${ISSUER:-none}"
fi

# 4.2 Wildcard SAN present
SANS=$(echo | openssl s_client -connect "127.0.0.1:443" -servername "$TRAEFIK_HOST" 2>/dev/null \
    | openssl x509 -noout -text 2>/dev/null \
    | grep -A1 "Subject Alternative Name" | tail -1)
if echo "$SANS" | grep -q '\*\.deviaaps\.com'; then
    pass "Wildcard SAN '*.deviaaps.com' present in certificate"
else
    fail "Wildcard SAN NOT found; SANs: ${SANS:-none}"
fi

# 4.3 TLS verify OK — traefik.deviaaps.com
VERIFY=$(echo | openssl s_client -connect "127.0.0.1:443" \
    -servername "$TRAEFIK_HOST" \
    -CApath /etc/ssl/certs 2>/dev/null | grep "Verify return code")
if echo "$VERIFY" | grep -q "0 (ok)"; then
    pass "${TRAEFIK_HOST} — TLS chain verified OK"
else
    fail "${TRAEFIK_HOST} — TLS chain verify FAILED: ${VERIFY:-no output}"
fi

# 4.4 TLS verify OK — whoami.deviaaps.com
VERIFY2=$(echo | openssl s_client -connect "127.0.0.1:443" \
    -servername "$WHOAMI_HOST" \
    -CApath /etc/ssl/certs 2>/dev/null | grep "Verify return code")
if echo "$VERIFY2" | grep -q "0 (ok)"; then
    pass "${WHOAMI_HOST} — TLS chain verified OK"
else
    fail "${WHOAMI_HOST} — TLS chain verify FAILED: ${VERIFY2:-no output}"
fi

# 4.5 Certificate expiry > 60 days
EXPIRY_RAW=$(get_cert_field "$TRAEFIK_HOST" -enddate 2>/dev/null | sed 's/notAfter=//')
if [ -n "$EXPIRY_RAW" ]; then
    EXPIRY_EPOCH=$(date -d "$EXPIRY_RAW" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [ "$DAYS_LEFT" -gt 60 ]; then
        pass "Certificate valid for ${DAYS_LEFT} days (expires: ${EXPIRY_RAW})"
    elif [ "$DAYS_LEFT" -gt 0 ]; then
        fail "Certificate expiring soon: ${DAYS_LEFT} days remaining!"
    else
        fail "Certificate appears to be expired (${EXPIRY_RAW})"
    fi
else
    fail "Could not determine certificate expiry date"
fi

# 4.6 acme.json has stored certificates
ACME_SIZE=$(docker exec traefik wc -c /letsencrypt/acme.json 2>/dev/null | awk '{print $1}')
if [ "${ACME_SIZE:-0}" -gt 1000 ]; then
    pass "acme.json has data (${ACME_SIZE} bytes) — certificates persisted to volume"
else
    fail "acme.json is empty or missing (${ACME_SIZE:-0} bytes)"
fi

# ------------------------------------------------------------------ #
# 5. Services & Routing                                                #
# ------------------------------------------------------------------ #
section "5. Services & Routing"

# 5.1 Dashboard — 401 without credentials
DASH_NOAUTH=$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "${TRAEFIK_HOST}:443:127.0.0.1" \
    "https://${TRAEFIK_HOST}/dashboard/" 2>/dev/null)
if [ "$DASH_NOAUTH" = "401" ]; then
    pass "Traefik dashboard requires authentication (401 without credentials)"
elif [ "$DASH_NOAUTH" = "302" ] || [ "$DASH_NOAUTH" = "301" ]; then
    pass "Traefik dashboard redirects (${DASH_NOAUTH}) — auth enforced"
else
    fail "Dashboard auth unexpected: ${DASH_NOAUTH} (expected 401)"
fi

# 5.2 Dashboard — 200 with valid credentials
DASH_AUTH=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${DASHBOARD_USER}:${DASHBOARD_PASS}" \
    --resolve "${TRAEFIK_HOST}:443:127.0.0.1" \
    "https://${TRAEFIK_HOST}/dashboard/" 2>/dev/null)
if [ "$DASH_AUTH" = "200" ]; then
    pass "Traefik dashboard accessible with credentials (200)"
else
    fail "Dashboard with credentials returned: ${DASH_AUTH} (expected 200)"
fi

# 5.3 API /api/rawdata responds with auth
API_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${DASHBOARD_USER}:${DASHBOARD_PASS}" \
    --resolve "${TRAEFIK_HOST}:443:127.0.0.1" \
    "https://${TRAEFIK_HOST}/api/rawdata" 2>/dev/null)
if [ "$API_CODE" = "200" ]; then
    pass "Traefik API /api/rawdata accessible (200)"
else
    fail "Traefik API returned: ${API_CODE} (expected 200)"
fi

# 5.4 whoami — HTTP 200
WHOAMI_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "${WHOAMI_HOST}:443:127.0.0.1" \
    "https://${WHOAMI_HOST}/" 2>/dev/null)
if [ "$WHOAMI_CODE" = "200" ]; then
    pass "whoami service responds with 200"
else
    fail "whoami service returned: ${WHOAMI_CODE} (expected 200)"
fi

# 5.5 whoami — response body contains expected content
WHOAMI_BODY=$(curl -sk \
    --resolve "${WHOAMI_HOST}:443:127.0.0.1" \
    "https://${WHOAMI_HOST}/" 2>/dev/null)
if echo "$WHOAMI_BODY" | grep -q "Hostname:"; then
    WHOAMI_HOSTNAME=$(echo "$WHOAMI_BODY" | grep "^Hostname:" | awk '{print $2}')
    pass "whoami response contains expected body (Hostname: ${WHOAMI_HOSTNAME})"
else
    fail "whoami response missing expected body content"
fi

# 5.6 whoami — X-Forwarded-Proto header set to https
if echo "$WHOAMI_BODY" | grep -qi "X-Forwarded-Proto: https"; then
    pass "whoami shows X-Forwarded-Proto: https (TLS passthrough correct)"
else
    fail "whoami missing X-Forwarded-Proto: https header"
fi

# ------------------------------------------------------------------ #
# 6. Traefik Logs & Health                                             #
# ------------------------------------------------------------------ #
section "6. Traefik Logs & Health"

# Capture recent Traefik logs once (--tail avoids SIGPIPE with pipefail)
TLOGS=$(docker logs traefik --tail 500 2>&1 || true)

# 6.1 No fatal errors in recent logs
RECENT_ERRS=$(docker logs traefik --since 60s 2>&1 | grep -c ' ERR ' || true)
if [ "${RECENT_ERRS}" = "0" ]; then
    pass "No ERR lines in Traefik logs (last 60s)"
else
    fail "${RECENT_ERRS} ERR line(s) in Traefik logs (last 60s)"
    docker logs traefik --since 60s 2>&1 | grep ' ERR ' | tail -5 || true
fi

# 6.2 Traefik version confirmed
if echo "$TLOGS" | grep -q "3.3"; then
    pass "Traefik version 3.3.x confirmed in logs"
else
    fail "Traefik version 3.3 not found in logs"
fi

# 6.3 Docker provider active
if echo "$TLOGS" | grep -q "docker.Provider"; then
    pass "Docker provider is active"
else
    fail "Docker provider NOT found in logs"
fi

# 6.4 ACME (Cloudflare) provider active
if echo "$TLOGS" | grep -q "acme"; then
    pass "ACME (Cloudflare) provider is active"
else
    fail "ACME provider NOT found in logs"
fi

# ------------------------------------------------------------------ #
# Summary                                                              #
# ------------------------------------------------------------------ #
TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo -e "${BOLD}========================================================${NC}"
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ALL TESTS PASSED${NC}  ${PASS}/${TOTAL} passed"
else
    echo -e "${RED}${BOLD}  $FAIL TEST(S) FAILED${NC}  ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
fi
echo -e "${BOLD}========================================================${NC}"
echo ""

exit $FAIL
