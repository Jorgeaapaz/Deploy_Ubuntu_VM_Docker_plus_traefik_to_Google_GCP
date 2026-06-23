# Session Retrospective — Traefik v3.3 on GCP VM

**Session date:** 2026-06-23
**Duration:** ~3 hours (across two context windows)
**Outcome:** All 30 automated tests passing; wildcard Let's Encrypt certificate issued and verified

---

## What We Set Out to Do

The CLAUDE.md instructions defined 5 goals:

1. Create `docker-compose.yml` for Traefik v3.3 with wildcard TLS via Cloudflare DNS-01
2. Create `deploy_UbMV_Doker28_Traefik.ps1` (GCP VM + Docker + Traefik automation)
3. Create `destroy_UbMV_Doker28_Traefik.ps1` (full teardown)
4. Run the deploy and validate Traefik readiness
5. Provide SSH and standalone docker-compose instructions

A sixth goal was added by the user mid-session: create automated test scripts under `test/`.

**Final delivery:** All 6 goals completed. VM provisioned, certificate obtained, 30/30 tests passing, VM destroyed on request.

---

## What Went Well

### Accurate diagnosis of the Docker network prefix bug
The first silent failure after deploy was that Traefik could not route to services. The network was named `traefik_miseia-net` by Docker Compose instead of `miseia-net`. Identifying that Docker Compose automatically prefixes network names with the project name, and fixing it with `name: miseia-net` in the network definition, was clean and correct on the first attempt.

### Structured approach to bash script encoding
The requirement to write bash scripts from a Windows PowerShell 5.1 environment created a classic encoding trap: `[System.Text.Encoding]::UTF8` in .NET 4.x adds a BOM that makes shebangs invisible to the Linux kernel. The fix — `New-Object System.Text.UTF8Encoding $false` — was applied consistently to both the Docker startup script and the Traefik setup script, preventing any shebang-related failures.

### Root cause analysis of the SHA1 vs bcrypt authentication issue
The basicauth middleware received `admin:{SHA}7UwG4eMPTyOKgxOc7DtaRWWgork=` instead of a bcrypt hash. The reasoning was correct: bcrypt produces `$2y$10$...` which Docker Compose expands as environment variables. SHA1 produces `{SHA}base64` with no `$` characters. The tradeoff (weaker crypto, working integration) was identified and justified clearly.

### TLS verification with openssl was definitive
Rather than relying only on browser behavior or logs, the certificate was verified directly:
```
subject=CN = deviaaps.com
issuer=C = US, O = Let's Encrypt, CN = YR1
DNS:*.deviaaps.com, DNS:deviaaps.com
Verify return code: 0 (ok)
```
This gave unambiguous proof of certificate validity without requiring DNS to propagate.

### The SIGPIPE + pipefail diagnosis
The failing test 6.4 (`ACME provider NOT found in logs`) was a genuine head-scratcher. Direct SSH commands confirmed that `docker logs traefik 2>&1 | grep -i acme` returned 13 matching lines. But `grep -q "acme"` inside the bash script with `set -o pipefail` consistently failed. The correct diagnosis: `grep -q` exits after the first match, closing the pipe; `docker logs` receives SIGPIPE and exits with code 141; `pipefail` adopts the non-zero exit code from `docker logs` even though grep returned 0. The fix — capture logs into a variable with `--tail 500` before grepping — is clean and works correctly.

---

## What Was Difficult

### The Cloudflare error 9109 (IP restriction)
The Cloudflare API token `YOUR_CLOUDFLARE_API_TOKEN` had an IP restriction that did not include the VM's external IP `YOUR_VM_EXTERNAL_IP`. This caused ACME to fail immediately with error 9109 on every attempt. Three Traefik restarts were needed across two context windows while waiting for the user to fix the token in the Cloudflare dashboard. The failure mode was clear from the logs but required user action in an external system.

**Lesson:** When a token works from a development machine but not from a cloud VM, IP restrictions on API tokens are the first thing to check. This check should be a prerequisite listed prominently in the deploy script output.

### PowerShell 5.1 parser quirks with special characters
Two separate parser failures occurred in PowerShell scripts:
- **Em dash** (`—`, U+2014): The UTF-8 byte sequence `E2 80 94` is read by PS 5.1 as CP1252, where `0x94` = U+201D (right double quotation mark). PowerShell recognizes U+201D as a string terminator, prematurely closing string literals and producing cascading parse errors several lines later.
- **`&&` operator**: In certain multi-line gcloud command patterns, `&&` inside a double-quoted `--command=` argument triggered a parse error in PS 5.1 (which does not support `&&` as a pipeline chain operator, unlike PS 7+). The fix was pre-building the command string via concatenation.

Both bugs produced error messages pointing to lines far from the actual cause, making diagnosis slow.

### Silent ACME success — no log confirmation
After the user fixed the Cloudflare token, Traefik was restarted and logged `Testing certificate renew...` with no subsequent error. This looked like potential progress, but also looked like a possible hang. The definitive answer came from `openssl s_client` checking the actual certificate being served, not from logs. The ACME process succeeded silently — Traefik updated `acme.json` without logging an "Obtained certificate" message visible in the tail. This made it difficult to confirm success through logs alone.

### gcloud SSH command escaping on Windows
Complex `--command=` values with variables, quotes, and pipes behaved inconsistently when constructed inline in PowerShell. The reliable pattern was to use the Bash tool for commands with complex quoting, and to pre-build command strings as variables in PowerShell before passing them to gcloud.

