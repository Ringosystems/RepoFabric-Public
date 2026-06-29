#!/usr/bin/env bash
# RepoFabric Sandbox deployment wizard (containerized orchestrator).
#
# Runs ON the Docker host through the mounted socket. Walks the operator through
# everything needed to stand up the throwaway, NON-ENTERPRISE all-in-one sandbox:
# prerequisites, host address + port, hostnames + self-signed certificate, and
# local-admin credentials. It then builds, seeds, brings the stack up HTTPS-only,
# and PROVES every input is correct before printing the client-side steps for the
# operator's workstation.
#
# This is the "dummy" method: it tests/confirms what it is given and blocks on
# failure. Production uses an external NPM, a real certificate, and Entra.
#
# Launch (on the Docker host):  sandbox/launch.sh   (or launch.ps1)
# Wipe everything:              docker compose -f sandbox/docker-compose.yml -p repofabric-sandbox down -v
set -uo pipefail

# --- constants --------------------------------------------------------------
SBX="/repo/sandbox"
LOCKFILE="${SBX}/versions.lock.env"
ENVFILE="${SBX}/.env"
CERT_DIR="/certs"
PROJECT="repofabric-sandbox"
NET="repofabric-sandbox"
MIN_ENGINE_MAJOR=24
DISK_MIN_GB=6

NON_INTERACTIVE=0
DO_LATEST=0
FORCE_CERTS=0

# --- pretty output ----------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_bold=$'\033[1m'; c_rst=$'\033[0m'
say()  { echo "${c_cyn}==>${c_rst} $*"; }
ok()   { echo "  ${c_grn}[ok]${c_rst}   $*"; }
warn() { echo "  ${c_yel}[warn]${c_rst} $*"; }
fail() { echo "  ${c_red}[fail]${c_rst} $*"; }
die()  { echo "${c_red}${c_bold}BLOCKED:${c_rst} $*" >&2; exit 1; }
hostlabel() { echo; echo "${c_bold}Run on: $1${c_rst}"; }

usage() {
    cat <<EOF
RepoFabric Sandbox wizard.
  --non-interactive   read all inputs from sandbox/.env, never prompt
  --latest            refresh the version lock to the newest images before build
  --force-certs       regenerate the self-signed CA + leaf
  -h, --help          this help
EOF
    exit 0
}

for a in "$@"; do
    case "$a" in
        --non-interactive) NON_INTERACTIVE=1 ;;
        --latest) DO_LATEST=1 ;;
        --force-certs) FORCE_CERTS=1 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $a" ;;
    esac
done

# --- .env helpers -----------------------------------------------------------
touch "${ENVFILE}" 2>/dev/null || die "cannot write ${ENVFILE} (is the repo mounted read-write?)"

get_env() { grep -E "^$1=" "${ENVFILE}" 2>/dev/null | head -1 | cut -d= -f2- ; }

set_env() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "${ENVFILE}" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"
        grep -vE "^${key}=" "${ENVFILE}" > "${tmp}"
        printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
        cat "${tmp}" > "${ENVFILE}"; rm -f "${tmp}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${ENVFILE}"
    fi
}

# prompt VAR "Question" "default" [secret]
prompt() {
    local var="$1" q="$2" def="$3" secret="${4:-}"
    local cur; cur="$(get_env "${var}")"
    [ -n "${cur}" ] && def="${cur}"
    if [ "${NON_INTERACTIVE}" -eq 1 ]; then
        [ -z "${def}" ] && die "${var} is required in ${ENVFILE} for --non-interactive"
        printf -v "${var}" '%s' "${def}"
        return
    fi
    local ans
    if [ -n "${secret}" ]; then
        read -r -s -p "  ${q} [${def:+set}]: " ans; echo
    else
        read -r -p "  ${q} [${def}]: " ans
    fi
    ans="${ans:-${def}}"
    printf -v "${var}" '%s' "${ans}"
}

gen_secret() { openssl rand -hex "${1:-24}"; }

compose() { docker compose --env-file "${LOCKFILE}" --env-file "${ENVFILE}" -f "${SBX}/docker-compose.yml" -p "${PROJECT}" "$@"; }

