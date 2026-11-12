#!/bin/sh
# ChannelLingo by IET5 - unattended receiver installer.
set -eu
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Run this installer as root."
# jsDelivr mirrors GitHub through a CDN and can be far faster than raw.githubusercontent.com, which some
# networks throttle heavily - but it caches a branch like "main" only briefly (each new build changes this
# path), so right after a release it is often an uncached, double-hop fetch that is slower than GitHub
# directly, not faster. GitHub stays the default first try; jsDelivr is still tried as a second option, since
# a later install (once jsDelivr's edge has warmed up) may well find it the quicker of the two.
if [ -n "${CHANNELLINGO_DOWNLOAD_BASE:-}" ]; then
    BASES=$CHANNELLINGO_DOWNLOAD_BASE
else
    BASES="https://raw.githubusercontent.com/Saiedf/ChannelLingo/main/Release/UNIVERSAL
https://cdn.jsdelivr.net/gh/Saiedf/ChannelLingo@main/Release/UNIVERSAL"
fi
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
        # --speed-limit/--speed-time: give up on a mirror that crawls (under 2KB/s for 20s straight)
        # instead of sitting on one slow source for the full --max-time, so the next mirror gets a turn.
        set -- curl -fL --retry 2 --connect-timeout 30 --speed-limit 2048 --speed-time 20 --max-time 180 -o "$2" "$1"
    else
        set -- wget -T 20 -O "$2" "$1"
    fi
    # Bound the whole transfer too, including a server that keeps sending tiny pieces (wget has no
    # minimum-speed option of its own, so this outer cap is its only defense against crawling along).
    case "$TIMEOUT_MODE" in
        modern) timeout 180 "$@" ;;
        legacy) timeout -t 180 "$@" ;;
        *) "$@" ;;
    esac
}
say "ChannelLingo by IET5 - automatic download and installation"
say "Downloading the universal package..."
# Each candidate is tried in full (zip and its checksum from the same mirror) before moving to the next,
# so a mirror that is merely slow still finishes rather than being abandoned mid-transfer.
BASE=""
for candidate in $BASES; do
    say "Trying $candidate ..."
    if fetch "$candidate/ChannelLingo-universal.zip" "$WORK/ChannelLingo-universal.zip" &&
       fetch "$candidate/ChannelLingo-universal.zip.sha256" "$WORK/checksum"; then
        BASE=$candidate
        break
    fi
    say "That source did not answer; trying the next one."
done
[ -n "$BASE" ] || die "Download failed from every source. Check internet access and that the repository is public."
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
