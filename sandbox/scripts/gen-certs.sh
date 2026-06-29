#!/usr/bin/env bash
# RepoFabric Sandbox: self-signed CA + leaf certificate generator.
#
# Generates a local Certificate Authority and one leaf certificate whose
# SubjectAltNames cover the three sandbox hostnames (winget./installers./gitea.
# <LOCALDOMAIN>). The bundled Nginx Proxy Manager terminates HTTPS with the
# leaf; the CA is exported so the operator's workstation can trust it (WinGet
# validates a REST source's chain against the machine store and has no
# per-source skip flag, so trusting this CA is the supported path).
#
# This is the SANDBOX (throwaway, non-enterprise) deployment. A production
# deployment uses a real CA-signed or Let's Encrypt certificate instead.
#
# Runs inside a container that has openssl, so the Docker host needs no openssl.
# Idempotent: existing material is reused unless --force is given.
#
# Env:
#   LOCALDOMAIN   base domain for the three hostnames (default repofabric.localhost)
#   OUT_DIR       output directory (default /certs, the mounted certs volume)
#   CA_DAYS       CA validity in days (default 3650)
#   LEAF_DAYS     leaf validity in days (default 825, modern client cap)
set -euo pipefail

LOCALDOMAIN="${LOCALDOMAIN:-repofabric.localhost}"
OUT_DIR="${OUT_DIR:-/certs}"
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-825}"
FORCE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --out) OUT_DIR="$2"; shift ;;
        --domain) LOCALDOMAIN="$2"; shift ;;
        *) echo "[gen-certs] unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

CA_KEY="${OUT_DIR}/ca.key"
CA_PEM="${OUT_DIR}/ca.pem"
LEAF_KEY="${OUT_DIR}/leaf.key"
LEAF_CSR="${OUT_DIR}/leaf.csr"
LEAF_PEM="${OUT_DIR}/leaf.pem"
LEAF_FULLCHAIN="${OUT_DIR}/leaf.fullchain.pem"
SAN_EXT="${OUT_DIR}/san.ext"

H_WINGET="winget.${LOCALDOMAIN}"
H_INSTALLERS="installers.${LOCALDOMAIN}"
H_GITEA="gitea.${LOCALDOMAIN}"

mkdir -p "${OUT_DIR}"

if [ "${FORCE}" -eq 0 ] && [ -f "${CA_PEM}" ] && [ -f "${LEAF_FULLCHAIN}" ] && [ -f "${LEAF_KEY}" ]; then
    echo "[gen-certs] existing material found in ${OUT_DIR}; reusing (pass --force to regenerate)"
    # Re-validate the SANs still match the requested domain; warn loudly if not.
    if ! openssl x509 -in "${LEAF_PEM}" -noout -text 2>/dev/null | grep -q "DNS:${H_WINGET}"; then
        echo "[gen-certs] WARN: existing leaf does not cover ${H_WINGET}; run with --force after fixing LOCALDOMAIN" >&2
    fi
    exit 0
fi

echo "[gen-certs] generating CA + leaf for *.${LOCALDOMAIN} into ${OUT_DIR}"

# 1. Certificate Authority (self-signed root).
openssl genrsa -out "${CA_KEY}" 4096
openssl req -x509 -new -nodes -key "${CA_KEY}" -sha256 -days "${CA_DAYS}" \
    -subj "/O=RingoSystems Heavy Industries/CN=RepoFabric Sandbox Local CA" \
    -out "${CA_PEM}"

# 2. Leaf key + CSR.
openssl genrsa -out "${LEAF_KEY}" 2048
openssl req -new -key "${LEAF_KEY}" \
    -subj "/O=RingoSystems Heavy Industries/CN=${H_WINGET}" \
    -out "${LEAF_CSR}"

# 3. SAN + EKU extension file. Connections are by hostname, so DNS SANs are
#    sufficient (no IP SAN needed even across the network).
cat > "${SAN_EXT}" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${H_WINGET},DNS:${H_INSTALLERS},DNS:${H_GITEA}
EOF

# 4. Sign the leaf with the CA.
openssl x509 -req -in "${LEAF_CSR}" -CA "${CA_PEM}" -CAkey "${CA_KEY}" \
    -CAcreateserial -days "${LEAF_DAYS}" -sha256 -extfile "${SAN_EXT}" \
    -out "${LEAF_PEM}"

# 5. Full chain (leaf + CA) for NPM's certificate upload.
cat "${LEAF_PEM}" "${CA_PEM}" > "${LEAF_FULLCHAIN}"

# Lock down the private keys.
chmod 0600 "${CA_KEY}" "${LEAF_KEY}" 2>/dev/null || true

echo "[gen-certs] done:"
echo "  CA (trust this on the workstation): ${CA_PEM}"
echo "  leaf fullchain (for NPM):           ${LEAF_FULLCHAIN}"
echo "  leaf key (for NPM):                 ${LEAF_KEY}"
echo "  SANs: ${H_WINGET}, ${H_INSTALLERS}, ${H_GITEA}"
