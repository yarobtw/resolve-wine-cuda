# DaVinci Resolve (Windows) на Linux з CUDA

Запуск **Windows-версії** DaVinci Resolve Studio на Linux через Wine (Bottles, Flatpak) **з робочою CUDA** на відеокарті NVIDIA, щоб можна було користуватися плагінами OFX, які існують лише під Windows.

[English version](README.md)

> **Статус: експериментальний.** Перевірено на одному комп'ютері (див. нижче): Resolve запускається, працює на CUDA, у ньому змонтовано простий проєкт. Рендер, тривалу роботу і сторонні OFX-плагіни ще треба ширше тестувати, тож звіти вітаються.

## Перевірена конфігурація

| Компонент | Версія |
|---|---|
| ОС | LMDE 7 (Debian 13 trixie), ядро 6.12 |
| Відеокарта | GeForce GTX 1060 6GB (Pascal) |
| Драйвер NVIDIA | 580.178.04 (`.run`-інсталятор) |
| Bottles | Flatpak |
| Раннер | soda-11.0-10 |
| Шар CUDA | [SveSop/nvidia-libs](https://github.com/SveSop/nvidia-libs) v1.0.2 |
| Resolve | Studio 21.1.1 (Windows) |

## Чому зазвичай не працює

Додати CUDA у Wine — лише половина справи. Власний автодетект Resolve відкидає CUDA з чотирьох окремих причин, а після цього ще дві прогалини Wine призводять до вильоту. Кожну треба виправити:

1. **Resolve кладе поруч із собою свій `nvcuda.dll`.** Windows шукає DLL спершу в папці програми, а потім у `system32`, тож Resolve завантажує цей Windows-файл драйвера замість Wine-реалізації з nvidia-libs. Під Wine той не знаходить драйвер, і в лозі з'являється `supports CUDA -1.-1`.
   **Рішення:** перейменувати `nvcuda.dll` у папці Resolve.
2. **Скрипт nvidia-libs для Bottles не ставить NVML.** `GPUDetect` у Resolve користується NVML. Windows-половинка має лежати в `system32` пляшки, а Unix-половинка в `x86_64-unix` раннера.
3. **Бракує записів реєстру відеоадаптера.** Resolve читає `ProviderName` з `HKLM\System\CurrentControlSet\Control\Video\{GUID}\0000` і `Driver` з `…\{GUID}\Video`. У Wine обидва поля порожні (`provider '' driver ''` у лозі). Wine створює ці ключі заново при кожному старті, тому вони записуються при кожному запуску. GUID на кожному комп'ютері свій.
4. **Версія драйвера.** Resolve 21 вимагає CUDA 12.8 (Windows-версія перевіряє драйвер 581.57+).
   - Драйвер на хості має давати CUDA ≥ 12.8, тобто **580+**. Для Pascal/Maxwell/Volta гілка 580 остання.
   - Linux-драйвер 580.x для Windows-програм виглядає як 580.x, тому `DXVK_NVAPI_DRIVER_VERSION=58157` змушує dxvk-nvapi видавати 581.57.

Коли ці чотири пункти виконано, у `ResolveDebug.txt` буде:

```
NVIDIA GPU Driver: 581.57, supports CUDA 13.0
Matches: CUDA, DirectX, NVAPI, NVML, OpenCL
Selected compute API: CUDA
...
Let There Be CUDA Light!
Board manager thread for "NVIDIA GeForce GTX 1060" ... is ready.
```

Далі ще дві проблеми валять Resolve:

5. **`unimplemented function ucrtbase.dll.cabsf`.** У вбудованій бібліотеці UCRT від Wine немає функції `cabsf()` (модуль комплексного числа). **Рішення:** справжній `ucrtbase.dll` через `winetricks ucrtbase2019`. Пакет `vcredist2019` з Bottles **не допомагає**: на Windows 10 інсталятор Visual C++ ніколи не ставить UCRT.
6. **Випадковий `c0000005` у `pthreadVC2.dll + 0x3cb3`** одразу після завантаження модулів Fusion (`info[1]=0x198`). Це `pthread_getw32threadid_np()` читає з нульового `pthread_t`: щойно запущений робочий потік питає свій Windows-номер раніше, ніж творець встигає записати його дескриптор. Це гонка потоків, яку виявляє інший порядок старту потоків у Wine. **Рішення:** виправлення цієї функції на 13 байт у бібліотеці pthreads-win32 (LGPL), яку постачає Resolve, щоб на нульовому дескрипторі вона повертала 0 замість падіння:
   ```
   було:  mov rax,[rcx] ; mov eax,[rax+0x198] ; ret ; int3 ×6
   стало: mov rax,[rcx] ; test rax,rax ; je +7 ; mov eax,[rax+0x198] ; ret ; ret
   ```
   Скрипт знаходить функцію за шаблоном байтів, виправляє вашу власну копію і зберігає `pthreadVC2.dll.orig`. Жоден бінарний файл тут не поширюється.

## Що потрібно

- Пропрієтарний драйвер NVIDIA **580+** (`nvidia-smi` показує CUDA ≥ 12.8)
- Flathub-runtime **точно** тієї самої версії, що й драйвер:
  ```bash
  flatpak install flathub org.freedesktop.Platform.GL.nvidia-580-178-04 org.freedesktop.Platform.GL32.nvidia-580-178-04
  ```
  (замініть `580-178-04` на свою версію; `flatpak remote-ls flathub | grep GL.nvidia-580` покаже, які є)
- Bottles з Flathub, пляшка зі свіжим раннером (Wine ≥ 10, наприклад soda 11), у ній встановлений Resolve
- Розпакований архів релізу [nvidia-libs](https://github.com/SveSop/nvidia-libs/releases) (звичайний, не `-fakedll`)

Тут не поширюються жодні файли Blackmagic чи NVIDIA.

## Встановлення

```bash
git clone https://github.com/yarobtw/resolve-wine-cuda.git
cd resolve-wine-cuda
./scripts/resolve-wine.sh setup <НазваПляшки> ~/Downloads/nvidia-libs-v1.0.2
```

`setup` запускається на хості і:

1. перевіряє версію драйвера і відповідний Flatpak-runtime;
2. запускає скрипт nvidia-libs для Bottles (на питання про експериментальний nvapi відповідайте **Y**, потім у Bottles виберіть `dxvk-nvapi-v0.9.1` в **Settings → Components → DXVK-NVAPI**);
3. ставить NVML у пляшку й раннер;
4. перейменовує `nvcuda.dll` Resolve на `nvcuda.dll.resolve-orig`;
5. ставить справжній `ucrtbase` через winetricks (завантажується з офіційного репозиторію) всередині пісочниці Bottles;
6. виправляє `pthreadVC2.dll` (оригінал зберігається як `.orig`);
7. один раз запускає Resolve у фоні, щоб визначити GUID адаптера, і закриває його;
8. записує `~/.var/app/com.usebottles.bottles/data/resolve-wine.conf` і додає в меню пункт **DaVinci Resolve (Wine)**.

Далі запускайте з меню або:

```bash
~/.var/app/com.usebottles.bottles/data/resolve-wine.sh launch
```

Діагностика:

```bash
~/.var/app/com.usebottles.bottles/data/resolve-wine.sh doctor
```

> Запуск звичайною кнопкою в Bottles **не працюватиме**: вона не записує значення реєстру і не підміняє версію драйвера.
>
> Запускайте **один** Resolve за раз: кілька копій в одній пляшці блокують базу проєктів і зависають на «Loading Project Libraries». Налагоджувальне логування (`WINEDEBUG=+seh` тощо) помітно гальмує Resolve, тому в скрипті запуску воно вимкнене.

## Драйвер 580 на Debian 13 / LMDE 7 (Pascal)

Debian 13 постачає 550 (CUDA 12.4), а репозиторій NVIDIA для Debian 13 починається з 590, де Pascal уже не підтримується. Тут спрацював офіційний `.run`-інсталятор:

1. Зробіть знімок у Timeshift.
2. Завантажте `NVIDIA-Linux-x86_64-580.x.run`. Беріть версію, для якої на Flathub є `GL.nvidia-580-…`.
3. Перейдіть у текстову консоль (**Ctrl+Alt+F3**), виконайте `sudo systemctl stop lightdm`.
4. `sudo apt purge '*nvidia*' libcuda1 libnvcuvid1`. Перевірте, що в списку немає пакетів робочого столу.
5. `sudo sh NVIDIA-Linux-x86_64-580.x.run --dkms` → модуль ядра **NVIDIA Proprietary** (open-версія не підтримує Pascal), 32-бітні бібліотеки: так, перебудувати initramfs: так, `nvidia-xconfig`: ні.
6. **Явно заблокуйте nouveau**, інакше після перезавантаження він захоплює карту (`GPU … is already bound to nouveau`):
   ```bash
   printf "blacklist nouveau\noptions nouveau modeset=0\n" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
   echo "options nvidia-drm modeset=1" | sudo tee /etc/modprobe.d/nvidia-drm.conf
   sudo update-initramfs -u && sudo reboot
   ```

Якщо робочий стіл не запускається: у GRUB натисніть `e`, допишіть `systemd.unit=multi-user.target` у кінець рядка `linux` (у той самий рядок), завантажтесь через **Ctrl+X** і виправте або відкотіть (`sudo nvidia-uninstall && sudo apt install nvidia-driver`).

## Як підтримувати в робочому стані

| Ви оновили… | Тоді |
|---|---|
| Resolve | Повторіть `setup` (інсталятор може повернути `nvcuda.dll` і оригінальний `pthreadVC2.dll`); якщо новій версії потрібен новіший драйвер, збільште `SPOOF_VERSION` у конфігу |
| Раннер | Змініть `RUNNER` у конфігу, повторіть `setup` |
| nvidia-libs | Повторіть `setup` |
| Драйвер NVIDIA | Поставте Flatpak-runtime `GL`/`GL32` точно тієї самої версії |
| Ядро | DKMS перезбере модуль; якщо ні: `sudo dkms autoinstall` |

## Проблеми

| Симптом (у `ResolveDebug.txt`) | Причина |
|---|---|
| `supports CUDA -1.-1`, у `Matches` немає `CUDA` | `nvcuda.dll` поруч із `Resolve.exe` або немає NVML |
| `provider '' driver ''` | Значення реєстру не записані: запускайте через скрипт |
| `supports CUDA 12.4` (або < 12.8), але `Selected compute API: OpenCL` | Застарий драйвер на хості |
| Зависає на «Loading Fairlight Engine» | Справа не в звуці: впала ініціалізація GPU через OpenCL, див. вище |
| Bottles взагалі не бачить GPU | Версія Flatpak-runtime `GL.nvidia-*` ≠ драйвер хоста |
| У лозі Wine: `unimplemented function ucrtbase.dll.cabsf` | Немає справжнього ucrtbase (`winetricks ucrtbase2019`) |
| Випадковий виліт після модулів Fusion, `c0000005` у `pthreadVC2.dll` | pthreadVC2 не виправлений |
| Зависає на «Loading Project Libraries» | Запущено кілька копій Resolve: `flatpak kill com.usebottles.bottles` і запустіть одну |

Як самому знайти причину вильоту: запустіть з `WINEDEBUG=-all,err+all,+seh,+loaddll`, візьміть `addr=` винятку `c0000005` і знайдіть модуль, у якого адреса `Loaded … at` найближча знизу.

`ResolveDebug.txt` лежить у `drive_c/users/<user>/AppData/Roaming/Blackmagic Design/DaVinci Resolve/Support/logs/`.

## Подяки

- [SveSop/nvidia-libs](https://github.com/SveSop/nvidia-libs): nvcuda, NVML, dxvk-nvapi для Wine. Без цього нічого б не вийшло.
- [Bottles](https://usebottles.com), Wine, dxvk-nvapi.

## Ліцензія

MIT. DaVinci Resolve — торгова марка Blackmagic Design; NVIDIA і CUDA — торгові марки NVIDIA. Проєкт не пов'язаний з жодною з цих компаній.
