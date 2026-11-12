#!/bin/sh
# ChannelLingo by IET5 - unattended receiver installer.
set -eu
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Run this installer as root."
# jsDelivr was tried here as a second mirror, but it rejects this package outright (HTTP 403): the universal
# zip bundles every architecture and runs well past jsDelivr's public size limit for a GitHub-sourced file.
# GitHub raw is the only real option until the package is split small enough for a CDN mirror to carry it.
if [ -n "${CHANNELLINGO_DOWNLOAD_BASE:-}" ]; then
    BASES=$CHANNELLINGO_DOWNLOAD_BASE
else
    BASES="https://raw.githubusercontent.com/Saiedf/ChannelLingo/main/Release/UNIVERSAL"
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
# Persistent download cache: reuse the partial file from earlier installer runs.
CACHE_ROOT=${CHANNELLINGO_CACHE_DIR:-}
if [ -z "$CACHE_ROOT" ]; then
    if [ -d /media/hdd ] && awk '$2 == "/media/hdd" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
        CACHE_ROOT=/media/hdd/.channellingo-installer-cache
    else
        CACHE_ROOT=/tmp/.channellingo-installer-cache
    fi
fi
mkdir -p "$CACHE_ROOT" || die "Cannot create download cache."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/channellingo-install-XXXXXX") || die "Cannot create temporary folder."
RESTART=""
DOWNLOAD_PID=""
restart_gui() {
    case "$RESTART" in
        systemctl) systemctl start enigma2.service ;;
        init) init 3 ;;
    esac
}
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -n "$DOWNLOAD_PID" ]; then
        kill "$DOWNLOAD_PID" 2>/dev/null || :
        wait "$DOWNLOAD_PID" 2>/dev/null || :
    fi
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
# No overall download time limit. Only connection/low-speed detection is used.
# Interrupted downloads are kept in the persistent cache; retries resume them.
fetch_once() {
    url=$1
    dest=$2
    resume=$3
    if [ "$FETCH" = curl ]; then
        if [ "$resume" = yes ]; then
            # -C - resumes at the size of the existing partial file.
            # --speed-time is not a total duration limit: it only detects stalls.
            curl -fL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -C - -o "$dest" "$url"
        else
            curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$dest" "$url"
        fi
    else
        if [ "$resume" = yes ]; then
            wget -q -c -T 60 -O "$dest" "$url"
        else
            wget -q -T 60 -O "$dest" "$url"
        fi
    fi
}
# Discover the full archive length from HTTP Content-Range (206), not from the
# resumed curl progress meter, which only measures the current transfer.
TOTAL_BYTES=""
get_total_bytes() {
    url=$1
    hdr="$WORK/package-headers"
    if [ "$FETCH" = curl ]; then
        curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
            -r 0-0 -D "$hdr" -o /dev/null "$url" || return 0
    else
        wget -q -S --header='Range: bytes=0-0' -O /dev/null "$url" 2> "$hdr" || return 0
    fi
    found=$(awk 'tolower($0) ~ /^content-range:/ {gsub("\r", "", $0); split($0, a, "/"); n=a[2]; if (n ~ /^[0-9]+$/) last=n} END {print last}' "$hdr")
    case "$found" in ''|*[!0-9]*) ;; *) TOTAL_BYTES=$found ;; esac
}

# Show progress for the ENTIRE file, including bytes saved by earlier runs.
# Speed measures growth of the local cache, not curl's resumed segment.
progress_line() {
    current=$1
    delta=$2
    rate=$(awk -v d="$delta" 'BEGIN {printf "%.1f", d/5/1024}')
    if [ -n "$TOTAL_BYTES" ] && [ "$TOTAL_BYTES" -gt 0 ]; then
        awk -v a="$current" -v t="$TOTAL_BYTES" -v r="$rate" 'BEGIN {
            left=t-a; if(left<0) left=0
            pct=100*a/t; if(pct>100) pct=100
            printf "\rTotal: %.1f / %.1f MiB | Remaining: %.1f MiB | %.1f%% | %.1f KiB/s     ", a/1048576,t/1048576,left/1048576,pct,r
        }'
    else
        awk -v a="$current" -v r="$rate" 'BEGIN {printf "\rDownloaded: %.1f MiB | %.1f KiB/s (total unknown)     ",a/1048576,r}'
    fi
}

