#!/bin/zsh
# Isolated routing tests. The production command is copied into a temporary
# fixture and its process, signature, launch and helper dependencies are mocked.
# The only real native-helper execution permitted here is the service helper's
# pure --self-test mode: no device enumeration, USB open or process signals.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
RELEASE_PATH="${PROJECT_ROOT}/dist/LUMIX Tether USB Fix"
MOCK_ONLY=0
TEST_ROOT=''
die() { print -u2 -r -- "Recovery test failed: $*"; exit 1; }
while (( $# )); do
    case "$1" in
        --release-dir)
            (( $# >= 2 )) || die '--release-dir needs a directory.'
            RELEASE_PATH="${2:A}"; shift 2 ;;
        --mock-only) MOCK_ONLY=1; shift ;;
        -h|--help)
            print -r -- 'Usage: scripts/test-recovery.sh [--release-dir DIRECTORY] [--mock-only]'
            print -r -- 'Runs isolated shell mocks and the native service helper pure --self-test; no camera access or signals.'
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
for source_name in 恢复S1H连接.command 重启相机服务并恢复连接.command; do
    [[ -f "${PROJECT_ROOT}/${source_name}" ]] || die "Missing ${source_name}."
    /bin/zsh -n "${PROJECT_ROOT}/${source_name}"
done
if (( ! MOCK_ONLY )); then
    [[ -x "${RELEASE_PATH}/bin/s1h_camera_service" ]] || die 'Build the release before running native guard self-tests.'
fi

TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lumix-recovery-tests.XXXXXXXX")"
# Match the production command's :A path canonicalization (including /var's
# symlink and the extra slash commonly present at the end of TMPDIR).
TEST_ROOT="${TEST_ROOT:A}"
trap '[[ -z "$TEST_ROOT" ]] || /bin/rm -rf -- "$TEST_ROOT"' EXIT
FIXTURE_DIR="${TEST_ROOT}/fixture"
MOCK_TOOLS_DIR="${TEST_ROOT}/tools"
TEST_HOME_DIR="${TEST_ROOT}/test-home"
MOCK_APP="${TEST_ROOT}/Fake Official Tether.app"
MOCK_EVENT_LOG="${TEST_ROOT}/events.log"
/bin/mkdir -p "${FIXTURE_DIR}/bin" "$MOCK_TOOLS_DIR" "$TEST_HOME_DIR" "${MOCK_APP}/Contents"
cat > "${MOCK_APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>isb-152.LUMIXTether</string>
<key>CFBundleShortVersionString</key><string>2.12</string>
</dict></plist>
PLIST

cat > "${MOCK_TOOLS_DIR}/defaults" <<'MOCK'
#!/bin/zsh
printf '(\n    "en-US"\n)\n'
MOCK
cat > "${MOCK_TOOLS_DIR}/sysctl" <<'MOCK'
#!/bin/zsh
[[ "$*" == '-n hw.optional.arm64' ]] || exit 1
print 1
MOCK
cat > "${MOCK_TOOLS_DIR}/PlistBuddy" <<'MOCK'
#!/bin/zsh
[[ "${argv[-1]}" == "$MOCK_APP/Contents/Info.plist" ]] || exit 1
case "$*" in
    *CFBundleIdentifier*) print 'isb-152.LUMIXTether' ;;
    *CFBundleShortVersionString*) print '2.12' ;;
    *) exit 1 ;;
esac
MOCK
cat > "${MOCK_TOOLS_DIR}/codesign" <<'MOCK'
#!/bin/zsh
[[ "$*" == *"$MOCK_APP"* ]]
MOCK
cat > "${MOCK_TOOLS_DIR}/pgrep" <<'MOCK'
#!/bin/zsh
if [[ -n "$MOCK_RUNNING_APP" && "${argv[-1]}" == "$MOCK_RUNNING_APP" ]]; then
    print 424242
    exit 0
