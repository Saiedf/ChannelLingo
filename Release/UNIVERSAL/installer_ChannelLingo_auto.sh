#!/bin/sh
# ChannelLingo by IET5 - unattended receiver installer.
set -eu
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Run this installer as root."
# Boot and multiboot protection: operate on the current root filesystem only.
# Refuse alternate roots that could redirect installation into a Barry Allen image.
case "${CHANNELLINGO_ROOT:-}" in
    ""|/) : ;;
    *) die "Boot protection: CHANNELLINGO_ROOT must be unset or /. Alternate image roots are forbidden." ;;
esac
# Guard the selected plugin directory against symbolic-link redirection.
# readlink -f is available on typical BusyBox receivers.
PLUGIN_PARENT=/usr/lib/enigma2/python/Plugins/Extensions
PLUGIN_FIXED="$PLUGIN_PARENT/ChannelLingo"
if [ -L "$PLUGIN_FIXED" ]; then
    die "Boot protection: plugin directory is a symlink; refusing to follow it."
fi
command -v readlink >/dev/null 2>&1 || die "readlink is required for boot-path protection."
plugin_parent=$(readlink -f "$PLUGIN_PARENT" 2>/dev/null) || die "Cannot resolve plugin parent."
[ "$plugin_parent" = "$PLUGIN_PARENT" ] || die "Boot protection: plugin parent redirects to $plugin_parent"
# Refuse temporary/cache directories under boot or Barry Allen image storage.
# This matters because the installer removes its own temporary work directory.
guard_storage_root() {
    candidate=$1
    case "$candidate" in
        /*) : ;;
        *) die "Boot protection: storage location must be an absolute path: $candidate" ;;
    esac
    case "$candidate" in
        /|/boot|/boot/*|/ba|/ba/*|/media/ba|/media/ba/*|/media/flash|/media/flash/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
            die "Boot protection: unsafe storage location: $candidate" ;;
    esac
    if command -v readlink >/dev/null 2>&1; then
        resolved=$(readlink -f "$candidate" 2>/dev/null) || true
        if [ -z "$resolved" ]; then
            # Candidate does not exist yet (not created until later). Some BusyBox
            # readlink builds cannot canonicalize a missing leaf component, so fall
            # back to resolving the existing parent and reattaching the leaf name.
            parent_resolved=$(readlink -f "$(dirname "$candidate")" 2>/dev/null) || die "Cannot resolve storage path: $candidate"
            resolved="$parent_resolved/$(basename "$candidate")"
        fi
        case "$resolved" in
            /|/boot|/boot/*|/ba|/ba/*|/media/ba|/media/ba/*|/media/flash|/media/flash/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
                die "Boot protection: storage redirects to protected path: $resolved" ;;
        esac
    fi
}
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
# Validate all ZIP entries before extraction, using the image's Python 2.7/3.x.
ARCHIVE_PYTHON=""
for candidate in python3 python python2; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -S -c 'import sys, zipfile, stat; sys.exit(0)' >/dev/null 2>&1; then
        ARCHIVE_PYTHON=$candidate
        break
    fi
done
[ -n "$ARCHIVE_PYTHON" ] || die "Python with zipfile is required for safe extraction."
# /media/hdd (a mounted drive, typically much larger than the receiver's own root/tmpfs) is
# preferred, both for the persistent download cache and for the scratch extraction work below:
# the archive is validated and unpacked in full before anything is installed, and that needs
# roughly twice the package size free. The receiver's own /tmp is often a small tmpfs.
large_storage_root() {
    if [ -d /media/hdd ] && awk '$2 == "/media/hdd" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
        if command -v df >/dev/null 2>&1; then
            # Compare actual free space; a mounted drive is not always the bigger one.
            tmp_free=$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}')
            hdd_free=$(df -Pk /media/hdd 2>/dev/null | awk 'NR==2 {print $4}')
            case "$tmp_free" in ''|*[!0-9]*) tmp_free=0 ;; esac
            case "$hdd_free" in ''|*[!0-9]*) hdd_free=0 ;; esac
            if [ "$hdd_free" -gt "$tmp_free" ]; then
                printf '%s\n' /media/hdd
            else
                printf '%s\n' /tmp
            fi
        else
            # No way to compare; a mounted drive is still the safer default over a small tmpfs.
            printf '%s\n' /media/hdd
        fi
    else
        printf '%s\n' /tmp
    fi
}
# Persistent download cache: reuse the partial file from earlier installer runs.
CACHE_ROOT=${CHANNELLINGO_CACHE_DIR:-}
if [ -z "$CACHE_ROOT" ]; then
    CACHE_ROOT=$(large_storage_root)/.channellingo-installer-cache
fi
# Resolve and validate the cache and scratch roots BEFORE creating anything.
# Cache location may not already exist; normalize via its existing parent.
cache_parent=$(dirname "$CACHE_ROOT")
guard_storage_root "$cache_parent"
guard_storage_root "$CACHE_ROOT"
TEMP_ROOT=${TMPDIR:-$(large_storage_root)}
guard_storage_root "$TEMP_ROOT"
mkdir -p "$CACHE_ROOT" || die "Cannot create download cache."
guard_storage_root "$CACHE_ROOT"
WORK=$(mktemp -d "$TEMP_ROOT/channellingo-install-XXXXXX") || die "Cannot create temporary folder."
guard_storage_root "$WORK"
RESTART=""
DOWNLOAD_PID=""
PACKAGE_SOURCE="unknown"
INITIAL_CACHED_BYTES=0
INSTALL_SUCCESS=no
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
    # Only delete the exact temporary directory created by mktemp.
    case "$WORK" in
        "$TEMP_ROOT"/channellingo-install-*)
            if [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
                rm -rf -- "$WORK"
            fi ;;
        *) say "WARNING: refused unsafe workdir cleanup: $WORK" >&2 ;;
    esac
    if [ "$result" -eq 0 ] && [ "$INSTALL_SUCCESS" = yes ]; then
        # Remove only ChannelLingo download artifacts, not a user-selected
        # cache directory or unrelated files that may exist in it.
        if rm -f "$ZIP" "$CACHE_ROOT/.cache-created-at"; then
            say "Download cache cleared after successful installation: $ZIP"
        else
            say "WARNING: Could not remove downloaded ZIP cache: $ZIP" >&2
        fi
        say "============================================================"
        say "SUCCESS: ChannelLingo installed successfully."
        say "Installation status: SUCCESS (exit code 0)"
        say "============================================================"
    elif [ "$result" -ne 0 ]; then
        say "FAILED: ChannelLingo installer exited with code $result." >&2
    fi
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
            curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -C - -o "$dest" "$url"
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

# For a resumed ZIP, HTTP 416 at EOF is not a network failure. Verify
# the cached file BEFORE making another Range request.
fetch_retry() {
    url=$1
    dest=$2
    resume=$3
    attempts=0
    while :; do
        if [ "$resume" = yes ] && [ -s "$dest" ]; then
            saved=$(wc -c < "$dest" | tr -d ' ')
            if [ -n "$TOTAL_BYTES" ]; then
                if [ "$saved" -eq "$TOTAL_BYTES" ]; then
                    if checksum_ok; then
                        say "Download complete: $saved / $TOTAL_BYTES bytes; SHA-256 verified."
                        return 0
                    fi
                    say "Complete-size file failed SHA-256; removing invalid cache and downloading again."
                    rm -f "$dest" || return 1
                elif [ "$saved" -gt "$TOTAL_BYTES" ]; then
                    say "Cached file exceeds expected size; removing invalid cache."
                    rm -f "$dest" || return 1
                fi
            elif checksum_ok; then
                say "Cached package already passes SHA-256; no download required."
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        say "Download attempt $attempts (no total time limit)..."
        if [ "$resume" = yes ]; then
            if fetch_with_progress "$url" "$dest" yes; then
                # Never accept a truncated archive, even if the HTTP client exits 0.
                if [ -n "$TOTAL_BYTES" ]; then
                    saved=$(wc -c < "$dest" | tr -d ' ')
                    if [ "$saved" -eq "$TOTAL_BYTES" ] && checksum_ok; then
                        say "Download complete; SHA-256 verified."
                        return 0
                    fi
                elif checksum_ok; then
                    say "Download complete; SHA-256 verified."
                    return 0
                fi
                say "Transfer ended, but archive is incomplete or failed verification."
            fi
        elif fetch_once "$url" "$dest" no && [ -s "$dest" ]; then
            return 0
        fi
        if [ -f "$dest" ]; then
            bytes=$(wc -c < "$dest" | tr -d ' ')
            say "Download not yet verified; saved $bytes bytes."
        fi
        say "Reconnecting in 5 seconds. Press Ctrl+C to stop."
        sleep 5
    done
}

ZIP="$CACHE_ROOT/ChannelLingo-universal.zip"
[ ! -L "$ZIP" ] || die "Boot protection: cached ZIP is a symlink."
CHECKSUM="$WORK/checksum"
# Cache is ONLY for resuming interrupted downloads. A successful installation
# clears the completed ZIP. On failure, preserve partial/verified ZIP for retry.
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
INITIAL_CACHED_BYTES=0
[ ! -f "$ZIP" ] || INITIAL_CACHED_BYTES=$(wc -c < "$ZIP" | tr -d ' ')
if checksum_ok; then
    PACKAGE_SOURCE="verified cache (no ZIP download this run)"
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
    PACKAGE_SOURCE="downloaded/resumed from GitHub"
fi
checksum_ok || die "Package SHA-256 mismatch. Nothing installed."
PACKAGE_BYTES=$(wc -c < "$ZIP" | tr -d ' ')
PACKAGE_MIB=$(awk -v n="$PACKAGE_BYTES" 'BEGIN {printf "%.2f", n/1048576}')
INITIAL_MIB=$(awk -v n="$INITIAL_CACHED_BYTES" 'BEGIN {printf "%.2f", n/1048576}')
say "------------------------------------------------------------"
say "PACKAGE DOWNLOAD SUMMARY"
say "File: ChannelLingo-universal.zip"
say "Total package size: $PACKAGE_BYTES bytes ($PACKAGE_MIB MiB)"
say "Cache bytes found at start: $INITIAL_CACHED_BYTES ($INITIAL_MIB MiB)"
say "Source this run: $PACKAGE_SOURCE"
say "Cache directory: $CACHE_ROOT"
say "Cache policy: delete after successful installation; retain on failure/interruption"
say "Download progress: 100% | Remaining: 0 bytes"
say "SHA-256 integrity: VERIFIED (PASS)"
say "------------------------------------------------------------"
say "Package checksum verified."
cp "$ZIP" "$WORK/ChannelLingo-universal.zip" || die "Cannot stage verified package."
if ! "$ARCHIVE_PYTHON" -S - "$WORK/ChannelLingo-universal.zip" "$WORK" <<'CHANNELLINGO_SAFE_EXTRACT'
from __future__ import print_function
import re
import stat
import sys
import zipfile

try:
    with zipfile.ZipFile(sys.argv[1], 'r') as archive:
        seen = set()
        plugin = 'usr/lib/enigma2/python/Plugins/Extensions/ChannelLingo'
        metadata = ('install.sh', 'uninstall.sh', 'README.txt', 'VARIANTS.txt', 'SHA256SUMS')
        for entry in archive.infolist():
            name = entry.filename
            parts = name.rstrip('/').split('/')
            if (not name or name.startswith('/') or '\\' in name or
                    any(part in ('', '.', '..', 'boot', '.bainfo', '.bainfotmp') for part in parts)):
                raise ValueError('unsafe archive path: ' + name)
            if name in seen:
                raise ValueError('duplicate archive path: ' + name)
            seen.add(name)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('links and special files are forbidden: ' + name)
            if parts[0] != 'ChannelLingo-universal':
                raise ValueError('unexpected archive root: ' + name)
            tail = parts[1:]
            allowed = not tail and name.endswith('/')
            if len(tail) == 1 and tail[0] in metadata:
                allowed = not name.endswith('/')
            if tail and tail[0] in ('resources', 'variants'):
                content = tail[1:]
                if tail[0] == 'variants' and content:
                    label = content.pop(0)
                    if not re.match(r'^[A-Za-z0-9][A-Za-z0-9_-]*$', label):
                        raise ValueError('unsafe variant name: ' + name)
                    if content in (['PACKAGE_MANIFEST.json'], ['INSTALL.txt']):
                        allowed = not name.endswith('/')
                relative = '/'.join(content)
                if (relative == plugin or relative.startswith(plugin + '/') or
                        (name.endswith('/') and (not relative or plugin.startswith(relative + '/')))):
                    allowed = True
            if not allowed:
                raise ValueError('entry outside the plugin package: ' + name)
        if 'ChannelLingo-universal/install.sh' not in seen:
            raise ValueError('archive has no universal installer')
        archive.extractall(sys.argv[2])
except Exception as error:
    print('Boot protection: invalid package: %s' % error, file=sys.stderr)
    sys.exit(1)
CHANNELLINGO_SAFE_EXTRACT
then
    die "Archive validation/extraction failed; nothing was installed."
fi
INSTALL="$WORK/ChannelLingo-universal/install.sh"
[ -f "$INSTALL" ] || die "The archive has no installer."
# Inspect the extracted inner installer BEFORE even running its --check mode.
# This is a conservative safety gate, not a sandbox: never execute unknown
# installation code without separately reviewing the universal package.
# Reject direct references to multiboot metadata, boot partitions and low-level
# image/flash operations. Remove comments from this check to avoid false matches.
if sed '/^[[:space:]]*#/d' "$INSTALL" | grep -nEi '(/boot|/media/ba|/ba/ba|\.bainfo|\.bainfotmp|fw_setenv|flash_erase|nandwrite|(^|[[:space:];|])(mkfs|dd|mount|umount|reboot)([[:space:];|]|$))' >/dev/null; then
    die "Boot protection: inner install.sh contains boot/multiboot/partition operations; installation aborted for review."
fi
# Refuse any packaged entry targeting a boot or Barry Allen directory directly.
# This is a path-name guard, not a full audit of arbitrary executed code.
if find "$WORK/ChannelLingo-universal" \( -name .bainfo -o -name .bainfotmp -o -name boot \) -print | grep -q .; then
    die "Boot protection: package contains boot or Barry Allen metadata paths; installation aborted."
fi
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
PLUGIN="$PLUGIN_FIXED"
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
INSTALL_SUCCESS=yes
say "Installed build: $INSTALL_PYTHON ($EXPECTED_FACTS)"
say "Installed plugin path: $PLUGIN"
say "Package verified: $PACKAGE_MIB MiB; $PACKAGE_SOURCE"
say "Cache policy: completed ZIP will be removed after successful installation and GUI restart."
# cleanup restarts Enigma2 if it was running, then removes this run's temporary files.
