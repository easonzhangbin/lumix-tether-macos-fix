#!/bin/zsh
# Recover USB/PTP before launching official Tether in the system language.
set -euo pipefail
TASK_DIR="${0:A:h}"
CHECK_ONLY=0
LANGUAGE_OPTION=auto
TETHER_APP_OPTION=''
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --language) (( $# >= 2 )) || exit 2; LANGUAGE_OPTION="$2"; shift 2 ;;
        --tether-app) (( $# >= 2 )) || exit 2; TETHER_APP_OPTION="${2:A}"; shift 2 ;;
        -h|--help)
            print -- 'Usage: Restore S1H Connection.command [--check] [--language auto|zh|en|ja|de|es|fr|it|ru] [--tether-app PATH]'
            print -- 'Install official Tether 2.12 first. --check does not access the camera or launch Tether.'
            exit 0 ;;
        *) print -u2 -- "Unknown argument: $1"; exit 2 ;;
    esac
done
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
say() { if [[ "$TETHER_LANGUAGE" == zh ]]; then print -r -- "$1"; else print -r -- "$2"; fi; }
fail() { say "$1" "$2" >&2; exit 1; }
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail '此工具只支持 macOS。' 'This tool requires macOS.'
[[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || fail '此版本只支持 Apple 芯片 Mac。' 'This release requires an Apple silicon Mac.'
RECOVERY_HELPER=''
for CANDIDATE in "$TASK_DIR/bin/s1h_iousbhost_probe" "$TASK_DIR/diagnostics/s1h_iousbhost_probe"; do
    if [[ -x "$CANDIDATE" ]]; then RECOVERY_HELPER="$CANDIDATE"; break; fi
done
[[ -n "$RECOVERY_HELPER" ]] || fail '缺少恢复程序，请保留整个工具文件夹。' 'Recovery helper is missing. Keep the whole tool folder.'
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
[[ -n "$TETHER_APP" ]] || fail '未找到官方 Tether 2.12。请先安装，或用 --tether-app 指定路径。' 'Official Tether 2.12 was not found. Install it, or specify --tether-app PATH.'
if (( CHECK_ONLY )); then
    print -r -- "Tether: $TETHER_APP"
    print -r -- "Helper: $RECOVERY_HELPER"
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
for CAMERA_APP in 'LUMIX Tether' 'Preview' 'Image Capture' 'Photos'; do
    if /usr/bin/pgrep -x "$CAMERA_APP" >/dev/null 2>&1; then
        fail "请先正常退出 $CAMERA_APP，再运行本工具。" "Quit $CAMERA_APP normally, then run this tool again."
    fi
done
RECOVERY_LOG_DIR="$HOME/Library/Logs/LUMIX Tether USB Fix"
/bin/mkdir -p "$RECOVERY_LOG_DIR"
RECOVERY_STAMP="$(TZ=Asia/Shanghai /bin/date +%Y%m%d-%H%M%S)"
RECOVERY_LOG="$RECOVERY_LOG_DIR/recovery-$RECOVERY_STAMP-$$.log"
say '请保持相机开机并选择 PC(Tether)。正在恢复 USB 连接……' 'Keep the camera on in PC(Tether) mode. Restoring USB connection...'
print -r -- "Tether language: $TETHER_LANGUAGE" > "$RECOVERY_LOG"
if "$RECOVERY_HELPER" --io-buffer --drain-input 2>&1 | /usr/bin/tee -a "$RECOVERY_LOG"; then
    say 'USB 会话验证成功，正在按所选语言打开 Tether。' 'USB session verified. Opening Tether in the selected language.'
    /usr/bin/open -n "$TETHER_APP" --args "-lang=$TETHER_LANGUAGE"
    say '点击“开始”，再点击“实时取景”。' 'Click Start, then LV for live view.'
else
    fail "未恢复连接。请退出其他相机软件，拔线重连后再试。日志：$RECOVERY_LOG" "Recovery did not complete. Close camera apps, reconnect and retry. Log: $RECOVERY_LOG"
fi
