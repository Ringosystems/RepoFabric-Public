#!/usr/bin/env bash
# RepoFabric Sandbox: headless Nginx Proxy Manager seeding.
#
# Drives NPM's REST API (not its SQLite DB, which is an unstable internal) to:
#   1. log in with the default admin and rotate its password,
#   2. upload the self-signed leaf+key+CA as a custom certificate,
#   3. create the three proxy hosts that mirror the documented production config
#      (linux/admin/static/docs/reverse-proxy-npm.md), HTTPS-forced, HSTS OFF.
#
# Idempotent: re-running after a partial failure reuses existing objects.
# Talks to NPM over the sandbox network on plain HTTP :81 (no chicken-and-egg
# with TLS); the public edge it configures is HTTPS-only.
#
# Env:
#   NPM_URL          NPM API base (default http://repofabric-npm:81)
#   NPM_DEFAULT_EMAIL/NPM_DEFAULT_PASS  NPM factory creds (admin@example.com/changeme)
#   SANDBOX_NPM_PASSWORD  password to rotate the NPM admin to (required)
#   LOCALDOMAIN      base domain (default repofabric.localhost)
#   CERT_DIR         where gen-certs.sh wrote the material (default /certs)
set -euo pipefail

NPM_URL="${NPM_URL:-http://repofabric-npm:81}"
NPM_DEFAULT_EMAIL="${NPM_DEFAULT_EMAIL:-admin@example.com}"
NPM_DEFAULT_PASS="${NPM_DEFAULT_PASS:-changeme}"
NPM_PASS="${SANDBOX_NPM_PASSWORD:?SANDBOX_NPM_PASSWORD is required}"
LOCALDOMAIN="${LOCALDOMAIN:-repofabric.localhost}"
CERT_DIR="${CERT_DIR:-/certs}"

API="${NPM_URL%/}/api"
H_WINGET="winget.${LOCALDOMAIN}"
H_INSTALLERS="installers.${LOCALDOMAIN}"
H_GITEA="gitea.${LOCALDOMAIN}"
CERT_NICE_NAME="repofabric-sandbox-leaf"

ADV_HEADERS=$'proxy_set_header Host $host;\nproxy_set_header X-Forwarded-Proto https;\nproxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\nproxy_set_header X-Real-IP $remote_addr;\nclient_max_body_size 2g;'

log() { echo "[seed-npm] $*"; }

# --- wait for the API -------------------------------------------------------
log "waiting for NPM API at ${API}"
for i in $(seq 1 60); do
    if curl -fsS "${API}/" >/dev/null 2>&1; then break; fi
    sleep 2
    if [ "$i" -eq 60 ]; then echo "[seed-npm] NPM API never became ready" >&2; exit 1; fi
done

# --- authenticate (rotating the default password if needed) -----------------
get_token() {
    curl -fsS -X POST "${API}/tokens" \
        -H 'Content-Type: application/json' \
        -d "{\"identity\":\"$1\",\"secret\":\"$2\"}" 2>/dev/null \
        | jq -r '.token // empty'
}

TOKEN="$(get_token "${NPM_DEFAULT_EMAIL}" "${NPM_PASS}" || true)"
if [ -n "${TOKEN}" ]; then
    log "authenticated with the already-rotated password"
else
    TOKEN="$(get_token "${NPM_DEFAULT_EMAIL}" "${NPM_DEFAULT_PASS}" || true)"
    if [ -z "${TOKEN}" ]; then
        # NPM 2.15+ ships with NO default admin (the user table starts empty),
        # so the factory login above finds nothing. Create the first user via the
        # onboarding endpoint (permitted unauthenticated while zero users exist),
        # then log in with the factory password so the rotation below can proceed.
        log "no default admin (NPM 2.15+ ships none); creating the first user via onboarding"
        curl -fsS -X POST "${API}/users" -H 'Content-Type: application/json' \
            -d "{\"name\":\"Administrator\",\"nickname\":\"Admin\",\"email\":\"${NPM_DEFAULT_EMAIL}\",\"roles\":[\"admin\"],\"is_disabled\":false,\"auth\":{\"type\":\"password\",\"secret\":\"${NPM_DEFAULT_PASS}\"}}" >/dev/null 2>&1 || true
        TOKEN="$(get_token "${NPM_DEFAULT_EMAIL}" "${NPM_DEFAULT_PASS}" || true)"
    fi
    if [ -z "${TOKEN}" ]; then echo "[seed-npm] could not authenticate to NPM" >&2; exit 1; fi
    log "authenticated with factory creds; rotating admin password"
    curl -fsS -X PUT "${API}/users/1/auth" \
        -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
        -d "{\"type\":\"password\",\"current\":\"${NPM_DEFAULT_PASS}\",\"secret\":\"${NPM_PASS}\"}" >/dev/null
    TOKEN="$(get_token "${NPM_DEFAULT_EMAIL}" "${NPM_PASS}")"
