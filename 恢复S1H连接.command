#!/bin/zsh
# Recover USB/PTP before launching official Tether in the system language.
set -euo pipefail
TASK_DIR="${0:A:h}"
VERSION_ONLY=0
CHECK_ONLY=0
DIAGNOSE_ONLY=0
RESTART_CAMERA_SERVICE=0
LANGUAGE_OPTION=auto
TETHER_APP_OPTION=''
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --diagnose) DIAGNOSE_ONLY=1; shift ;;
        --restart-camera-service) RESTART_CAMERA_SERVICE=1; shift ;;
        --version) VERSION_ONLY=1; break ;;
        --language) (( $# >= 2 )) || exit 2; LANGUAGE_OPTION="$2"; shift 2 ;;
        --tether-app) (( $# >= 2 )) || exit 2; TETHER_APP_OPTION="${2:A}"; shift 2 ;;
        -h|--help)
            print -- 'Usage: Restore S1H Connection.command [--check | --diagnose] [--restart-camera-service] [--language auto|zh|en|ja|de|es|fr|it|ru] [--tether-app PATH]'
            print -- 'Install official Tether 2.12 first. --check does not access the camera or launch Tether.'
            print -- '--diagnose reads USB ownership and process metadata without opening USB or launching Tether.'
            print -- '--restart-camera-service explicitly permits a guarded restart of the current user camera service.'
            exit 0 ;;
        *) print -u2 -- "Unknown argument: $1"; exit 2 ;;
    esac
done
if (( DIAGNOSE_ONLY && (CHECK_ONLY || RESTART_CAMERA_SERVICE) )); then
    print -u2 -- '--diagnose cannot be combined with --check or --restart-camera-service.'
    exit 2
fi
SYSTEM_FIRST_LANGUAGE="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | /usr/bin/awk '
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "");
      if ($0 == "(" || $0 == ")" || $0 == "") next;
      gsub(/[",]/, ""); print; exit; }
' || true)"
if [[ "$LANGUAGE_OPTION" == auto ]]; then
    TETHER_LANGUAGE="${SYSTEM_FIRST_LANGUAGE%%[-_]*}"
    TETHER_LANGUAGE="${TETHER_LANGUAGE:l}"
    case "$TETHER_LANGUAGE" in zh|en|ja|de|es|fr|it|ru) ;; *) TETHER_LANGUAGE=en ;; esac
else
    TETHER_LANGUAGE="${LANGUAGE_OPTION:l}"
    case "$TETHER_LANGUAGE" in zh|en|ja|de|es|fr|it|ru) ;; *) print -u2 -- 'Unsupported language'; exit 2 ;; esac
fi
RECOVERY_LOG=''
say() {
    local MESSAGE="$2"
    [[ "$TETHER_LANGUAGE" != zh ]] || MESSAGE="$1"
    print -r -- "$MESSAGE"
    [[ -z "$RECOVERY_LOG" ]] || print -r -- "$MESSAGE" >> "$RECOVERY_LOG"
    return 0
}
fail() { say "$1" "$2" >&2; exit 1; }
TOOL_VERSION=''
if [[ -f "$TASK_DIR/VERSION" ]]; then
    TOOL_VERSION="$(< "$TASK_DIR/VERSION")" 2>/dev/null || TOOL_VERSION=''
fi
[[ -n "$TOOL_VERSION" ]] || fail '无法读取版本，请重新解压整个工具文件夹。' 'Version is unavailable. Extract the complete tool folder.'
if (( VERSION_ONLY )); then
    print -r -- "$TOOL_VERSION"
    exit 0
