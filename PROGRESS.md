# Vita Linux Port - Progress

## Date: 2026-02-22

## Status: LINUX BOOTS — eMMC PARTITIONS MOUNTED — REBOOT WORKS

Linux 6.7.0-rc5 boots to a Buildroot shell on the PlayStation Vita with all 4 Cortex-A9 cores,
framebuffer, touchscreen, buttons, GPIO LEDs, RTC, serial console, and SDHCI storage (eMMC readable).
All VitaOS partitions on the eMMC are mountable and readable from Linux.
`reboot` performs a clean hardware cold reset back to VitaOS with memory card intact.

## The L2 Cache Fix

The main blocker was stale PL310 L2 cache data corrupting the kernel's `.data` section.
The decompressor's `__armv7_mmu_cache_off` only flushes L1 via CP15 — but CP15 cache ops
do NOT propagate to the PL310 (which is MMIO-controlled). After decompression, L2 retains
stale zeros that corrupt variables like `kernel_sec_start`/`kernel_sec_end`.

**Fix applied in two places:**

1. **`arch/arm/boot/compressed/head.S`** (`__armv7_mmu_cache_off`) — Full PL310 L2
   clean+invalidate of all ways via MMIO before turning off L1/MMU. This is the
   comprehensive fix that eliminates all stale L2 data.

2. **`arch/arm/kernel/head.S`** (`__create_page_tables`) — Targeted PL310 L2 line
   invalidation for `kernel_sec_start`/`kernel_sec_end` after writing them. Belt-and-suspenders.

PL310 base on Vita: `0x1A002000`. Key registers:
- `0x7FC` = Clean+Invalidate by Way
- `0x770` = Invalidate Line by PA
- `0x730` = Cache Sync

## SDHCI / Storage

### Driver: `drivers/mmc/host/sdhci-vita.c`

Custom SDHCI platform driver for the Vita's 4 SDIF controllers. All use standard SDHCI
registers with identical capabilities:
- SDHCI Spec 3.0 (version reg 0x8901)
- 48MHz base clock, High Speed, SDMA, ADMA2
- 3.3V + 1.8V voltage support
- Caps: 0x6DEF30B0, Caps1: 0x00000000

The driver handles pervasive clock gating and reset deassert before accessing SDHCI registers.
Falls back to hardware-probe-only mode if no IRQ is available.

Quirks applied:
- `SDHCI_QUIRK_NO_SIMULT_VDD_AND_POWER`
- `SDHCI_QUIRK_BROKEN_TIMEOUT_VAL`
- `SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN`
- `SDHCI_QUIRK_BROKEN_CARD_DETECTION` (hardware CD pin unreliable)

### GIC Interrupt Numbers

Found via reverse engineering in `psvcmd56` (motoharu-gosuto):
- VitaOS interrupt codes: SDIF0=0xDC, SDIF1=0xDD, SDIF2=0xDE, SDIF3=0xDF
- Mapping: VitaOS code = GIC hardware IRQ ID, GIC_SPI = code - 32
- **SDIF0: GIC_SPI 188, SDIF1: GIC_SPI 189, SDIF2: GIC_SPI 190, SDIF3: GIC_SPI 191**

### SDIF Controllers

| SDIF | Address      | GIC SPI | Function        | Status |
|------|-------------|---------|-----------------|--------|
| SDIF0 | 0xE0B00000 | 188     | eMMC            | **Working** — M4G1FA 3.55 GiB detected, readable |
| SDIF1 | 0xE0C00000 | 189     | Game card       | Card init fails (SD2Vita adapter) |
| SDIF2 | 0xE0C10000 | 190     | WLAN/BT (SD8787)| Card present but init fails (see WiFi section) |
| SDIF3 | 0xE0C20000 | 191     | microSD         | Controller registered, no card |

### eMMC

The Vita's 3.55 GiB eMMC is readable at the block level. Data is NOT encrypted at the
raw block level — the first sector contains a plaintext SCE master boot record:
- Header: "Sony Computer Entertainment Inc." (32 bytes)
- Version: 3, Total size: 0x0071A000 = 7,446,528 sectors (matches device size)
- Custom SCE partition table (not standard MBR/GPT)
- MBR boot signature: 0x55AA at offset 0x1FE
- Backup MBR at sector 1 (identical copy)

