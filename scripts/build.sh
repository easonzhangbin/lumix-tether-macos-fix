#!/bin/zsh
# Compile and assemble our CLI release only; never access USB or start Tether.
set -euo pipefail
umask 022
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
RELEASE_NAME='LUMIX Tether USB Fix'
OUTPUT_DIR="${PROJECT_ROOT}/dist"
BUILD_TMP=''
DRY_RUN=0
die() { print -u2 -r -- "Build failed: $*"; exit 1; }
usage() {
    cat <<'USAGE'
Usage: scripts/build.sh [--output-dir DIRECTORY] [--dry-run]

Build an arm64 USB helper and two .command entrypoints. Official LUMIX Tether
2.12 must be installed separately; no Panasonic binaries are copied.

--dry-run validates inputs and tools without compiling or writing the release.
All build and static-check modes avoid the camera and never launch Tether.
USAGE
}
while (( $# )); do
    case "$1" in
        --output-dir)
            (( $# >= 2 )) || die '--output-dir needs a directory.'
            OUTPUT_DIR="${2:A}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || die 'macOS and Apple developer tools are required.'
for required_path in src/s1h_iousbhost_probe.m 恢复S1H连接.command README.md README.zh-CN.md LICENSE; do
    [[ -f "${PROJECT_ROOT}/${required_path}" ]] || die "Missing ${required_path}."
done
/bin/zsh -n "${PROJECT_ROOT}/恢复S1H连接.command"
CLANG_PATH="$(/usr/bin/xcrun --find clang)" || die 'Install Xcode or Command Line Tools.'
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" || die 'The macOS SDK is unavailable.'
[[ -x "$CLANG_PATH" ]] || die 'clang is unavailable.'
[[ -d "${SDK_PATH}/System/Library/Frameworks/IOUSBHost.framework" ]] || die 'The SDK must include IOUSBHost.framework.'
if (( DRY_RUN )); then
    print -r -- 'Dry run passed: arm64 only, macOS 12.0 minimum, native system frameworks.'
    print -r -- "Output would be: ${OUTPUT_DIR}/${RELEASE_NAME}"
    exit 0
fi
BUILD_TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lumix-tether-cli-build.XXXXXXXX")"
trap '[[ -z "$BUILD_TMP" ]] || /bin/rm -rf -- "$BUILD_TMP"' EXIT
STAGED_RELEASE="${BUILD_TMP}/${RELEASE_NAME}"
/bin/mkdir -p "${STAGED_RELEASE}/bin"
"$CLANG_PATH" -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks \
    -Wall -Wextra -Werror -O2 -isysroot "$SDK_PATH" \
    "${PROJECT_ROOT}/src/s1h_iousbhost_probe.m" \
    -framework Foundation -framework IOKit -framework IOUSBHost \
    -o "${STAGED_RELEASE}/bin/s1h_iousbhost_probe"
/usr/bin/codesign --force --sign - --timestamp=none "${STAGED_RELEASE}/bin/s1h_iousbhost_probe"
for document_name in README.md README.zh-CN.md LICENSE CONTRIBUTING.md docs/TECHNICAL.md assets/alipay-donate.jpg; do
    if [[ -f "${PROJECT_ROOT}/${document_name}" ]]; then
        /bin/mkdir -p "${STAGED_RELEASE}/${document_name:h}"
        /usr/bin/ditto --norsrc --noextattr --noacl \
            "${PROJECT_ROOT}/${document_name}" "${STAGED_RELEASE}/${document_name}"
    fi
done
/usr/bin/ditto --norsrc --noextattr --noacl \
    "${PROJECT_ROOT}/恢复S1H连接.command" "${STAGED_RELEASE}/恢复S1H连接.command"
# Same source, ordinary file: no symlink and no dependency on shell wrappers.
/usr/bin/ditto --norsrc --noextattr --noacl \
    "${PROJECT_ROOT}/恢复S1H连接.command" "${STAGED_RELEASE}/Restore S1H Connection.command"
/bin/chmod 755 "${STAGED_RELEASE}/恢复S1H连接.command" "${STAGED_RELEASE}/Restore S1H Connection.command"
"${SCRIPT_DIR}/self-check.sh" "$STAGED_RELEASE"
/bin/mkdir -p "$OUTPUT_DIR"
FINAL_RELEASE="${OUTPUT_DIR}/${RELEASE_NAME}"
# Replace this build-owned directory, avoiding stale files from earlier builds.
[[ ! -e "$FINAL_RELEASE" ]] || /bin/rm -rf -- "$FINAL_RELEASE"
/usr/bin/ditto --norsrc --noextattr --noacl "$STAGED_RELEASE" "$FINAL_RELEASE"
"${SCRIPT_DIR}/self-check.sh" "$FINAL_RELEASE"
print -r -- "Built CLI release: ${FINAL_RELEASE}"
