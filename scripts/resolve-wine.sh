#!/usr/bin/env bash
# resolve-wine.sh — run the Windows build of DaVinci Resolve in a Bottles (Flatpak)
# bottle with working CUDA on NVIDIA GPUs.
#
# Commands:
#   setup <bottle> <nvidia-libs-dir>   one-time setup of a bottle (run on the host)
#   launch                             start Resolve (re-executes itself inside the Bottles sandbox)
#   doctor                             print a diagnostic summary
#
# The script never ships or downloads Resolve or NVIDIA binaries.
# License: MIT

set -euo pipefail

APP_ID="com.usebottles.bottles"
DATA_DIR="$HOME/.var/app/$APP_ID/data"
BOTTLES_DIR="$DATA_DIR/bottles/bottles"
RUNNERS_DIR="$DATA_DIR/bottles/runners"
INSTALL_PATH="$DATA_DIR/resolve-wine.sh"
CONF="$DATA_DIR/resolve-wine.conf"
DESKTOP_FILE="$HOME/.local/share/applications/resolve-wine.desktop"

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

in_sandbox() { [[ "${FLATPAK_ID:-}" == "$APP_ID" ]]; }

load_conf() {
    [[ -f "$CONF" ]] || die "No config at $CONF. Run: $0 setup <bottle> <nvidia-libs-dir>"
    # shellcheck source=/dev/null
    source "$CONF"
    : "${BOTTLE:?}" "${RUNNER:?}"
    # Optional: report a different NVIDIA driver version to Resolve (e.g. 58157 = 581.57),
    # only useful if a future Resolve version rejects your driver. Empty/0 = off (default).
    SPOOF_VERSION="${RW_SPOOF:-${SPOOF_VERSION:-0}}"
    export WINEPREFIX="$BOTTLES_DIR/$BOTTLE"
    WINE="$RUNNERS_DIR/$RUNNER/bin/wine"
    WINESERVER="$RUNNERS_DIR/$RUNNER/bin/wineserver"
    RESOLVE_DIR="$WINEPREFIX/drive_c/Program Files/Blackmagic Design/DaVinci Resolve"
    RESOLVE_EXE="$RESOLVE_DIR/Resolve.exe"
}

# Re-run this script inside the Bottles sandbox (same filesystem view as Bottles).
reexec_in_sandbox() {
    [[ -f "$INSTALL_PATH" ]] || die "Script is not installed at $INSTALL_PATH. Run setup first."
    exec flatpak run --command=bash "$APP_ID" "$INSTALL_PATH" "$@"
}

runner_of_bottle() {
    local yml="$BOTTLES_DIR/$1/bottle.yml"
    [[ -f "$yml" ]] || die "Bottle '$1' not found ($yml missing)."
    grep -E '^Runner:' "$yml" | head -n1 | awk '{print $2}'
}

# --------------------------------------------------------------------------- pthread patch
# Original body of pthread_getw32threadid_np (+ int3 padding):
#   mov rax,[rcx] ; mov eax,[rax+0x198] ; ret ; int3 x6
# Patched (same 16 bytes):
#   mov rax,[rcx] ; test rax,rax ; je +7 ; mov eax,[rax+0x198] ; ret ; ret
PTHREAD_ORIG_HEX="488b018b8098010000c3cccccccccccc"
PTHREAD_NEW_HEX="488b014885c074078b8098010000c3c3"

patch_pthread() {
    local dll="$1"
    [[ -f "$dll" ]] || { warn "pthreadVC2.dll not found — skipping patch."; return 0; }
    python3 -I - "$dll" "$PTHREAD_ORIG_HEX" "$PTHREAD_NEW_HEX" <<'PY'
import sys, shutil, os
path, old, new = sys.argv[1], bytes.fromhex(sys.argv[2]), bytes.fromhex(sys.argv[3])
data = open(path, "rb").read()
if data.count(new) == 1 and data.count(old) == 0:
    print("pthreadVC2.dll is already patched"); sys.exit(0)
n = data.count(old)
if n != 1:
    print(f"pattern found {n} times — unknown pthreadVC2.dll version, not patching", file=sys.stderr)
    sys.exit(1)
if not os.path.exists(path + ".orig"):
    shutil.copy2(path, path + ".orig")
open(path, "wb").write(data.replace(old, new))
print("pthreadVC2.dll patched (original saved as pthreadVC2.dll.orig)")
PY
}

