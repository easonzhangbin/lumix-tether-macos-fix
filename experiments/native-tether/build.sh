#!/bin/zsh
# Compile and self-test only. Building never opens the camera or launches UI.
set -euo pipefail
TASK_DIR="${0:A:h}"
OUTPUT_DIR="${NATIVE_TETHER_OUTPUT_DIR:-$TASK_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
WORKER_ONLY=0
[[ $# -le 1 ]] || { print -u2 -- 'Usage: ./build.sh [--worker-only]'; exit 2; }
case "${1:-}" in
    '') ;;
    --worker-only) WORKER_ONLY=1 ;;
    --help|-h)
        print -- 'Usage: ./build.sh [--worker-only]'
        print -- 'NATIVE_TETHER_OUTPUT_DIR sets the local build output directory (default: build beside this script).'
        exit 0 ;;
    *) print -u2 -- 'Unknown argument.'; exit 2 ;;
esac
[[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] || {
    print -u2 -- 'This experimental build requires an Apple silicon Mac.'; exit 1;
}
/bin/mkdir -p "$OUTPUT_DIR"
TASK_BUILD_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.s1h-native-worker.XXXXXXXX")"
trap '/bin/rm -rf -- "$TASK_BUILD_DIR"' EXIT
WORKER_PATH="$TASK_BUILD_DIR/s1h_native_preview"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks \
    -Wall -Wextra -Werror -O2 "$TASK_DIR/s1h_native_preview.m" \
    -framework Foundation -framework IOKit -framework IOUSBHost \
    -framework ImageIO -framework CoreGraphics -o "$WORKER_PATH"
/usr/bin/codesign --force --sign - --timestamp=none "$WORKER_PATH"
/usr/bin/codesign --verify --strict "$WORKER_PATH"
"$WORKER_PATH" --self-test
if (( ! WORKER_ONLY )); then
    NATIVE_TETHER_OUTPUT_DIR="$OUTPUT_DIR" /bin/zsh "$TASK_DIR/build-preview-app.sh" "$WORKER_PATH"
fi
[[ ! -L "$OUTPUT_DIR/s1h_native_preview" && ! -d "$OUTPUT_DIR/s1h_native_preview" ]] || {
    print -u2 -- 'Worker output path must be a regular file or absent.'; exit 1;
}
/bin/mv -f -- "$WORKER_PATH" "$OUTPUT_DIR/s1h_native_preview"
if (( WORKER_ONLY )); then print -r -- "$OUTPUT_DIR/s1h_native_preview"; fi
