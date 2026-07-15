#!/bin/zsh
##===----------------------------------------------------------------------===##
## generate-soto-services.sh
##
## Maintainer-run script that generates minimal AWS service clients (S3, SSM)
## using the Soto Code Generator, with only the operations this project needs.
## NOT part of the build. Generated files are committed under Sources/Soto/.
##===----------------------------------------------------------------------===##
set -euo pipefail
log() { printf -- "** %s\n" "$*" >&2; }
fatal() { printf -- "** ERROR: %s\n" "$*" >&2; exit 1; }

SCRIPT_DIR="${0:a:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
WORK_DIR="${PROJECT_ROOT}/.build/codegen-work"
SERVICES=(S3 SSM)

command -v swift &>/dev/null || fatal "Swift toolchain not found"
command -v git &>/dev/null || fatal "git not found"

log "Setting up ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

if [ -d "${WORK_DIR}/soto-codegenerator" ]; then
    git -C "${WORK_DIR}/soto-codegenerator" pull --quiet || true
else
    git clone --quiet --depth 1 --branch main \
        https://github.com/soto-project/soto-codegenerator.git \
        "${WORK_DIR}/soto-codegenerator"
fi

log "Building Soto Code Generator (release)..."
( cd "${WORK_DIR}/soto-codegenerator" && swift build -c release 2>&1 | tail -3 )

cat > "${WORK_DIR}/soto.config.json" << 'EOF'
{
    "services": {
        "s3": {
            "operations": ["headObject","getObject","putObject","copyObject","deleteObject","getBucketLocation"]
        },
        "ssm": {
            "operations": ["getParameter","putParameter"]
        }
    }
}
EOF

DOWNLOADER="${WORK_DIR}/soto-codegenerator/.build/release/SotoModelDownloader"
MODELS="${WORK_DIR}/models"
mkdir -p "${MODELS}"
log "Downloading models..."
"${DOWNLOADER}" --output-folder "${MODELS}" --config-file "${WORK_DIR}/soto.config.json"

CODEGEN="${WORK_DIR}/soto-codegenerator/.build/release/SotoCodeGenerator-tool"
[ -x "${CODEGEN}" ] || CODEGEN="${WORK_DIR}/soto-codegenerator/.build/release/SotoCodeGenerator"
GEN="${WORK_DIR}/generated"
for service in "${SERVICES[@]}"; do
    lower="${service:l}"
    out="${GEN}/Soto${service}"
    mkdir -p "${out}"
    log "Generating Soto${service}..."
    "${CODEGEN}" \
        --output-folder "${out}" \
        --input-file "${MODELS}/${lower}.json" \
        --config "${WORK_DIR}/soto.config.json" \
        --endpoints "${MODELS}/endpoints.json" \
        --log-level info 2>&1 || log "Warning: codegen for ${service} returned non-zero"
done

for service in "${SERVICES[@]}"; do
    src="${GEN}/Soto${service}"
    dest="${PROJECT_ROOT}/Sources/Soto/${service}"
    if [ -d "${src}" ] && [ "$(ls -A "${src}" 2>/dev/null)" ]; then
        rm -rf "${dest}"; mkdir -p "${dest}"; cp -r "${src}/"* "${dest}/"
        log "Soto${service} → ${dest} ($(ls "${dest}" | wc -l | tr -d ' ') files)"
    else
        log "Warning: no generated files for ${service}"
    fi
done
log "Done."
