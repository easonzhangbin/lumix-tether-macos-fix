#!/bin/zsh
# Package our own app and documentation only. Never access a camera or launch apps.
set -euo pipefail
umask 022
TASK_DIR="${0:A:h}"
PROJECT_ROOT="${TASK_DIR:h:h}"
[[ -f "$PROJECT_ROOT/src/s1h_iousbhost_probe.m" ]] || PROJECT_ROOT="$PROJECT_ROOT/lumix-tether-macos-fix"
APP_PATH="${GUARDIAN_OUTPUT_DIR:-$TASK_DIR/build}/LUMIX Connection Guardian.app"
[[ -d "$APP_PATH" ]] || { print -u2 -- 'Build Guardian first.'; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" == '0.2.1' ]] || { print -u2 -- 'Unexpected app version.'; exit 1; }
ARCHIVE_NAME="LUMIX-Connection-Guardian-${VERSION}-arm64.zip"
TASK_PACKAGE_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lumix-guardian-package.XXXXXXXX")"
trap '/bin/rm -rf -- "$TASK_PACKAGE_DIR"' EXIT
STAGE="$TASK_PACKAGE_DIR/LUMIX Connection Guardian"
/bin/mkdir -p "$STAGE/assets"
/usr/bin/ditto --norsrc --noextattr --noacl "$APP_PATH" "$STAGE/LUMIX Connection Guardian.app"
for name in README.md README.zh-CN.md; do
    /usr/bin/ditto --norsrc --noextattr --noacl "$TASK_DIR/$name" "$STAGE/$name"
done
/usr/bin/ditto --norsrc --noextattr --noacl "$PROJECT_ROOT/LICENSE" "$STAGE/LICENSE"
/usr/bin/ditto --norsrc --noextattr --noacl "$PROJECT_ROOT/assets/alipay-donate.jpg" "$STAGE/assets/alipay-donate.jpg"
/usr/bin/codesign --verify --deep --strict "$STAGE/LUMIX Connection Guardian.app"
(
    cd "$TASK_PACKAGE_DIR"
    /usr/bin/zip -q -r -X "$ARCHIVE_NAME" 'LUMIX Connection Guardian'
)
/bin/mkdir "$TASK_PACKAGE_DIR/unpacked"
/usr/bin/ditto -x -k "$TASK_PACKAGE_DIR/$ARCHIVE_NAME" "$TASK_PACKAGE_DIR/unpacked"
/usr/bin/codesign --verify --deep --strict "$TASK_PACKAGE_DIR/unpacked/LUMIX Connection Guardian/LUMIX Connection Guardian.app"
/bin/mkdir -p "$TASK_DIR/dist"
/usr/bin/ditto --norsrc --noextattr --noacl "$TASK_PACKAGE_DIR/$ARCHIVE_NAME" "$TASK_DIR/dist/$ARCHIVE_NAME"
(
    cd "$TASK_DIR/dist"
    /usr/bin/shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
print -r -- "Packaged Guardian beta: $TASK_DIR/dist/$ARCHIVE_NAME"