fetch_with_progress() {
    url=$1
    dest=$2
    resume=$3
    # Launch only the ZIP transfer in background, to read the growing file size.
    fetch_once "$url" "$dest" "$resume" &
    DOWNLOAD_PID=$!
    previous=0
    [ ! -f "$dest" ] || previous=$(wc -c < "$dest" | tr -d ' ')
    while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
        sleep 5
        current=0
        [ ! -f "$dest" ] || current=$(wc -c < "$dest" | tr -d ' ')
        delta=$((current - previous))
        [ "$delta" -ge 0 ] || delta=0
        progress_line "$current" "$delta"
        previous=$current
    done
    current=0
    [ ! -f "$dest" ] || current=$(wc -c < "$dest" | tr -d ' ')
    delta=$((current - previous))
    [ "$delta" -ge 0 ] || delta=0
    progress_line "$current" "$delta"
    printf '\n'
    if wait "$DOWNLOAD_PID"; then
        DOWNLOAD_PID=""
        return 0
    fi
    DOWNLOAD_PID=""
    return 1
}

fetch_retry() {
    url=$1
    dest=$2
    resume=$3
    attempts=0
    while :; do
        attempts=$((attempts + 1))
        say "Download attempt $attempts (no total time limit)..."
        if { [ "$resume" = yes ] && fetch_with_progress "$url" "$dest" "$resume" || [ "$resume" != yes ] && fetch_once "$url" "$dest" "$resume"; } && [ -s "$dest" ]; then
            return 0
        fi
        if [ -f "$dest" ]; then
            bytes=$(wc -c < "$dest" | tr -d ' ')
            say "Download interrupted; saved $bytes bytes. Will resume."
        fi
        say "Reconnecting in 5 seconds. Press Ctrl+C to stop."
        sleep 5
    done
}
ZIP="$CACHE_ROOT/ChannelLingo-universal.zip"
CHECKSUM="$WORK/checksum"
checksum_ok() {
    [ -s "$ZIP" ] || return 1
    ACTUAL=$(sha256sum "$ZIP") || return 1
    ACTUAL=${ACTUAL%% *}
    [ "$EXPECTED" = "$ACTUAL" ]
}
say "ChannelLingo by IET5 - automatic download and installation"
say "Persistent download cache: $CACHE_ROOT"
say "Downloading the package checksum..."
# Keep checksum and archive on the same mirror.
BASE=""
for candidate in $BASES; do
    # The default mirror is GitHub Raw. Optional alternate mirrors can be
    # selected with CHANNELLINGO_DOWNLOAD_BASE.
    BASE=$candidate
    break
done
[ -n "$BASE" ] || die "No download source configured."
fetch_retry "$BASE/ChannelLingo-universal.zip.sha256" "$CHECKSUM" no
EXPECTED=$(awk 'NR == 1 {print $1}' "$WORK/checksum")
[ "${#EXPECTED}" = 64 ] || die "Invalid checksum file."
case "$EXPECTED" in *[!0-9a-fA-F]*) die "Invalid checksum file." ;; esac
if checksum_ok; then
    say "Cached package already verified. Skipping download."
else
    say "Downloading universal package with automatic resume (no total time limit)..."
    get_total_bytes "$BASE/ChannelLingo-universal.zip"
    if [ -n "$TOTAL_BYTES" ]; then
        say "Archive size: $TOTAL_BYTES bytes (total progress includes cached data)."
    else
        say "Could not determine archive size; downloaded bytes will still be shown."
    fi
    if [ -s "$ZIP" ]; then
        say "Resuming existing partial file: $(wc -c < "$ZIP" | tr -d ' ') bytes."
    fi
    fetch_retry "$BASE/ChannelLingo-universal.zip" "$ZIP" yes
    if ! checksum_ok; then
        # A fully downloaded but corrupted/obsolete ZIP is not safe to install.
        # Clear it once and re-fetch the archive, validating the final SHA-256.
        say "Checksum mismatch. Restarting a clean download once."
        rm -f "$ZIP"
        fetch_retry "$BASE/ChannelLingo-universal.zip" "$ZIP" yes
        checksum_ok || die "Package checksum mismatch after clean download. Nothing installed."
    fi
fi
say "Package checksum verified."
cp "$ZIP" "$WORK/ChannelLingo-universal.zip" || die "Cannot stage verified package."
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
