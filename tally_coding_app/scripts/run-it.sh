#!/usr/bin/env bash
# Sprint 53+: integration_test runner under Xvfb.
#
# Boots the real Tally Coding Flutter app on Linux desktop inside a
# headless X server so the AI iteration loop doesn't take focus from
# the user's live session.  Passes through any args to `flutter test`
# so a specific file can be targeted:
#
#   ./scripts/run-it.sh                              # all integration_test/
#   ./scripts/run-it.sh integration_test/smoke_test.dart
#   ./scripts/run-it.sh --no-xvfb integration_test/  # run on real display
#
# Requires xvfb (xorg-server-xvfb on Arch) + dbus-run-session.
#
# Why separated Xvfb instead of `xvfb-run flutter test`:
# `xvfb-run` wraps flutter test's stdio in ways that confuse Flutter's
# log reader when it spawns the built Linux app — the test driver
# can't attach a debug connection and bails with "log reader stopped
# unexpectedly".  Starting Xvfb out-of-band and just exporting DISPLAY
# keeps the test driver's stdio untouched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER="${FLUTTER:-/home/nick/.local/flutter/bin/flutter}"

cd "$REPO_ROOT"

ARGS=("$@")
USE_XVFB=1
if [[ "${ARGS[0]:-}" == "--no-xvfb" ]]; then
  USE_XVFB=0
  ARGS=("${ARGS[@]:1}")
fi
if [[ ${#ARGS[@]} -eq 0 ]]; then
  ARGS=("integration_test/smoke_test.dart")
fi

run_flutter_test() {
  echo "[run-it] flutter test ${ARGS[*]} -d linux  (DISPLAY=$DISPLAY)"
  # LIBGL_ALWAYS_SOFTWARE forces Mesa's llvmpipe so we don't need a real
  # GPU under Xvfb.  dbus-run-session provides the session bus that
  # Clerk / app_links / shared_preferences expect.
  LIBGL_ALWAYS_SOFTWARE=1 \
  dbus-run-session -- "$FLUTTER" test "${ARGS[@]}" -d linux
}

if [[ "$USE_XVFB" == 1 ]] && command -v Xvfb >/dev/null 2>&1; then
  # Pick a free display number (>=99 to avoid clashing with real X11).
  for n in 99 100 101 102 103; do
    if [[ ! -e "/tmp/.X${n}-lock" ]]; then
      DISPLAY_NUM=$n
      break
    fi
  done
  : "${DISPLAY_NUM:?could not find a free X display number}"
  Xvfb ":${DISPLAY_NUM}" -screen 0 1280x800x24 +extension GLX -nolisten tcp >/dev/null 2>&1 &
  XVFB_PID=$!
  trap 'kill "$XVFB_PID" 2>/dev/null || true' EXIT
  # Give Xvfb a moment to come up.
  for _ in 1 2 3 4 5; do
    [[ -e "/tmp/.X${DISPLAY_NUM}-lock" ]] && break
    sleep 0.2
  done
  export DISPLAY=":${DISPLAY_NUM}"
  echo "[run-it] Xvfb up on $DISPLAY (pid=$XVFB_PID)"
  run_flutter_test
else
  if [[ "$USE_XVFB" == 1 ]]; then
    echo "[run-it] Xvfb not found; falling back to real display" >&2
  fi
  : "${DISPLAY:=:0}"
  export DISPLAY
  run_flutter_test
fi