echo
echo "${c_bold}RepoFabric Sandbox  -  throwaway, NON-ENTERPRISE all-in-one deployment${c_rst}"
echo "This is NOT the recommended production method. See sandbox/README.md."
echo

# ===========================================================================
# STEP 0: PREFLIGHT GATE  (confirm every host prerequisite, block on failure)
# ===========================================================================
say "Step 0: preflight (host prerequisites)"

docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon over /var/run/docker.sock. Start Docker / fix socket permissions, and ensure the launcher mounts the socket."
ok "Docker daemon reachable"

ENGINE_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '0')"
ENGINE_MAJOR="${ENGINE_VER%%.*}"; ENGINE_MAJOR="${ENGINE_MAJOR:-0}"
if [ "${ENGINE_MAJOR}" -lt "${MIN_ENGINE_MAJOR}" ] 2>/dev/null; then
    die "Docker Engine ${ENGINE_VER} is too old; need ${MIN_ENGINE_MAJOR}.0+. Upgrade Docker Engine."
fi
ok "Docker Engine ${ENGINE_VER} (>= ${MIN_ENGINE_MAJOR}.0)"

docker buildx version >/dev/null 2>&1 || die "buildx is unavailable; enable BuildKit/buildx on the host."
ok "buildx available"

# Disk space on the Docker data root.
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
FREE_KB="$(df -Pk "${DOCKER_ROOT}" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${FREE_KB}" ]; then
    FREE_GB=$(( FREE_KB / 1024 / 1024 ))
    if [ "${FREE_GB}" -lt "${DISK_MIN_GB}" ]; then
        warn "only ${FREE_GB}GB free on ${DOCKER_ROOT} (recommend >= ${DISK_MIN_GB}GB). Consider 'docker system prune'."
    else
        ok "disk: ${FREE_GB}GB free on ${DOCKER_ROOT}"
    fi
fi

# Outbound registry reachability (warn-only; pinned images may already be cached).
if curl -fsS --max-time 8 https://registry-1.docker.io/v2/ >/dev/null 2>&1 \
   || curl -sS --max-time 8 -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null | grep -qE '401|200'; then
    ok "registry reachable (docker hub)"
else
    warn "could not confirm registry egress; the build needs pinned images cached locally if offline."
fi

# ===========================================================================
# STEP 1: HOST ADDRESS + LOCAL PORT
# ===========================================================================
say "Step 1: host address and HTTPS port"
DETECTED_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
DETECTED_IP="${DETECTED_IP:-127.0.0.1}"
prompt HOST_ADDRESS "Address your WORKSTATION uses to reach this server (IP or DNS name)" "${DETECTED_IP}"
prompt SANDBOX_HTTPS_PORT "HTTPS port to publish on this host" "443"
set_env HOST_ADDRESS "${HOST_ADDRESS}"
set_env SANDBOX_HTTPS_PORT "${SANDBOX_HTTPS_PORT}"

# Port-free check on the host (best-effort, via a transient bind on the daemon).
if docker run --rm -p "127.0.0.1:${SANDBOX_HTTPS_PORT}:9" "${WIZARD_BASE_IMAGE:-docker:27-cli}" true >/dev/null 2>&1; then
    ok "host port ${SANDBOX_HTTPS_PORT} is free"
    warn "the workstation must be able to reach ${HOST_ADDRESS}:${SANDBOX_HTTPS_PORT} through any firewall"
else
    die "host port ${SANDBOX_HTTPS_PORT} appears to be in use. Stop the conflicting process or choose another (SANDBOX_HTTPS_PORT)."
fi

# ===========================================================================
# STEP 2: HOSTNAMES + CERTIFICATE
# ===========================================================================
say "Step 2: hostnames and self-signed certificate"
prompt LOCALDOMAIN "Base local domain for the three hostnames" "repofabric.localhost"
set_env LOCALDOMAIN "${LOCALDOMAIN}"
H_WINGET="winget.${LOCALDOMAIN}"; H_INSTALLERS="installers.${LOCALDOMAIN}"; H_GITEA="gitea.${LOCALDOMAIN}"

