#!/bin/zsh
# Compile our menu-bar supervisor and native helpers; never open a camera or app.
set -euo pipefail
TASK_DIR="${0:A:h}"
PROJECT_ROOT="${TASK_DIR:h:h}"
[[ -f "$PROJECT_ROOT/src/s1h_iousbhost_probe.m" ]] || PROJECT_ROOT="$PROJECT_ROOT/lumix-tether-macos-fix"
OUTPUT_DIR="${GUARDIAN_OUTPUT_DIR:-$TASK_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
APP_PATH="$OUTPUT_DIR/LUMIX Connection Guardian.app"
ICON_PATH="$TASK_DIR/assets/GuardianAppIcon.icns"
[[ -f "$ICON_PATH" ]] || { print -u2 -- 'Missing assets/GuardianAppIcon.icns.'; exit 1; }
# Other installed copies may stay open; never replace this output app while running.
while IFS= read -r running_executable; do
    if [[ "$running_executable" == "$APP_PATH/Contents/MacOS/LUMIXConnectionGuardian" ]]; then
        print -u2 -- 'Quit this output copy of LUMIX Connection Guardian before rebuilding it.'
        exit 1
    fi
done < <(/bin/ps -axo comm=)
TASK_BUILD_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lumix-guardian-build.XXXXXXXX")"
trap '/bin/rm -rf -- "$TASK_BUILD_DIR"' EXIT
STAGE="$TASK_BUILD_DIR/LUMIX Connection Guardian.app"
/bin/mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
/usr/bin/ditto --norsrc --noextattr --noacl "$ICON_PATH" "$STAGE/Contents/Resources/GuardianAppIcon.icns"
CLANG="$(/usr/bin/xcrun --find clang)"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
COMMON=(-arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks -Wall -Wextra -Werror -O2 -isysroot "$SDK_PATH")
"$CLANG" "${COMMON[@]}" "$PROJECT_ROOT/src/s1h_iousbhost_probe.m" \
    -framework Foundation -framework IOKit -framework IOUSBHost \
    -o "$STAGE/Contents/Resources/s1h_iousbhost_probe"
"$CLANG" "${COMMON[@]}" "$PROJECT_ROOT/src/s1h_camera_service.m" \
    -framework Foundation -framework IOKit \
    -o "$STAGE/Contents/Resources/s1h_camera_service"
for name in s1h_iousbhost_probe s1h_camera_service; do
    /usr/bin/codesign --force --sign - --timestamp=none "$STAGE/Contents/Resources/$name"
    "$STAGE/Contents/Resources/$name" --self-test
done
"$CLANG" "${COMMON[@]}" "$TASK_DIR/tests/GuardianEventLogTests.m" "$TASK_DIR/GuardianEventLog.m" \
    -framework Foundation -o "$TASK_BUILD_DIR/GuardianEventLogTests"
"$TASK_BUILD_DIR/GuardianEventLogTests"
"$CLANG" "${COMMON[@]}" "$TASK_DIR/tests/GuardianPolicyTests.m" "$TASK_DIR/GuardianEventLog.m" \
    -framework Cocoa -framework Security -o "$TASK_BUILD_DIR/GuardianPolicyTests"
"$TASK_BUILD_DIR/GuardianPolicyTests"
"$CLANG" "${COMMON[@]}" "$TASK_DIR/GuardianApp.m" "$TASK_DIR/GuardianController.m" "$TASK_DIR/GuardianEventLog.m" \
    -framework Cocoa -framework Security -o "$STAGE/Contents/MacOS/LUMIXConnectionGuardian"
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.easonzhang.lumix.connectionguardian</string>
<key>CFBundleName</key><string>LUMIX Connection Guardian</string>
<key>CFBundleDisplayName</key><string>LUMIX Connection Guardian</string>
<key>CFBundleExecutable</key><string>LUMIXConnectionGuardian</string>
<key>CFBundleIconFile</key><string>GuardianAppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --timestamp=none "$STAGE"
/usr/bin/codesign --verify --deep --strict "$STAGE"
/bin/mkdir -p "$OUTPUT_DIR"
[[ ! -e "$APP_PATH" ]] || /bin/rm -rf -- "$APP_PATH"
/usr/bin/ditto --norsrc --noextattr --noacl "$STAGE" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
print -r -- "Built without camera access: $APP_PATH"
