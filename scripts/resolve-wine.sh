#!/usr/bin/env bash
# resolve-wine.sh — run the Windows build of DaVinci Resolve in a Bottles (Flatpak)
# bottle with working CUDA on NVIDIA GPUs.
#
# Commands:
#   setup <bottle> <nvidia-libs-dir>   one-time setup of a bottle (run on the host)
#   launch                             start Resolve (re-executes itself inside the Bottles sandbox)
#   detect-guid                        find the Wine display-adapter GUID Resolve queries (sandbox)
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

# Windows Resolve 21.1 checks for NVIDIA driver >= 581.57. A Linux 580.x driver is
# reported to Windows apps as 580.x, so dxvk-nvapi is told to report this instead.
DEFAULT_SPOOF_VERSION="58157"
# Windows device class GUID for display adapters (constant on every Windows system).
DISPLAY_CLASS='{4d36e968-e325-11ce-bfc1-08002be10318}\0000'

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

in_sandbox() { [[ "${FLATPAK_ID:-}" == "$APP_ID" ]]; }

load_conf() {
    [[ -f "$CONF" ]] || die "No config at $CONF. Run: $0 setup <bottle> <nvidia-libs-dir>"
    # shellcheck source=/dev/null
    source "$CONF"
    : "${BOTTLE:?}" "${RUNNER:?}"
    SPOOF_VERSION="${SPOOF_VERSION:-$DEFAULT_SPOOF_VERSION}"
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

# --------------------------------------------------------------------------- detect-guid
# Wine creates HKLM\...\Control\Video\{GUID}\0000 for every display adapter when the first
# GUI process starts. Method 1 starts a tiny GUI program (notepad) and reads those keys,
# picking the adapter whose keys mention NVIDIA. Method 2 (fallback) starts Resolve with
# registry logging and takes the GUID it queries ProviderName from.
guid_re='\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'

detect_guid_registry() {
    local base='HKLM\System\CurrentControlSet\Control\Video' list g i
    "$WINESERVER" -p
    WINEDEBUG=-all "$WINE" start /min notepad >/dev/null 2>&1 &
    for i in $(seq 1 30); do
        list=$(WINEDEBUG=-all "$WINE" reg query "$base" 2>/dev/null | tr -d '\r' | grep -oE "$guid_re" | sort -u || true)
        [[ -n "$list" ]] && break
        sleep 1
    done
    for g in $list; do
        if WINEDEBUG=-all "$WINE" reg query "$base\\$g" /s 2>/dev/null | grep -qi nvidia; then
            echo "$g"; return 0
        fi
    done
    # exactly one adapter and nothing names NVIDIA: take it
    [[ $(wc -w <<<"$list") -eq 1 ]] && { echo "$list"; return 0; }
    return 1
}

detect_guid_resolve() {
    local log="$WINEPREFIX/drive_c/resolve-wine-guid.log" guid="" i
    WINEDEBUG=-all,+reg "$WINE" "$RESOLVE_EXE" >"$log" 2>&1 &
    for i in $(seq 1 180); do
        guid=$(grep -F '"ProviderName"' "$log" 2>/dev/null | grep -oE "$guid_re" | head -n1 || true)
        [[ -n "$guid" ]] && break
        sleep 1
    done
    if [[ -n "$guid" ]]; then rm -f "$log"; echo "$guid"; return 0; fi
    warn "Resolve did not query ProviderName; log kept at $log"
    return 1
}

cmd_detect_guid() {
    in_sandbox || reexec_in_sandbox detect-guid
    load_conf
    local guid=""
    "$WINESERVER" -k 2>/dev/null || true
    guid=$(detect_guid_registry || true)
    "$WINESERVER" -k 2>/dev/null || true
    if [[ -z "$guid" && -f "$RESOLVE_EXE" ]]; then
        warn "Registry method failed, trying via Resolve (up to 3 minutes)"
        guid=$(detect_guid_resolve || true)
        "$WINESERVER" -k 2>/dev/null || true
    fi
    [[ -n "$guid" ]] || die "Could not detect the adapter GUID."
    echo "$guid"
}

# --------------------------------------------------------------------------- setup
cmd_setup() {
    in_sandbox && die "Run setup on the host, not inside the sandbox."
    local bottle="${1:-}" nvlibs="${2:-}"
    [[ -n "$bottle" && -n "$nvlibs" ]] || die "Usage: $0 setup <bottle> <nvidia-libs-dir>"
    [[ -d "$nvlibs" ]] || die "nvidia-libs directory not found: $nvlibs"
    command -v flatpak >/dev/null || die "flatpak not found."
    command -v nvidia-smi >/dev/null || die "nvidia-smi not found (NVIDIA proprietary driver required)."

    # 1. Driver and matching Flatpak runtime
    local drv major cuda
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')
    major=${drv%%.*}
    cuda=$(nvidia-smi | grep -oE 'CUDA Version: [0-9.]+' | awk '{print $3}')
    msg "Host driver: $drv (CUDA $cuda)"
    (( major >= 580 )) || warn "Resolve 21 needs CUDA 12.8 (driver 570+/580+). Driver $drv will be rejected."
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
    local sys32="$prefix/drive_c/windows/system32"
    local rdir="$prefix/drive_c/Program Files/Blackmagic Design/DaVinci Resolve"
    [[ -f "$rdir/Resolve.exe" ]] || die "Install Resolve into the bottle first ($rdir/Resolve.exe missing)."

    # 3. nvidia-libs (nvcuda, nvapi, ...) via the upstream Bottles script
    local bscript
    bscript=$(ls "$nvlibs"/bottles_setup.sh "$nvlibs"/bottles-install.sh 2>/dev/null | head -n1 || true)
    [[ -n "$bscript" ]] || die "No Bottles install script found in $nvlibs."
    msg "Installing nvidia-libs into the bottle"
    (cd "$nvlibs" && "./$(basename "$bscript")" "$bottle")

    # 4. NVML: Windows half into system32, Unix half into the runner
    local nvml_win="$nvlibs/x64/wine/x86_64-windows/nvml.dll"
    local nvml_unix="$nvlibs/x64/wine/x86_64-unix/nvml.so"
    [[ -f "$nvml_win" && -f "$nvml_unix" ]] || die "nvml.dll / nvml.so not found in $nvlibs/x64/wine/."
    msg "Installing NVML"
    cp "$nvml_win" "$sys32/"
    cp "$nvml_win" "$RUNNERS_DIR/$runner/lib/wine/x86_64-windows/"
    cp "$nvml_unix" "$RUNNERS_DIR/$runner/lib/wine/x86_64-unix/"

    # 5. A nvcuda.dll next to Resolve.exe shadows the working one in system32
    if [[ -f "$rdir/nvcuda.dll" ]]; then
        msg "Renaming nvcuda.dll in the Resolve folder (it shadows the Wine one)"
        mv "$rdir/nvcuda.dll" "$rdir/nvcuda.dll.resolve-orig"
    fi

    # 6. Native ucrtbase: Wine's builtin one lacks cabsf() and Resolve aborts on it
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

    # 7. pthreadVC2.dll: pthread_getw32threadid_np() dereferences a NULL pthread_t when a new
    #    thread starts before its creator stored the handle (a race Wine's timing exposes).
    #    Patch it to return 0 instead of crashing. The original is kept as .orig.
    patch_pthread "$rdir/pthreadVC2.dll"

    # 8. Install script and write a first config
    install -m 755 "$0" "$INSTALL_PATH"
    printf 'BOTTLE=%q\nRUNNER=%q\nSPOOF_VERSION=%q\n' "$bottle" "$runner" "$DEFAULT_SPOOF_VERSION" >"$CONF"

    # 9. Adapter GUID (unique per bottle)
    msg "Detecting the display-adapter GUID"
    local guid
    guid=$(flatpak run --command=bash "$APP_ID" "$INSTALL_PATH" detect-guid | tail -n1 || true)
    [[ "$guid" =~ ^\{[0-9a-fA-F-]{36}\}$ ]] \
        || die "GUID detection failed. Run '$INSTALL_PATH detect-guid' and report its output."
    printf 'ADAPTER_GUID=%q\n' "$guid" >>"$CONF"
    msg "Adapter GUID: $guid"

    # 10. Menu entry
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
    if [[ -z "${ADAPTER_GUID:-}" ]]; then
        msg "Adapter GUID not in config yet — detecting it now"
        "$WINESERVER" -k 2>/dev/null || true
        ADAPTER_GUID=$(detect_guid_registry || true)
        "$WINESERVER" -k 2>/dev/null || true
        [[ "$ADAPTER_GUID" =~ ^\{[0-9a-fA-F-]{36}\}$ ]] \
            || die "Could not detect the adapter GUID. Run '$INSTALL_PATH detect-guid' and report its output."
        printf 'ADAPTER_GUID=%q\n' "$ADAPTER_GUID" >>"$CONF"
        msg "Adapter GUID: $ADAPTER_GUID (saved)"
    fi
    local base="HKLM\\System\\CurrentControlSet\\Control\\Video\\$ADAPTER_GUID"
    "$WINESERVER" -p
    # Wine recreates these keys on every start, so they are written per launch.
    "$WINE" reg add "$base\\0000" /v ProviderName /t REG_SZ /d NVIDIA /f >/dev/null 2>&1 \
        || warn "Could not write ProviderName"
    "$WINE" reg add "$base\\Video" /v Driver /t REG_SZ /d "$DISPLAY_CLASS" /f >/dev/null 2>&1 \
        || warn "Could not write Video\\Driver"
    # DLL load order is forced here because Bottles rewrites the registry overrides
    # (enabling DXVK-NVAPI in Bottles sets "nvcuda"="disabled", which stops Resolve.exe
    # from loading at all: llama.dll -> ggml.dll -> ggml-cuda.dll -> nvcuda.dll).
    local overrides="nvcuda,nvcuvid,nvencodeapi64,nvoptix=n;nvapi64,ucrtbase=n,b"
    WINEDLLOVERRIDES="$overrides${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}" \
    DXVK_ENABLE_NVAPI=1 DXVK_NVAPI_DRIVER_VERSION="$SPOOF_VERSION" WINEDEBUG="${WINEDEBUG:--all}" \
        "$WINE" "$RESOLVE_EXE" || true
    "$WINESERVER" -k 2>/dev/null || true
}

# --------------------------------------------------------------------------- doctor
cmd_doctor() {
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi | grep -E 'Driver Version' || true
    fi
    if [[ -f "$CONF" ]]; then
        load_conf
        echo "Bottle: $BOTTLE  Runner: $RUNNER  GUID: ${ADAPTER_GUID:-?}  Spoof: $SPOOF_VERSION"
        local f
        for f in "$WINEPREFIX/drive_c/windows/system32/nvcuda.dll" \
                 "$WINEPREFIX/drive_c/windows/system32/nvml.dll" \
                 "$RUNNERS_DIR/$RUNNER/lib/wine/x86_64-unix/nvml.so"; do
            [[ -e "$f" ]] && echo "ok       $f" || echo "MISSING  $f"
        done
        [[ -e "$RESOLVE_DIR/nvcuda.dll" ]] && echo "PROBLEM  $RESOLVE_DIR/nvcuda.dll shadows the Wine nvcuda"
        grep -qi '^"nvcuda"="disabled"' "$WINEPREFIX/user.reg" \
            && echo "note     registry has nvcuda=disabled (set by Bottles) — 'launch' overrides it, the Bottles button does not"
        grep -qi '"ucrtbase"="native' "$WINEPREFIX/user.reg" \
            && echo "ok       ucrtbase override (native)" || echo "MISSING  ucrtbase override (run: winetricks ucrtbase2019)"
        [[ -e "$RESOLVE_DIR/pthreadVC2.dll.orig" ]] \
            && echo "ok       pthreadVC2.dll patched" || echo "MISSING  pthreadVC2.dll patch"
        local log
        log=$(find "$WINEPREFIX" -name ResolveDebug.txt 2>/dev/null | head -n1)
        [[ -n "$log" ]] && grep -E 'GPU Driver|Matches|compute API' "$log" | tail -n 4
    else
        echo "Not set up yet ($CONF missing)."
    fi
}

case "${1:-}" in
    setup)       shift; cmd_setup "$@" ;;
    launch)      cmd_launch ;;
    detect-guid) cmd_detect_guid ;;
    doctor)      cmd_doctor ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
