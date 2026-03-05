# Vita Linux Port

See [BUILDING.md](BUILDING.md), [PROGRESS.md](PROGRESS.md), [HARDWARE.md](HARDWARE.md), [WORKFLOW.md](WORKFLOW.md).

## Layout

- `linux_vita/` — kernel (submodule, Linux 6.12 + xerpi's Vita patches)
- `vita-baremetal-linux-loader/` — loader (submodule)
- `refs/` — reference repos (vita-headers, psvcmd56, vita-libbaremetal, xerpi-linux-vita, StorageMgr, etc.)

**Branches:** The dev branch for each submodule may change over time. Check
`.gitmodules` for the configured branch, or `git -C <submodule> branch -r` to
see the remote default. Don't assume a hardcoded branch name — verify it.

## Devices

### Vita 1000 (primary)
- PCH-1103, OLED, FW 3.65 + enso, 16GB Sony memory card
- SSH host: `vita` — FTP on 1337, VitaCompanion TCP on 1338 (only available in VitaOS)
- SD2Vita 256GB not yet working (needs YAMT plugin)
- tai config: `ur0:tai/config.txt`

### PSTV
- SSH host: `pstv` — FTP on 1337, VitaCompanion TCP on 1338
- Framebuffer: 1280x720 (HDMI), vs 960x544 on Vita 1000
- I2C1 has ADV7533 HDMI transmitter (no Linux driver yet)

### Files on device (all models)
- `ux0:/linux/zImage` — kernel with embedded rootfs
- `ux0:/linux/vita1000.dtb`, `vita2000.dtb`, `pstv.dtb` — device trees (loader auto-selects)
- `ux0:/baremetal/payload.bin` — baremetal linux loader
- `ux0:/data/tai/kplugin.skprx` — baremetal loader kernel plugin
- Plugin Loader VPK installed as app

## Buildroot VM

- `ssh periscope` — Debian 13 aarch64 (UTM + Rosetta), rootfs builds only
- Build: `cd ~/buildroot && make -j6` → `output/images/rootfs.cpio.zst`
- Overlay: `~/buildroot/rootfs-overlay/`
- Fetch: `scp periscope:~/buildroot/output/images/rootfs.cpio.zst linux_vita/rootfs.cpio.zst`

## Workflow

`make deploy` — full pipeline: build → push → boot. See `make help` for all targets.

Target a different device with `VITA_HOST=`: `make deploy VITA_HOST=pstv`

1. Edit files in `linux_vita/` (or a kernel worktree — see [WORKFLOW.md](WORKFLOW.md))
2. `make deploy` (or `make build`, `make dtb`, `make push`, `make boot` individually)
3. After boot: `./vita_cmd.sh "command"` to run commands on Vita over serial
4. Reboot to VitaOS: `./vita_cmd.sh "reboot"` — cold reset, vitacompanion auto-starts

### Worktree development

See [WORKFLOW.md](WORKFLOW.md) for the full three-tier worktree model. Key commands:

- `make kernel-worktree NAME=<feature>` — create kernel worktree for driver/feature work
- `make kernel-use NAME=<wt>` — switch which kernel dir the current worktree builds against
- `make worktree NAME=<branch>` — create outer worktree for scripts/docs/agents
- `make kernel-bump` — pin linux_vita submodule to a commit (integration lane)
- `make setup-cache` — one-time: create bare cache for fast clones/fetches

The kernel directory is resolved via: `LINUX_VITA_DIR` env/arg → `.linux-vita-dir` file → `./linux_vita`.

### Git workflow

**Branching:** In a worktree the outer repo (`vita-linux-port`) is typically on a
feature branch. Submodules will be checked out at a detached commit. When doing
work in a submodule, create a branch (matching the outer repo's branch name, or a
descriptive name for the work) and push to that branch. Never push directly to the
submodule's main dev branch without permission.

**Commits in `linux_vita`:** Follow Linux kernel commit conventions (subject prefix
like `arm: vita:` or `mmc: sdhci-vita:`, imperative mood, concise subject, blank
line, explanatory body). On a working branch commits can be messy, but clean them
up (interactive rebase / fixup) before merge.

**PRs:** Create PRs against the outer `vita-linux-port` repo, bumping submodule
refs as needed, so CI can run. Update documentation in the outer repo as part of
the PR.

**Other rules:**
- **Never `git add -A`** in `linux_vita/` — macOS case-insensitive FS creates spurious diffs
- Run `fix_case_sensitivity.sh` once after cloning

## VitaCompanion

TCP command interface: `echo "cmd" | nc <VITA_IP> 1338`
- `launch PLGINLDR0` — launch Plugin Loader (boots Linux)
- `destroy` — kill all running apps
- `reboot` — cold reboot
- `screen on|off` — control display

## Tools

- `serial_log.py` — serial console (must be running in another terminal for boot/vita_cmd)
  - Logs: `logs/latest.log`; send input: `printf 'cmd\n' > /tmp/serial.pipe`
- `serial-bridge.sh <vm-host>` — bridge local serial to a remote build VM (see below)
- `boot_watch.sh` — monitors boot progress, auto-login; called by `make boot`, standalone via `make watch`
- `vita_cmd.sh "cmd" [timeout]` — run command on Vita, blocks until prompt returns

### Remote serial bridge

When the build VM is not on the same network as the Vita / does not have the
serial adapter attached, `serial-bridge.sh` bridges the serial console from the Mac
(where `serial_log.py` and the UART adapter run) to the VM over SSH.

Run on the Mac:
```sh
./serial-bridge.sh <vm-ssh-host>
# or: make serial-bridge BUILD_HOST=<vm-ssh-host>
```

This creates a transparent bridge — the VM gets a real `/tmp/serial.pipe` and
`logs/latest.log` so that `make boot`, `make deploy`, `boot_watch.sh`, and
`vita_cmd.sh` all work unmodified.

How it works:
- **Log stream (Mac → VM):** `tail -F logs/latest.log` piped over SSH to the VM
- **Pipe relay (VM → Mac):** SSH reverse tunnel + FIFO relay on the VM; writes
  to `/tmp/serial.pipe` on the VM are forwarded back to the Mac's pipe

Prerequisites: `serial_log.py` running on the Mac, SSH key auth to the VM.

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
