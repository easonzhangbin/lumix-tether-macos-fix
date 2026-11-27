#!/bin/zsh
# Static checks only: never execute the helper/entrypoints or access a camera.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
RELEASE_PATH="${PROJECT_ROOT}/dist/LUMIX Tether USB Fix"
PATH_ARGUMENT_SET=0
die() { print -u2 -r -- "Self-check failed: $*"; exit 1; }
while (( $# )); do
    case "$1" in
        -h|--help)
            print -r -- 'Usage: scripts/self-check.sh [RELEASE_DIRECTORY]'
            exit 0 ;;
        --*) die "Unknown argument: $1" ;;
        *)
            (( PATH_ARGUMENT_SET == 0 )) || die 'Only one release directory is accepted.'
            RELEASE_PATH="${1:A}"; PATH_ARGUMENT_SET=1; shift ;;
    esac
done
[[ -d "$RELEASE_PATH" ]] || die "Missing release directory: ${RELEASE_PATH}"
typeset -a ALLOWED_FILES
ALLOWED_FILES=(bin/s1h_iousbhost_probe bin/s1h_camera_service VERSION 恢复S1H连接.command 'Restore S1H Connection.command'
               重启相机服务并恢复连接.command 'Restart Camera Service and Restore.command'
               README.md README.zh-CN.md LICENSE CONTRIBUTING.md docs/TECHNICAL.md assets/alipay-donate.jpg)
for item_path in "${RELEASE_PATH}"/**/*(DN); do
    [[ ! -L "$item_path" ]] || die 'Release symlinks are not allowed.'
    relative_path="${item_path#${RELEASE_PATH}/}"
    [[ "$item_path" != *.app && "$item_path" != *.pkg ]] || die 'Vendor app/package content is forbidden.'
    if [[ -d "$item_path" ]]; then
        [[ "$relative_path" == bin || "$relative_path" == docs || "$relative_path" == assets ]] || die "Unexpected release directory: ${relative_path}"
    else
        # Finder metadata is tolerated in a local directory but never packaged.
        [[ "${item_path:t}" != .DS_Store && "${item_path:t}" != ._* ]] || continue
        (( ${ALLOWED_FILES[(Ie)$relative_path]} != 0 )) || die "Unexpected release file: ${relative_path}"
    fi
done
for required_file in bin/s1h_iousbhost_probe bin/s1h_camera_service VERSION 恢复S1H连接.command 'Restore S1H Connection.command' 重启相机服务并恢复连接.command 'Restart Camera Service and Restore.command' README.md README.zh-CN.md LICENSE; do
    [[ -f "${RELEASE_PATH}/${required_file}" ]] || die "Missing ${required_file}."
done
for helper_name in s1h_iousbhost_probe s1h_camera_service; do
    HELPER_PATH="${RELEASE_PATH}/bin/${helper_name}"
    [[ -x "$HELPER_PATH" ]] || die "Helper must be executable: ${helper_name}"
    [[ "$(/usr/bin/lipo -archs "$HELPER_PATH")" == arm64 ]] || die "Helper must contain only arm64: ${helper_name}"
    /usr/bin/codesign --verify --strict "$HELPER_PATH" || die "Invalid helper signature: ${helper_name}"
done
for command_name in 恢复S1H连接.command 'Restore S1H Connection.command' 重启相机服务并恢复连接.command 'Restart Camera Service and Restore.command'; do
    [[ -x "${RELEASE_PATH}/${command_name}" ]] || die "Entrypoint is not executable: ${command_name}"
    /bin/zsh -n "${RELEASE_PATH}/${command_name}"
done
/usr/bin/cmp -s "${RELEASE_PATH}/恢复S1H连接.command" "${RELEASE_PATH}/Restore S1H Connection.command" ||
    die 'The English entrypoint must match the canonical command.'
/usr/bin/cmp -s "${RELEASE_PATH}/重启相机服务并恢复连接.command" "${RELEASE_PATH}/Restart Camera Service and Restore.command" ||
    die 'The English restart entrypoint must match the canonical restart command.'
print -r -- "Static CLI self-check passed: ${RELEASE_PATH}"