# --------------------------------------------------------------------------- setup
cmd_setup() {
    in_sandbox && die "Run setup on the host, not inside the sandbox."
    local bottle="${1:-}" nvlibs="${2:-}"
    [[ -n "$bottle" && -n "$nvlibs" ]] || die "Usage: $0 setup <bottle> <nvidia-libs-dir>"
    [[ -d "$nvlibs" ]] || die "nvidia-libs directory not found: $nvlibs"
    command -v flatpak >/dev/null || die "flatpak not found."
    command -v nvidia-smi >/dev/null || die "nvidia-smi not found (NVIDIA proprietary driver required)."

    # 1. Driver (Resolve 21 needs CUDA >= 12.8) and the matching Flatpak runtime
    local drv major cuda
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')
    major=${drv%%.*}
    cuda=$(nvidia-smi | grep -oE 'CUDA Version: [0-9.]+' | awk '{print $3}')
    msg "Host driver: $drv (CUDA $cuda)"
    (( major >= 580 )) || warn "Resolve 21 needs CUDA 12.8 (driver 580+). Driver $drv will be rejected."
    local rt="org.freedesktop.Platform.GL.nvidia-${drv//./-}"
    flatpak info "$rt" >/dev/null 2>&1 \
        || die "Flatpak runtime $rt is missing. Install it (and the GL32 variant) from Flathub."
    flatpak info "org.freedesktop.Platform.GL32.nvidia-${drv//./-}" >/dev/null 2>&1 \
        || warn "GL32 runtime for $drv is missing (32-bit parts of Wine may lose the GPU)."

    # 2. Bottle and runner
    local runner
    runner=$(runner_of_bottle "$bottle")
    [[ -n "$runner" && -d "$RUNNERS_DIR/$runner" ]] || die "Runner '$runner' of bottle '$bottle' not found."
    msg "Bottle: $bottle, runner: $runner"
    local prefix="$BOTTLES_DIR/$bottle"
    local rdir="$prefix/drive_c/Program Files/Blackmagic Design/DaVinci Resolve"
    [[ -f "$rdir/Resolve.exe" ]] || die "Install Resolve into the bottle first ($rdir/Resolve.exe missing)."

    # 3. nvidia-libs (CUDA layer for Wine) via the upstream Bottles script
    local bscript
    bscript=$(ls "$nvlibs"/bottles_setup.sh "$nvlibs"/bottles-install.sh 2>/dev/null | head -n1 || true)
    [[ -n "$bscript" ]] || die "No Bottles install script found in $nvlibs."
    msg "Installing nvidia-libs into the bottle"
    (cd "$nvlibs" && "./$(basename "$bscript")" "$bottle")

    # 4. Resolve ships its own nvcuda.dll next to Resolve.exe. The DLL search order picks it
    #    before system32, so the Wine nvcuda is never used and Resolve sees "CUDA -1.-1".
    if [[ -f "$rdir/nvcuda.dll" ]]; then
        msg "Renaming nvcuda.dll in the Resolve folder (it shadows the Wine one)"
        mv "$rdir/nvcuda.dll" "$rdir/nvcuda.dll.resolve-orig"
    fi

    # 5. Native ucrtbase: Wine's builtin one lacks cabsf() and Resolve aborts on it
    msg "Installing native ucrtbase (winetricks ucrtbase2019)"
    local wt="$DATA_DIR/winetricks"
    if [[ ! -x "$wt" ]]; then
        curl -fsSL -o "$wt" https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
            || die "Could not download winetricks."
        chmod +x "$wt"
    fi
    flatpak run --command=bash "$APP_ID" -c \
        "WINEPREFIX='$prefix' WINE='$RUNNERS_DIR/$runner/bin/wine' WINESERVER='$RUNNERS_DIR/$runner/bin/wineserver' '$wt' -q ucrtbase2019" \
        || warn "winetricks ucrtbase2019 failed — Resolve may abort with 'unimplemented function ucrtbase.dll.cabsf'."

    # 6. pthreadVC2.dll: pthread_getw32threadid_np() dereferences a NULL pthread_t when a new
    #    thread starts before its creator stored the handle (a race Wine's timing exposes).
    #    Patch it to return 0 instead of crashing. The original is kept as .orig.
    patch_pthread "$rdir/pthreadVC2.dll"

    # 7. Install script, config and menu entry (an existing SPOOF_VERSION is kept)
    install -m 755 "$0" "$INSTALL_PATH"
    local keep_spoof=""
    [[ -f "$CONF" ]] && keep_spoof=$(grep -E '^SPOOF_VERSION=' "$CONF" | tail -n1 || true)
    printf 'BOTTLE=%q\nRUNNER=%q\n' "$bottle" "$runner" >"$CONF"
    [[ -n "$keep_spoof" && "$keep_spoof" != "SPOOF_VERSION=58157" ]] && echo "$keep_spoof" >>"$CONF"

    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=DaVinci Resolve (Wine)
Exec=flatpak run --command=bash $APP_ID $INSTALL_PATH launch
Icon=video-editor
Type=Application
Categories=AudioVideo;Video;
EOF
    msg "Done. Start Resolve from the menu ('DaVinci Resolve (Wine)') or: $INSTALL_PATH launch"
}

