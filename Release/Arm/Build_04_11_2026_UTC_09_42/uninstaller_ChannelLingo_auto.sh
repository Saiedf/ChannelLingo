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
if ! mv "$PLUGIN" "$BACKUP/ChannelLingo"; then
    rmdir "$BACKUP" 2>/dev/null || :
    die "cannot move the plugin to the backup."
fi
say "ChannelLingo uninstalled."
say "Plugin files kept in: $BACKUP/ChannelLingo"
say "Settings, keys and earlier backups were kept."
say "Now restart Enigma2 (or restart the receiver)."
