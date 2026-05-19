#!/usr/bin/env bash
# Sprint 32.5: register the `tallycoding://` URL scheme on Linux so
# Clerk's hosted sign-in can redirect back into the running Flutter app
# after the user signs in with GitHub.
#
# Run from this directory (linux/) after building the app at least
# once.  The script:
#   1. Symlinks the built flutter_app binary to /usr/local/bin/tally-coding-app
#      (so the .desktop file's `Exec=` resolves), OR if pkexec/sudo is
#      unavailable, drops a per-user wrapper at ~/.local/bin/.
#   2. Copies tally-coding.desktop to ~/.local/share/applications/.
#   3. Tells xdg this .desktop owns the tallycoding scheme.
#   4. Refreshes the desktop-file database.
#
# Re-run any time after a fresh `flutter build linux` — the symlink
# points at the same path so the binary is whatever the latest build
# emitted.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_LINUX="${HERE}"
BUNDLE_BIN="${REPO_LINUX}/../build/linux/x64/release/bundle/flutter_app"
[ -x "$BUNDLE_BIN" ] || BUNDLE_BIN="${REPO_LINUX}/../build/linux/x64/debug/bundle/flutter_app"
[ -x "$BUNDLE_BIN" ] || {
  echo "no flutter_app bundle found; build first with:" >&2
  echo "  (cd $(dirname "$REPO_LINUX") && flutter build linux --release)" >&2
  exit 1
}

WRAPPER="${HOME}/.local/bin/tally-coding-app"
mkdir -p "$(dirname "$WRAPPER")"
cat >"$WRAPPER" <<EOF
#!/usr/bin/env bash
exec "$BUNDLE_BIN" "\$@"
EOF
chmod +x "$WRAPPER"

# Patch the .desktop's Exec= to point at the per-user wrapper.
APP_DIR="${HOME}/.local/share/applications"
mkdir -p "$APP_DIR"
DESKTOP_OUT="${APP_DIR}/tally-coding.desktop"
sed "s|/usr/local/bin/tally-coding-app|${WRAPPER}|g" \
  "${REPO_LINUX}/tally-coding.desktop" >"$DESKTOP_OUT"
chmod 644 "$DESKTOP_OUT"

xdg-mime default tally-coding.desktop x-scheme-handler/tallycoding
update-desktop-database "$APP_DIR" 2>/dev/null || true

echo ">>> wrapper:   $WRAPPER"
echo ">>> desktop:   $DESKTOP_OUT"
echo ">>> xdg-mime:  registered tally-coding.desktop for x-scheme-handler/tallycoding"
echo
echo "Verify with:"
echo "  xdg-mime query default x-scheme-handler/tallycoding"
echo "  xdg-open 'tallycoding://auth/oauth?probe=1' &"
echo "(second command should launch / focus tally-coding)"