---

## Bugs Found and Fixed

| Bug | Root Cause | Fix |
|---|---|---|
| Network `traefik_miseia-net` instead of `miseia-net` | Docker Compose project name prefix | Added `name: miseia-net` to network definition |
| Shebang `#!/bin/bash` invisible on Linux | UTF-8 BOM added by .NET 4.x `System.Text.Encoding.UTF8` | `New-Object System.Text.UTF8Encoding $false` |
| Dashboard auth broken (empty string) | bcrypt `$2y$...` expanded as env var by docker-compose | Switched to SHA1 htpasswd (`{SHA}base64`) |
| `&&` parse error in PowerShell 5.1 | PS 5.1 does not support `&&` as operator | Used `;` and pre-built command strings |
| Em dash caused premature string close | U+2014 → CP1252 `0x94` = U+201D closes PS5.1 strings | Replaced all `—` with ASCII `-` |
| Test 6.4 false negative with `pipefail` | `grep -q` SIGPIPE kills `docker logs`, pipefail adopts non-zero | Captured logs in variable with `--tail 500` |
| Cloudflare error 9109 | API token had IP restriction excluding VM IP | User removed restriction in Cloudflare dashboard |

---

## What We Would Do Differently

### Never store secrets in script variables
The Cloudflare token and dashboard password are hardcoded in `deploy_UbMV_Doker28_Traefik.ps1`. For a real production environment, these should come from GCP Secret Manager, environment variables set by the CI/CD system, or a local secrets file that is gitignored. The deploy script should read them with:
```powershell
$CF_TOKEN = gcloud secrets versions access latest --secret=cf-api-token
```

### Add a preflight check for Cloudflare token validity
Before creating the VM, the deploy script should validate the Cloudflare token:
```powershell
$cfCheck = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/user/tokens/verify" `
    -Headers @{Authorization = "Bearer $CF_TOKEN"}
if (-not $cfCheck.success) { Write-Error "CF token invalid"; exit 1 }
```
This would have caught the IP restriction issue in the deploy step rather than after the VM was running.

### Add a Traefik readiness check (not just Docker readiness)
The deploy polling checks `docker info` to confirm Docker is running, but does not check that Traefik is actually listening on port 443. A more complete readiness check:
```bash
curl -sk --max-time 5 https://localhost/ -o /dev/null && echo TRAEFIK_READY
```

### Pin `traefik/whoami` to a specific tag
`image: traefik/whoami` uses `latest` implicitly, which is a reproducibility risk. Should be pinned to a specific version such as `traefik/whoami:v1.10.3`.

### Use `--resolve` in all curl tests from the start
Several tests initially used `-H "Host: ..."` which bypasses SNI. Using `--resolve hostname:port:ip` from the start is cleaner, sets correct SNI, and avoids edge cases in TLS negotiation.

---

## Key Technical Learnings

1. **`set -o pipefail` + `grep -q` is a landmine.** Any pipeline where a downstream command exits early (like `grep -q` on first match, or `head -1`) can cause SIGPIPE on the upstream producer, which pipefail then elevates to a pipeline failure. The solution is to drain the pipe fully before processing, either with `--tail N` limits, `cat` to a file, or variable capture.

2. **PowerShell 5.1 reads files as CP1252 when there is no BOM.** Any file saved without explicit UTF-8 BOM encoding by a tool that defaults to UTF-8 will have its high-byte characters misinterpreted. This is especially dangerous with curly quotes and em dashes, which map to characters PowerShell treats as syntax (string delimiters).

3. **Docker Compose network naming is context-dependent.** The same `docker-compose.yml` deployed from different directories or with different `-p` flags will create differently-named networks. External tools (like Traefik) that reference network names by value must use the canonical `name:` property to guarantee consistency.

4. **Let's Encrypt ACME DNS-01 with Cloudflare is reliable but opaque.** When it works, there is minimal logging. When it fails, the error (9109, API validation failure, etc.) appears within 3 seconds of "Testing certificate renew...". The absence of an error after that window is a positive signal, but not a guarantee of success. `openssl s_client` against the live port is the definitive verification method.

5. **`gcloud compute ssh --command` on Windows passes through PuTTY/plink.** Complex shell syntax (pipes, escapes, heredocs) in `--command=` values does not always survive the Windows→plink→SSH chain intact. Simpler commands and pre-built strings are more reliable than inline complex pipelines.

---

## Final Metrics

| Metric | Value |
|---|---|
| Total files created | 5 (deploy.ps1, destroy.ps1, docker-compose.yml, test_traefik.ps1, test_traefik_vm.sh) |
| Total files created (this session addition) | 1 (README.md) + 1 (RETROSPECTIVE.md) |
| Automated tests | 30 |
| Tests passing | 30/30 (100%) |
| Certificate validity | 89 days (expires Sep 21, 2026) |
| Certificate SAN | `*.deviaaps.com`, `deviaaps.com` |
| Deploy time (VM to Traefik operational) | ~8 minutes |
| Bugs fixed during session | 7 |
| Cloudflare token fixes required (user action) | 2 (DNS A records + IP restriction removal) |
| Context windows used | 2 (session ran out of context once) |

---

*Retrospective written by Claude Sonnet 4.6 — 2026-06-23*
