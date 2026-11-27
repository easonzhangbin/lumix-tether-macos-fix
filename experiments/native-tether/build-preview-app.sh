#!/bin/zsh
# Build only the independent experimental UI and the supplied native USB worker.
set -euo pipefail
TASK_DIR="${0:A:h}"
OUTPUT_DIR="${NATIVE_TETHER_OUTPUT_DIR:-$TASK_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
WORKER_PATH="${1:-$OUTPUT_DIR/s1h_native_preview}"
WORKER_PATH="${WORKER_PATH:A}"
APP_PATH="$OUTPUT_DIR/S1H Native Tether.app"
APP_EXECUTABLE=S1HNativeTether
APP_IDENTIFIER=com.easonzhang.s1h.nativetether
ICON_PATH="$TASK_DIR/assets/AppIcon.icns"
[[ -x "$WORKER_PATH" ]] || { print -u2 -- 'Build the native preview worker first, or pass its path.'; exit 1; }
[[ "$(/usr/bin/lipo -archs "$WORKER_PATH")" == arm64 ]] || { print -u2 -- 'The experimental worker must be arm64 only.'; exit 1; }
[[ -f "$ICON_PATH" ]] || { print -u2 -- 'Missing assets/AppIcon.icns.'; exit 1; }
/bin/mkdir -p "$OUTPUT_DIR"
TASK_BUILD_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.s1h-native-app.XXXXXXXX")"
STAGED_APP="$TASK_BUILD_DIR/S1H Native Tether.app"
PREVIOUS_APP="$TASK_BUILD_DIR/Previous.app"
PUBLISH_LOCK="$OUTPUT_DIR/.s1h-native-app.lock"
LOCK_HELD=0
cleanup() {
    if [[ -d "$PREVIOUS_APP" && ! -e "$APP_PATH" ]]; then
        if ! /bin/mv -- "$PREVIOUS_APP" "$APP_PATH"; then
            print -u2 -r -- "Previous app preserved at $PREVIOUS_APP"
            (( ! LOCK_HELD )) || /bin/rmdir -- "$PUBLISH_LOCK"
            return
        fi
    fi
    /bin/rm -rf -- "$TASK_BUILD_DIR"
    (( ! LOCK_HELD )) || /bin/rmdir -- "$PUBLISH_LOCK"
}
trap cleanup EXIT
/bin/mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks \
    -Wall -Wextra -Werror -O2 "$TASK_DIR/S1HNativePreviewApp.m" "$TASK_DIR/S1HControlPanel.m" \
    "$TASK_DIR/S1HBorderBeam.m" "$TASK_DIR/S1HCaptureConsole.m" "$TASK_DIR/S1HPreviewView.m" \
    -framework Cocoa -framework QuartzCore -framework CoreText -o "$STAGED_APP/Contents/MacOS/$APP_EXECUTABLE"
/usr/bin/ditto --norsrc --noextattr --noacl "$WORKER_PATH" "$STAGED_APP/Contents/Resources/s1h_native_preview"
/usr/bin/ditto --norsrc --noextattr --noacl "$ICON_PATH" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto --norsrc --noextattr --noacl "$TASK_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
for font in LG1055-Light.ttf LG1055_R.ttf; do
    font_path="$TASK_DIR/private/fonts/$font"
    if [[ -f "$font_path" ]]; then
        /bin/mkdir -p "$STAGED_APP/Contents/Resources/Fonts"
        /usr/bin/ditto --norsrc --noextattr --noacl "$font_path" "$STAGED_APP/Contents/Resources/Fonts/$font"
    fi
done
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP/Contents/Resources/s1h_native_preview"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.easonzhang.s1h.nativetether</string>
<key>CFBundleName</key><string>S1H Native Tether</string>
<key>CFBundleDisplayName</key><string>S1H Native Tether</string>
<key>CFBundleExecutable</key><string>S1HNativeTether</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.14</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP/Contents/Resources/s1h_native_preview"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
if ! /bin/mkdir -- "$PUBLISH_LOCK"; then
    print -u2 -- 'Another app build is writing this output directory.'
    exit 1
fi
LOCK_HELD=1
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    [[ -d "$APP_PATH" && ! -L "$APP_PATH" &&
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" == "$APP_IDENTIFIER" ]] || {
        print -u2 -- 'The app output path is occupied by a different item.'; exit 1;
    }
    RUNNING_EXECUTABLES="$(/bin/ps axww -o comm=)"
    if /usr/bin/grep -Fxq -e "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE" \
            -e "$APP_PATH/Contents/Resources/s1h_native_preview" <<< "$RUNNING_EXECUTABLES"; then
        print -u2 -- 'This output app is running. Choose another output directory or quit it before rebuilding.'
        exit 1
    fi
    /bin/mv -- "$APP_PATH" "$PREVIOUS_APP"
fi
/bin/mv -- "$STAGED_APP" "$APP_PATH"
print -r -- "$APP_PATH"
