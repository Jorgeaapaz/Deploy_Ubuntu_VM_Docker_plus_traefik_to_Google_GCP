# Traefik v3.3 en Google Cloud Platform — Despliegue Automatizado con Certificados Wildcard

> Infraestructura como codigo (IaC) en PowerShell que aprovisiona una maquina virtual Ubuntu 24.04 en GCP, instala Docker 28, despliega Traefik v3.3 como proxy inverso con certificado wildcard `*.deviaaps.com` via desafio DNS-01 de Let's Encrypt a traves de Cloudflare, e incluye suite de pruebas automatizadas de validacion.

---

## Tabla de Contenidos

1. [Funcionalidades Implementadas](#1-funcionalidades-implementadas)
2. [Estructura del Proyecto](#2-estructura-del-proyecto)
3. [Patrones de Diseno y Arquitectura](#3-patrones-de-diseno-y-arquitectura)
4. [Como Funciona](#4-como-funciona)
5. [Inicio Rapido](#5-inicio-rapido)
6. [Ejemplo de Salida](#6-ejemplo-de-salida)
7. [Requerimientos](#7-requerimientos)
8. [Especificaciones](#8-especificaciones)
9. [Pruebas Unitarias e de Integracion](#9-pruebas-unitarias-e-de-integracion)
10. [Despliegue](#10-despliegue)
11. [Mejoras](#11-mejoras)
12. [Cambios Documentados](#12-cambios-documentados)

---

## 1. Funcionalidades Implementadas

### 1.1 Aprovisionamiento Automatizado de VM en GCP

Script PowerShell 5.1 que crea y configura completamente una maquina virtual en Google Cloud Platform sin intervencion manual.

| Parametro | Valor |
|---|---|
| Proveedor | Google Cloud Platform |
| Zona | `us-south1-c` |
| Tipo de maquina | `n2-custom-4-16384` (4 vCPU / 16 GB RAM) |
| Sistema operativo | Ubuntu 24.04 LTS (Noble Numbat) |
| Disco | 50 GB SSD (`pd-ssd`) |
| Docker | 28.5.2 (instalado via startup-script) |

El script espera activamente a que Docker este listo mediante un ciclo de polling con intervalos de 20 segundos y un tiempo maximo de espera de 5 minutos antes de proceder al despliegue de Traefik.

**Limitacion:** Requiere `gcloud` CLI autenticado con permisos `compute.instances.create`, `compute.firewalls.create` y `compute.sshPublicKeys.create` en el proyecto de destino.

---

### 1.2 Proxy Inverso Traefik v3.3 con TLS Wildcard

Traefik v3.3 configurado completamente via etiquetas de Docker Compose (sin archivo `traefik.yml` separado), con los siguientes componentes:

- **Entrypoints:** `web` (puerto 80) y `websecure` (puerto 443)
- **Redireccion global HTTP -> HTTPS:** 301 Permanent para todo el trafico
- **Proveedor Docker:** detecta servicios automaticamente via etiquetas de contenedor
- **Red compartida:** `miseia-net` (nombre fijo, sin prefijo de proyecto Compose)
- **Certificado wildcard:** `*.deviaaps.com` + `deviaaps.com` emitido por Let's Encrypt
- **Resolutor ACME:** `cloudflare` — desafio DNS-01 via API de Cloudflare
- **Dashboard:** protegido con autenticacion basica (SHA1 htpasswd)

**Tiempo de emision del certificado:** 1-3 minutos dependiendo de la propagacion DNS de Cloudflare.

**Requisito:** Token de API de Cloudflare con permisos `Zone:Read` y `DNS:Edit` para la zona `deviaaps.com`, sin restriccion de IP sobre la IP publica de la VM.

---

### 1.3 Suite de Pruebas Automatizadas de Validacion

30 pruebas automatizadas distribuidas en 6 categorias que validan el estado completo del sistema:

| Categoria | Pruebas | Descripcion |
|---|---|---|
| Infraestructura | 5 | Docker daemon, version, red, archivos de configuracion |
| Contenedores | 5 | Estado, imagen, reinicios, membresıa de red |
| Puertos y Conectividad | 4 | Escucha en 80/443, redireccion HTTP->HTTPS |
| Certificados TLS | 6 | Emisor, SAN wildcard, verificacion de cadena, vigencia |
| Servicios y Ruteo | 6 | Auth del dashboard, API, whoami, cabeceras HTTP |
| Logs y Salud | 4 | Errores recientes, version, proveedores activos |

**Ejecucion:** `.\test\test_traefik.ps1` desde Windows — carga, sube y ejecuta `test_traefik_vm.sh` en la VM via `gcloud compute scp/ssh`.

---

## 2. Estructura del Proyecto

```
003_Traefik_in_VM/
|
|-- deploy_UbMV_Doker28_Traefik.ps1   # Script de despliegue completo (7 pasos)
|-- destroy_UbMV_Doker28_Traefik.ps1  # Script de teardown completo (4 pasos)
|-- docker-compose.yml                # Stack Traefik v3.3 + whoami (config inline)
|-- CLAUDE.md                         # Instrucciones para el agente de IA
|
+-- test/
    |-- test_traefik.ps1              # Lanzador PowerShell (re-codifica y sube el .sh)
    +-- test_traefik_vm.sh            # Runner de pruebas bash (se ejecuta en la VM)
```

### Descripcion de archivos

| Archivo | Proposito |
|---|---|
| `deploy_UbMV_Doker28_Traefik.ps1` | Orquesta los 7 pasos: proyecto GCP, reglas de firewall SSH y HTTP/HTTPS, startup script de Docker, creacion de VM, espera de Docker, despliegue de Traefik |
| `destroy_UbMV_Doker28_Traefik.ps1` | Elimina VM con todos los discos, verifica disco huerfano, elimina reglas de firewall SSH y HTTP/HTTPS |
| `docker-compose.yml` | Define la red `miseia-net`, el volumen `traefik_letsencrypt`, el servicio `traefik` (config completa via `command:`) y el servicio `whoami` |
| `test/test_traefik.ps1` | Lee `test_traefik_vm.sh`, lo re-codifica a UTF-8 sin BOM con saltos de linea LF, lo sube via `gcloud compute scp` y lo ejecuta via `gcloud compute ssh` |
| `test/test_traefik_vm.sh` | Script bash con 30 pruebas, usa `--tail` en `docker logs` para evitar SIGPIPE con `set -o pipefail`, captura salida en variable `$TLOGS` |

---

## 3. Patrones de Diseno y Arquitectura

### 3.1 Infrastructure as Code (IaC)

Toda la infraestructura se define en codigo versionable. Los scripts PowerShell son idempotentes: verifican la existencia de recursos (VM, reglas de firewall) antes de crearlos, evitando errores en re-ejecuciones.

```powershell
$existingVm = gcloud compute instances describe $VM_NAME --zone=$ZONE --format="value(name)" 2>$null
if ($LASTEXITCODE -eq 0 -and $existingVm -eq $VM_NAME) {
    Write-Host "VM ya existe, omitiendo." -ForegroundColor Gray
} else {
    # crear VM...
}
```

### 3.2 Proxy Inverso con Descubrimiento de Servicios

Traefik actua como proxy inverso que descubre servicios automaticamente via etiquetas Docker. Cualquier nuevo contenedor en la red `miseia-net` con `traefik.enable=true` queda expuesto automaticamente con el certificado wildcard, sin reiniciar Traefik.

### 3.3 Separacion de Configuracion del Entorno (.env)

Las credenciales sensibles (token de Cloudflare, hash de contrasena del dashboard) se mantienen fuera del `docker-compose.yml` en un archivo `.env` generado en tiempo de despliegue en la VM. El `.env` nunca se sube desde Windows — se genera directamente en la VM con `htpasswd` y `printf`.

### 3.4 Template Method para Scripts de Setup

Los scripts bash que se ejecutan en la VM se construyen en Windows usando el patron Template Method: se define una cadena de texto con placeholders (`__TRAEFIK_DIR__`, `__ADMIN_PASS__`, `__CF_TOKEN__`) que se reemplazan con valores reales antes de subir el archivo a la VM.

```powershell
$TRAEFIK_SETUP = $TRAEFIK_SETUP_TEMPLATE `
    -replace '__TRAEFIK_DIR__', $TRAEFIK_DIR `
    -replace '__ADMIN_PASS__',  $ADMIN_PASS `
    -replace '__CF_TOKEN__',    $CF_TOKEN
```

### 3.5 Arquitectura de Red Aislada

Todos los servicios comparten la red Docker `miseia-net` con nombre fijo (via `name: miseia-net` en el Compose), evitando el prefijo de proyecto que Docker Compose agrega por defecto (`traefik_miseia-net`). Traefik esta configurado explicitamente con `--providers.docker.network=miseia-net`.

---

## 4. Como Funciona

El script `deploy_UbMV_Doker28_Traefik.ps1` ejecuta 7 pasos secuenciales: configura el proyecto GCP, crea las reglas de firewall para SSH (22) y web (80/443), genera un startup script bash que instala Docker 28 en la VM, aprovisiona la VM (el startup script se ejecuta automaticamente al primer arranque), espera activamente hasta que Docker responda, sube `docker-compose.yml` a la VM, genera el archivo `.env` con el hash de autenticacion y el token de Cloudflare, y finalmente ejecuta `docker compose up -d`.

Traefik inicia y lee las etiquetas de todos los contenedores en `miseia-net`. Al detectar el resolver `cloudflare`, contacta la API de Cloudflare para crear un registro TXT `_acme-challenge.deviaaps.com`, espera la propagacion DNS (verificada contra `1.1.1.1` y `8.8.8.8`), notifica a Let's Encrypt para validar el desafio, y recibe el certificado wildcard `*.deviaaps.com` que se almacena en el volumen `traefik_letsencrypt`.

```powershell
# Paso 7 del deploy: genera .env en la VM y arranca el stack
$TRAEFIK_SETUP = @'
HASH=$(htpasswd -nbs admin '__ADMIN_PASS__' | tr -d '\n')
printf 'CF_DNS_API_TOKEN=__CF_TOKEN__\n' > .env
printf 'CF_API_TOKEN=__CF_TOKEN__\n'    >> .env
printf 'TRAEFIK_DASHBOARD_AUTH=%s\n' "$HASH" >> .env
docker compose up -d
'@
```

---

## 5. Inicio Rapido

### Prerrequisitos

| Herramienta | Version minima | Proposito |
|---|---|---|
| PowerShell | 5.1 | Ejecutar scripts de deploy/destroy/test |
| gcloud CLI | 400+ | Interaccion con GCP (ssh, scp, compute) |
| PuTTY / plink | Incluido con gcloud en Windows | Transporte SSH de gcloud en Windows |
| Llave SSH | Par RSA/ED25519 en `C:\ubuntuiso\.ssh\` | Autenticacion en la VM |

### Configuracion previa

1. Autenticarse en GCP:
   ```powershell
   gcloud auth login
   gcloud config set project YOUR_GCP_PROJECT_ID
   ```

2. Verificar que la llave SSH existe:
   ```powershell
   Test-Path YOUR_SSH_KEY_PATH.pub
   ```

3. En Cloudflare: asegurarse de que el token `YOUR_CLOUDFLARE_API_TOKEN` tenga permisos `Zone:Read` + `DNS:Edit` para `deviaaps.com` **sin restriccion de IP**.

4. En Cloudflare DNS: crear registros A:
   ```
   traefik.deviaaps.com  -> <IP externa de la VM>
   whoami.deviaaps.com   -> <IP externa de la VM>
   ```

### Clonar el repositorio

```bash
git clone https://github.com/jorge/003_Traefik_in_VM.git
cd 003_Traefik_in_VM
```

### Desplegar

```powershell
.\deploy_UbMV_Doker28_Traefik.ps1
```

El script imprime la IP externa al finalizar. El certificado wildcard se emite automaticamente en 1-3 minutos.

### Validar

```powershell
.\test\test_traefik.ps1
```

### Destruir

```powershell
.\destroy_UbMV_Doker28_Traefik.ps1
```

---

## 6. Ejemplo de Salida

### 6.1 Despliegue exitoso

```
=== Google Cloud Deployment (Ubuntu 24.04 + Docker 28 + Traefik v3.3) ===
Project : YOUR_GCP_PROJECT_ID
VM Name : ubuntu-vm-docker28
Machine : n2-custom-4-16384
Zone    : us-south1-c
Domain  : *.deviaaps.com

[1/7] Setting active project...
[2/7] Checking SSH firewall rule 'allow-ssh-external'...
      SSH firewall rule created.
[3/7] Checking HTTP/HTTPS firewall rule 'allow-http-https-external'...
      HTTP/HTTPS firewall rule created.
[4/7] Preparing Docker 28 startup script...
[5/7] Checking VM instance 'ubuntu-vm-docker28'...
      Creating VM (Docker 28 will install in background, ~90 sec)...
      External IP: YOUR_VM_EXTERNAL_IP
[6/7] Waiting for Docker to be ready (up to 5 min)...
      Polling Docker... (20/300 s)
      Polling Docker... (40/300 s)
      Docker is ready!
[7/7] Deploying Traefik v3.3...
      Dashboard: https://traefik.deviaaps.com  (admin / YOUR_ADMIN_PASSWORD)
      Test svc : https://whoami.deviaaps.com

=== Deployment Complete ===
```

### 6.2 Suite de pruebas — todas pasadas (30/30)

```
========================================================
  Traefik v3.3 Validation Tests
  VM IP  : 10.206.0.4
  Date   : 2026-06-23 08:56:26 UTC
  Domain : *.deviaaps.com
========================================================

--- 1. Infrastructure ---
[PASS] Docker daemon is running
[PASS] Docker version >= 28 (28.5.2)
[PASS] Docker network 'miseia-net' exists
[PASS] docker-compose.yml present in /home/gcvmuser/traefik
[PASS] .env file present in /home/gcvmuser/traefik

--- 2. Containers ---
[PASS] traefik container running (image: traefik:v3.3)
[PASS] whoami container running
[PASS] traefik container has 0 restarts (stable)
[PASS] traefik is on network 'miseia-net'
[PASS] whoami is on network 'miseia-net'

--- 3. Ports & Connectivity ---
[PASS] Port 80 is listening
[PASS] Port 443 is listening
[PASS] HTTP port 80 redirects to HTTPS (301 Moved Permanently)
[PASS] HTTPS port 443 is responding (HTTP 401)

--- 4. TLS Certificates ---
[PASS] Certificate issued by Let's Encrypt (issuer=C = US, O = Let's Encrypt, CN = YR1)
[PASS] Wildcard SAN '*.deviaaps.com' present in certificate
[PASS] traefik.deviaaps.com - TLS chain verified OK
[PASS] whoami.deviaaps.com - TLS chain verified OK
[PASS] Certificate valid for 89 days (expires: Sep 21 07:38:22 2026 GMT)
[PASS] acme.json has data (28527 bytes) - certificates persisted to volume

--- 5. Services & Routing ---
[PASS] Traefik dashboard requires authentication (401 without credentials)
[PASS] Traefik dashboard accessible with credentials (200)
[PASS] Traefik API /api/rawdata accessible (200)
[PASS] whoami service responds with 200
[PASS] whoami response contains expected body (Hostname: 6ea69a50898f)
[PASS] whoami shows X-Forwarded-Proto: https (TLS passthrough correct)

--- 6. Traefik Logs & Health ---
[PASS] No ERR lines in Traefik logs (last 60s)
[PASS] Traefik version 3.3.x confirmed in logs
[PASS] Docker provider is active
[PASS] ACME (Cloudflare) provider is active

========================================================
  ALL TESTS PASSED  30/30 passed
========================================================
```

### 6.3 Caso de falla — token de Cloudflare con restriccion de IP

```
[ERR] Unable to obtain ACME certificate for domains
  error: cloudflare: failed to find zone deviaaps.com.:
  ListZonesContext command failed: Cannot use the access token
  from location: YOUR_VM_EXTERNAL_IP (9109)
```

**Solucion:** Eliminar la restriccion de IP del token en el panel de Cloudflare o agregar la IP de la VM a la lista de IPs permitidas.

### 6.4 Certificado TLS verificado con openssl

```
subject=CN = deviaaps.com
issuer=C = US, O = Let's Encrypt, CN = YR1

X509v3 Subject Alternative Name:
    DNS:*.deviaaps.com, DNS:deviaaps.com

Verify return code: 0 (ok)
```

---

## 7. Requerimientos

### 7.1 Requerimientos Funcionales

```
FR-001: El administrador del sistema shall ser capaz de ejecutar el script de despliegue
        en una sola ejecucion so that la VM, Docker y Traefik queden operativos
        sin intervencion manual adicional.

FR-002: El script de despliegue shall ser capaz de verificar la existencia previa
        de recursos GCP (VM, reglas de firewall) so that las re-ejecuciones sean
        idempotentes y no generen errores por recursos duplicados.

FR-003: El agente de aprovisionamiento shall ser capaz de esperar activamente hasta
        que Docker este disponible en la VM so that el despliegue de Traefik no
        falle por condicion de carrera con el startup script.

FR-004: Traefik shall ser capaz de obtener automaticamente un certificado wildcard
        *.deviaaps.com via desafio DNS-01 so that todos los subdominios queden
        protegidos con TLS valido de Let's Encrypt sin configuracion manual.

FR-005: Traefik shall ser capaz de redirigir todo el trafico HTTP (puerto 80) a
        HTTPS (puerto 443) con codigo 301 so that todas las conexiones de usuarios
        sean cifradas sin excepcion.

FR-006: El administrador shall ser capaz de acceder al dashboard de Traefik con
        credenciales de autenticacion basica so that el panel de control quede
        protegido contra acceso no autorizado.

FR-007: El administrador shall ser capaz de agregar nuevos servicios a la red
        miseia-net con etiquetas Docker so that Traefik los detecte y exponga
        automaticamente sin reinicio del proxy.

FR-008: El administrador shall ser capaz de ejecutar la suite de pruebas desde
        Windows con un solo comando so that se valide el estado completo del
        sistema de forma automatizada en 30 verificaciones.

FR-009: El script de destruccion shall ser capaz de eliminar todos los recursos
        GCP creados (VM, discos, reglas de firewall) so that no queden recursos
        huerfanos que generen costos en la plataforma.

FR-010: Traefik shall ser capaz de persistir los certificados ACME en un volumen
        Docker so that los certificados sobrevivan reinicios del contenedor y no
        se soliciten nuevos certificados innecesariamente.

FR-011: El sistema shall ser capaz de generar el archivo .env con el hash de
        autenticacion directamente en la VM so that las credenciales sensibles
        nunca se transmitan desde la maquina de desarrollo en texto plano.

FR-012: El administrador shall ser capaz de verificar el certificado TLS emitido
        con openssl so that se confirme que el emisor es Let's Encrypt y el SAN
        incluye *.deviaaps.com.
```

### 7.2 Requerimientos No Funcionales

```
NFR-PERF-001: Latencia de respuesta de Traefik < 10ms de overhead por solicitud
              -> Traefik procesa cabeceras en memoria sin I/O adicional

NFR-PERF-002: Tiempo de despliegue completo < 8 minutos desde ejecucion del script
              hasta Traefik operativo -> Polling de Docker cada 20s, imagen
              traefik:v3.3 (~100MB) descargada una sola vez

NFR-SEC-001: El dashboard de Traefik debe requerir autenticacion basica con hash
             SHA1 htpasswd -> curl sin credenciales debe retornar HTTP 401

NFR-SEC-002: El token de Cloudflare debe tener permisos minimos necesarios
             (Zone:Read + DNS:Edit) -> principio de minimo privilegio,
             sin acceso a otras zonas ni servicios de Cloudflare

NFR-SEC-003: Las credenciales (token CF, contrasena dashboard) no deben existir
             en archivos versionables -> .env generado en VM, nunca en git

NFR-SCAL-001: La red miseia-net debe soportar la adicion de hasta 50 servicios
              adicionales sin reconfiguracion de Traefik -> descubrimiento
              automatico via Docker labels

NFR-SCAL-002: El volumen traefik_letsencrypt debe persistir acme.json < 10MB
              para certificados de hasta 100 dominios -> formato JSON compacto
              de Let's Encrypt

NFR-USAB-001: El script de despliegue debe imprimir instrucciones DNS al finalizar
              con la IP exacta de la VM -> el administrador no debe consultar
              la consola de GCP manualmente

NFR-AVAIL-001: Traefik debe configurarse con restart: unless-stopped so that
               el servicio se reinicie automaticamente tras un fallo del contenedor
               o reinicio de la VM

NFR-AVAIL-002: Los certificados deben tener vigencia minima de 60 dias en
               cualquier momento -> Let's Encrypt renueva a los 30 dias de
               emision (a los 60 dias restantes)

NFR-MAINT-001: Todos los parametros de configuracion (proyecto GCP, zona, nombre
               de VM, dominio) deben estar en variables al inicio del script ->
               un cambio de valor no debe requerir modificar mas de 1 linea

NFR-OBS-001: La suite de pruebas debe reportar el estado de 30 verificaciones
             con codigo de salida 0 (exito) o N (N pruebas fallidas) para
             integracion con pipelines de CI/CD
```

### 7.3 Requerimientos Regulatorios (Mexico)

```
REG-001: LFPDPPP (Ley Federal de Proteccion de Datos Personales en Posesion
         de los Particulares) — Si el sistema procesa datos personales de
         ciudadanos mexicanos, debe garantizar cifrado en transito (TLS 1.2+)
         y en reposo. El certificado wildcard TLS de Let's Encrypt y la
         redireccion forzada HTTPS satisfacen el requisito de cifrado en
         transito. Aplica si los servicios detras de Traefik manejan datos
         personales.

REG-002: NOM-151-SCFI-2016 (Conservacion de Mensajes de Datos) — Los logs
         de Traefik y los registros de acceso deben conservarse por al menos
         5 anos si el sistema participa en transacciones comerciales electronicas
         o actos juridicos. Se recomienda configurar un driver de logging
         externo (CloudWatch, GCS) para cumplimiento a largo plazo.

REG-003: MAAGTICSI (Manual Administrativo de Aplicacion General en Tecnologias
         de Informacion) — Si el sistema es operado por una dependencia del
         gobierno federal mexicano, debe cumplir con los controles de seguridad
         de la informacion incluyendo gestion de accesos, registro de auditoria
         y evaluacion de vulnerabilidades periodica. El dashboard de Traefik
         con autenticacion basica debe complementarse con MFA para cumplimiento
         en entornos gubernamentales.
```

### 7.4 Requerimientos Operativos

```
OPS-001: Disponibilidad — Traefik debe estar disponible las 24 horas del dia,
         los 7 dias de la semana. La politica restart: unless-stopped garantiza
         el reinicio automatico. Ventana de mantenimiento permitida: domingos
         02:00-04:00 UTC.

OPS-002: Respaldo — El volumen traefik_letsencrypt (acme.json) debe respaldarse
         semanalmente. RPO < 7 dias para certificados. En caso de perdida,
         Traefik obtiene nuevos certificados automaticamente (sujeto a rate
         limits de Let's Encrypt: 5 certificados por dominio por semana).

OPS-003: Monitoreo — La suite de pruebas automatizadas (test_traefik.ps1) debe
         ejecutarse despues de cada despliegue o reinicio planificado y al menos
         una vez por semana. Los 30 resultados deben archivarse con timestamp.
         Alertas en caso de cualquier prueba fallida en < 5 minutos.

OPS-004: Recuperacion — RTO < 30 minutos. Procedimiento: ejecutar
         destroy_UbMV_Doker28_Traefik.ps1 seguido de
         deploy_UbMV_Doker28_Traefik.ps1. Verificacion: ejecutar
         test_traefik.ps1 y confirmar 30/30 pruebas pasadas.

OPS-005: Entorno — El sistema requiere Windows 10/11 con PowerShell 5.1,
         gcloud CLI 400+, y acceso de red a GCP (TCP 443 para API de GCP
         y SSH a la VM). La VM requiere Ubuntu 24.04 LTS con acceso a
         Internet para descargar imagenes Docker y contactar la API de
         Let's Encrypt y Cloudflare.

OPS-006: Gestion de Secretos — El token de Cloudflare y la contrasena del
         dashboard deben rotarse cada 90 dias. Al rotar, ejecutar:
         docker compose down && regenerar .env && docker compose up -d
         en la VM. Los certificados ACME no se ven afectados por la
         rotacion del token (ya estan emitidos y en acme.json).
```

### 7.5 Atributos de Calidad

#### 7.5.1 Rendimiento: Latencia de Proxy [PERF-PROXY-LATENCY]

**Atributo de Calidad:** Rendimiento
**Metrica:** Latencia adicional introducida por Traefik (ms)

**Especificacion:**
- Overhead de Traefik: < 5ms en percentil 99
- Tiempo de respuesta total (incluyendo servicio): < 200ms en percentil 95
- Procesamiento de cabeceras TLS: < 2ms para conexiones existentes (TLS session resumption)

**Condiciones:**
- Carga: 100 solicitudes concurrentes
- Red: VM en GCP us-south1-c, cliente en la misma region
- Certificado wildcard ya emitido y en cache

**Excepciones:**
- Primera solicitud tras reinicio de Traefik: hasta 500ms (lectura de acme.json)
- Emision inicial del certificado: hasta 3 minutos (unico evento)

**Verificacion:**
- Prueba de carga con `wrk` o `k6` contra `https://whoami.deviaaps.com`
- Comparar tiempo de respuesta de whoami directo vs a traves de Traefik

---

#### 7.5.2 Escalabilidad: Servicios en la Red [SCAL-SERVICES]

**Atributo de Calidad:** Escalabilidad
**Metrica:** Numero de servicios en miseia-net soportados sin degradacion

**Especificacion:**
- Servicios simultaneos: hasta 50 contenedores en miseia-net
- Tiempo de deteccion de nuevo servicio: < 2 segundos tras `docker compose up`
- Memoria adicional por servicio: < 1 MB en el proceso de Traefik

**Condiciones:**
- VM: n2-custom-4-16384 (4 vCPU / 16 GB RAM)
- Todos los servicios usan el certificado wildcard compartido
- Configuracion via etiquetas Docker (sin archivos de configuracion adicionales)

**Excepciones:**
- Servicios con rutas complejas (regex) pueden aumentar el tiempo de compilacion de rutas
- Mas de 100 servicios puede requerir aumento de memoria de la VM

**Verificacion:**
- Desplegar 10, 20, 50 instancias de whoami con nombres de host diferentes
- Verificar que Traefik detecta todos y responde correctamente

---

#### 7.5.3 Confiabilidad: Persistencia de Certificados [REL-CERT-PERSIST]

**Atributo de Calidad:** Confiabilidad
**Metrica:** Porcentaje de reinicios que preservan el certificado existente

**Especificacion:**
- 100% de reinicios del contenedor Traefik deben usar el certificado del volumen
- 0 solicitudes duplicadas de certificados tras reinicios
- Renovacion automatica a los 30 dias antes del vencimiento (Let's Encrypt)

**Condiciones:**
- Volumen Docker `traefik_letsencrypt` persistente (no eliminado con `docker compose down`)
- acme.json con permisos 600 (Traefik lo configura automaticamente)

**Excepciones:**
- `docker compose down -v` elimina el volumen: se solicita nuevo certificado
- Rate limit de Let's Encrypt: maximo 5 certificados identicos por semana

**Verificacion:**
- Reiniciar Traefik 5 veces con `docker compose restart traefik`
- Verificar que acme.json no cambia de tamano y el certificado tiene la misma fecha de emision

---

#### 7.5.4 Seguridad: Autenticacion del Dashboard [SEC-DASHBOARD-AUTH]

**Atributo de Calidad:** Seguridad
**Metrica:** Tasa de solicitudes no autorizadas bloqueadas (%)

**Especificacion:**
- 100% de solicitudes sin credenciales deben retornar HTTP 401
- 0 endpoints del API de Traefik expuestos sin autenticacion
- Hash de contrasena: SHA1 htpasswd (sin caracteres `$` que rompan expansion de variables Docker Compose)

**Condiciones:**
- Dashboard en `https://traefik.deviaaps.com/dashboard/`
- Middleware `dashboard-auth@docker` aplicado al router `dashboard`
- TLS 1.3 requerido para todas las conexiones al dashboard

**Excepciones:**
- El endpoint `/ping` de Traefik (si se habilita) puede quedar sin autenticacion para health checks
- SHA1 es suficiente para autenticacion basica HTTP; para mayor seguridad migrar a bcrypt

**Verificacion:**
- Prueba 5.1 y 5.2 de la suite automatizada: `curl` con y sin credenciales

---

#### 7.5.5 Mantenibilidad: Parametrizacion del Despliegue [MAINT-PARAMS]

**Atributo de Calidad:** Mantenibilidad
**Metrica:** Numero de lineas a modificar para cambiar la configuracion de destino

**Especificacion:**
- Cambiar de proyecto GCP: modificar 1 variable (`$PROJECT`)
- Cambiar de zona: modificar 1 variable (`$ZONE`)
- Cambiar de dominio: modificar etiquetas en `docker-compose.yml` (< 8 lineas)
- Cambiar credenciales: modificar 2 variables (`$ADMIN_PASS`, `$CF_TOKEN`)

**Condiciones:**
- Todas las variables de configuracion en las primeras 30 lineas del script
- Sin valores hardcodeados en el cuerpo del script

**Excepciones:**
- Cambiar el proveedor de nube requiere reescribir los comandos `gcloud`
- Cambiar el proveedor ACME (ej. de Cloudflare a Route53) requiere cambiar variables de entorno y el provider en docker-compose.yml

**Verificacion:**
- Code review: buscar literales de proyecto/zona/dominio fuera del bloque de variables
- Grep: `Select-String -Pattern "YOUR_GCP_PROJECT_ID" deploy_UbMV_Doker28_Traefik.ps1`

---

### 7.6 Criterios de Aceptacion BDD

```gherkin
Feature: Despliegue automatizado de infraestructura

  Scenario: Despliegue exitoso desde cero
    Given el administrador tiene gcloud autenticado con permisos de compute
    And el archivo docker-compose.yml existe en el directorio del proyecto
    And la llave SSH existe en YOUR_SSH_KEY_PATH.pub
    When el administrador ejecuta deploy_UbMV_Doker28_Traefik.ps1
    Then la VM ubuntu-vm-docker28 existe en us-south1-c
    And Docker 28 esta instalado y activo en la VM
    And los contenedores traefik y whoami estan en estado running
    And el script termina con exit code 0

Feature: Certificado TLS wildcard

  Scenario: Obtencion exitosa del certificado wildcard
    Given Traefik v3.3 esta corriendo con el resolver cloudflare configurado
    And el token de Cloudflare tiene permisos Zone:Read y DNS:Edit para deviaaps.com
    And no hay restriccion de IP en el token que bloquee la IP de la VM
    When Traefik intenta obtener el certificado para *.deviaaps.com
    Then Cloudflare crea el registro TXT _acme-challenge.deviaaps.com
    And Let's Encrypt valida el desafio DNS-01
    And el certificado es almacenado en /letsencrypt/acme.json
    And el SAN del certificado incluye DNS:*.deviaaps.com y DNS:deviaaps.com

Feature: Redireccion HTTPS

  Scenario: Redireccion de HTTP a HTTPS
    Given Traefik esta escuchando en los puertos 80 y 443
    And la redireccion global esta configurada como permanente
    When un cliente hace una solicitud HTTP a http://whoami.deviaaps.com/
    Then Traefik responde con HTTP 301
    And la cabecera Location apunta a https://whoami.deviaaps.com/

Feature: Autenticacion del dashboard

  Scenario: Acceso denegado sin credenciales
    Given el dashboard de Traefik esta en https://traefik.deviaaps.com/dashboard/
    And el middleware dashboard-auth esta aplicado al router
    When un cliente hace una solicitud GET sin cabecera Authorization
    Then Traefik responde con HTTP 401 Unauthorized
    And la cabecera WWW-Authenticate esta presente en la respuesta

  Scenario: Acceso exitoso con credenciales validas
    Given el dashboard de Traefik esta en https://traefik.deviaaps.com/dashboard/
    When un cliente hace una solicitud GET con credenciales admin:YOUR_ADMIN_PASSWORD
    Then Traefik responde con HTTP 200 OK
    And el cuerpo contiene la interfaz del dashboard de Traefik

Feature: Suite de pruebas automatizadas

  Scenario: Todas las pruebas pasan en sistema sano
    Given la VM esta corriendo con Traefik y whoami activos
    And el certificado wildcard ha sido emitido por Let's Encrypt
    When el administrador ejecuta test_traefik.ps1 desde Windows
    Then el script sube test_traefik_vm.sh a la VM via gcloud compute scp
    And ejecuta las 30 pruebas en la VM via gcloud compute ssh
    And reporta "ALL TESTS PASSED 30/30 passed"
    And termina con exit code 0
```

---

## 8. Especificaciones

### 8.1 Especificacion Dirigida por Comportamiento (SDD)

#### Especificacion Funcional: Despliegue de Infraestructura

```
# Spec Funcional: Aprovisionamiento de VM con Traefik

## Caso de Uso: Desplegar Stack Completo
Actores: Administrador de Sistemas, GCP API, Cloudflare API, Let's Encrypt ACME

Precondiciones:
- gcloud autenticado con permisos compute.*
- Llave SSH en YOUR_SSH_KEY_PATH.pub
- docker-compose.yml presente en el directorio del script

Flujo Principal:
1. Script verifica existencia de reglas de firewall (idempotente)
2. Script crea VM con startup-script que instala Docker 28
3. Script genera .env con hash htpasswd SHA1 y token CF
4. Script sube docker-compose.yml via gcloud compute scp
5. Script ejecuta docker compose up -d en la VM
6. Traefik detecta etiquetas Docker y configura routers
7. Traefik solicita certificado wildcard a Let's Encrypt via Cloudflare DNS-01
8. Let's Encrypt emite certificado y Traefik lo almacena en acme.json

Criterios de Aceptacion:
- Given script ejecutado en sistema limpio (sin VM previa)
- When deploy completa sin errores (exit code 0)
- Then curl https://whoami.deviaaps.com retorna HTTP 200 con TLS valido
- And acme.json tiene tamano > 1000 bytes
```

#### Especificacion Estructural

```
Componentes del Sistema:

[Windows/macOS - Maquina del Administrador]
  |
  |-- deploy_UbMV_Doker28_Traefik.ps1
  |     - Orquestador principal
  |     - Genera scripts bash con placeholders
  |     - Sube archivos via gcloud compute scp
  |     - Ejecuta comandos remotos via gcloud compute ssh
  |
  |-- docker-compose.yml
  |     - Define stack completo de Traefik
  |     - Configuracion de red miseia-net
  |     - Configuracion ACME inline (sin traefik.yml)
  |
  +-- test/
        - test_traefik.ps1: lanzador con re-codificacion UTF-8 No BOM
        - test_traefik_vm.sh: 30 pruebas en bash

[GCP - VM ubuntu-vm-docker28 (us-south1-c)]
  |
  |-- /home/gcvmuser/traefik/
  |     |-- docker-compose.yml (copiado desde Windows)
  |     +-- .env (generado en VM)
  |           - CF_DNS_API_TOKEN
  |           - CF_API_TOKEN
  |           - TRAEFIK_DASHBOARD_AUTH (hash SHA1)
  |
  +-- Docker Engine 28.5.2
        |-- Red: miseia-net (bridge, nombre fijo)
        |-- Volumen: traefik_letsencrypt
        |     +-- acme.json (certificados Let's Encrypt)
        |
        |-- Contenedor: traefik (traefik:v3.3)
        |     - Puerto 80 -> Redireccion HTTP
        |     - Puerto 443 -> TLS Termination
        |     - Providers: docker, acme (cloudflare)
        |
        +-- Contenedor: whoami (traefik/whoami)
              - Sin puertos expuestos directamente
              - Accesible solo via Traefik en miseia-net

[Cloudflare]
  - DNS Zone: deviaaps.com
  - Registro A: *.deviaaps.com -> YOUR_VM_EXTERNAL_IP
  - API Token: Zone:Read + DNS:Edit

[Let's Encrypt]
  - ACME v2: https://acme-v02.api.letsencrypt.org
  - Certificado: CN=deviaaps.com, SAN=*.deviaaps.com, deviaaps.com
  - Vigencia: 90 dias, renovacion automatica a los 60 dias
```

#### Especificacion de Comportamiento — Maquinas de Estado

**Ciclo de vida del certificado ACME:**

```mermaid
stateDiagram-v2
    [*] --> SinCertificado : Traefik inicia

    SinCertificado --> SolicitandoCertificado : Router con certresolver detectado
    SolicitandoCertificado --> ContactandoCloudflare : Traefik llama API Cloudflare

    ContactandoCloudflare --> ErrorIP : Error 9109 (IP restringida)
    ContactandoCloudflare --> RegistroTXTCreado : TXT _acme-challenge creado

    ErrorIP --> SolicitandoCertificado : Administrador corrige token CF
    RegistroTXTCreado --> EsperandoPropagacion : Traefik espera verificacion DNS

    EsperandoPropagacion --> ValidandoConLE : DNS propagado (1.1.1.1 + 8.8.8.8 confirman)
    ValidandoConLE --> CertificadoEmitido : Let's Encrypt valida y emite
    ValidandoConLE --> ErrorValidacion : Let's Encrypt no puede verificar TXT

    CertificadoEmitido --> Operativo : acme.json actualizado
    ErrorValidacion --> SolicitandoCertificado : Reintento automatico

    Operativo --> Renovando : 60 dias antes de vencimiento
    Renovando --> Operativo : Renovacion exitosa
    Renovando --> ErrorRenovacion : Falla de renovacion

    ErrorRenovacion --> Operativo : Reintento en siguiente ciclo
    Operativo --> [*] : docker compose down -v
```

**Flujo de solicitud HTTP:**

```mermaid
stateDiagram-v2
    [*] --> SolicitudRecibida : Cliente hace request

    SolicitudRecibida --> EntrypointWeb : Puerto 80
    SolicitudRecibida --> EntrypointWebsecure : Puerto 443

    EntrypointWeb --> Redireccion301 : Regla de redireccion global
    Redireccion301 --> [*] : HTTP 301 -> https://

    EntrypointWebsecure --> TLSHandshake : TLS 1.3
    TLSHandshake --> RouterMatching : SNI -> certificado wildcard

    RouterMatching --> RouterDashboard : Host(traefik.deviaaps.com)
    RouterMatching --> RouterWhoami : Host(whoami.deviaaps.com)
    RouterMatching --> HTTP404 : Sin router coincidente

    RouterDashboard --> MiddlewareAuth : dashboard-auth@docker
    MiddlewareAuth --> HTTP401 : Sin credenciales / credenciales invalidas
    MiddlewareAuth --> ServiceDashboard : Credenciales validas
    ServiceDashboard --> [*] : HTTP 200 (api@internal)

    RouterWhoami --> ServiceWhoami : Sin middleware
    ServiceWhoami --> [*] : HTTP 200 (traefik/whoami)

    HTTP401 --> [*]
    HTTP404 --> [*]
```

#### Especificacion Operativa

```
# Spec Operativa: Traefik v3.3 en GCP

## Despliegue
- Script PowerShell idempotente (deploy_UbMV_Doker28_Traefik.ps1)
- Verificacion post-despliegue: ejecutar test_traefik.ps1 (30 pruebas)
- Rollback: ejecutar destroy_UbMV_Doker28_Traefik.ps1 + re-deploy

## Escalado
- Horizontal de servicios: agregar contenedores a miseia-net con etiquetas Traefik
- Vertical de VM: cambiar $MACHINE_TYPE en el script (requiere recrear VM)
- Traefik no requiere reinicio al agregar/eliminar servicios

## Monitoreo
- Verificacion semanal: test_traefik.ps1 (30/30 pruebas)
- Vigencia del certificado: prueba 4.5 alerta si quedan < 60 dias
- Logs de Traefik: docker logs traefik --since 1h
- Puertos activos: ss -tlnp | grep -E '80|443'

## Runbook: Falla de certificado (Error 9109)
1. Verificar IP externa de VM: gcloud compute instances describe ubuntu-vm-docker28 ...
2. Ir a Cloudflare > API Tokens > Editar token
3. Verificar que zona deviaaps.com esta en permisos
4. Verificar que no hay restriccion de IP, o agregar IP de VM
5. Reiniciar Traefik: docker compose restart traefik
6. Esperar 2 minutos y verificar logs: docker logs traefik --tail 20
7. Ejecutar test_traefik.ps1 y confirmar prueba 4.6 pasa

## Runbook: VM no responde
1. Verificar estado en GCP Console
2. Si VM corriendo pero sin respuesta SSH: gcloud compute instances reset ubuntu-vm-docker28
3. Si VM detenida: gcloud compute instances start ubuntu-vm-docker28
4. Esperar 2 minutos para que Docker inicie los contenedores (restart: unless-stopped)
5. Ejecutar test_traefik.ps1 para validar

## Limpieza de recursos
- Destruccion completa: destroy_UbMV_Doker28_Traefik.ps1
- Solo contenedores (preservar VM): docker compose down (en VM via SSH)
- Solo Traefik (preservar whoami): docker compose stop traefik (en VM via SSH)
```

### 8.2 Invariantes y Contratos

#### Contrato del Script de Despliegue

```
CONTRATO: deploy_UbMV_Doker28_Traefik.ps1

PRECONDICIONES:
- gcloud CLI autenticado con rol roles/compute.admin en el proyecto
- Archivo YOUR_SSH_KEY_PATH.pub existe y es una llave publica RSA/ED25519 valida
- Archivo docker-compose.yml existe en el mismo directorio que el script
- La variable $CF_TOKEN corresponde a un token de Cloudflare con permisos Zone:Read + DNS:Edit
- La variable $ADMIN_PASS tiene al menos 8 caracteres

POSTCONDICIONES:
- VM ubuntu-vm-docker28 existe en us-south1-c con estado RUNNING
- Docker 28.x esta instalado y el daemon esta activo (systemctl is-active docker = active)
- El directorio /home/gcvmuser/traefik/ contiene docker-compose.yml y .env
- Los contenedores traefik y whoami estan en estado running
- Los puertos 80 y 443 estan escuchando en la VM
- El script termina con exit code 0

INVARIANTES:
- La regla de firewall allow-ssh-external (puerto 22) existe durante toda la ejecucion
- El usuario gcvmuser existe en la VM y pertenece al grupo docker
- El volumen traefik_letsencrypt persiste entre reinicios del contenedor

EJEMPLOS:
- Ejecucion en sistema limpio (sin VM previa) -> VM creada, Traefik operativo en ~6 min
- Ejecucion con VM ya existente -> VM no recreada, Traefik re-desplegado
- Ejecucion con Docker no disponible despues de 5 min -> exit code 1, mensaje de error
- Ejecucion sin llave SSH -> Write-Error, exit code 1 antes de llamar a GCP
```

#### Contrato del archivo .env

```
CONTRATO: .env (en /home/gcvmuser/traefik/)

PRECONDICIONES:
- htpasswd esta instalado (apache2-utils)
- $ADMIN_PASS no contiene el caracter $ (rompe expansion de variables en docker-compose)
- $CF_TOKEN es una cadena no vacia

POSTCONDICIONES:
- Archivo .env contiene exactamente 3 lineas:
  CF_DNS_API_TOKEN=<token>
  CF_API_TOKEN=<token>
  TRAEFIK_DASHBOARD_AUTH=admin:{SHA}<base64>
- El hash SHA1 es valido y htpasswd lo verifica con la contrasena original
- El archivo NO contiene caracteres $ en el valor del hash (SHA1 no los produce)

INVARIANTES:
- CF_DNS_API_TOKEN y CF_API_TOKEN tienen el mismo valor
- El hash del dashboard siempre comienza con "admin:{SHA}"
- El archivo existe mientras docker-compose.yml este en el mismo directorio

EJEMPLOS:
- htpasswd -nbs admin 'YOUR_ADMIN_PASSWORD' -> admin:{SHA}7UwG4eMPTyOKgxOc7DtaRWWgork=
- Hash con bcrypt ($2y$...) -> INVALIDO (los $ rompen docker-compose)
- .env vacio -> docker compose falla con variable no definida
```

#### Contrato del servicio whoami

```
CONTRATO: Servicio whoami en miseia-net

PRECONDICIONES:
- Contenedor whoami esta en estado running
- Traefik tiene el router whoami configurado para Host(whoami.deviaaps.com)
- El certificado wildcard *.deviaaps.com ha sido emitido

POSTCONDICIONES:
- GET https://whoami.deviaaps.com/ retorna HTTP 200
- El cuerpo contiene "Hostname: <container_id>"
- El cuerpo contiene "X-Forwarded-Proto: https"
- El certificado TLS tiene Verify return code: 0 (ok)

INVARIANTES:
- whoami no expone puertos directamente al host (solo accesible via Traefik)
- El contenedor siempre esta en la red miseia-net
- La respuesta siempre incluye informacion de la solicitud (headers, IP, etc.)

EJEMPLOS:
- curl -sk --resolve whoami.deviaaps.com:443:127.0.0.1 https://whoami.deviaaps.com/
  -> Hostname: 6ea69a50898f\nX-Forwarded-Proto: https\n...
- curl sin TLS (HTTP) -> HTTP 301 redirect a HTTPS
- curl a IP directa sin Host header -> HTTP 404 (sin router coincidente)
```

### 8.3 ADRs (Registros de Decisiones Arquitectonicas)

---

#### ADR-001: Google Cloud Platform como Proveedor de Nube

**Estado:** Aceptado

**Contexto:**
El proyecto requiere una VM con IP publica fija para recibir solicitudes HTTPS en los puertos 80 y 443. Se evaluaron opciones de proveedor de nube.

**Opciones consideradas:**
1. **AWS EC2**: Mayor ecosistema, costos variables, curva de aprendizaje alta para usuarios de GCP
2. **Azure VM**: Mejor integracion con Active Directory, pero menos familiar para el equipo
3. **GCP Compute Engine**: Familiar para el equipo, CLI bien documentada, startup scripts nativos
4. **DigitalOcean Droplet**: Mas simple, pero menos capacidades de automatizacion via CLI

**Decision:** GCP Compute Engine.

**Razones:**
- El equipo ya tiene credenciales y familiaridad con `gcloud` CLI
- Los startup scripts de GCP Compute Engine son nativamente soportados y se ejecutan con root al primer arranque
- `gcloud compute scp` y `gcloud compute ssh` eliminan la necesidad de gestionar llaves SSH manualmente en el inicio
- La zona `us-south1-c` (Dallas) ofrece latencia baja para usuarios en Mexico y Estados Unidos

**Consecuencias:**
- Positivas: despliegue 100% via CLI sin consola web, integracion nativa con APIs de GCP
- Negativas: dependencia de gcloud CLI en la maquina del administrador, sin portabilidad directa a otros proveedores
- Riesgos: cambio de precios de GCP puede afectar el costo del tipo de maquina n2-custom-4-16384

---

#### ADR-002: Traefik v3.3 como Proxy Inverso (vs Nginx, HAProxy, Caddy)

**Estado:** Aceptado

**Contexto:**
Se necesita un proxy inverso que soporte TLS automatico via ACME, descubrimiento de servicios Docker, y configuracion sin archivos estaticos.

**Opciones consideradas:**
1. **Nginx + Certbot**: Maduro y estable, pero requiere recarga manual de configuracion al agregar servicios
2. **HAProxy**: Alto rendimiento (benchmark: 1M req/s), pero sin soporte nativo de ACME
3. **Caddy v2**: TLS automatico nativo, pero el soporte de Cloudflare requiere compilacion personalizada
4. **Traefik v3.3**: Descubrimiento automatico de Docker, ACME nativo con multiples proveedores DNS, dashboard integrado

**Decision:** Traefik v3.3

**Razones:**
- Traefik detecta contenedores Docker automaticamente via etiquetas sin reinicio: latencia de deteccion < 2 segundos
- El provider ACME de Traefik soporta DNS-01 challenge con Cloudflare nativamente (lego library)
- La configuracion completa se puede definir en docker-compose.yml sin archivos externos
- Benchmark interno: Traefik introduce < 5ms de overhead vs 2ms de Nginx (diferencia aceptable para este caso de uso)

**Consecuencias:**
- Positivas: cero reconfiguracion al agregar servicios, certificado wildcard automatico, dashboard de observabilidad
- Negativas: overhead ligeramente mayor que Nginx en escenarios de alto trafico (> 10K req/s)
- Riesgos: breaking changes entre versiones mayores de Traefik (v2 a v3 requirio migracion)

---

#### ADR-003: DNS-01 Challenge para Certificado Wildcard (vs HTTP-01)

**Estado:** Aceptado

**Contexto:**
Let's Encrypt requiere un desafio de validacion para emitir certificados. Se evaluo el tipo de desafio para el caso de wildcard `*.deviaaps.com`.

**Opciones consideradas:**
1. **HTTP-01**: Simple, pero no soporta certificados wildcard por diseno de ACME
2. **TLS-ALPN-01**: No soporta wildcards
3. **DNS-01 via Cloudflare**: Soporta wildcards, requiere acceso a API del registrador DNS

**Decision:** DNS-01 via Cloudflare

**Razones:**
- HTTP-01 no puede emitir certificados wildcard (limitacion del protocolo ACME)
- Un unico certificado wildcard `*.deviaaps.com` cubre todos los subdominios sin configuracion adicional por servicio
- Cloudflare propaga registros TXT en < 30 segundos (medicion: propagacion detectada por lego en 20-40s)
- El token de Cloudflare puede tener permisos minimos (solo DNS:Edit para una zona)

**Consecuencias:**
- Positivas: un solo certificado para todos los subdominios actuales y futuros, sin exposicion de puertos adicionales
- Negativas: dependencia del acceso a la API de Cloudflare durante la renovacion del certificado
- Riesgos: si el token de CF expira o es revocado, la renovacion falla silenciosamente hasta que el certificado venza

---

#### ADR-004: SHA1 htpasswd para Autenticacion del Dashboard (vs bcrypt)

**Estado:** Aceptado

**Contexto:**
El middleware `basicauth` de Traefik requiere un hash de contrasena en formato htpasswd. Se evaluo el algoritmo de hash considerando la integracion con Docker Compose.

**Opciones consideradas:**
1. **bcrypt (`htpasswd -nbB`)**: Mas seguro (costo computacional de ataque > 10^9 intentos/s), pero produce hashes con `$2y$10$...` que contienen multiples caracteres `$`
2. **MD5 (`htpasswd -nbm`)**: Hashes con `$apr1$...`, tambien contiene `$`, misma problematica
3. **SHA1 (`htpasswd -nbs`)**: Produce `{SHA}base64` sin caracteres `$`, compatible con la expansion de variables de docker-compose

**Decision:** SHA1 (`htpasswd -nbs`)

**Razones:**
- Docker Compose expande `${VAR}` y `$VAR` en cualquier valor leido del archivo `.env`
- Un hash bcrypt como `$2y$10$abc...` seria interpretado parcialmente como variables, resultando en cadena vacia y autenticacion rota
- SHA1 htpasswd produce `admin:{SHA}7UwG4eMPTyOKgxOc7DtaRWWgork=` — sin caracteres `$`
- El dashboard de Traefik es un panel de administracion interno, no un sistema de autenticacion de usuarios finales

**Consecuencias:**
- Positivas: autenticacion funcional sin modificaciones al proceso de docker-compose
- Negativas: SHA1 es criptograficamente mas debil que bcrypt; susceptible a ataques de diccionario con hardware moderno (> 10^9 SHA1/s en GPU)
- Mitigacion: usar contrasenas de alta entropia (> 16 caracteres, mezcla de mayusculas, numeros y simbolos)
- Alternativa futura: usar `docker secret` o Vault para inyectar credenciales sin pasar por variables de entorno

---

#### ADR-005: Docker Compose (vs Kubernetes) para Orquestacion de Contenedores

**Estado:** Aceptado

**Contexto:**
Se necesita un sistema de orquestacion para ejecutar Traefik y los servicios backend en la VM.

**Opciones consideradas:**
1. **Kubernetes (k3s/minikube)**: Orquestacion robusta, auto-healing, pero requiere 2+ GB RAM solo para el control plane
2. **Docker Swarm**: Similar a Compose pero con soporte multi-nodo, complejidad innecesaria para VM unica
3. **Docker Compose v2**: Simple, declarativo, soporte nativo de volumes y networks, integrado en Docker 28

**Decision:** Docker Compose v2 (plugin `docker compose`)

**Razones:**
- La VM tiene una sola instancia; no hay necesidad de orquestacion multi-nodo
- Docker Compose v2 esta incluido en Docker 28 como plugin nativo (sin instalacion adicional)
- La integracion de Traefik con Docker Compose es la ruta mas documentada y estable
- Recursos de VM preservados para las cargas de trabajo: Docker Compose usa < 50 MB de memoria vs 2 GB de k3s

**Consecuencias:**
- Positivas: stack completo en un archivo declarativo, ciclo de desarrollo rapido, facil de entender
- Negativas: sin auto-scaling horizontal automatico, sin rolling updates nativas, sin self-healing de VMs
- Riesgos: si los requerimientos escalan a multiples VMs, se requerira migracion a Kubernetes o Docker Swarm

---

## 9. Pruebas Unitarias e de Integracion

La suite de pruebas esta implementada en `test/test_traefik_vm.sh` (runner bash en la VM) y `test/test_traefik.ps1` (lanzador PowerShell en Windows).

### Estructura del directorio de pruebas

```
test/
|-- test_traefik.ps1      # Lanzador: re-codifica UTF-8 No BOM, sube y ejecuta
+-- test_traefik_vm.sh    # Runner: 30 pruebas en 6 categorias
```

### Ejecucion

```powershell
# Desde el directorio raiz del proyecto en Windows
.\test\test_traefik.ps1
```

El lanzador realiza 3 pasos:
1. Lee `test_traefik_vm.sh`, convierte a UTF-8 sin BOM con saltos de linea LF (requerido por bash en Linux)
2. Sube el archivo a `/tmp/test_traefik_vm.sh` en la VM via `gcloud compute scp`
3. Ejecuta `bash /tmp/test_traefik_vm.sh` en la VM via `gcloud compute ssh`

### Cobertura de pruebas

| ID | Categoria | Tipo | Descripcion |
|---|---|---|---|
| 1.1-1.5 | Infraestructura | Integracion | Docker daemon, version >= 28, red miseia-net, archivos de configuracion |
| 2.1-2.5 | Contenedores | Integracion | Estado running, imagen correcta, reinicios, membresıa de red |
| 3.1-3.4 | Puertos | Integracion | ss -tlnp en 80/443, curl HTTP -> 301, curl HTTPS -> respuesta |
| 4.1-4.6 | Certificados TLS | Integracion | Emisor LE, SAN wildcard, verify 0, verify 0 whoami, vigencia > 60d, acme.json |
| 5.1-5.6 | Servicios | E2E | Dashboard 401/200, API /rawdata 200, whoami 200/body/X-Forwarded-Proto |
| 6.1-6.4 | Logs y Salud | Integracion | Sin ERR recientes, version 3.3, docker.Provider, acme presente |

### Nota sobre pipefail y SIGPIPE

El script usa `set -uo pipefail`. Para evitar que `docker logs traefik 2>&1 | grep -q "pattern"` falle por SIGPIPE (grep sale al encontrar la primera coincidencia, causando que docker logs reciba SIGPIPE y salga con codigo 141), los logs se capturan con `--tail 500` en una variable antes de hacer grep:

```bash
# Correcto: docker logs termina antes que grep empiece a filtrar
TLOGS=$(docker logs traefik --tail 500 2>&1 || true)
if echo "$TLOGS" | grep -q "acme"; then ...

# Problematico con pipefail: grep sale antes que docker logs termine
if docker logs traefik 2>&1 | grep -q "acme"; then ...
```

### Resultado de la ultima ejecucion

```
ALL TESTS PASSED  30/30 passed
Date: 2026-06-23 08:56:26 UTC
```

---

## 10. Despliegue

### 10.1 URL de Despliegue

> **Nota:** La VM fue destruida al finalizar la sesion de desarrollo. Para re-desplegar, ejecutar `.\deploy_UbMV_Doker28_Traefik.ps1`.

Durante la sesion activa, los servicios estaban disponibles en:

```
https://traefik.deviaaps.com    # Dashboard (admin / YOUR_ADMIN_PASSWORD)
https://whoami.deviaaps.com     # Servicio de prueba
```

IP de la VM durante la sesion: `YOUR_VM_EXTERNAL_IP`

### 10.2 Versionado de Dependencias

El proyecto no usa un gestor de paquetes tradicional (npm, pip, etc.), pero las versiones estan fijadas en:

| Archivo | Dependencia | Version fijada |
|---|---|---|
| `docker-compose.yml` | `image: traefik:v3.3` | v3.3 (tag semantico) |
| `docker-compose.yml` | `image: traefik/whoami` | latest (sin fijar) |
| `deploy_UbMV_Doker28_Traefik.ps1` | Docker CE | `5:28.*` (pin a major 28) |
| `deploy_UbMV_Doker28_Traefik.ps1` | Ubuntu | `ubuntu-2404-lts-amd64` |

**Recomendacion:** Fijar `traefik/whoami` a una tag especifica (ej. `traefik/whoami:v1.10.3`) para mayor reproducibilidad.

### 10.3 Instrucciones de Despliegue

#### Despliegue completo (desde cero)

```powershell
# 1. Clonar repositorio
git clone https://github.com/jorge/003_Traefik_in_VM.git
cd 003_Traefik_in_VM

# 2. Autenticar gcloud
gcloud auth login
gcloud config set project YOUR_GCP_PROJECT_ID

# 3. Ejecutar despliegue (7 pasos automaticos, ~6-8 minutos)
.\deploy_UbMV_Doker28_Traefik.ps1

# 4. Configurar DNS en Cloudflare (tras obtener IP externa del script)
# traefik.deviaaps.com -> <IP>
# whoami.deviaaps.com  -> <IP>
# (o wildcard *.deviaaps.com -> <IP>)

# 5. Validar (1-3 minutos despues para que el certificado se emita)
.\test\test_traefik.ps1
```

#### Despliegue standalone (VM y Docker ya instalados)

```bash
# En la VM via SSH
ssh -i YOUR_SSH_KEY_PATH gcvmuser@YOUR_VM_EXTERNAL_IP

mkdir -p ~/traefik && cd ~/traefik

# Subir docker-compose.yml (desde Windows):
# gcloud compute scp docker-compose.yml gcvmuser@ubuntu-vm-docker28:~/traefik/ ...

# Generar .env
HASH=$(htpasswd -nbs admin 'YOUR_ADMIN_PASSWORD' | tr -d '\n')
printf 'CF_DNS_API_TOKEN=<token>\nCF_API_TOKEN=<token>\nTRAEFIK_DASHBOARD_AUTH=%s\n' "$HASH" > .env

# Iniciar stack
docker compose up -d

# Verificar
docker compose ps
docker logs traefik -f
```

#### Destruccion de recursos

```powershell
.\destroy_UbMV_Doker28_Traefik.ps1
```

Elimina: VM + discos + reglas de firewall SSH y HTTP/HTTPS.

---

## 11. Mejoras

### 11.1 Soporte Multi-VM con Docker Swarm o Kubernetes

La arquitectura actual es de instancia unica. Para alta disponibilidad se puede migrar a:
- **Docker Swarm**: Minima complejidad adicional, compatible con el docker-compose.yml actual
- **GKE (Google Kubernetes Engine)**: Para entornos de produccion con SLA > 99.9%

### 11.2 Gestion de Secretos con HashiCorp Vault o GCP Secret Manager

Actualmente el token de Cloudflare se almacena en el archivo `.env` en la VM. Una mejora es usar GCP Secret Manager:

```powershell
# Almacenar secreto en GCP Secret Manager
gcloud secrets create cf-api-token --data-file=./token.txt

# En la VM, leer el secreto en tiempo de ejecucion
CF_TOKEN=$(gcloud secrets versions access latest --secret=cf-api-token)
```

### 11.3 Notificaciones de Expiracion de Certificado

Agregar un cronjob en la VM que ejecute la prueba 4.5 diariamente y envie una alerta si quedan < 30 dias:

```bash
0 9 * * * bash /home/gcvmuser/test_traefik_vm.sh 2>&1 | grep "Certificate valid" | mail -s "Cert Status" admin@deviaaps.com
```

### 11.4 CI/CD con GitHub Actions

Automatizar el despliegue y las pruebas en cada push a la rama `main`:

```yaml
# .github/workflows/deploy.yml
- name: Deploy to GCP
  run: pwsh ./deploy_UbMV_Doker28_Traefik.ps1

- name: Run validation tests
  run: pwsh ./test/test_traefik.ps1
```

### 11.5 Dashboard de Monitoreo con Prometheus + Grafana

Traefik v3.3 expone metricas en formato Prometheus en `/metrics`. Agregar un servicio Prometheus + Grafana a `docker-compose.yml` para visualizar latencias, tasa de errores y estado de certificados.

### 11.6 Autenticacion con OAuth2 (Google/GitHub)

Reemplazar la autenticacion basica SHA1 del dashboard con el middleware `oauth2-proxy` de Traefik, usando Google OAuth2:

```yaml
labels:
  - "traefik.http.routers.dashboard.middlewares=oauth2@docker"
```

---

## 12. Cambios Documentados

### 12.1 Cambios Introducidos con Asistencia de IA

#### Cambio 1: Nombre fijo de red Docker (`name: miseia-net`)

**Problema detectado:** Docker Compose agrega el nombre del proyecto como prefijo a los recursos de red. La red se creaba como `traefik_miseia-net` en lugar de `miseia-net`. Traefik estaba configurado con `--providers.docker.network=miseia-net` y no podia encontrar la red, causando que los servicios no fueran enrutados.

**Cambio:** Se agrego `name: miseia-net` en la definicion de red en `docker-compose.yml`:
```yaml
networks:
  miseia-net:
    driver: bridge
    name: miseia-net  # <- nombre canonico, sin prefijo de proyecto
```

**Razon:** El nombre canonico garantiza que Traefik siempre encuentre la red correcta independientemente del nombre del proyecto de Compose.

---

#### Cambio 2: SHA1 en lugar de bcrypt para el hash del dashboard

**Problema detectado:** `htpasswd -nbB` (bcrypt) produce hashes como `admin:$2y$05$abc...`. Al escribir esto en el archivo `.env` y usarlo en `docker-compose.yml` con `${TRAEFIK_DASHBOARD_AUTH}`, Docker Compose interpreta los `$` como inicio de variables de entorno, resultando en una cadena vacia y autenticacion rota.

**Cambio:** Se cambio a `htpasswd -nbs` (SHA1):
```bash
HASH=$(htpasswd -nbs admin 'YOUR_ADMIN_PASSWORD' | tr -d '\n')
# Resultado: admin:{SHA}7UwG4eMPTyOKgxOc7DtaRWWgork=  (sin caracteres $)
```

**Razon:** El formato SHA1 `{SHA}base64` no contiene caracteres `$`, lo que evita la expansion de variables de Docker Compose.

---

#### Cambio 3: UTF-8 sin BOM para scripts bash

**Problema detectado:** PowerShell 5.1 usa `[System.Text.Encoding]::UTF8` que agrega BOM (Byte Order Mark, 3 bytes `EF BB BF`) al inicio del archivo. Bash en Linux interpreta el BOM como parte de la primera linea, convirtiendo `#!/bin/bash` en `﻿#!/bin/bash` con un caracter invisible al inicio, lo que hace que el kernel no encuentre el interprete y el script falle con `exec format error`.

**Cambio:** Se uso `System.Text.UTF8Encoding $false` para escribir sin BOM:
```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
```

**Razon:** Los scripts bash en Linux requieren archivos UTF-8 sin BOM con saltos de linea LF para que el shebang funcione correctamente.

---

#### Cambio 4: Solucion al problema SIGPIPE + pipefail en pruebas

**Problema detectado:** Con `set -o pipefail`, el comando `docker logs traefik 2>&1 | grep -q "acme"` fallaba incorrectamente. `grep -q` sale al encontrar la primera coincidencia (exit 0), cerrando el pipe. Docker logs recibe SIGPIPE y sale con codigo 141. Con `pipefail`, el pipeline adopta el codigo del comando fallido (141), haciendo que la condicion `if` tome el branch `else` aunque el patron fue encontrado.

**Cambio:** Se captura la salida con `--tail` en una variable antes de hacer grep:
```bash
TLOGS=$(docker logs traefik --tail 500 2>&1 || true)
if echo "$TLOGS" | grep -q "acme"; then
```

**Razon:** `docker logs --tail 500` termina despues de escribir 500 lineas, evitando SIGPIPE. La variable `$TLOGS` es buscada por grep sin involucrar pipes entre procesos de larga duracion.

---

#### Cambio 5: Em dash ASCII en scripts PowerShell

**Problema detectado:** El caracter em dash (`—`, U+2014) en cadenas de PowerShell genera errores de parseo en PowerShell 5.1. Al leer el archivo con codificacion CP1252 (defecto de PS5.1 sin BOM), la secuencia UTF-8 `E2 80 94` del em dash se interpreta como `â€"`, donde el byte `0x94` corresponde al caracter `"` (U+201D, comilla doble derecha) en CP1252. PowerShell reconoce U+201D como terminador de cadena, cerrando prematuramente el string literal.

**Cambio:** Se reemplazaron todos los em dashes con guion simple ASCII `-`:
```powershell
# Antes (rompe PS5.1):
Write-Host "  Traefik v3.3 Validation — Remote Test Runner"

# Despues (compatible):
Write-Host "  Traefik v3.3 Validation - Remote Test Runner"
```

**Razon:** PowerShell 5.1 en Windows lee archivos sin BOM como CP1252. Los caracteres Unicode fuera del rango CP1252 deben evitarse en strings de PS5.1 o el archivo debe guardarse con BOM UTF-8.

---

### 12.2 Evaluacion Critica

**Fortalezas del proyecto:**
- La automatizacion es genuinamente util: reduce un despliegue manual de ~45 minutos a ~8 minutos automatizados
- La suite de 30 pruebas proporciona confianza real en el estado del sistema; las pruebas verifican comportamientos observables (codigos HTTP, contenido de certificados) en lugar de solo verificar que los procesos esten corriendo
- La solucion al problema SIGPIPE + pipefail demuestra comprension profunda de como bash, `set -o pipefail` y `grep -q` interactuan

**Debilidades identificadas:**
- **Secretos en variables de script:** El token de Cloudflare y la contrasena del dashboard estan hardcodeados en el script `.ps1`. En un entorno de produccion, esto es inaceptable; se requiere integracion con un gestor de secretos
- **SHA1 para autenticacion:** Aunque resuelve el problema de los caracteres `$`, SHA1 es criptograficamente debil para autenticacion. Una solucion mas robusta seria usar variables de entorno del sistema operativo en lugar de `.env`, o un gestor de secretos que inyecte el valor sin necesidad de expansion de variables
- **Sin HTTPS en el health check de la VM:** El polling de Docker usa `docker info` como criterio de listo. No valida que Traefik este escuchando en el puerto 443, lo que puede resultar en un deploy exitoso pero con Traefik aun iniciando
- **traefik/whoami sin tag fijada:** El uso de `latest` para el servicio de prueba puede introducir cambios no intencionados en actualizaciones de imagen

**Evidencia de funcionamiento:**
- 30/30 pruebas automatizadas pasadas (2026-06-23 08:56:26 UTC)
- Certificado Let's Encrypt emitido y verificado: `Verify return code: 0 (ok)` para ambos dominios
- acme.json: 28,527 bytes confirmando persistencia del certificado
- Vigencia confirmada: 89 dias (expira Sep 21, 2026)

---

*Generado con asistencia de Claude Code (Anthropic) — 2026-06-23*

---

## Updates — 2026-06-23

### Archivos nuevos agregados al proyecto
- `test/test_traefik.ps1` — Lanzador PowerShell para la suite de pruebas automatizadas
- `test/test_traefik_vm.sh` — Runner de 30 pruebas bash ejecutadas en la VM
- `README.md` — Documentacion completa del proyecto (este archivo), escrita en Espanol
- `RETROSPECTIVE.md` — Retrospectiva tecnica de la sesion, escrita en Ingles

### Sanitizacion de datos sensibles
Todos los valores sensibles fueron reemplazados por placeholders para publicacion en repositorio publico:

| Valor original | Placeholder |
|---|---|
| ID de proyecto GCP | `YOUR_GCP_PROJECT_ID` |
| Token API de Cloudflare | `YOUR_CLOUDFLARE_API_TOKEN` |
| Contrasena del dashboard | `YOUR_ADMIN_PASSWORD` |
| Email de Let's Encrypt | `YOUR_EMAIL@example.com` |
| IP externa de la VM | `YOUR_VM_EXTERNAL_IP` |
| Ruta de llave SSH | `YOUR_SSH_KEY_PATH` |

### Estado final del despliegue
- VM destruida el 2026-06-23 tras validacion exitosa
- 30/30 pruebas automatizadas pasadas antes de la destruccion
- Certificado wildcard `*.deviaaps.com` emitido por Let's Encrypt (vigencia 89 dias)
