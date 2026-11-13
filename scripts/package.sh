#!/bin/zsh
# Package only allowlisted own code/docs; never run the helper or vendor app.
set -euo pipefail
umask 022
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
RELEASE_NAME='LUMIX Tether USB Fix'
OUTPUT_DIR="${PROJECT_ROOT}/dist"
RELEASE_VERSION='1.0.0'
PACKAGE_TMP=''
DRY_RUN=0
die() { print -u2 -r -- "Packaging failed: $*"; exit 1; }
while (( $# )); do
    case "$1" in
        --output-dir)
            (( $# >= 2 )) || die '--output-dir needs a directory.'
            OUTPUT_DIR="${2:A}"; shift 2 ;;
        --version)
            (( $# >= 2 )) || die '--version needs a value.'
            RELEASE_VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            print -r -- 'Usage: scripts/package.sh [--output-dir DIRECTORY] [--version VERSION] [--dry-run]'
            print -r -- 'Packages DIRECTORY/LUMIX Tether USB Fix using an explicit own-code/docs allowlist.'
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ "$RELEASE_VERSION" == [0-9]* && "$RELEASE_VERSION" != *[^0-9A-Za-z._-]* ]] || die 'Unsafe version string.'
RELEASE_PATH="${OUTPUT_DIR}/${RELEASE_NAME}"
[[ -d "$RELEASE_PATH" ]] || die 'Build the CLI release with scripts/build.sh first.'
"${SCRIPT_DIR}/self-check.sh" "$RELEASE_PATH"
ZIP_NAME="LUMIX-Tether-USB-Fix-${RELEASE_VERSION}-arm64.zip"
ZIP_PATH="${OUTPUT_DIR}/${ZIP_NAME}"
if (( DRY_RUN )); then
    print -r -- "Dry run passed; public ZIP would be: ${ZIP_PATH}"
    exit 0
fi
PACKAGE_TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lumix-tether-cli-package.XXXXXXXX")"
trap '[[ -z "$PACKAGE_TMP" ]] || /bin/rm -rf -- "$PACKAGE_TMP"' EXIT
STAGED_RELEASE="${PACKAGE_TMP}/${RELEASE_NAME}"
/bin/mkdir -p "$STAGED_RELEASE"
typeset -a ALLOWED_FILES
ALLOWED_FILES=(bin/s1h_iousbhost_probe 恢复S1H连接.command 'Restore S1H Connection.command'
               README.md README.zh-CN.md LICENSE CONTRIBUTING.md docs/TECHNICAL.md assets/alipay-donate.jpg)
for relative_path in "${ALLOWED_FILES[@]}"; do
    if [[ -f "${RELEASE_PATH}/${relative_path}" ]]; then
        /bin/mkdir -p "${STAGED_RELEASE}/${relative_path:h}"
        /usr/bin/ditto --norsrc --noextattr --noacl \
            "${RELEASE_PATH}/${relative_path}" "${STAGED_RELEASE}/${relative_path}"
    fi
done
"${SCRIPT_DIR}/self-check.sh" "$STAGED_RELEASE"
(
    cd "$PACKAGE_TMP"
    /usr/bin/zip -q -r -X "$ZIP_NAME" "$RELEASE_NAME"
)
/bin/mkdir "${PACKAGE_TMP}/unpacked"
/usr/bin/ditto -x -k "${PACKAGE_TMP}/${ZIP_NAME}" "${PACKAGE_TMP}/unpacked"
"${SCRIPT_DIR}/self-check.sh" "${PACKAGE_TMP}/unpacked/${RELEASE_NAME}"
/usr/bin/ditto --norsrc --noextattr --noacl "${PACKAGE_TMP}/${ZIP_NAME}" "$ZIP_PATH"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "$ZIP_NAME" > "${ZIP_NAME}.sha256"
)
print -r -- "Public CLI ZIP: ${ZIP_PATH}"
print -r -- "SHA-256: ${ZIP_PATH}.sha256"
