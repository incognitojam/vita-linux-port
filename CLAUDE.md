# Vita Linux Port

See [BUILDING.md](BUILDING.md), [PROGRESS.md](PROGRESS.md), [HARDWARE.md](HARDWARE.md).

## Layout

- `linux_vita/` — kernel (submodule, branch `vita-port-6.12`, Linux 6.12 + xerpi's Vita patches)
- `vita-baremetal-linux-loader/` — loader (submodule, branch `vita-port`)
- `refs/` — reference repos (vita-headers, psvcmd56, vita-libbaremetal, xerpi-linux-vita, StorageMgr, etc.)

## Vita

- PCH-1103 (Vita 1000, OLED), FW 3.65 + enso, 16GB Sony memory card
- IP: `192.168.1.34` — FTP on 1337, VitaCompanion TCP on 1338 (only available in VitaOS)
- Files: `ux0:/linux/zImage`, `ux0:/linux/vita1000.dtb`, `ux0:/baremetal/payload.bin`
- SD2Vita 256GB not yet working (needs YAMT plugin)
- tai config: `ur0:tai/config.txt`

## Buildroot VM

- `ssh periscope` — Debian 13 aarch64 (UTM + Rosetta), rootfs builds only
- Build: `cd ~/buildroot && make -j6` → `output/images/rootfs.cpio.xz`
- Overlay: `~/buildroot/rootfs-overlay/`
- Fetch: `scp periscope:~/buildroot/output/images/rootfs.cpio.xz linux_vita/rootfs.cpio.xz`

## Workflow

`make deploy` — full pipeline: build → push → boot. See `make help` for all targets.

1. Edit files in `linux_vita/`
2. `make deploy` (or `make build`, `make dtb`, `make push`, `make boot` individually)
3. After boot: `./vita_cmd.sh "command"` to run commands on Vita over serial
4. Reboot to VitaOS: `./vita_cmd.sh "reboot"` — cold reset, vitacompanion auto-starts
5. Commit: `cd linux_vita && git add <specific files> && git commit -m "..." && git push origin vita-port-6.12`
   - **Never `git add -A`** — macOS case-insensitive FS creates spurious diffs
   - Run `fix_case_sensitivity.sh` once after cloning

## VitaCompanion

TCP command interface: `echo "cmd" | nc 192.168.1.34 1338`
- `launch PLGINLDR0` — launch Plugin Loader (boots Linux)
- `destroy` — kill all running apps
- `reboot` — cold reboot
- `screen on|off` — control display

## Tools

- `serial_log.py` — serial console (must be running in another terminal for boot/vita_cmd)
  - Logs: `logs/latest.log`; send input: `printf 'cmd\n' > /tmp/serial.pipe`
- `boot_watch.sh` — monitors boot progress, auto-login; called by `make boot`, standalone via `make watch`
- `vita_cmd.sh "cmd" [timeout]` — run command on Vita, blocks until prompt returns

## Decrypted os0 Modules (`refs/vita-os0`)

Decrypted VitaOS kernel modules (not committed). SCE-format ELFs — `objdump -d`
produces no output because the sections aren't standard. To disassemble:

```sh
# Get code segment offset+size from first LOAD segment
arm-none-eabi-readelf -l module.skprx.elf
# Extract raw code, repackage as a proper ELF, disassemble as Thumb
dd if=module.skprx.elf of=/tmp/code.bin bs=1 skip=$((OFFSET)) count=$((SIZE))
arm-none-eabi-objcopy -I binary -O elf32-littlearm -B arm /tmp/code.bin /tmp/code.elf \
  --change-section-address .data=0x81000000 --set-section-flags .data=code,alloc,load
arm-none-eabi-objdump -d -M force-thumb /tmp/code.elf > /tmp/disasm.txt
```

Key modules: `kd/syscon.skprx.elf` (Ernie SPI), `kd/sysstatemgr.skprx.elf` (power states),
`kd/lowio.skprx.elf` (low-level I/O), `kd/usbstor.skprx.elf` / `kd/usbdev_serial.skprx.elf` (USB).
`sm/` contains F00D (Toshiba MeP) secure modules — not ARM, different toolchain.

## Key Reference Repos (`refs/`)

- `psvcmd56` — reversed SceSdif/SceSdstor (SDIF GIC interrupt numbers)
- `vita-headers` — vitasdk kernel headers
- `vita-libbaremetal` — xerpi's bare-metal library (SDIF, GPIO, SPI polling drivers)
- `xerpi-linux-vita` — xerpi's Linux kernel fork (reference for existing Vita drivers)
- `PSVita-StorageMgr`, `gamecard-microsd`, `psvgamesd` — SD2Vita / game card storage plugins
- `henkaku-wiki` — local mirror of wiki.henkaku.xyz (354 pages, `pages/`)
