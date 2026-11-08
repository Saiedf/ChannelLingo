#!/bin/sh
# ChannelLingo by iet5 - remove the plugin while keeping its files as a backup.
set -u
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
CHECK=0
case "$#:${1:-}" in
    0:) ;;
    1:--check) CHECK=1 ;;
    *) die "Usage: sh uninstall.sh [--check]" ;;
esac
# Tests only: use a temporary receiver filesystem instead of /.
ROOT=${CHANNELLINGO_ROOT:-}
PLUGIN="$ROOT/usr/lib/enigma2/python/Plugins/Extensions/ChannelLingo"
[ ! -L "$PLUGIN" ] || die "the plugin folder is a symbolic link; nothing was removed."
if [ ! -e "$PLUGIN" ]; then
    say "ChannelLingo is not installed. Nothing was changed."
    exit 0
fi
[ -d "$PLUGIN" ] || die "the plugin path is not a folder; nothing was removed."
say "Plugin to remove: $PLUGIN"
if [ "$CHECK" = 1 ]; then
    say "Would move it to a backup in $ROOT/home/root. Settings and keys are kept."
    say "(--check: nothing was changed.)"
    exit 0
fi
mkdir -p "$ROOT/home/root" || die "cannot create the backup folder; nothing was removed."
BACKUP=$(mktemp -d "$ROOT/home/root/ChannelLingo.uninstalled-XXXXXX") || die "cannot create a unique backup; nothing was removed."
RESTART=""
restart_gui() {
    case "$RESTART" in
        systemctl) systemctl start enigma2.service ;;
        init) init 3 ;;
    esac
}
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -n "$RESTART" ]; then
        if ! restart_gui; then
            say "ERROR: Could not restart Enigma2. Restart the receiver."
            result=1
        fi
    fi
    # Remove only an empty failed backup; a saved plugin always stays intact.
    rmdir "$BACKUP" 2>/dev/null || :
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet enigma2.service; then
    RESTART=systemctl
    systemctl stop enigma2.service || die "Cannot stop Enigma2; nothing was removed."
elif command -v pidof >/dev/null 2>&1 && pidof enigma2 >/dev/null 2>&1; then
    command -v init >/dev/null 2>&1 || die "Cannot stop Enigma2 automatically: init is missing."
    RESTART=init
    init 4 || die "Cannot stop Enigma2; nothing was removed."
    sleep 3 || die "Interrupted while stopping Enigma2; nothing was removed."
fi
if ! mv "$PLUGIN" "$BACKUP/ChannelLingo"; then
    die "cannot move the plugin to the backup."
fi
say "ChannelLingo uninstalled."
say "Plugin files kept in: $BACKUP/ChannelLingo"
say "Settings, keys and earlier backups were kept."
if [ -n "$RESTART" ]; then
    say "Restarting Enigma2 automatically."
else
    say "Enigma2 was not running; it remains stopped."
fi