fi
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail '此工具只支持 macOS。' 'This tool requires macOS.'
[[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || fail '此版本只支持 Apple 芯片 Mac。' 'This release requires an Apple silicon Mac.'
RECOVERY_HELPER=''
for CANDIDATE in "$TASK_DIR/bin/s1h_iousbhost_probe" "$TASK_DIR/diagnostics/s1h_iousbhost_probe"; do
    if [[ -x "$CANDIDATE" ]]; then RECOVERY_HELPER="$CANDIDATE"; break; fi
done
[[ -n "$RECOVERY_HELPER" ]] || fail '缺少恢复程序，请保留整个工具文件夹。' 'Recovery helper is missing. Keep the whole tool folder.'
SERVICE_HELPER=''
for CANDIDATE in "$TASK_DIR/bin/s1h_camera_service" "$TASK_DIR/diagnostics/s1h_camera_service"; do
    if [[ -x "$CANDIDATE" ]]; then SERVICE_HELPER="$CANDIDATE"; break; fi
done
[[ -n "$SERVICE_HELPER" ]] || fail '缺少相机服务检查程序，请重新解压整个新版工具文件夹。' 'Camera service helper is missing. Extract the complete updated tool folder.'
valid_tether() {
    local CANDIDATE="$1"
    local INFO="$CANDIDATE/Contents/Info.plist"
    [[ -f "$INFO" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null)" == isb-152.LUMIXTether ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null)" == 2.12 ]] || return 1
    /usr/bin/codesign --verify --deep -R='anchor apple generic and certificate leaf[subject.OU] = "7R6S626R47"' "$CANDIDATE" >/dev/null 2>&1
}
TETHER_APP=''
if [[ -n "$TETHER_APP_OPTION" ]]; then
    valid_tether "$TETHER_APP_OPTION" || fail '指定应用不是签名有效的松下官方 Tether 2.12。' 'The selected app is not a valid Panasonic-signed Tether 2.12.'
    TETHER_APP="$TETHER_APP_OPTION"
else
    for CANDIDATE in '/Applications/LUMIX Tether.app' "$HOME/Applications/LUMIX Tether.app" "$TASK_DIR/LUMIX Tether.app" "$TASK_DIR/diagnostics/LUMIXTether-v2_12-expanded/LUMIXTether.pkg/Payload/LUMIX Tether.app"; do
        if valid_tether "$CANDIDATE"; then TETHER_APP="$CANDIDATE"; break; fi
    done
fi
if (( ! DIAGNOSE_ONLY )); then
    [[ -n "$TETHER_APP" ]] || fail '未找到官方 Tether 2.12。请先安装，或用 --tether-app 指定路径。' 'Official Tether 2.12 was not found. Install it, or specify --tether-app PATH.'
fi
if (( CHECK_ONLY )); then
    print -r -- "Tether: $TETHER_APP"
    print -r -- "Helper: $RECOVERY_HELPER"
    print -r -- "Service helper: $SERVICE_HELPER"
    print -r -- "System preferred language: ${SYSTEM_FIRST_LANGUAGE:-unknown}"
    print -r -- "Launch argument: -lang=$TETHER_LANGUAGE"
    say '检查通过；未访问相机、未启动 Tether。' 'Check passed; no camera access or Tether launch.'
    exit 0
fi
recovery_exit() {
    local RECOVERY_EXIT_CODE=$?
    if [[ -t 0 ]]; then
        print
        if [[ "$TETHER_LANGUAGE" == zh ]]; then read -r '?按回车结束。' || true;
        else read -r '?Press Return to finish.' || true; fi
    fi
    return "$RECOVERY_EXIT_CODE"
}
trap recovery_exit EXIT
RECOVERY_LOG_DIR="$HOME/Library/Logs/LUMIX Tether USB Fix"
/bin/mkdir -p "$RECOVERY_LOG_DIR"
RECOVERY_STAMP="$(TZ=Asia/Shanghai /bin/date +%Y%m%d-%H%M%S)"
RECOVERY_LOG="$RECOVERY_LOG_DIR/recovery-$RECOVERY_STAMP-$$.log"
{
    print -r -- "Tool version: $TOOL_VERSION"
    print -r -- "macOS: $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    print -r -- "Tether: ${TETHER_APP:-not found}"
    print -r -- "Tether language: $TETHER_LANGUAGE"
    print -r -- "Mode: diagnose=$DIAGNOSE_ONLY restart-camera-service=$RESTART_CAMERA_SERVICE"
} > "$RECOVERY_LOG"
run_logged() { "$@" 2>&1 | /usr/bin/tee -a "$RECOVERY_LOG"; }
say "日志：$RECOVERY_LOG" "Log: $RECOVERY_LOG"
if (( DIAGNOSE_ONLY )); then
    say '只读检查：不打开 USB、不重启服务、不启动 Tether。' 'Read-only check: no USB open, service restart or Tether launch.'
    run_logged "$SERVICE_HELPER" --inspect
    say "诊断日志：$RECOVERY_LOG" "Diagnostic log: $RECOVERY_LOG"
    exit 0
fi
# The service helper is the only owner of the camera/import software list.
# A running application is a conservative blocker, not proof of USB ownership.
INSPECTION_JSON="$RECOVERY_LOG_DIR/inspection-$RECOVERY_STAMP-$$.json"
"$SERVICE_HELPER" --inspect > "$INSPECTION_JSON" 2>> "$RECOVERY_LOG" ||
    fail "无法确认相机软件状态；未执行 USB 恢复、未启动 Tether。日志：$RECOVERY_LOG" "Camera software could not be checked; no USB probe or Tether launch. Log: $RECOVERY_LOG"
/bin/cat "$INSPECTION_JSON" >> "$RECOVERY_LOG"
CAMERA_APPS_PLIST="$(/usr/bin/plutil -extract known_camera_apps xml1 -o - "$INSPECTION_JSON" 2>/dev/null)" ||
    fail "无法读取相机软件状态；未执行 USB 恢复、未启动 Tether。日志：$RECOVERY_LOG" "Camera software state was unreadable; no USB probe or Tether launch. Log: $RECOVERY_LOG"
CAMERA_APP_NAMES="$(print -r -- "$CAMERA_APPS_PLIST" | /usr/bin/awk '
    /<key>name<\/key>/ { wanted = 1; next }
    wanted && /<string>/ { gsub(/.*<string>|<\/string>.*/, ""); list = list (list ? ", " : "") $0; wanted = 0 }
    END { print list }')"
if [[ -n "$CAMERA_APP_NAMES" ]]; then
    fail "请先正常退出 $CAMERA_APP_NAMES，再运行本工具。" "Quit $CAMERA_APP_NAMES normally, then run this tool again."
fi
if (( RESTART_CAMERA_SERVICE )); then
    say '检查 USB 占用与应用状态，按明确选择重启当前用户的相机服务……' 'Checking USB ownership and camera apps before the explicitly selected camera service restart...'
    if ! run_logged "$SERVICE_HELPER" --restart-camera-service; then
        fail "相机服务检查未通过；未执行 USB 恢复、未启动 Tether。日志：$RECOVERY_LOG" "Camera service check refused recovery; no USB probe or Tether launch. Log: $RECOVERY_LOG"
    fi
fi
say '请保持相机开机并选择 PC(Tether)。正在恢复 USB 连接……' 'Keep the camera on in PC(Tether) mode. Restoring USB connection...'
if run_logged "$RECOVERY_HELPER" --io-buffer --drain-input; then
    say 'USB 会话验证成功，正在按所选语言打开 Tether。' 'USB session verified. Opening Tether in the selected language.'
    if ! /usr/bin/open -n "$TETHER_APP" --args "-lang=$TETHER_LANGUAGE"; then
        fail "USB 已验证，但未能打开 Tether。日志：$RECOVERY_LOG" "USB was verified, but Tether could not be opened. Log: $RECOVERY_LOG"
    fi
    say '点击“开始”，再点击“实时取景”。' 'Click Start, then LV for live view.'
else
    RECOVERY_RESULT=$?
    case "$RECOVERY_RESULT" in
        20) say '未找到相机的 PTP 接口：请检查相机开机、数据线和 PC(Tether) 模式。' 'No camera PTP interface found: check power, data cable and PC(Tether) mode.' ;;
        21) say '检测到多个匹配接口：请只连接一台相机再恢复。' 'Multiple matching interfaces found: connect only one camera before recovery.' ;;
        22) say '无法打开相机接口：需要检查实际占用与访问权限。' 'The camera interface could not be opened: check actual ownership and access permissions.' ;;
        23) say '未能确认旧响应已完整排空：已停止，未发送新的相机命令。' 'Pending responses could not be fully cleared: stopped before sending new camera commands.' ;;
        24) say '新的 PTP 会话验证未通过：未启动 Tether。' 'Fresh PTP session validation failed: Tether was not launched.' ;;
        124) say '恢复程序达到时间上限：未启动 Tether。' 'Recovery reached its time limit: Tether was not launched.' ;;
    esac
    print -r -- "USB helper exit status: $RECOVERY_RESULT" >> "$RECOVERY_LOG"
    say '恢复失败，下面只读检查 USB 占用；不会自动重启服务。' 'Recovery failed. Checking USB ownership read-only; the service will not be restarted automatically.'
    run_logged "$SERVICE_HELPER" --inspect || true
    say '若报告相机服务仍占用接口，请先退出所有相机和导入软件，再运行“重启相机服务并恢复连接.command”。' 'If the camera service still owns the interface, quit all camera/import apps and run Restart Camera Service and Restore.command.'
    fail "未恢复连接。若设备未识别，请检查数据线与 PC(Tether) 模式。日志：$RECOVERY_LOG" "Recovery did not complete. If no device is found, check the data cable and PC(Tether) mode. Log: $RECOVERY_LOG"
fi