### SCE Partition Table

Partition entries start at MBR offset 0x50, each 17 bytes packed (defined in
`refs/psvgamesd/driver/mbr_types.h`): `uint32_t offset, uint32_t size` (in 512-byte
blocks), `uint8_t code, type, active, flags, unk[5]`.

| # | Name | Offset (blk) | Size (blk) | Start MB | Size MB | FS | Active |
|---|------|-------------|-----------|----------|---------|------|--------|
| 0 | IdStorage | 512 | 1,024 | 0.25 | 0.5 | raw | |
| 1 | SLB2 | 16,384 | 8,192 | 8 | 4 | raw | backup |
| 2 | SLB2 | 24,576 | 8,192 | 12 | 4 | raw | active |
| 3 | os0 | 32,768 | 32,768 | 16 | 16 | fat16 | backup |
| 4 | os0 | 65,536 | 32,768 | 32 | 16 | fat16 | active |
| 5 | sa0 | 98,304 | 196,608 | 48 | 96 | fat16 | |
| 6 | tm0 | 294,912 | 65,536 | 144 | 32 | fat16 | |
| 7 | vs0 | 360,448 | 524,288 | 176 | 256 | fat16 | |
| 8 | vd0 | 884,736 | 65,536 | 432 | 32 | fat16 | |
| 9 | ud0 | 950,272 | 524,288 | 464 | 256 | fat16 | |
| 10 | pd0 | 1,474,560 | 622,592 | 720 | 304 | exfat | |
| 11 | ur0 | 2,097,152 | 5,349,376 | 1024 | 2612 | exfat | |

Partition codes: 0x01=eMMC/IdStorage, 0x02=SLB2, 0x03=os0, 0x04=vs0, 0x05=vd0,
0x06=tm0, 0x07=ur0, 0x08=ux0, 0x09=gro0, 0x0B=ud0, 0x0C=sa0, 0x0D=cardsExt, 0x0E=pd0.
Type codes: 0x06=fat16, 0x07=exfat, 0xDA=raw.

### Mounting eMMC Partitions

The SCE partition parser (`block/partitions/sce.c`, CONFIG_SCE_PARTITION=y) auto-detects
the partition table at boot and creates `/dev/mmcblk*p1` through `p12`. The eMMC device
number varies between boots (mmcblk0, mmcblk1, mmcblk2) so the rootfs includes:

- **`/etc/init.d/S05vita`** — init script that finds the eMMC (the mmcblk with a p12)
  and creates stable `/dev/vita/{os0,vs0,ur0,...}` symlinks
- **`/etc/fstab`** — entries using `/dev/vita/*` paths, all `ro,noauto`

Mounting is just: `mount /mnt/ur0` (fstab handles device, fs type, and flags).

Also available via loop devices with manual offsets (original method, still works):
```sh
losetup -r -o 1073741824 /dev/loop0 /dev/mmcblk0 && mount -t exfat -o ro /dev/loop0 /mnt/ur0
```

### eMMC Contents (from mounted partitions)

**ur0** (9 MiB used / 2.5 GiB): tai config, app data, user settings. tai/config.txt
confirms no storage manager plugin installed (no YAMT/StorageMgr — explains SD2Vita failure).