CERT_ARGS=(); [ "${FORCE_CERTS}" -eq 1 ] && CERT_ARGS+=(--force)
LOCALDOMAIN="${LOCALDOMAIN}" OUT_DIR="${CERT_DIR}" bash "${SBX}/scripts/gen-certs.sh" "${CERT_ARGS[@]}" \
    || die "certificate generation failed"

# Validate the cert: parses, SANs match, key matches, not expired.
openssl x509 -in "${CERT_DIR}/leaf.pem" -noout >/dev/null 2>&1 || die "generated leaf certificate does not parse"
for h in "${H_WINGET}" "${H_INSTALLERS}" "${H_GITEA}"; do
    openssl x509 -in "${CERT_DIR}/leaf.pem" -noout -text 2>/dev/null | grep -q "DNS:${h}" \
        || die "certificate SANs do not cover ${h}. Re-run with --force-certs after fixing LOCALDOMAIN."
done
# Compare the moduli directly (string equality), so no hash is involved.
CRT_MOD="$(openssl x509 -noout -modulus -in "${CERT_DIR}/leaf.pem" 2>/dev/null)"
KEY_MOD="$(openssl rsa  -noout -modulus -in "${CERT_DIR}/leaf.key" 2>/dev/null)"
[ -n "${CRT_MOD}" ] && [ "${CRT_MOD}" = "${KEY_MOD}" ] || die "leaf certificate and key do not match"
openssl x509 -in "${CERT_DIR}/leaf.pem" -checkend 0 >/dev/null 2>&1 || die "leaf certificate is already expired"
ok "certificate valid; SANs cover ${H_WINGET}, ${H_INSTALLERS}, ${H_GITEA}"

# ===========================================================================
# STEP 3: LOCAL ADMIN CREDENTIALS + generated secrets
# ===========================================================================
say "Step 3: local-admin credentials"
prompt SANDBOX_ADMIN_USER "Local admin username for the RepoFabric admin UI" "admin"
SANDBOX_ADMIN_PASSWORD="$(get_env SANDBOX_ADMIN_PASSWORD)"
if [ -z "${SANDBOX_ADMIN_PASSWORD}" ]; then
    if [ "${NON_INTERACTIVE}" -eq 1 ]; then die "SANDBOX_ADMIN_PASSWORD required in ${ENVFILE} for --non-interactive"; fi
    prompt SANDBOX_ADMIN_PASSWORD "Local admin password (blank = generate one)" ""
    [ -z "${SANDBOX_ADMIN_PASSWORD}" ] && { SANDBOX_ADMIN_PASSWORD="$(gen_secret 12)"; say "generated local admin password: ${c_bold}${SANDBOX_ADMIN_PASSWORD}${c_rst}"; }
fi
set_env SANDBOX_ADMIN_USER "${SANDBOX_ADMIN_USER}"
set_env SANDBOX_ADMIN_PASSWORD "${SANDBOX_ADMIN_PASSWORD}"

# Generated-once secrets persisted to .env.
[ -n "$(get_env SANDBOX_SESSION_SECRET)" ] || set_env SANDBOX_SESSION_SECRET "$(gen_secret 32)"
[ -n "$(get_env SANDBOX_NPM_PASSWORD)" ]    || set_env SANDBOX_NPM_PASSWORD "$(gen_secret 16)"
[ -n "$(get_env GITEA_ADMIN_PASS)" ]        || set_env GITEA_ADMIN_PASS "$(gen_secret 16)"
[ -n "$(get_env TZ)" ]                      || set_env TZ "UTC"
SANDBOX_NPM_PASSWORD="$(get_env SANDBOX_NPM_PASSWORD)"
GITEA_ADMIN_PASS="$(get_env GITEA_ADMIN_PASS)"
ok "credentials and secrets recorded in sandbox/.env"

# ===========================================================================
# STEP 4: VERSION PINNING (default = pin current; --latest = refresh newest)
# ===========================================================================
say "Step 4: versions"
RESOLVED_AT="$(get_env RESOLVED_AT)"; [ -n "${RESOLVED_AT}" ] || RESOLVED_AT="$(grep -E '^RESOLVED_AT=' "${LOCKFILE}" | cut -d= -f2-)"
if [ "${DO_LATEST}" -eq 1 ]; then
    say "refreshing version lock to the newest published images"
    bash "${SBX}/scripts/refresh-versions.sh" || warn "refresh-versions.sh failed; continuing with current lock"
