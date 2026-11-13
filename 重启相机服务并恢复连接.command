#!/bin/zsh
# Explicit opt-in: guarded current-user camera service restart, then USB recovery.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
exec /bin/zsh "$SCRIPT_DIR/恢复S1H连接.command" --restart-camera-service "$@"
