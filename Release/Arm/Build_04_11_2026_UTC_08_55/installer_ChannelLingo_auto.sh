#!/bin/sh
# ChannelLingo by IET5 - unattended receiver installer.
set -eu
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Run this installer as root."
BASE=${CHANNELLINGO_DOWNLOAD_BASE:-https://raw.githubusercontent.com/Saiedf/ChannelLingo/main/Release/UNIVERSAL}
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
if command -v curl >/dev/null 2>&1; then
    FETCH=curl
elif command -v wget >/dev/null 2>&1; then
    FETCH=wget
else
    die "curl or wget is required."
fi
PY=""
if ! command -v unzip >/dev/null 2>&1; then
    for candidate in python3 python python2; do
        if command -v "$candidate" >/dev/null 2>&1; then PY=$candidate; break; fi
    done
    [ -n "$PY" ] || die "unzip or Python is required."
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/channellingo-install-XXXXXX") || die "Cannot create temporary folder."
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
    rm -rf "$WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# BusyBox images may use "timeout -t SECONDS", while GNU/new BusyBox use "timeout SECONDS".
TIMEOUT_MODE=none
if command -v timeout >/dev/null 2>&1; then
    if timeout 1 sh -c 'exit 0' >/dev/null 2>&1; then
        TIMEOUT_MODE=modern
    elif timeout -t 1 sh -c 'exit 0' >/dev/null 2>&1; then
        TIMEOUT_MODE=legacy
    fi
fi
fetch() {
    if [ "$FETCH" = curl ]; then
        set -- curl -fL --retry 2 --connect-timeout 30 --max-time 900 -o "$2" "$1"
    else
        set -- wget -T 30 -O "$2" "$1"
    fi
    # Bound the whole transfer too, including a server that keeps sending tiny pieces.
    case "$TIMEOUT_MODE" in
        modern) timeout 900 "$@" ;;
        legacy) timeout -t 900 "$@" ;;
        *) "$@" ;;
    esac
}
say "ChannelLingo by IET5 - automatic download and installation"
say "Downloading the universal package..."
fetch "$BASE/ChannelLingo-universal.zip" "$WORK/ChannelLingo-universal.zip" || die "Download failed. Check internet access and that the repository is public."
fetch "$BASE/ChannelLingo-universal.zip.sha256" "$WORK/checksum" || die "Cannot download the package checksum."
EXPECTED=$(awk 'NR == 1 {print $1}' "$WORK/checksum")
[ "${#EXPECTED}" = 64 ] || die "Invalid checksum file."
case "$EXPECTED" in *[!0-9a-fA-F]*) die "Invalid checksum file." ;; esac
ACTUAL=$(sha256sum "$WORK/ChannelLingo-universal.zip")
ACTUAL=${ACTUAL%% *}
[ "$EXPECTED" = "$ACTUAL" ] || die "Package checksum mismatch. Nothing was installed."
say "Package checksum verified."
if [ -n "$PY" ]; then
    "$PY" -m zipfile -e "$WORK/ChannelLingo-universal.zip" "$WORK"
else
    unzip -q "$WORK/ChannelLingo-universal.zip" -d "$WORK"
fi
INSTALL="$WORK/ChannelLingo-universal/install.sh"
[ -f "$INSTALL" ] || die "The archive has no installer."
# Check compatibility before interrupting the receiver's running interface.
sh "$INSTALL" --check
PLUGIN="${CHANNELLINGO_ROOT:-}/usr/lib/enigma2/python/Plugins/Extensions/ChannelLingo"
if [ -e "$PLUGIN" ] || [ -L "$PLUGIN" ]; then
    say "ChannelLingo by IET5: an existing installation was found; replacing it automatically."
else
    say "ChannelLingo by IET5: installing a new copy."
fi
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet enigma2.service; then
    RESTART=systemctl
    systemctl stop enigma2.service
elif command -v pidof >/dev/null 2>&1 && pidof enigma2 >/dev/null 2>&1; then
    command -v init >/dev/null 2>&1 || die "Cannot stop Enigma2 automatically: init is missing."
    RESTART=init
    init 4
    sleep 3
fi
sh "$INSTALL"
say "ChannelLingo installation completed."
# cleanup restarts Enigma2 if it was running, then removes this run's temporary files.