elif [ "${RESOLVED_AT}" = "unpinned" ]; then
    say "pinning the bundled images to their current digests for a reproducible build"
    bash "${SBX}/scripts/refresh-versions.sh" || warn "could not pin digests; building from floating tags"
else
    ok "using pinned versions (resolved ${RESOLVED_AT})"
fi

# ===========================================================================
# STEP 5: BUILD + BRING UP
# ===========================================================================
say "Step 5: build and start the stack"
compose build repofabric-linux || die "image build failed"
compose up -d repofabric-npm repofabric-gitea || die "failed to start NPM + Gitea"

# Self-connect to the sandbox network so we can reach the services by name
# (no-op when launched via 'compose run', which already attached us).
docker network connect "${NET}" "$(hostname)" >/dev/null 2>&1 || true

# Wait for NPM + Gitea over the network.
say "waiting for NPM and Gitea"
for i in $(seq 1 60); do curl -fsS "http://repofabric-npm:81/api" >/dev/null 2>&1 && break; sleep 2; [ "$i" -eq 60 ] && die "NPM never came up (docker compose -f sandbox/docker-compose.yml -p ${PROJECT} logs repofabric-npm)"; done
ok "NPM up"
for i in $(seq 1 60); do curl -fsS "http://repofabric-gitea:3000/api/healthz" >/dev/null 2>&1 && break; sleep 2; [ "$i" -eq 60 ] && die "Gitea never came up (docker compose -f sandbox/docker-compose.yml -p ${PROJECT} logs repofabric-gitea)"; done
ok "Gitea up"

# Seed Gitea (admin + PAT). NPM is seeded later, after every upstream container
# is up (see below), because NPM validates each proxy host's nginx config at
# creation time and rejects (and caches the failure for) any host whose upstream
# does not yet resolve.
say "seeding Gitea admin + access token"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS}" bash "${SBX}/scripts/seed-gitea.sh" > /tmp/pat.txt 2>/tmp/gitea-seed.log || { cat /tmp/gitea-seed.log >&2; die "Gitea seeding failed"; }
GITEA_PAT="$(tr -d '\r\n' < /tmp/pat.txt)"; rm -f /tmp/pat.txt
[ -n "${GITEA_PAT}" ] || die "Gitea seeding did not produce an access token"
ok "Gitea admin + PAT ready"

# Start the app (boots in first-run setup mode) and rewinged.
compose up -d repofabric-linux || die "failed to start repofabric-linux"
say "waiting for repofabric-linux"
for i in $(seq 1 60); do docker exec repofabric-linux curl -fsS http://127.0.0.1:8086/healthz >/dev/null 2>&1 && break; sleep 2; [ "$i" -eq 60 ] && die "repofabric-linux never became healthy (docker compose -f sandbox/docker-compose.yml -p ${PROJECT} logs repofabric-linux)"; done
ok "repofabric-linux up"

# Pre-create the manifests subtree so rewinged does not crash on an empty volume,
# then start it. Publish the CA into the installers root for the workstation.
docker exec repofabric-linux mkdir -p /var/cache/repofabric/manifests/manifests >/dev/null 2>&1 || true
docker cp "${CERT_DIR}/ca.pem" repofabric-linux:/var/cache/repofabric/installers/sandbox-ca.pem >/dev/null 2>&1 \
    && docker exec repofabric-linux chown 99:100 /var/cache/repofabric/installers/sandbox-ca.pem >/dev/null 2>&1 || warn "could not publish CA to the installers root; use docker cp instead"
compose up -d repofabric-rewinged || die "failed to start rewinged"
ok "rewinged started; CA published for download"

