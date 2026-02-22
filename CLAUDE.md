# Vita Linux Port

See [PROGRESS.md](PROGRESS.md) for detailed status, findings, and next steps.
See [HARDWARE.md](HARDWARE.md) for peripheral addresses, register maps, and pinouts.

## Environment

### Local (macOS)
- `linux_vita/` — kernel repo (branch `vita-port`, based on xerpi's `rebase-6.7.0-rc5`)
- `vita-baremetal-linux-loader/` — loader repo (branch `vita-port`)
- `refs/` — reference repos for research (vita-headers, psvcmd56, StorageMgr, etc.)
- Edit locally, then follow the build/deploy workflow below

### Build VM
- **periscope** (`ssh periscope`) — Debian 13 aarch64 (UTM + Rosetta)
- Cross-compiler: `/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1`
- Build: `export PATH=/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1/bin:$PATH && cd ~/linux_vita && make ARCH=arm CROSS_COMPILE=arm-linux- zImage -j6`
- DTB (manual, not in `make dtbs`):
  ```
  cpp -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
      -undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
      scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -
  ```
- Buildroot: `cd ~/buildroot && make -j6` → `output/images/rootfs.cpio.xz`
  - Uses `BR2_TOOLCHAIN_EXTERNAL_CUSTOM` (not Bootlin preset, which isn't available on aarch64 hosts)
  - Rootfs overlay: `~/buildroot/rootfs-overlay/` (add files to include in initramfs)

### Vita
- Model: PCH-1103 (Vita 1000, OLED), no internal user storage
- Firmware: 3.65 with enso
- Storage: 3.55GB eMMC (system), 16GB Sony memory card (`ux0:`), SD2Vita 256GB (not yet working)
- FTP: `ftp://192.168.1.34:1337` (auto-starts via vitacompanion plugin)
- Upload: `curl -s -T file "ftp://192.168.1.34:1337/ux0:/linux/file"`
- Files: `ux0:/linux/zImage`, `ux0:/linux/vita1000.dtb`, `ux0:/baremetal/payload.bin`
- SD2Vita needs YAMT plugin installed first (https://vita.hacks.guide/yamt.html)
- tai config: `ur0:tai/config.txt` (no storage manager plugin currently installed)

## Build & Deploy Workflow

The `Makefile` orchestrates the full workflow from macOS. Run `make help` for all targets.

- `make deploy` — full pipeline: sync → build → pull → push → boot
- `make sync` — rsync kernel source to periscope
- `make build` — compile zImage on periscope via SSH
- `make dtb` — compile device tree on periscope via SSH
- `make pull` — fetch built zImage + DTB from periscope
- `make push` — upload zImage + DTB to Vita via FTP
- `make boot` — launch Plugin Loader via VitaCompanion, then stream serial output with boot stage tracking
- `make watch` — watch an in-progress boot without triggering a launch

### Manual steps (if not using Makefile)

1. **Edit** source files locally (kernel, DTS, driver)
2. **scp to periscope**: `scp linux_vita/path/to/file periscope:~/linux_vita/path/to/file`
3. **Build on periscope** (ssh):
   - zImage: `export PATH=/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1/bin:$PATH && cd ~/linux_vita && make ARCH=arm CROSS_COMPILE=arm-linux- zImage -j6`
   - DTB: see manual command in Build VM section above
4. **scp back**: `scp periscope:~/linux_vita/arch/arm/boot/zImage linux_vita/arch/arm/boot/zImage`
5. **Upload via FTP** (Vita must be in VitaOS, NOT booted into Linux):
   - `curl -s -T linux_vita/arch/arm/boot/zImage "ftp://192.168.1.34:1337/ux0:/linux/zImage"`
   - `curl -s -T linux_vita/arch/arm/boot/dts/vita1000.dtb "ftp://192.168.1.34:1337/ux0:/linux/vita1000.dtb"`
6. **Boot**: Launch Plugin Loader app on Vita → triggers baremetal loader → Linux boots
7. **Monitor**: serial output via `serial_log.py` in another terminal, or `tail latest.log`

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
  - Called automatically by `make boot`; run standalone with `make watch`
  - Requires `serial_log.py` running in another terminal

## Reference repos (`refs/`)

Key repos for research and code reference (shallow clones):
- `psvcmd56` — reversed SceSdif/SceSdstor (source of SDIF GIC interrupt numbers)
- `vita-headers` — vitasdk kernel headers (interrupt manager, lowio APIs)
- `vita-libbaremetal` — xerpi's bare-metal library (SDIF, GPIO, SPI polling drivers)
- `vita-linux-loader` — xerpi's VitaOS kernel plugin that loads Linux
- `PSVita-StorageMgr` — SD2Vita storage manager plugin
- `gamecard-microsd` — original SD2Vita plugin (xyzz)
- `psvgamesd` — virtual game card with physical SD support
- `GhidraVitaLoader` — Ghidra plugin for Vita module RE
- `vita-baremetal-sample` — xerpi's bare-metal sample code
- `enso_ex`, `broombroom`, `taiHEN` — Vita homebrew/exploit tools
