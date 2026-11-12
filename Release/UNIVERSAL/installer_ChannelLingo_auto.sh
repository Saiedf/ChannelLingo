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
# Use persistent receiver storage for interrupted downloads, when available.
# /tmp remains available for extraction only and is always cleaned.
CACHE_ROOT=${CHANNELLINGO_CACHE_DIR:-}
if [ -z "$CACHE_ROOT" ]; then
    if awk '$2 == "/media/hdd" {found=1} END {exit !found}' /proc/mounts 2>/dev/null && [ -d /media/hdd ]; then
        CACHE_ROOT=/media/hdd/.channellingo-installer-cache
    else
        CACHE_ROOT=/tmp/.channellingo-installer-cache
    fi
fi
mkdir -p "$CACHE_ROOT" || die "Cannot create persistent download cache."
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
# Per-attempt timeout limits stalled transfers without losing the partial file.
TIMEOUT_MODE=none
if command -v timeout >/dev/null 2>&1; then
    if timeout 1 sh -c 'exit 0' >/dev/null 2>&1; then
        TIMEOUT_MODE=modern
    elif timeout -t 1 sh -c 'exit 0' >/dev/null 2>&1; then
        TIMEOUT_MODE=legacy
    fi
fi
fetch_once() {
    url=$1
    dest=$2
    resume=$3
    if [ "$FETCH" = curl ]; then
        if [ "$resume" = yes ]; then
            set -- curl -fL --connect-timeout 15 --max-time 180 --speed-limit 1024 --speed-time 45 -C - -o "$dest" "$url"
        else
            set -- curl -fL --connect-timeout 15 --max-time 90 -o "$dest" "$url"
        fi
    else
        if [ "$resume" = yes ]; then
            set -- wget -c -T 25 -O "$dest" "$url"
        else
            set -- wget -T 25 -O "$dest" "$url"
        fi
    fi
    case "$TIMEOUT_MODE" in
        modern) timeout 180 "$@" ;;
        legacy) timeout -t 180 "$@" ;;
        *) "$@" ;;
    esac
}
fetch_retry() {
    url=$1 dest=$2 resume=$3
    attempt=1
    while [ "$attempt" -le 12 ]; do
        say "Download attempt $attempt/12 ..."
        if fetch_once "$url" "$dest" "$resume"; then
            [ -s "$dest" ] && return 0
        fi
        if [ -f "$dest" ]; then
            bytes=$(wc -c < "$dest" | tr -d ' ')
            say "Partial file preserved: $bytes bytes."
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le 12 ] && sleep 3
    done
    return 1
}
ZIP="$CACHE_ROOT/ChannelLingo-universal.zip"
CHECKSUM="$WORK/checksum"
say "ChannelLingo by IET5 - automatic download and installation"
say "Download cache: $CACHE_ROOT"
say "Downloading package checksum..."
fetch_retry "$BASE/ChannelLingo-universal.zip.sha256" "$CHECKSUM" no || die "Cannot download package checksum."
EXPECTED=$(awk 'NR == 1 {print $1}' "$CHECKSUM")
[ "${#EXPECTED}" = 64 ] || die "Invalid checksum file."
case "$EXPECTED" in *[!0-9a-fA-F]*) die "Invalid checksum file." ;; esac
checksum_ok() {
    [ -s "$ZIP" ] || return 1
    ACTUAL=$(sha256sum "$ZIP")
    ACTUAL=${ACTUAL%% *}
    [ "$EXPECTED" = "$ACTUAL" ]
}
if checksum_ok; then
    say "Previously downloaded package is valid; skipping download."
else
    say "Downloading the universal package (resumable)..."
    fetch_retry "$BASE/ChannelLingo-universal.zip" "$ZIP" yes || die "Download interrupted. Partial file kept in $ZIP; rerun to resume."
    if ! checksum_ok; then
        say "Checksum mismatch: retrying once from a clean download."
        rm -f "$ZIP"
        fetch_retry "$BASE/ChannelLingo-universal.zip" "$ZIP" yes || die "Download interrupted. Partial file preserved; rerun to resume."
        checksum_ok || die "Package checksum mismatch after clean download. Nothing was installed."
    fi
fi
# Extraction and installation always use the verified archive.
cp "$ZIP" "$WORK/ChannelLingo-universal.zip" || die "Cannot copy verified package to temporary directory."
say "Package checksum verified."
if [ -n "$PY" ]; then
    "$PY" -m zipfile -e "$WORK/ChannelLingo-universal.zip" "$WORK"
else
    unzip -q "$WORK/ChannelLingo-universal.zip" -d "$WORK"
fi
INSTALL="$WORK/ChannelLingo-universal/install.sh"
[ -f "$INSTALL" ] || die "The archive has no installer."
# Check compatibility while Enigma2 is running: some images load libpython
# dynamically, so its ELF dependencies alone cannot identify Python after init 4.
PREFLIGHT=$(sh "$INSTALL" --check) || die "Compatibility check failed; nothing was installed."
say "$PREFLIGHT"
EXPECTED_FACTS=$(printf '%s\n' "$PREFLIGHT" | awk '/^This receiver: Python / {print}')
VERSION=$(printf '%s\n' "$PREFLIGHT" | awk '/^This receiver: Python / {print $4}')
[ -n "$EXPECTED_FACTS" ] && [ -n "$VERSION" ] || die "The package did not report its Python requirements. Nothing was installed."
INSTALL_PYTHON=""
for candidate in "python$VERSION" python3 python python2; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    # Match version, pointer size, Unicode ABI and processor to the successful
    # preflight; do not select an interpreter merely because it is on PATH.
    observed=$("$candidate" -S -c 'import platform, struct, sys
if getattr(sys, "abiflags", "") or hasattr(sys, "gettotalrefcount"):
    sys.exit(1)
width = ("ucs2" if sys.maxunicode == 65535 else "ucs4") if sys.version_info[0] == 2 else "-"
print("This receiver: Python %d.%d (%s), %d-bit, processor %s." %
    (sys.version_info[0], sys.version_info[1], width, struct.calcsize("P") * 8, platform.machine().lower()))' 2>/dev/null) || continue
    if [ "$observed" = "$EXPECTED_FACTS" ]; then
        INSTALL_PYTHON=$candidate
        break
    fi
done
[ -n "$INSTALL_PYTHON" ] || die "No interpreter matches the successful compatibility check. Nothing was installed."
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
# Keep the already verified interpreter after the GUI has stopped. The package
# still reads its actual ABI and selects/checks the build before replacing files.
CHANNELLINGO_PYTHON="$INSTALL_PYTHON" sh "$INSTALL"
say "ChannelLingo installation completed."
# cleanup restarts Enigma2 if it was running, then removes this run's temporary files.