# Seed NPM now that every upstream (repofabric-linux, repofabric-rewinged,
# repofabric-gitea) is up and resolvable. Seeding here -- not before the app
# starts -- means each proxy host's nginx config passes validation on first
# write, so the winget host (-> repofabric-linux/rewinged) is not rejected.
say "seeding NPM (certificate + 3 proxy hosts, HTTPS-forced)"
SANDBOX_NPM_PASSWORD="${SANDBOX_NPM_PASSWORD}" LOCALDOMAIN="${LOCALDOMAIN}" CERT_DIR="${CERT_DIR}" \
    bash "${SBX}/scripts/seed-npm.sh" || die "NPM seeding failed"
ok "NPM seeded"

# ===========================================================================
# STEP 6: AUTO-COMPLETE FIRST-RUN SETUP (via the app's own validated path)
# ===========================================================================
say "Step 6: completing first-run configuration"
NPM_IP="$(getent hosts repofabric-npm | awk '{print $1}' | head -1)"
[ -n "${NPM_IP}" ] || die "could not resolve repofabric-npm on the sandbox network"
CURL_NPM=(curl -fsS --cacert "${CERT_DIR}/ca.pem" --resolve "${H_WINGET}:443:${NPM_IP}")

# nginx can take a beat to reload after seeding; wait until the winget vhost
# actually answers over HTTPS so the first setup call does not race the reload.
say "waiting for the winget HTTPS route"
for i in $(seq 1 30); do "${CURL_NPM[@]}" -o /dev/null "https://${H_WINGET}/admin/auth/login" >/dev/null 2>&1 && break; sleep 2; [ "$i" -eq 30 ] && warn "winget HTTPS route slow to respond; continuing"; done

SETUP_TOKEN="$(docker exec repofabric-linux cat /var/lib/repofabric/setup-token.txt 2>/dev/null | tr -d '\r\n')"
if [ -n "${SETUP_TOKEN}" ]; then
    # Public installer URL must carry the published HTTPS port (clients reach the
    # bundled NPM on SANDBOX_HTTPS_PORT, e.g. 8443), or custom-installer downloads
    # land on the wrong port. Omit the suffix for the default 443.
    PUBSFX=""; [ "${SANDBOX_HTTPS_PORT}" != "443" ] && PUBSFX=":${SANDBOX_HTTPS_PORT}"
    PAYLOAD="$(jq -n --arg pat "${GITEA_PAT}" --arg dom "${LOCALDOMAIN}" --arg u "${SANDBOX_ADMIN_USER}" --arg p "${SANDBOX_ADMIN_PASSWORD}" --arg pubsfx "${PUBSFX}" '{
        auth: { tenant_id:"", client_id:"", client_secret:"", allowed_users:[], allowed_groups:[] },
        targets: {
            gitea_base_url:"http://repofabric-gitea:3000",
            gitea_repo:"repofabric/winget-manifests",
            gitea_pat:$pat,
            rewinged_url:"http://repofabric-rewinged:8080",
            installer_base_url:("https://installers." + $dom + $pubsfx),
            manifest_mount_path:"/var/cache/repofabric/manifests"
        },
        sandbox: { local_admin: { username:$u, password:$p } }
    }')"
    CJ="$(mktemp)"
    "${CURL_NPM[@]}" -c "${CJ}" -X POST "https://${H_WINGET}/setup/api/verify-token" \
        -H 'Content-Type: application/json' -d "{\"token\":\"${SETUP_TOKEN}\"}" >/dev/null \
        || die "could not verify the setup token through NPM"
    "${CURL_NPM[@]}" -b "${CJ}" -X POST "https://${H_WINGET}/setup/api/save" \
        -H 'Content-Type: application/json' -d "${PAYLOAD}" >/dev/null \
        || die "first-run save failed"
    rm -f "${CJ}"
    say "waiting for the app to restart in normal mode"
    for i in $(seq 1 45); do
        sm="$(docker exec repofabric-linux curl -fsS http://127.0.0.1:8086/healthz 2>/dev/null | jq -r '.setup_mode' 2>/dev/null)"
        [ "${sm}" = "false" ] && break
        sleep 2
        [ "$i" -eq 45 ] && warn "app still reports setup mode; check 'docker compose -f sandbox/docker-compose.yml -p ${PROJECT} logs repofabric-linux'"
    done
    ok "first-run configuration applied (local-admin sign-in, internal targets)"
