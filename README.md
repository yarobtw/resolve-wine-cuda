# DaVinci Resolve (Windows) on Linux with CUDA

Run the **Windows build** of DaVinci Resolve Studio on Linux through Wine (Bottles, Flatpak) **with working CUDA** on an NVIDIA GPU — so Windows‑only OFX plugins can be used.

[Українська версія](README.uk.md)

> **Status: experimental.** Verified on one machine (see below): Resolve starts, runs on CUDA, and a simple project was edited. Rendering, long sessions and third‑party OFX plugins still need wider testing — reports are welcome.

## Tested configuration

| Component | Version |
|---|---|
| OS | LMDE 7 (Debian 13 trixie), kernel 6.12 |
| GPU | GeForce GTX 1060 6GB (Pascal) |
| NVIDIA driver | 580.178.04 (`.run` installer) |
| Bottles | Flatpak |
| Runner | soda‑11.0‑10 |
| CUDA layer | [SveSop/nvidia-libs](https://github.com/SveSop/nvidia-libs) v1.0.2 |
| Resolve | Studio 21.1.1 (Windows) |

## Why it normally fails

Getting CUDA into Wine is only half of it. Resolve's own GPU detection rejects CUDA for four separate reasons, and after that two more Wine gaps crash it. Each one has to be fixed:

1. **Resolve ships its own `nvcuda.dll`.** Windows searches the program folder before `system32`, so Resolve loads that Windows driver DLL instead of the Wine implementation from nvidia-libs. Under Wine it cannot reach a driver, and Resolve logs `supports CUDA -1.-1`.
   **Fix:** rename `nvcuda.dll` in the Resolve folder.
2. **NVML is not installed by the Bottles script of nvidia-libs.** Resolve's `GPUDetect` uses NVML; it must be in the bottle's `system32` (Windows half) and the runner's `x86_64-unix` (Unix half).
3. **Missing registry data for the display adapter.** Resolve reads `ProviderName` from `HKLM\System\CurrentControlSet\Control\Video\{GUID}\0000` and `Driver` from `…\{GUID}\Video`. Wine leaves both empty (`provider '' driver ''` in the log). Wine recreates these keys at every start, so they are written on every launch. The GUID is different on every machine.
4. **Driver version.** Resolve 21 requires CUDA 12.8 (the Windows build checks for driver 581.57+).
   - The host driver must provide CUDA ≥ 12.8 → **580+**. For Pascal/Maxwell/Volta 580 is the last supported branch.
   - A Linux 580.x driver is reported to Windows apps as 580.x, so `DXVK_NVAPI_DRIVER_VERSION=58157` makes dxvk‑nvapi report 581.57.

With these four in place, `ResolveDebug.txt` shows:

```
NVIDIA GPU Driver: 581.57, supports CUDA 13.0
Matches: CUDA, DirectX, NVAPI, NVML, OpenCL
Selected compute API: CUDA
...
Let There Be CUDA Light!
Board manager thread for "NVIDIA GeForce GTX 1060" ... is ready.
```

Two more problems then crash Resolve:

5. **`unimplemented function ucrtbase.dll.cabsf`.** Wine's builtin UCRT lacks `cabsf()` (complex absolute value). **Fix:** native `ucrtbase.dll` via `winetricks ucrtbase2019`. Bottles' `vcredist2019` does *not* help — on Windows 10 the VC++ redistributable never installs UCRT.
6. **Intermittent `c0000005` in `pthreadVC2.dll + 0x3cb3`** right after the Fusion modules load (`info[1]=0x198`). That is `pthread_getw32threadid_np()` dereferencing a NULL `pthread_t`: a freshly started worker asks for its Win32 thread id before its creator has stored the handle — a race that Wine's thread start‑up timing exposes. **Fix:** a 13‑byte patch of the function in Resolve's bundled pthreads‑win32 (LGPL) that returns 0 for a NULL handle instead of crashing:
   ```
   before: mov rax,[rcx] ; mov eax,[rax+0x198] ; ret ; int3 ×6
   after:  mov rax,[rcx] ; test rax,rax ; je +7 ; mov eax,[rax+0x198] ; ret ; ret
   ```
   The script locates the function by its byte pattern, patches your own copy and keeps `pthreadVC2.dll.orig`. No binary is distributed.

## Requirements

- NVIDIA proprietary driver **580+** (`nvidia-smi` shows CUDA ≥ 12.8)
- Matching Flathub runtimes, exact same version as the driver:
  ```bash
  flatpak install flathub org.freedesktop.Platform.GL.nvidia-580-178-04 org.freedesktop.Platform.GL32.nvidia-580-178-04
  ```
  (replace `580-178-04` with your driver version; `flatpak remote-ls flathub | grep GL.nvidia-580` lists what exists)
- Bottles from Flathub, a bottle with a recent runner (Wine ≥ 10, e.g. soda 11), Resolve installed in it
- [nvidia-libs](https://github.com/SveSop/nvidia-libs/releases) release archive (the regular one, not `-fakedll`), extracted

Nothing from Blackmagic or NVIDIA is distributed here.

## Setup

```bash
git clone https://github.com/yarobtw/resolve-wine-cuda.git
cd resolve-wine-cuda
./scripts/resolve-wine.sh setup <BottleName> ~/Downloads/nvidia-libs-v1.0.2
```

`setup` runs on the host and:

1. checks the driver version and the matching Flatpak runtime;
2. runs the nvidia-libs Bottles script (answer **Y** to the experimental nvapi question, then pick `dxvk-nvapi-v0.9.1` under **Settings → Components → DXVK-NVAPI** in Bottles);
3. installs NVML into the bottle and the runner;
4. renames Resolve's `nvcuda.dll` to `nvcuda.dll.resolve-orig`;
5. installs native `ucrtbase` with winetricks (downloaded from the official repo) inside the Bottles sandbox;
6. patches `pthreadVC2.dll` (original kept as `.orig`);
7. starts Resolve once in the background to detect the adapter GUID, then closes it;
8. writes `~/.var/app/com.usebottles.bottles/data/resolve-wine.conf` and adds **DaVinci Resolve (Wine)** to the application menu.

Then launch from the menu or:

```bash
~/.var/app/com.usebottles.bottles/data/resolve-wine.sh launch
```

Diagnostics:

```bash
~/.var/app/com.usebottles.bottles/data/resolve-wine.sh doctor
```

> Launching from the normal Bottles button will **not** work — it does not apply the registry values and the version override.
>
> Run **one** Resolve at a time: several instances in one bottle lock the project database and hang on "Loading Project Libraries". Debug logging (`WINEDEBUG=+seh` etc.) makes Resolve noticeably slower — the launcher runs with logging off.

## Manual method

<details>
<summary>The same steps without the script</summary>

Inside the sandbox (`flatpak run --command=bash com.usebottles.bottles`):

```bash
export WINEPREFIX=~/.var/app/com.usebottles.bottles/data/bottles/bottles/<Bottle>
RUNNER=~/.var/app/com.usebottles.bottles/data/bottles/runners/<runner>/bin

# find the adapter GUID once: start Resolve with registry logging, then
#   grep '"ProviderName"' reg.log    -> ...\Control\Video\{GUID}\0000
WINEDEBUG=-all,+reg "$RUNNER/wine" "$WINEPREFIX/drive_c/Program Files/Blackmagic Design/DaVinci Resolve/Resolve.exe" > reg.log 2>&1

KEY='HKLM\System\CurrentControlSet\Control\Video\{GUID}'
"$RUNNER/wineserver" -p
"$RUNNER/wine" reg add "$KEY\0000" /v ProviderName /t REG_SZ /d NVIDIA /f
"$RUNNER/wine" reg add "$KEY\Video" /v Driver /t REG_SZ /d '{4d36e968-e325-11ce-bfc1-08002be10318}\0000' /f
DXVK_ENABLE_NVAPI=1 DXVK_NVAPI_DRIVER_VERSION=58157 \
  "$RUNNER/wine" "$WINEPREFIX/drive_c/Program Files/Blackmagic Design/DaVinci Resolve/Resolve.exe"
```

NVML: copy `x64/wine/x86_64-windows/nvml.dll` to the bottle's `drive_c/windows/system32/` and `x64/wine/x86_64-unix/nvml.so` to the runner's `lib/wine/x86_64-unix/`.
</details>

## Installing driver 580 on Debian 13 / LMDE 7 (Pascal)

Debian 13 ships 550 (CUDA 12.4); NVIDIA's Debian 13 repo starts at 590, which dropped Pascal. What worked here was the official `.run` installer:

1. Make a Timeshift snapshot.
2. Download `NVIDIA-Linux-x86_64-580.x.run` (pick a version that also exists on Flathub as `GL.nvidia-580-…`).
3. Switch to a text console (**Ctrl+Alt+F3**), `sudo systemctl stop lightdm`.
4. `sudo apt purge '*nvidia*' libcuda1 libnvcuvid1` — check the list does not contain desktop packages.
5. `sudo sh NVIDIA-Linux-x86_64-580.x.run --dkms` → **NVIDIA Proprietary** kernel module (the open one does not support Pascal), 32‑bit libraries: yes, rebuild initramfs: yes, `nvidia-xconfig`: no.
6. **Blacklist nouveau explicitly** — without this it grabbed the GPU after reboot (`GPU … is already bound to nouveau`):
   ```bash
   printf "blacklist nouveau\noptions nouveau modeset=0\n" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
   echo "options nvidia-drm modeset=1" | sudo tee /etc/modprobe.d/nvidia-drm.conf
   sudo update-initramfs -u && sudo reboot
   ```

If the desktop does not come up: in GRUB press `e`, append `systemd.unit=multi-user.target` to the end of the `linux` line (same line), boot with **Ctrl+X**, then fix or roll back (`sudo nvidia-uninstall && sudo apt install nvidia-driver`).

## Keeping it working

| You update… | Then |
|---|---|
| Resolve | Re-run `setup` (the installer may restore `nvcuda.dll` and the original `pthreadVC2.dll`); raise `SPOOF_VERSION` in the config if a newer driver is required |
| Runner | Change `RUNNER` in the config, re-run `setup` |
| nvidia-libs | Re-run `setup` |
| NVIDIA driver | Install the Flatpak `GL`/`GL32` runtime of exactly the same version |
| Kernel | DKMS rebuilds the module; if not: `sudo dkms autoinstall` |

## Troubleshooting

| Symptom (in `ResolveDebug.txt`) | Cause |
|---|---|
| `supports CUDA -1.-1`, no `CUDA` in `Matches` | `nvcuda.dll` next to `Resolve.exe`, or NVML missing |
| `provider '' driver ''` | Registry values not written — launch through the script |
| `supports CUDA 12.4` (or < 12.8) but `Selected compute API: OpenCL` | Host driver too old |
| Hangs on "Loading Fairlight Engine" | Not audio: GPU init failed in OpenCL; see above |
| No GPU at all in Bottles | Flatpak `GL.nvidia-*` runtime version ≠ host driver |
| Wine log: `unimplemented function ucrtbase.dll.cabsf` | Native ucrtbase missing (`winetricks ucrtbase2019`) |
| Random crash after Fusion modules, `c0000005` in `pthreadVC2.dll` | pthreadVC2 not patched |
| Stuck on "Loading Project Libraries" | Several Resolve instances running — `flatpak kill com.usebottles.bottles`, start one |

To locate a crash yourself: run with `WINEDEBUG=-all,err+all,+seh,+loaddll`, take the `addr=` of the `c0000005` exception and find the module whose `Loaded … at` base is the closest one below it.

`ResolveDebug.txt` lives in `drive_c/users/<user>/AppData/Roaming/Blackmagic Design/DaVinci Resolve/Support/logs/`.

## Credits

- [SveSop/nvidia-libs](https://github.com/SveSop/nvidia-libs) — nvcuda, NVML, dxvk-nvapi for Wine. None of this works without it.
- [Bottles](https://usebottles.com), Wine, dxvk-nvapi.

## License

MIT. DaVinci Resolve is a trademark of Blackmagic Design; NVIDIA and CUDA are trademarks of NVIDIA. Not affiliated with either.