fi
exit 1
MOCK
cat > "${MOCK_TOOLS_DIR}/open" <<'MOCK'
#!/bin/zsh
print -r -- "open $*" >> "$MOCK_EVENT_LOG"
exit "$MOCK_OPEN_EXIT"
MOCK
cat > "${MOCK_TOOLS_DIR}/forbidden" <<'MOCK'
#!/bin/zsh
print -r -- "FORBIDDEN $*" >> "$MOCK_EVENT_LOG"
exit 97
MOCK
cat > "${FIXTURE_DIR}/bin/s1h_iousbhost_probe" <<'MOCK'
#!/bin/zsh
print -r -- "probe $*" >> "$MOCK_EVENT_LOG"
[[ "$*" == '--io-buffer --drain-input' ]] || exit 98
exit "$MOCK_PROBE_EXIT"
MOCK
cat > "${FIXTURE_DIR}/bin/s1h_camera_service" <<'MOCK'
#!/bin/zsh
print -r -- "service $*" >> "$MOCK_EVENT_LOG"
case "$*" in
    --inspect) exit "$MOCK_INSPECT_EXIT" ;;
    --restart-camera-service) exit "$MOCK_GUARD_EXIT" ;;
    *) exit 98 ;;
esac
MOCK
/bin/chmod 755 "${MOCK_TOOLS_DIR}"/* "${FIXTURE_DIR}/bin/"*

# Only this test copy gets redirected. Production gains no override mechanism.
COMMAND_SOURCE="$(< "${PROJECT_ROOT}/恢复S1H连接.command")"
redirect_tool() {
    local original_path="$1" replacement_path="$2"
    COMMAND_SOURCE="${COMMAND_SOURCE//${original_path}/${(q)replacement_path}}"
}
redirect_tool /usr/bin/defaults "${MOCK_TOOLS_DIR}/defaults"
redirect_tool /usr/sbin/sysctl "${MOCK_TOOLS_DIR}/sysctl"
redirect_tool /usr/libexec/PlistBuddy "${MOCK_TOOLS_DIR}/PlistBuddy"
redirect_tool /usr/bin/codesign "${MOCK_TOOLS_DIR}/codesign"
redirect_tool /usr/bin/pgrep "${MOCK_TOOLS_DIR}/pgrep"
redirect_tool /usr/bin/open "${MOCK_TOOLS_DIR}/open"
for dangerous_tool in /usr/bin/killall /usr/bin/pkill /bin/launchctl /usr/bin/sudo /bin/kill; do
    redirect_tool "$dangerous_tool" "${MOCK_TOOLS_DIR}/forbidden"
done
# Keep log output and user-application fallback inside the test directory.
# The actual HOME environment variable remains unchanged.
COMMAND_SOURCE="${COMMAND_SOURCE//'$HOME'/$TEST_HOME_DIR}"
{
    print -r -- '#!/bin/zsh'
    print -r -- 'kill() { "$MOCK_TOOLS_DIR/forbidden" builtin-kill "$@"; }'
    print -r -- 'killall() { "$MOCK_TOOLS_DIR/forbidden" killall "$@"; }'
    print -r -- 'pkill() { "$MOCK_TOOLS_DIR/forbidden" pkill "$@"; }'
    print -r -- 'launchctl() { "$MOCK_TOOLS_DIR/forbidden" launchctl "$@"; }'
    print -r -- 'sudo() { "$MOCK_TOOLS_DIR/forbidden" sudo "$@"; }'
    print -r -- "$COMMAND_SOURCE"
} > "${FIXTURE_DIR}/恢复S1H连接.command"
/usr/bin/ditto --norsrc --noextattr --noacl "${PROJECT_ROOT}/重启相机服务并恢复连接.command" \
    "${FIXTURE_DIR}/重启相机服务并恢复连接.command"
/bin/zsh -n "${FIXTURE_DIR}/恢复S1H连接.command"
export MOCK_APP MOCK_EVENT_LOG MOCK_TOOLS_DIR
export MOCK_PROBE_EXIT=0 MOCK_GUARD_EXIT=0 MOCK_INSPECT_EXIT=0 MOCK_OPEN_EXIT=0 MOCK_RUNNING_APP=''
WITH_TETHER=1
TEST_ENTRYPOINT="${FIXTURE_DIR}/恢复S1H连接.command"
TEST_COUNT=0
LAST_OUTPUT=''

run_case() {
    local case_name="$1" expected_exit="$2" actual_exit
    shift 2
    local -a fixture_args
    fixture_args=(--language en)
    (( WITH_TETHER == 0 )) || fixture_args+=(--tether-app "$MOCK_APP")
    : > "$MOCK_EVENT_LOG"
    LAST_OUTPUT="${TEST_ROOT}/${case_name}.output"
    if /bin/zsh "$TEST_ENTRYPOINT" "${fixture_args[@]}" "$@" </dev/null > "$LAST_OUTPUT" 2>&1; then
        actual_exit=0
    else
        actual_exit=$?
    fi
    if (( actual_exit != expected_exit )); then
        /bin/cat "$LAST_OUTPUT" >&2
        die "${case_name}: expected exit ${expected_exit}, got ${actual_exit}."
    fi
    (( TEST_COUNT += 1 ))
    print -r -- "PASS ${case_name}"
}
assert_actions() {
    local expected_actions="$1" actual_actions
    actual_actions="$(< "$MOCK_EVENT_LOG")"
    if [[ "$actual_actions" != "$expected_actions" ]]; then
        print -u2 -r -- "Expected actions: ${expected_actions}"
        print -u2 -r -- "Actual actions: ${actual_actions}"
        /bin/cat "$LAST_OUTPUT" >&2
        die 'Unexpected helper/launch routing.'
    fi
}
OPEN_ACTION="open -n ${MOCK_APP} --args -lang=en"
PROBE_ACTION='probe --io-buffer --drain-input'
RESTART_ACTION='service --restart-camera-service'
INSPECT_ACTION='service --inspect'

run_case version 0 --version
assert_actions ''
[[ "$(< "$LAST_OUTPUT")" == 1.0.1 ]] || die 'Unexpected command version.'
run_case check 0 --check
assert_actions ''
run_case check_with_restart 0 --check --restart-camera-service
assert_actions ''
run_case normal_success 0
assert_actions "${PROBE_ACTION}"$'\n'"${OPEN_ACTION}"
run_case explicit_restart_success 0 --restart-camera-service
assert_actions "${RESTART_ACTION}"$'\n'"${PROBE_ACTION}"$'\n'"${OPEN_ACTION}"
TEST_ENTRYPOINT="${FIXTURE_DIR}/重启相机服务并恢复连接.command"
run_case restart_wrapper 0
assert_actions "${RESTART_ACTION}"$'\n'"${PROBE_ACTION}"$'\n'"${OPEN_ACTION}"
TEST_ENTRYPOINT="${FIXTURE_DIR}/恢复S1H连接.command"
MOCK_GUARD_EXIT=12
run_case guard_refuses 1 --restart-camera-service
assert_actions "$RESTART_ACTION"
MOCK_GUARD_EXIT=0
MOCK_PROBE_EXIT=22
run_case usb_open_failure 1
assert_actions "${PROBE_ACTION}"$'\n'"${INSPECT_ACTION}"
MOCK_PROBE_EXIT=23
run_case usb_drain_failure 1
assert_actions "${PROBE_ACTION}"$'\n'"${INSPECT_ACTION}"
run_case usb_failure_after_restart 1 --restart-camera-service
assert_actions "${RESTART_ACTION}"$'\n'"${PROBE_ACTION}"$'\n'"${INSPECT_ACTION}"
MOCK_PROBE_EXIT=0
MOCK_RUNNING_APP='LUMIX Tether'
run_case tether_already_running 1
assert_actions ''
MOCK_RUNNING_APP=''
WITH_TETHER=0
run_case diagnose_without_tether 0 --diagnose
assert_actions "$INSPECT_ACTION"
WITH_TETHER=1
run_case incompatible_modes 2 --diagnose --restart-camera-service
assert_actions ''
MOCK_OPEN_EXIT=14
run_case launch_failure 1
assert_actions "${PROBE_ACTION}"$'\n'"${OPEN_ACTION}"
MOCK_OPEN_EXIT=0
print -r -- "Isolated command routing: ${TEST_COUNT} cases passed."

if (( ! MOCK_ONLY )); then
    print -r -- 'Running native camera-service pure self-test (no hardware or signals).'
    "${RELEASE_PATH}/bin/s1h_camera_service" --self-test
fi