else
    warn "no setup token found; the app may already be configured. Open /setup/ to configure manually."
fi

# ===========================================================================
# STEP 7: PROVE IT  (host-side validations, block on failure)
# ===========================================================================
say "Step 7: validating the running sandbox"

if "${CURL_NPM[@]}" "https://${H_WINGET}/api/information" | jq -e '.Data.SourceIdentifier // .SourceIdentifier // empty' >/dev/null 2>&1; then
    ok "WinGet REST API reachable over HTTPS (winget.${LOCALDOMAIN}/api/information)"
else
    fail "WinGet REST API did not return valid JSON through NPM"
    die "routing/cert problem at winget.${LOCALDOMAIN}/api. Check 'docker compose -f sandbox/docker-compose.yml -p ${PROJECT} logs repofabric-npm repofabric-rewinged'."
fi

if "${CURL_NPM[@]}" -X POST "https://${H_WINGET}/api/manifestSearch" -H 'Content-Type: application/json' -d '{"Query":{"KeyWord":"","MatchType":"Substring"}}' >/dev/null 2>&1; then
    ok "WinGet manifestSearch responds (catalog empty until first publish)"
else
    warn "manifestSearch did not respond cleanly (harmless on an empty catalog)"
fi

if "${CURL_NPM[@]}" -o /dev/null "https://${H_WINGET}/admin/auth/login"; then
    ok "Admin UI reachable over HTTPS (winget.${LOCALDOMAIN}/admin)"
else
    fail "Admin UI not reachable through NPM"; die "check repofabric-linux + NPM proxy host for winget.${LOCALDOMAIN}/admin"
fi

if "${CURL_NPM[@]}" --resolve "${H_INSTALLERS}:443:${NPM_IP}" -o /dev/null "https://${H_INSTALLERS}/sandbox-ca.pem"; then
    ok "Installers host serving the CA over HTTPS (installers.${LOCALDOMAIN}/sandbox-ca.pem)"
else
    warn "could not fetch the CA over HTTPS; the docker cp fallback is printed below"
fi

if curl -fsS --cacert "${CERT_DIR}/ca.pem" --resolve "${H_GITEA}:443:${NPM_IP}" -o /dev/null "https://${H_GITEA}/"; then
    ok "Gitea reachable over HTTPS (gitea.${LOCALDOMAIN})"
else
    warn "Gitea host did not respond over HTTPS (non-blocking)"
fi

# ===========================================================================
# STEP 8: CLIENT HANDOFF  (printed for the operator's workstation)
# ===========================================================================
echo
echo "${c_grn}${c_bold}Sandbox is up and validated.${c_rst} Finish on your workstation:"

hostlabel "your workstation (edit the hosts file, elevated)"
echo "  Windows: C:\\Windows\\System32\\drivers\\etc\\hosts   |   macOS/Linux: /etc/hosts"
echo "  ${HOST_ADDRESS} ${H_WINGET} ${H_INSTALLERS} ${H_GITEA}"

hostlabel "your workstation (fetch + trust the CA, elevated PowerShell)"
echo "  curl.exe -k -o ca.pem https://${H_INSTALLERS}:${SANDBOX_HTTPS_PORT}/sandbox-ca.pem; Import-Certificate -FilePath .\\ca.pem -CertStoreLocation Cert:\\LocalMachine\\Root"
echo "  (fallback if the download host is unreachable: docker cp repofabric-linux:/var/cache/repofabric/installers/sandbox-ca.pem ca.pem)"

hostlabel "your workstation (add the WinGet source, after trusting the CA)"
echo "  winget source add --name repofabric-sandbox --arg https://${H_WINGET}:${SANDBOX_HTTPS_PORT}/api/ --type Microsoft.Rest"

echo
echo "${c_bold}Admin UI:${c_rst}  https://${H_WINGET}:${SANDBOX_HTTPS_PORT}/admin    (local-admin: ${SANDBOX_ADMIN_USER})"
echo "${c_bold}Throw it all away:${c_rst}  docker compose -f sandbox/docker-compose.yml -p ${PROJECT} down -v"
echo
echo "Reminder: this is the SANDBOX. It is not the enterprise deployment and is meant to be deleted."