fi
AUTH=(-H "Authorization: Bearer ${TOKEN}")

# --- custom certificate -----------------------------------------------------
CERT_ID="$(curl -fsS "${AUTH[@]}" "${API}/nginx/certificates" \
    | jq -r --arg n "${CERT_NICE_NAME}" '.[] | select(.nice_name==$n) | .id' | head -1)"

if [ -z "${CERT_ID}" ] || [ "${CERT_ID}" = "null" ]; then
    log "creating custom certificate record"
    CERT_ID="$(curl -fsS -X POST "${AUTH[@]}" "${API}/nginx/certificates" \
        -H 'Content-Type: application/json' \
        -d "{\"provider\":\"other\",\"nice_name\":\"${CERT_NICE_NAME}\"}" | jq -r '.id')"
    log "uploading leaf + key + CA (multipart) to cert ${CERT_ID}"
    # The upload MUST use real multipart file parts with filenames, otherwise NPM
    # returns "No files were uploaded" (jc21/nginx-proxy-manager#4243, #5086).
    curl -fsS -X POST "${AUTH[@]}" "${API}/nginx/certificates/${CERT_ID}/upload" \
        -F "certificate=@${CERT_DIR}/leaf.fullchain.pem" \
        -F "certificate_key=@${CERT_DIR}/leaf.key" \
        -F "intermediate_certificate=@${CERT_DIR}/ca.pem" >/dev/null
else
    log "reusing existing certificate ${CERT_ID}"
fi

# --- proxy host helpers -----------------------------------------------------
host_exists() {
    curl -fsS "${AUTH[@]}" "${API}/nginx/proxy-hosts" \
        | jq -e --arg d "$1" 'any(.[]; .domain_names | index($d))' >/dev/null 2>&1
}

create_host() {
    local payload="$1" domain="$2"
    if host_exists "${domain}"; then log "proxy host ${domain} already present; skipping"; return 0; fi
    log "creating proxy host ${domain}"
    curl -fsS -X POST "${AUTH[@]}" "${API}/nginx/proxy-hosts" \
        -H 'Content-Type: application/json' -d "${payload}" >/dev/null
}

# winget.<domain>: default -> rewinged; /admin and /setup -> repofabric-linux.
WINGET_PAYLOAD="$(jq -n \
    --arg d "${H_WINGET}" --argjson cid "${CERT_ID}" --arg adv "${ADV_HEADERS}" '{
    domain_names: [$d], forward_scheme: "http", forward_host: "repofabric-rewinged", forward_port: 8080,
    certificate_id: $cid, ssl_forced: true, http2_support: true, hsts_enabled: false,
    block_exploits: true, allow_websocket_upgrade: true, caching_enabled: false, advanced_config: "",
    meta: { letsencrypt_agree: false, dns_challenge: false },
    locations: [
      { path: "/admin", forward_scheme: "http", forward_host: "repofabric-linux", forward_port: 8086, advanced_config: $adv },
      { path: "/setup", forward_scheme: "http", forward_host: "repofabric-linux", forward_port: 8086, advanced_config: $adv }
    ]
}')"

INSTALLERS_PAYLOAD="$(jq -n --arg d "${H_INSTALLERS}" --argjson cid "${CERT_ID}" '{
    domain_names: [$d], forward_scheme: "http", forward_host: "repofabric-linux", forward_port: 8091,
    certificate_id: $cid, ssl_forced: true, http2_support: true, hsts_enabled: false,
    block_exploits: true, allow_websocket_upgrade: false, caching_enabled: true,
    advanced_config: "client_max_body_size 0;\nproxy_buffering on;\nproxy_max_temp_file_size 0;",
    meta: { letsencrypt_agree: false, dns_challenge: false }, locations: []
}')"

GITEA_PAYLOAD="$(jq -n --arg d "${H_GITEA}" --argjson cid "${CERT_ID}" '{
    domain_names: [$d], forward_scheme: "http", forward_host: "repofabric-gitea", forward_port: 3000,
    certificate_id: $cid, ssl_forced: true, http2_support: true, hsts_enabled: false,
    block_exploits: true, allow_websocket_upgrade: true, caching_enabled: false,
    advanced_config: "client_max_body_size 50m;",
    meta: { letsencrypt_agree: false, dns_challenge: false }, locations: []
}')"

create_host "${WINGET_PAYLOAD}" "${H_WINGET}"
create_host "${INSTALLERS_PAYLOAD}" "${H_INSTALLERS}"
create_host "${GITEA_PAYLOAD}" "${H_GITEA}"

log "done: cert ${CERT_ID}, hosts ${H_WINGET} / ${H_INSTALLERS} / ${H_GITEA} (HTTPS-forced, HSTS off)"