# --------------------------------------------------------------------------- launch
cmd_launch() {
    in_sandbox || reexec_in_sandbox launch
    load_conf
    [[ -f "$RESOLVE_EXE" ]] || die "Resolve.exe not found in bottle '$BOTTLE'."
    # DLL load order is forced here because Bottles rewrites the registry overrides
    # (enabling DXVK-NVAPI in Bottles sets "nvcuda"="disabled", which stops Resolve.exe
    # from loading at all: llama.dll -> ggml.dll -> ggml-cuda.dll -> nvcuda.dll).
    local overrides="nvcuda,nvcuvid,nvencodeapi64,nvoptix=n;nvapi64,ucrtbase=n,b"
    local extra=()
    if [[ -n "$SPOOF_VERSION" && "$SPOOF_VERSION" != "0" ]]; then
        extra=(DXVK_NVAPI_DRIVER_VERSION="$SPOOF_VERSION")
        msg "Reporting NVIDIA driver version $SPOOF_VERSION to Resolve"
    fi
    "$WINESERVER" -p
    env WINEDLLOVERRIDES="$overrides${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}" \
        DXVK_ENABLE_NVAPI=1 "${extra[@]}" WINEDEBUG="${WINEDEBUG:--all}" \
        "$WINE" "$RESOLVE_EXE" || true
    "$WINESERVER" -k 2>/dev/null || true
}

# --------------------------------------------------------------------------- doctor
latest_log() {
    find "$WINEPREFIX/drive_c/users" -iname 'ResolveDebug*.txt' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n1 | cut -d' ' -f2-
}

cmd_doctor() {
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi | grep -E 'Driver Version' || true
    fi
    if [[ -f "$CONF" ]]; then
        load_conf
        echo "Bottle: $BOTTLE  Runner: $RUNNER  Driver-version override: ${SPOOF_VERSION/#0/off}"
        [[ -e "$WINEPREFIX/drive_c/windows/system32/nvcuda.dll" ]] \
            && echo "ok       nvcuda.dll (nvidia-libs) in system32" || echo "MISSING  nvcuda.dll in system32 (nvidia-libs)"
        [[ -e "$RESOLVE_DIR/nvcuda.dll" ]] \
            && echo "PROBLEM  $RESOLVE_DIR/nvcuda.dll shadows the Wine nvcuda" || echo "ok       no nvcuda.dll in the Resolve folder"
        grep -qi '^"nvcuda"="disabled"' "$WINEPREFIX/user.reg" \
            && echo "note     registry has nvcuda=disabled (set by Bottles) — 'launch' overrides it, the Bottles button does not"
        grep -qi '"ucrtbase"="native' "$WINEPREFIX/user.reg" \
            && echo "ok       ucrtbase override (native)" || echo "MISSING  ucrtbase override (run: winetricks ucrtbase2019)"
        [[ -e "$RESOLVE_DIR/pthreadVC2.dll.orig" ]] \
            && echo "ok       pthreadVC2.dll patched" || echo "MISSING  pthreadVC2.dll patch"
        local log
        log=$(latest_log)
        [[ -n "$log" ]] && grep -E 'GPU Driver|Matches|compute API' "$log" | tail -n 4
    else
        echo "Not set up yet ($CONF missing)."
    fi
}

case "${1:-}" in
    setup)  shift; cmd_setup "$@" ;;
    launch) cmd_launch ;;
    doctor) cmd_doctor ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