**os0/kd/** — VitaOS kernel modules (SCE-encrypted ELF): sdif.skprx, sdstor.skprx,
syscon.skprx, usbdev_serial.skprx, usbstor.skprx, wlanbt_robin_img_ax.skprx (311 KB,
WiFi/BT firmware container), display.skprx, oled.skprx, lowio.skprx, intrmgr.skprx, etc.

**vs0** (116 MiB used / 256 MiB): system apps (NPXS10xxx), shared libraries
(vs0/sys/external/).

**Note:** ux0 (memory card) is a separate physical device (Sony memory card via SDIF3
or SD2Vita via SDIF1), NOT an eMMC partition. Our Linux files at `ux0:/linux/` are on
the Sony memory card.

### SD2Vita (SDIF1)

The SD2Vita adapter in the game card slot is not yet working. The controller registers
and gets an IRQ, but card initialization fails ("Failed to initialize a non-removable card").
The hardware card-detect pin never asserts (present state bit 16 = 0).

**Key finding from StorageMgr RE:** No special hardware register writes are needed to switch
SDIF1 from game card mode to SD mode. The SDIF controller auto-negotiates the protocol based
on card responses (CMD0/CMD8/ACMD41 for SD vs CMD1 for MMC). The VitaOS firmware had software
blocks in SceSdstor that rejected SD-type cards on device index 1 — StorageMgr patches those
checks. In Linux, the SDHCI/MMC core handles protocol negotiation natively.

**Current blocker:** No SD2Vita plugin is installed on the Vita (`ur0:tai/config.txt` has no
storage plugin). The SD2Vita has never been verified working on this unit. Need to:
1. Install YAMT (recommended: https://vita.hacks.guide/yamt.html) and verify SD2Vita works in VitaOS
2. If it works in VitaOS, the Linux SDHCI driver should also work
3. If it still fails in Linux, check SDHCI command timeout / error interrupt status

### WiFi / SDIF2 Investigation (2026-02-22)

The Marvell SD8787 WiFi/BT chip is on SDIF2. Key findings:

**At boot:** SDIF2 present state = `0x1ffc0000` — card detect pin high but card NOT
inserted, state NOT stable. The chip isn't ready when the SDHCI driver probes (~0.9s
into boot).

**After ~30 minutes:** Present state changes to `0x01ff0000` — card inserted, state
stable, all data lines and CMD high. VitaOS left the chip powered and it eventually
becomes visible on the SDIO bus. Unbinding/rebinding the driver (`echo e0c10000.mmc >
/sys/bus/platform/drivers/sdhci-vita/{unbind,bind}`) confirms `[card present]`.

**But card init fails:** Despite the chip being present, the MMC core continuously polls
and fails to initialize it (~37 interrupts/sec on GIC SPI 190). No SDIO device appears
in `/sys/bus/sdio/devices/`. The SDHCI error status register reads 0 (errors handled
and cleared). The chip responds to some commands (interrupts fire) but never completes
SDIO enumeration (CMD5 likely failing).

**Root cause hypothesis:** The chip was left in an active/associated state by VitaOS,
not in a fresh SDIO-enumerable state. The SD8787 needs a PDn (power-down) GPIO toggle
to do a clean power cycle and re-enter SDIO enumeration mode.

**Power sequencing:** The kernel has `drivers/mmc/core/pwrseq_sd8787.c` which handles
exactly this — it toggles `reset-gpios` and `powerdown-gpios` with a 300ms delay.
But we need the actual GPIO pin numbers for the Vita's PDn and RESETN connections.

**What's needed to get WiFi working:**
1. Find SD8787 PDn and RESETN GPIO pin numbers (unknown — needs RE or community research)
2. Add `mmc-pwrseq-sd8787` node to device tree with the GPIO pins
3. Enable `CONFIG_WIRELESS`, `CONFIG_CFG80211`, `CONFIG_MWIFIEX`, `CONFIG_MWIFIEX_SDIO`
4. Enable `CONFIG_DEBUG_FS` + `CONFIG_DYNAMIC_DEBUG` (currently missing, needed for debugging)
5. Add `mrvl/sd8787_uapsta.bin` firmware to rootfs `/lib/firmware/mrvl/`
6. The Vita's encrypted firmware (`os0/kd/wlanbt_robin_img_ax.skprx`, 311 KB) is
   SCE-encrypted and NOT usable directly — standard linux-firmware blob needed

**Research leads for GPIO pins:**
- RE `os0/kd/wlanbt_robin_img_ax.skprx` or VitaOS bootloader in Ghidra
- HENkaku wiki: https://wiki.henkaku.xyz/vita/SceWlanBt
- Check vita-libbaremetal `gpio.h` — defines GPIO0 base `0xE20A0000`, GPIO1 base `0xE0100000`,
  but WiFi GPIO pins are NOT listed in available headers
- Community research: HENkaku Discord, xerpi's work, SonicMastr's contributions

### DTB Build Note

The vita DTS files are in `arch/arm/boot/dts/` (top level, not a subdirectory), so
`make dtbs` does NOT build them. Build manually:
```
cpp -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
    -undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
    scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -
```

## Environment

### Local (macOS)
- `/Users/cameron/Developer/vita-linux-port/` — working directory with:
  - `linux_vita/` — cloned kernel repo (shallow, branch `rebase-6.7.0-rc5`)
  - `vita-baremetal-linux-loader/` — cloned loader repo
  - `refs/` — reference repos (vita-libbaremetal, vita-headers, psvcmd56, etc.)
- Edit locally with proper tools, `scp` changed files to periscope, build there

### VM (UTM on macOS)
- **periscope** (`ssh periscope`) — Debian 13 aarch64 (virtualized + Rosetta) — main dev VM

### Periscope layout
- `~/linux_vita` — xerpi's kernel, branch `rebase-6.7.0-rc5` (patched)
- `~/buildroot` — buildroot 2025.11.1 (built natively, `BR2_TOOLCHAIN_EXTERNAL_CUSTOM`)
- `~/vita-baremetal-loader` — kernel plugin for standby/resume
- `~/vita-libbaremetal` — bare-metal hardware library
- `~/vita-baremetal-linux-loader` — payload that loads zImage+DTB (patched with cache flush)
- `~/vita_plugin_loader` — VPK app to trigger kernel plugin
- Cross-compiler: `/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1`
- VitaSDK: `/usr/local/vitasdk`
- **Build command:** `export PATH=/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1/bin:$PATH && cd ~/linux_vita && make ARCH=arm CROSS_COMPILE=arm-linux- zImage -j6`


### Vita
- Model: PCH-1103 (Vita 1000)
- Firmware: 3.65 with enso
- UART via Tigard at 115200 baud (`/dev/tty.usbserial-TG110fda0`)
- FTP via VitaShell at `ftp://192.168.1.34:1337`

### Files on Vita
- `ux0:data/tai/kplugin.skprx` — baremetal-loader_363.skprx
- `ux0:baremetal/payload.bin` — vita-baremetal-linux-loader.bin
- `ux0:linux/zImage` — kernel with embedded rootfs
- `ux0:linux/vita1000.dtb` — device tree
- Plugin Loader VPK installed as app

## What works
- Full boot to Buildroot login shell
- All 4 Cortex-A9 CPUs (574 BogoMIPS per core)
- 480MB RAM available (of 512MB total)
- Framebuffer: 960x544 OLED (simple-framebuffer, fb0)
- UART serial console (ttyS0 @ 115200)
- Touchscreen input (via syscon)
- Button input (via syscon)
- GPIO LEDs (PS button blue LED, gamecard activity LED)
- RTC (reads correct time from syscon)
- PL310 L2 cache controller (16-way, 2MB)
- **SDHCI storage** — eMMC (3.55 GiB) readable via ADMA, all 4 SDIF hosts registered
- **eMMC partitions** — SCE partition table auto-detected via custom kernel partition parser
  (`block/partitions/sce.c`), all 12 partitions exposed as `/dev/mmcblk*pN`
- **eMMC auto-mount** — `S05vita` init script creates `/dev/vita/*` symlinks, fstab
  provides `mount /mnt/ur0` etc. (read-only, noauto)
- **Filesystem support** — CONFIG_EXFAT_FS=y, CONFIG_VFAT_FS=y, CONFIG_BLK_DEV_LOOP=y

## What doesn't work / not yet implemented
- **WiFi** — SD8787 chip is electrically present on SDIF2 (VitaOS left it powered),
  SDHCI bus works, MMC core polls actively, but SDIO enumeration fails. Needs power
  cycle via PDn GPIO (pin number unknown). See WiFi section above.
- **SD2Vita** — Card init fails on SDIF1. No SD2Vita plugin in VitaOS tai config.
  Need to install YAMT and verify in VitaOS first.
- **USB** — `CONFIG_USB_SUPPORT` not set. UDC MMIO base address unknown (needs RE).
  3 UDC buses exist (pervasive offsets 0x90/0x94/0x98). RE targets: `os0/kd/usbstor.skprx`,
  `os0/kd/usbdev_serial.skprx` (accessible from mounted os0 partition).
- **Vita memory card** — Uses MSIF (0xE0900000), proprietary protocol with crypto auth.
  Not standard SD. Would need custom driver.
- **Kernel debug** — `CONFIG_DEBUG_FS` and `CONFIG_DYNAMIC_DEBUG` not set. Can't use
  dynamic debug for MMC/SDHCI troubleshooting.
- **File transfer** — No network = no scp/wget. Workflow: edit rootfs overlay on
  periscope → rebuild → upload zImage via FTP.

## Modified files (from upstream xerpi)

### `arch/arm/boot/compressed/head.S` (decompressor)
- Added PL310 L2 clean+invalidate-all-ways in `__armv7_mmu_cache_off` before disabling L1/MMU

### `arch/arm/kernel/head.S` (kernel boot)
- Added PL310 L2 line invalidation via MMIO after writing `kernel_sec_start`/`kernel_sec_end`
- Removed previous failed CP15 D-cache invalidate attempts

### `arch/arm/boot/dts/vita.dtsi`
- Added 4 SDIF device tree nodes (mmc@e0b00000 through mmc@e0c20000) with interrupt properties

### `arch/arm/boot/dts/vita1000.dts`
- Added `console=ttyS0,115200` to bootargs
- Enabled all 4 SDIF controllers, SDIF1 with `non-removable`

### `drivers/mmc/host/sdhci-vita.c` (NEW)
- SDHCI platform driver for Vita's SDIF controllers

### `drivers/mmc/host/Kconfig` + `Makefile`
- Added MMC_SDHCI_VITA config and build entries

### `block/partitions/sce.c` (NEW)
- SCE partition table parser for Vita eMMC — detects "Sony Computer Entertainment Inc."
  magic, parses 16 packed entries (17 bytes each at MBR offset 0x50), registers partitions
  automatically. Kernel creates `/dev/mmcblk*p1` through `p12` on boot.

### `block/partitions/check.h` + `core.c` + `Makefile` + `Kconfig`
- Registered SCE parser (CONFIG_SCE_PARTITION), placed before msdos in probe order
  since SCE MBR also has 0x55AA signature

### `vita-baremetal-linux-loader/src/main.c`
- Added L1+L2 cache flush before jumping to Linux

## Reference repos (in `refs/`)
- `vita-libbaremetal` — xerpi's bare-metal library (polling SDIF, GPIO, SPI, etc.)
- `vita-headers` — vitasdk kernel headers (interrupt manager, lowio, etc.)
- `psvcmd56` — motoharu-gosuto's reversed SDIF/CMD56 code (**source of GIC IRQ numbers**)
- `vita-linux-loader` — xerpi's VitaOS kernel plugin
- `GhidraVitaLoader` — Ghidra plugin for Vita module analysis
- `vita-baremetal-sample` — xerpi's bare-metal sample code
- `enso_ex`, `broombroom`, `taiHEN`, `PSP2-batteryFixer` — various Vita homebrew

## Key references
- xerpi's gist: https://gist.github.com/xerpi/ef487ec59a8246cb2823d007f5e8dfcb
- HENkaku wiki driver status: https://wiki.henkaku.xyz/vita/Linux_Driver_Status
- Buildroot .config expects rootfs.cpio.zst (recompress from .xz with zstd)
- psvcmd56 SceIntrmgr.h: SDIF interrupt codes 0xDC-0xDF

## Kernel config additions (beyond xerpi baseline)
- `CONFIG_SCE_PARTITION=y` + `CONFIG_PARTITION_ADVANCED=y` — SCE partition parser
- `CONFIG_BLK_DEV_LOOP=y` — loop block devices
- `CONFIG_VFAT_FS=y` + `CONFIG_FAT_FS=y` — FAT16 filesystem
- `CONFIG_NLS_CODEPAGE_437=y` + `CONFIG_NLS_ISO8859_1=y` — NLS for vfat

## Buildroot rootfs overlay (on periscope: `~/buildroot/rootfs-overlay/`)
- `etc/fstab` — standard mounts + Vita eMMC partitions (ro, noauto)
- `etc/init.d/S05vita` — creates `/dev/vita/*` symlinks to eMMC partitions
- `mnt/{os0,vs0,sa0,tm0,vd0,ud0,pd0,ur0}/` — mountpoint directories

## Reboot / Power Management (2026-02-22) — SOLVED

### Solution

Cold reset via direct SPI command `0x0801` to Ernie. Before issuing the reset,
power off the memory card (MSIF, cmd `0x89B`) and game card slot (cmd `0x888`)
so VitaOS finds them in a clean state on the next boot.

Implementation: reboot notifier in `vita-syscon.c` with priority 255.

### Key Discovery: Raw Ernie Commands

The TrustZone Secure Monitor (SMC 0x11A) is the normal path for power commands,
but it can't function after Linux reconfigures the GIC and SPI controller.
Analysis of the Monitor's handler (henkaku wiki `SceSyscon#sceSysconSetPowerModeForDriver`)
revealed it sends **different raw SPI commands** than the VitaOS kernel-level
abstraction (cmd 0x0C). The raw Ernie commands are:

| Command | Description | Wire format `{cmd_lo, cmd_hi, args_size, args}` | Status |
|---------|-------------|--------------------------------------------------|--------|
| 0x0801 | Cold reset | `{0x01, 0x08, 0x01, 0x00}` | **Works** |
| 0x00C0 | Power off/suspend/soft-reset | `{0xC0, 0x00, 0x05, type, ~mode...}` | Rejected (0x3B) |
| 0x00C1 | Ext boot / update mode | `{0xC1, 0x00, 0x02, 0x00}` | Untested |
| 0x00C2 | Hibernate | `{0xC2, 0x00, 0x02, 0x5A}` | Untested |

The VitaOS-level command 0x0C is rejected with result 0x3F — this is a
higher-level abstraction that goes through `ksceSysconCmdExec` with flags.
The raw commands 0x0801 and 0x00C0+ are what the TrustZone Monitor actually
sends to Ernie on the wire.

### Memory Card Issue

Cold reset (0x0801) resets the ARM cores but does NOT power-cycle the Sony
memory card (MSIF) controller. Without explicitly powering off the memory
card before the reset, VitaOS boots into a state where the card is visible
but unmountable (capacity shows "-", apps missing). Powering off via syscon
command 0x89B before the reset fixes this.

### Failed Approaches

| Approach | Result |
|----------|--------|
| Direct SPI cmd 0x0C (COLD_RESET) | Ernie rejects with result 0x3F |
| Direct SPI cmd 0x00C0 (POWEROFF) | Ernie rejects with result 0x3B |
| SMC 0x11A (COLD_RESET) | Returns without resetting, RCU stall |
| SMC 0x11A (SOFT_RESET) | Hangs forever inside Monitor |

### Architecture Notes

- Ernie (Renesas RL78) controls all power rails, reset, and standby/resume
- TrustZone Secure Monitor at phys `0x40000000`-`0x401FFFFF` handles SMC 0x11A
- Monitor does polled SPI I/O on SPI0 (`0xE0A00000`) — same controller Linux owns
- Linux boots in Secure mode (NS bit never set), so SMC instruction works but
  Monitor's handlers fail because GIC/SPI state has been reconfigured
- VitaOS power flow: `kscePowerRequestStandby()` → `ksceSysconResetDevice()` →
  `ksceSysconSendCommand(0x0C, buffer, 4)` → TrustZone SMC → raw Ernie SPI

### Files Modified

- `linux_vita/drivers/mfd/vita-syscon.c` — Reboot notifier sends syscon 0x89B
  (MSIF power off), 0x888 (game card power off), then 0x0801 (cold reset)
- `linux_vita/include/linux/mfd/vita-syscon.h` — Added `reboot_nb` to
  `struct vita_syscon`, added reset type constants

## Next steps
- **Find WiFi GPIO pins** — The key blocker for networking. Research avenues:
  - HENkaku wiki (SceWlanBt, GPIO pages)
  - HENkaku Discord / community
  - xerpi's or SonicMastr's research
  - RE VitaOS modules in Ghidra (os0/kd/wlanbt_robin_img_ax.skprx, lowio.skprx)
- **Enable wireless stack** — CONFIG_WIRELESS, CONFIG_MWIFIEX, CONFIG_MWIFIEX_SDIO,
  CONFIG_DEBUG_FS, CONFIG_DYNAMIC_DEBUG. Add mrvl/sd8787_uapsta.bin to rootfs.
- **USB controller RE** — Find UDC MMIO base from os0/kd/usbstor.skprx via Ghidra.
  Would enable USB gadget networking as alternative to WiFi.
- **SD2Vita** — Install YAMT on VitaOS, verify adapter works, then revisit Linux.
- **Add tools to rootfs** — devmem2, evtest, strace via buildroot packages
- **Contribute upstream** — L2 cache fix + SDHCI driver + SCE partition parser to xerpi's repo
