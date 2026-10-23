# DaVinci Resolve (Windows) on Linux with CUDA

Run the **Windows build** of DaVinci Resolve Studio on Linux through Wine (Bottles, Flatpak) **with working CUDA** on an NVIDIA GPU — so Windows‑only OFX plugins can be used.

[Українська версія](README.uk.md)

> **Status: experimental.** Verified on one machine (see below): Resolve starts, runs on CUDA, a simple project was edited and rendered to H.264 (Studio). Long sessions and third‑party OFX plugins still need wider testing — reports are welcome.

![DaVinci Resolve Studio running on Linux with CUDA](docs/screenshot.png)

```
GPUDetect          | NVIDIA GPU Driver: 580.99, supports CUDA 13.0
Main.GPUConfig     | Selected compute API: CUDA
GPU.MultiBoardMgr  | Let There Be CUDA Light!
GPU.SingleBoardMgr | Board manager thread for "NVIDIA GeForce GTX 1060" is ready.
```

## Tested configuration

| Component | Version |
|---|---|
| OS | LMDE 7 (Debian 13 trixie), kernel 6.12 |
| GPU | GeForce GTX 1060 6GB (Pascal) |
| NVIDIA driver | 580.178.04 (`.run` installer) |
| Bottles | Flatpak |
| Runner | soda‑11.0‑10 |
| CUDA layer | [SveSop/nvidia-libs](https://github.com/SveSop/nvidia-libs) v1.0.2 |
| Resolve | Studio 21.1.1 (Windows); `setup` also verified on a fresh bottle with the free version |

> **Bottles 66.8+ has a CUDA dependency.** It puts the CUDA layer into the prefix — that covers what nvidia-libs does here, i.e. only the first piece. The other fixes below are still needed.

## Why it normally fails

Getting CUDA into Wine is only the first step. Five more things stop Resolve:

1. **Resolve ships its own `nvcuda.dll`.** Windows searches the program folder before `system32`, so Resolve loads that Windows driver DLL instead of the Wine implementation from nvidia-libs. Under Wine it cannot reach a driver, and Resolve logs `supports CUDA -1.-1` and falls back to OpenCL (which fails under Wine).
   **Fix:** rename `nvcuda.dll` in the Resolve folder.
2. **Bottles may disable `nvcuda`.** Enabling DXVK‑NVAPI in Bottles writes `"nvcuda"="disabled"` into the prefix. Resolve 21 links `llama.dll → ggml.dll → ggml-cuda.dll → nvcuda.dll` at start‑up, so with `nvcuda` disabled it does not start at all (`c0000135`).
   **Fix:** the launcher forces `WINEDLLOVERRIDES="nvcuda=n"`, which takes priority over the registry.
3. **Driver version.** Resolve 21 requires CUDA 12.8. The host driver must provide it → **580+**. For Pascal/Maxwell/Volta, 580 is the last supported branch (see [installing 580 on Debian 13](#installing-driver-580-on-debian-13--lmde-7-pascal)).
4. **`unimplemented function ucrtbase.dll.cabsf`.** Wine's builtin UCRT lacks `cabsf()` (complex absolute value), and Resolve aborts.
   **Fix:** native `ucrtbase.dll` via `winetricks ucrtbase2019`. Bottles' `vcredist2019` does *not* help — on Windows 10 the VC++ redistributable never installs UCRT.
5. **Intermittent `c0000005` in `pthreadVC2.dll + 0x3cb3`** right after the Fusion modules load (`info[1]=0x198`). That is `pthread_getw32threadid_np()` dereferencing a NULL `pthread_t`: a freshly started worker asks for its Win32 thread id before its creator has stored the handle — a race that Wine's thread start‑up timing exposes.
   **Fix:** a 13‑byte patch of the function in Resolve's bundled pthreads‑win32 (LGPL) that returns 0 for a NULL handle instead of crashing:
   ```
   before: mov rax,[rcx] ; mov eax,[rax+0x198] ; ret ; int3 ×6
   after:  mov rax,[rcx] ; test rax,rax ; je +7 ; mov eax,[rax+0x198] ; ret ; ret
   ```
   The script locates the function by its byte pattern, patches your own copy and keeps `pthreadVC2.dll.orig`. No binary is distributed.

### Tested and not needed

While debugging, three more things looked necessary but turned out not to be (each was removed and re‑tested on its own):

- **NVML** (`nvml.dll`/`nvml.so` from nvidia-libs) — Resolve uses it for extra GPU info, but selects CUDA without it.
- **Display‑adapter registry values** (`ProviderName`, `Video\Driver`) — without them Resolve logs `Failed to find provider information … provider '' driver ''`, but still selects CUDA.
- **Driver‑version override** (`DXVK_NVAPI_DRIVER_VERSION`) — with a real 580 driver Resolve reports `580.99` and accepts it. Only needed if a future Resolve version demands a newer driver than yours; set `SPOOF_VERSION=58157` (= 581.57) in the config for that.

The real cause of `CUDA -1.-1` was only the bundled `nvcuda.dll` (fix 1).

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
2. runs the nvidia-libs Bottles script (answer **Y** to the experimental nvapi question);
3. renames Resolve's `nvcuda.dll` to `nvcuda.dll.resolve-orig`;
4. installs native `ucrtbase` with winetricks (downloaded from the official repo) inside the Bottles sandbox;
5. patches `pthreadVC2.dll` (original kept as `.orig`);
6. writes `~/.var/app/com.usebottles.bottles/data/resolve-wine.conf` and adds **DaVinci Resolve (Wine)** to the application menu.

Then, in Bottles, open the bottle → **Settings → Components** and make sure **DXVK** is installed and **DXVK-NVAPI** is set to `dxvk-nvapi-v0.9.1`; under **Graphics** enable **DXVK-NVAPI** (and **Discrete Graphics** on hybrid laptops). A freshly created bottle may have none of these.

Launch from the menu or:

```bash
~/.var/app/com.usebottles.bottles/data/resolve-wine.sh launch
```

Diagnostics:

```bash
~/.var/app/com.usebottles.bottles/data/resolve-wine.sh doctor
```

> Launching from the normal Bottles button will **not** work — it does not apply the DLL overrides.
>
> Run **one** Resolve at a time: several instances in one bottle lock the project database and hang on "Loading Project Libraries". Debug logging (`WINEDEBUG=+seh` etc.) makes Resolve noticeably slower — the launcher runs with logging off.

## Manual method

<details>
<summary>The same steps without the script</summary>

1. Install nvidia-libs into the bottle with its `bottles_setup.sh <Bottle>`.
2. Rename `drive_c/Program Files/Blackmagic Design/DaVinci Resolve/nvcuda.dll`.
3. `winetricks ucrtbase2019` in the prefix (with `WINE`/`WINESERVER` pointing to the runner).
4. Patch `pthreadVC2.dll` (byte pattern in the script, `patch_pthread`).
5. Launch inside the sandbox (`flatpak run --command=bash com.usebottles.bottles`):

```bash
export WINEPREFIX=~/.var/app/com.usebottles.bottles/data/bottles/bottles/<Bottle>
RUNNER=~/.var/app/com.usebottles.bottles/data/bottles/runners/<runner>/bin
WINEDLLOVERRIDES="nvcuda,nvcuvid,nvencodeapi64,nvoptix=n;nvapi64,ucrtbase=n,b" DXVK_ENABLE_NVAPI=1 \
  "$RUNNER/wine" "$WINEPREFIX/drive_c/Program Files/Blackmagic Design/DaVinci Resolve/Resolve.exe"
```
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

On Arch, nvidia-libs is packaged in the AUR as `wine-nvidia-libs-bin`.

## Keeping it working

| You update… | Then |
|---|---|
| Resolve | Re-run `setup` (the installer may restore `nvcuda.dll` and the original `pthreadVC2.dll`) |
| Runner | Re-run `setup` |
| nvidia-libs | Re-run `setup` |
| NVIDIA driver | Install the Flatpak `GL`/`GL32` runtime of exactly the same version |
| Kernel | DKMS rebuilds the module; if not: `sudo dkms autoinstall` |

## Troubleshooting

| Symptom | Cause |
|---|---|
| `supports CUDA -1.-1`, no `CUDA` in `Matches` | `nvcuda.dll` next to `Resolve.exe` |
| Resolve does not start, Wine log: `nvcuda.dll (which is needed by ggml-cuda.dll) not found`, status `c0000135` | `"nvcuda"="disabled"` set by Bottles. `launch` overrides it; the Bottles button does not |
| `supports CUDA 12.4` (or < 12.8) but `Selected compute API: OpenCL` | Host driver too old |
| Hangs on "Loading Fairlight Engine" | Not audio: GPU init failed in OpenCL; see above |
| No GPU at all in Bottles | Flatpak `GL.nvidia-*` runtime version ≠ host driver |
| Wine log: `unimplemented function ucrtbase.dll.cabsf` | Native ucrtbase missing (`winetricks ucrtbase2019`) |
| Random crash after Fusion modules, `c0000005` in `pthreadVC2.dll` | pthreadVC2 not patched |
| Stuck on "Loading Project Libraries" | Several Resolve instances running — `flatpak kill com.usebottles.bottles`, start one |
| `launch` returns immediately, nothing opens | Leftover Wine processes — `flatpak kill com.usebottles.bottles` and launch again |
| White window on the first start (`DaVinci Resolve Welcome.exe`) | The first-run tour renders slowly/white under Wine — wait or close it; it is shown only once |
| Free version: no H.264/H.265 in Deliver | The free Windows build encodes through Media Foundation, which Wine lacks. Studio encodes via NVENC |

To locate a crash yourself: run with `WINEDEBUG=-all,err+all,+seh,+loaddll`, take the `addr=` of the `c0000005` exception and find the module whose `Loaded … at` base is the closest one below it.

Resolve logs live in `drive_c/users/<user>/AppData/Roaming/Blackmagic Design/DaVinci Resolve/Support/logs/` — after Resolve closes, the log is moved to `LogArchive/ResolveDebug_1.txt` (newest).

## Credits

- [SveSop/nvidia-libs](https://github.com/SveSop/nvidia-libs) — nvcuda and dxvk-nvapi for Wine. None of this works without it.
- [Bottles](https://usebottles.com), Wine, dxvk-nvapi.

## License

MIT. DaVinci Resolve is a trademark of Blackmagic Design; NVIDIA and CUDA are trademarks of NVIDIA. Not affiliated with either.
