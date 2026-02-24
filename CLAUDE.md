# Vita Linux Port

See [BUILDING.md](BUILDING.md) for build instructions (macOS or Linux).
See [PROGRESS.md](PROGRESS.md) for detailed status, findings, and next steps.
See [HARDWARE.md](HARDWARE.md) for peripheral addresses, register maps, and pinouts.

## Environment

### Local (macOS or Linux)
- `linux_vita/` — kernel repo, git submodule (branch `vita-port-6.12`, based on Linux 6.12 + xerpi's Vita patches)
- `vita-baremetal-linux-loader/` — loader repo, git submodule (branch `vita-port`)
- `refs/` — reference repos for research (vita-headers, psvcmd56, StorageMgr, etc.)
- Clone with `git clone --recursive` to get submodules, or run `git submodule update --init` after cloning
- Builds locally: macOS uses LLVM/Clang, Linux uses Bootlin GCC cross-compiler (see [BUILDING.md](BUILDING.md))

### Buildroot VM (periscope)
- **periscope** (`ssh periscope`) — Debian 13 aarch64 (UTM + Rosetta) — used for building the rootfs only
- Buildroot: `cd ~/buildroot && make -j6` → `output/images/rootfs.cpio.xz`
  - Uses `BR2_TOOLCHAIN_EXTERNAL_CUSTOM` (not Bootlin preset, which isn't available on aarch64 hosts)
  - Rootfs overlay: `~/buildroot/rootfs-overlay/` (add files to include in initramfs)
- Fetch rootfs for local builds: `scp periscope:~/buildroot/output/images/rootfs.cpio.xz linux_vita/rootfs.cpio.xz`

### Vita
- Model: PCH-1103 (Vita 1000, OLED), no internal user storage
- Firmware: 3.65 with enso
- Storage: 3.55GB eMMC (system), 16GB Sony memory card (`ux0:`), SD2Vita 256GB (not yet working)
- FTP: `ftp://192.168.1.34:1337` (auto-starts via vitacompanion plugin, only available in VitaOS — not while running Linux)
- Upload: `curl -s -T file "ftp://192.168.1.34:1337/ux0:/linux/file"` (must reboot to VitaOS first if Vita is running Linux)
- Files: `ux0:/linux/zImage`, `ux0:/linux/vita1000.dtb`, `ux0:/baremetal/payload.bin`
- SD2Vita needs YAMT plugin installed first (https://vita.hacks.guide/yamt.html)
- tai config: `ur0:tai/config.txt` (no storage manager plugin currently installed)

## Build & Deploy Workflow

The `Makefile` orchestrates the full workflow from macOS or Linux. Run `make help` for all targets.

- `make deploy` — full pipeline: build → push → boot
- `make config` — copy `kernel.config` to `linux_vita/.config` and run `olddefconfig`
- `make build` — compile zImage + DTB locally
- `make dtb` — compile device tree only
- `make push` — upload zImage + DTB to Vita via FTP
- `make boot` — launch Plugin Loader via VitaCompanion, then stream serial output with boot stage tracking
- `make watch` — watch an in-progress boot without triggering a launch

### Agent workflow (edit → build → test)

1. Edit files in `linux_vita/` (drivers, DTS, etc.)
2. `make deploy` — builds locally, uploads to Vita, boots
3. If build fails: read error output, fix, `make deploy` again
4. After boot: use `./vita_cmd.sh "command"` to run commands on the Vita
5. To reboot back to VitaOS: `./vita_cmd.sh "reboot"` — performs cold reset, Vita boots to VitaOS with memory card intact
6. After VitaOS boots, vitacompanion auto-starts — go back to step 2
7. **Commit and push** when changes are working: `cd linux_vita && git add <files> && git commit -m "..." && git push origin vita-port-6.12`
   - Always stage specific files — never `git add -A` (macOS case-insensitive FS creates spurious diffs)
   - Run `fix_case_sensitivity.sh` once after cloning to hide the known bad files

### Kernel config

- `kernel.config` (outer repo) is the canonical `.config` — tracked in git
- `make config` copies it to `linux_vita/.config` and runs `olddefconfig`
- Edit `kernel.config` locally, then `make config` to apply
- Buildroot initramfs (`rootfs.cpio.xz`) must be present in `linux_vita/` — fetch from periscope if needed

### VitaCompanion (remote control)

The vitacompanion plugin exposes FTP (port 1337) and a TCP command interface (port 1338).
Commands can be sent with `echo "cmd" | nc 192.168.1.34 1338`. Available commands:
- `launch <TITLEID>` — launch an app (Plugin Loader = `PLGINLDR0`)
- `destroy` — kill all running apps
- `reboot` — cold reboot
- `screen on|off` — control display

## Tools

- `serial_log.py` — Tigard serial console with logging and bidirectional I/O. See `SERIAL.md` for usage.
  - Read serial output: `latest.log` symlinks to the current/most recent log
  - Send commands to the device: `printf 'cmd\n' > /tmp/tigard.pipe`
  - Pipe input is paced at 5ms/byte to avoid target buffer overflows
- `boot_watch.sh` — monitors `latest.log` for boot progress after launching Linux
  - Streams all serial output with colored stage markers injected
  - Detects kernel panics and per-stage timeouts for early abort
  - Auto-logs in as root when login prompt is reached
  - Called automatically by `make boot`; run standalone with `make watch`
  - Requires `serial_log.py` running in another terminal
- `vita_cmd.sh` — run a command on the Vita over serial and get its output
  - Usage: `./vita_cmd.sh "uname -a"` or `./vita_cmd.sh "dmesg" 30` (custom timeout)
  - Blocks until the shell prompt (`# `) returns, then exits
  - Requires `serial_log.py` running and the Vita booted + logged in

## Reference repos (`refs/`)

Key repos for research and code reference (shallow clones):
- `psvcmd56` — reversed SceSdif/SceSdstor (source of SDIF GIC interrupt numbers)
- `vita-headers` — vitasdk kernel headers (interrupt manager, lowio APIs)
- `vita-libbaremetal` — xerpi's bare-metal library (SDIF, GPIO, SPI polling drivers)
- `vita-linux-loader` — xerpi's VitaOS kernel plugin that loads Linux
- `xerpi-linux-vita` — xerpi's Linux kernel fork (reference for existing Vita drivers)
- `PSVita-StorageMgr` — SD2Vita storage manager plugin
- `gamecard-microsd` — original SD2Vita plugin (xyzz)
- `psvgamesd` — virtual game card with physical SD support
- `GhidraVitaLoader` — Ghidra plugin for Vita module RE
- `vita-baremetal-sample` — xerpi's bare-metal sample code
- `enso_ex`, `broombroom`, `taiHEN` — Vita homebrew/exploit tools
- `PSP2-batteryFixer` — battery calibration/fix tool
- `newlib` — C library (reference for Vita toolchain)
- `henkaku-wiki` — local mirror of wiki.henkaku.xyz (354 pages, raw MediaWiki markup in `pages/`)
