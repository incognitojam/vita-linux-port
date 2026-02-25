# Vita Linux Port - Progress

## Date: 2026-02-25

## Status: LINUX BOOTS — WiFi WORKING — eMMC PARTITIONS MOUNTED — REBOOT + POWEROFF WORK

Linux 6.12 boots to a Buildroot shell on the PlayStation Vita with all 4 Cortex-A9 cores,
framebuffer, touchscreen, buttons, GPIO LEDs, RTC, serial console, SDHCI storage (eMMC readable),
and WiFi networking (Marvell SD8787 via mwifiex).
All VitaOS partitions on the eMMC are mountable and readable from Linux.
`reboot` performs a clean hardware cold reset back to VitaOS with memory card intact.
`poweroff` powers the device off completely (not a reboot).

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
| SDIF2 | 0xE0C10000 | 190     | WLAN/BT (SD8787)| **Working** — mwifiex SDIO WiFi via custom power sequencing |
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

### WiFi / SDIF2 — WORKING (2026-02-25)

The Marvell SD8787 WiFi/BT chip is on SDIF2. WiFi is fully working with the
mwifiex SDIO driver after implementing custom power sequencing.

**Key discovery:** The SD8787 power control on the Vita does NOT use direct GPIO
pins (as initially assumed). Instead, power, reset, and the 27MHz reference clock
are all controlled indirectly:

- **Power & reset:** Ernie (syscon) commands `0x88A` (wireless power on/off) and
  `0x88F` (device reset assert/de-assert with mask `0x10` for WLANBT)
- **27MHz clock:** P1P40167 clockgen chip on I2C bus 0 (address `0x69`), register 1
  bit 3 enables the WlanBt clock. Uses CY27040 write protocol where register N is
  addressed as command byte `N - 128` (so reg 1 → cmd `0x81`, NOT `0x01`)

This means the in-tree `pwrseq_sd8787.c` driver (which expects direct GPIO pins)
cannot be used. The power sequencing is implemented directly in `vita-syscon.c`.

**Power-on sequence** (matches VitaOS boot order):
1. Disable SDIF2 interrupts (prevent premature MMC detect at wrong voltage)
2. Enable 27MHz WlanBt clock from clockgen via raw I2C0
3. Power on wireless via Ernie cmd `0x88A`
4. De-assert WLANBT reset via Ernie cmd `0x88F`
5. Full SDHCI controller re-init (pervasive reset cycle, 1.8V I/O voltage)
6. Trigger MMC core rescan (CMD5 SDIO enumeration)

**SDHCI re-init** (required after WiFi power change):
The SDHCI controller must be fully torn down and rebuilt after the SD8787 is
powered on. This matches vita-libbaremetal's `sdif_reset()` sequence: pervasive
gate/reset cycle, I/O voltage selection via misc register `0xE3100124` (bit 2 = 1.8V
for SDIF2), SDHCI software reset, interrupt configuration, bus voltage select, and
clock setup (div 128 for initial enumeration).

**I2C0 clockgen access:** Raw MMIO I2C (base `0xE0500000`) since no I2C subsystem
driver exists yet. Requires pervasive gate/reset for I2C bus 0 (offset `0x110`).
The I2C register layout was derived from vita-libbaremetal.

**Usage:** `echo 1 > /sys/devices/platform/soc/e0a00000.spi/spi_master/spi0/spi0.0/wlan_power`
then `wpa_supplicant` + `udhcpc` for network access. The reboot notifier automatically
powers off WiFi/BT before cold reset.

**Firmware:** Standard `mrvl/sd8787_uapsta.bin` from linux-firmware, placed in rootfs
at `/lib/firmware/mrvl/`. The Vita's encrypted firmware (`wlanbt_robin_img_ax.skprx`)
is NOT usable.

**DTS changes:** SDIF1 (game card) and SDIF3 (microSD) disabled to avoid polling log
spam — only SDIF0 (eMMC) and SDIF2 (WLAN) enabled.

#### Previous investigation (2026-02-22)

Before the power sequencing was understood, the chip was observed in a stuck state
left by VitaOS. At boot, SDIF2 present state was `0x1ffc0000` (card not inserted),
changing to `0x01ff0000` after ~30 minutes (card present but SDIO enumeration failing
at ~37 interrupts/sec). The initial hypothesis was that direct GPIO PDn/RESETN pins
were needed, but the actual control path is through Ernie syscon commands.

### DTB Build Note

The vita DTS files are in `arch/arm/boot/dts/` (top level, not a subdirectory), so
`make dtbs` does NOT build them. Build manually:
```
cpp -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
    -undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
    scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -
```

## Environment

### Local (macOS or Linux)
- `linux_vita/` — kernel repo, git submodule (branch `vita-port-6.12`, based on Linux 6.12)
- `vita-baremetal-linux-loader/` — loader repo, git submodule
- `refs/` — reference repos (vita-libbaremetal, vita-headers, psvcmd56, etc.)
- Build locally with LLVM/Clang (macOS) or Bootlin GCC cross-compiler (Linux)
- See [BUILDING.md](BUILDING.md) for prerequisites and build instructions

### Buildroot VM (periscope)
- **periscope** (`ssh periscope`) — Debian 13 aarch64 (UTM + Rosetta) — used for building the rootfs only
- `~/buildroot` — buildroot 2025.11.1 (built natively, `BR2_TOOLCHAIN_EXTERNAL_CUSTOM`)
- Rootfs overlay: `~/buildroot/rootfs-overlay/`
- VitaSDK: `/usr/local/vitasdk` (for building Vita homebrew plugins)


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
- **SDHCI storage** — eMMC (3.55 GiB) readable via ADMA, SDIF0 + SDIF2 enabled
- **eMMC partitions** — SCE partition table auto-detected via custom kernel partition parser
  (`block/partitions/sce.c`), all 12 partitions exposed as `/dev/mmcblk*pN`
- **eMMC auto-mount** — `S05vita` init script creates `/dev/vita/*` symlinks, fstab
  provides `mount /mnt/ur0` etc. (read-only, noauto)
- **Filesystem support** — CONFIG_EXFAT_FS=y, CONFIG_VFAT_FS=y, CONFIG_BLK_DEV_LOOP=y
- **WiFi** — Marvell SD8787 via mwifiex SDIO driver. Power sequencing through Ernie
  syscon commands + I2C clockgen. Controlled via `wlan_power` sysfs attribute.
- **Reboot + Poweroff** — `reboot` cold-resets to VitaOS, `poweroff` powers off completely.
  Both clean up peripherals (MSIF, game card, WiFi) before acting.
- **Debug infrastructure** — debugfs (auto-mounted), dynamic debug (687 callsites),
  MMC debug, SysRq over serial, printk timestamps, softlockup/hung task detection,
  frame pointer unwinder for clean stack traces

## What doesn't work / not yet implemented
- **SD2Vita** — Card init fails on SDIF1. No SD2Vita plugin in VitaOS tai config.
  Need to install YAMT and verify in VitaOS first. SDIF1 currently disabled in DTS.
- **USB** — `CONFIG_USB_SUPPORT` not set. UDC MMIO base address unknown (needs RE).
  3 UDC buses exist (pervasive offsets 0x90/0x94/0x98). RE targets: `os0/kd/usbstor.skprx`,
  `os0/kd/usbdev_serial.skprx` (accessible from mounted os0 partition).
- **Vita memory card** — Uses MSIF (0xE0900000), proprietary protocol with crypto auth.
  Not standard SD. Would need custom driver.
- **Bluetooth** — SD8787 has BT capability but only WiFi is enabled (mwifiex).
  BT would need `CONFIG_BT`, `CONFIG_BT_MRVL`, `CONFIG_BT_MRVL_SDIO`.

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
- Enabled SDIF0 (eMMC) and SDIF2 (WLAN) only — SDIF1/3 disabled to reduce log spam

### `drivers/mmc/host/sdhci-vita.c` (NEW)
- SDHCI platform driver for Vita's SDIF controllers
- Tracks SDIF hosts for cross-driver access
- Exports `sdhci_vita_reinit_host()` and `sdhci_vita_trigger_rescan()` for WiFi
  power sequencing — full pervasive reset cycle, I/O voltage config, SDHCI software
  reset, and MMC core rescan
- Bus-specific OCR enforcement and SDIF2 power behavior for SD8787 SDIO

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
- `CONFIG_WIRELESS=y` + `CONFIG_CFG80211=y` + `CONFIG_MAC80211=y` — wireless networking stack
- `CONFIG_MWIFIEX=y` + `CONFIG_MWIFIEX_SDIO=y` — Marvell WiFi-Ex SDIO driver for SD8787
- `CONFIG_NETDEVICES=y` + `CONFIG_WLAN=y` — network device and WLAN subsystem
- `CONFIG_DEBUG_FS=y` — debugfs filesystem (required by mwifiex, MMC, clock, GPIO debug)
- `CONFIG_DYNAMIC_DEBUG=y` — per-callsite `pr_debug`/`dev_dbg` control via debugfs
- `CONFIG_MMC_DEBUG=y` — MMC subsystem debug logging
- `CONFIG_MAGIC_SYSRQ=y` + `SERIAL=y` — SysRq over serial for emergency debug
- `CONFIG_PRINTK_TIME=y` — timestamps on kernel messages
- `CONFIG_SOFTLOCKUP_DETECTOR=y` — CPU soft lockup warnings
- `CONFIG_DETECT_HUNG_TASK=y` — hung task warnings (120s timeout)
- `CONFIG_UNWINDER_FRAME_POINTER=y` — better stack traces in panics/oopses

## Buildroot rootfs overlay (on periscope: `~/buildroot/rootfs-overlay/`)
- `etc/fstab` — standard mounts + debugfs + Vita eMMC partitions (ro, noauto)
- `etc/init.d/S05vita` — creates `/dev/vita/*` symlinks to eMMC partitions
- `lib/firmware/mrvl/sd8787_uapsta.bin` — Marvell SD8787 WiFi firmware (from linux-firmware)
- `mnt/{os0,vs0,sa0,tm0,vd0,ud0,pd0,ur0}/` — mountpoint directories

## Reboot / Power Management — SOLVED (reboot 2026-02-22, poweroff 2026-02-25)

### Solution

**Reboot:** Cold reset via direct SPI command `0x0801` to Ernie.

**Poweroff:** Direct SPI command `0x00C0` to Ernie with type=0 (poweroff), mode=0x2
(software-initiated). The mode bytes must be **bit-inverted** in the SPI payload.

Before issuing either command, power off the memory card (MSIF, cmd `0x89B`),
game card slot (cmd `0x888`), and WiFi/BT if enabled. Implementation: reboot
notifier in `vita-syscon.c` with priority 255.

### Key Discovery: Ernie Power Mode Protocol

The TrustZone Secure Monitor (SMC 0x11A) is the normal path for power commands,
but it can't function after Linux reconfigures the GIC and SPI controller.
Reverse-engineering the VitaOS `syscon.skprx` (disassembled from decrypted os0
dump) and the henkaku wiki documentation of `sceSysconSetPowerModeForDriver(type, mode)`
revealed the raw SPI commands the TZ Monitor sends to Ernie:

| Command | Description | Wire format `{cmd_lo, cmd_hi, len, data...}` | Status |
|---------|-------------|-----------------------------------------------|--------|
| 0x0801 | Cold reset | `{0x01, 0x08, 0x02, 0x00}` | **Working** |
| 0x00C0 | Power off (type=0, mode=0x2) | `{0xC0, 0x00, 0x05, 0x00, 0xFD, 0xFF, 0x00}` | **Working** |
| 0x00C0 | Suspend (type=1) | `{0xC0, 0x00, 0x05, 0x01, ~mode...}` | Untested |
| 0x00C0 | Soft reset (type=17) | `{0xC0, 0x00, 0x05, 0x11, ~mode...}` | Untested |
| 0x00C1 | Ext boot / update mode | `{0xC1, 0x00, 0x02, 0x00/0x01}` | Untested |
| 0x00C2 | Hibernate | `{0xC2, 0x00, 0x02, 0x5A}` | Untested |

The 0x00C0 command data format is `{type, (~mode) & 0xFF, (~mode >> 8) & 0xFF, (mode >> 16) & 0xFF}`.
The bit-inversion of the mode bytes is critical — earlier experiments sent the mode
value raw, causing Ernie to misparse the packet and fall back to cold reset behavior.

The VitaOS-level command 0x0C is rejected with result 0x3F — this is a
higher-level abstraction that goes through `ksceSysconCmdExec` with flags.
The raw commands 0x0801 and 0x00C0+ are what the TrustZone Monitor actually
sends to Ernie on the wire.

### Poweroff Investigation (2026-02-25)

Before the fix, `poweroff` in Linux printed "Requesting system poweroff" but the
device cold-rebooted into VitaOS. The reboot notifier handled all actions identically,
always sending the cold reset command (0x0801).

**What was tried (and failed):**

| # | Approach | Result |
|---|----------|--------|
| 1 | SPI cmd `0x00C0` with raw mode bytes | Instant reboot (mode bytes not inverted) |
| 2 | SPI cmd `0x8B0` (EnableHibernateIO) + `0x00C0` | Instant reboot |
| 3 | SPI cmd `0x00C0` with VitaOS mode value 0x8102 (raw) | Instant reboot |
| 4 | SPI cmd `0x00C1` (ErnieShutdown) data=0 | Silently ignored |
| 5 | SMC 0x11A via inline `smc #0` | No effect (TZ Monitor broken) |

**What fixed it:** Disassembling the decrypted `syscon.skprx` from the os0 dump
revealed the `sceSysconSetPowerModeForDriver` SMC wrapper at offset `0x3bcc`,
which passes type/mode straight through to SMC 0x11A. The henkaku wiki documents
that the SceSysconTzs handler constructs the SPI packet with **bit-inverted mode
bytes**. Applying this inversion (`~mode` in bytes 1-2 of the data payload)
made Ernie accept the poweroff command.

### Memory Card Issue

Cold reset (0x0801) resets the ARM cores but does NOT power-cycle the Sony
memory card (MSIF) controller. Without explicitly powering off the memory
card before the reset, VitaOS boots into a state where the card is visible
but unmountable (capacity shows "-", apps missing). Powering off via syscon
command 0x89B before the reset fixes this.

### Architecture Notes

- Ernie (Renesas RL78) controls all power rails, reset, and standby/resume
- TrustZone Secure Monitor at phys `0x40000000`-`0x401FFFFF` handles SMC 0x11A
- Monitor does polled SPI I/O on SPI0 (`0xE0A00000`) — same controller Linux owns
- Linux boots in Secure mode (NS bit never set), so SMC instruction works but
  Monitor's handlers fail because GIC/SPI state has been reconfigured
- VitaOS power flow: `kscePowerRequestStandby()` → `ksceSysconResetDevice()` →
  `ksceSysconSendCommand(0x0C, buffer, 4)` → TrustZone SMC → raw Ernie SPI

### Files Modified

- `linux_vita/drivers/mfd/vita-syscon.c` — Reboot notifier: powers off peripherals
  (MSIF 0x89B, game card 0x888, WiFi/BT if enabled), then sends poweroff (0x00C0
  with inverted mode) for SYS_POWER_OFF/SYS_HALT or cold reset (0x0801) for
  SYS_RESTART, with cold reset as fallback if poweroff fails. Also: WiFi power
  sequencing via Ernie commands (0x88A, 0x88F) and raw I2C0 clockgen access
  (P1P40167 at 0x69), `wlan_power` sysfs attribute.
- `linux_vita/include/linux/mfd/vita-syscon.h` — Added `reboot_nb` and `wlan_power`
  to `struct vita_syscon`, added reset type constants

## Next steps
- **Bluetooth** — SD8787 has combined WiFi/BT. Enable `CONFIG_BT`, `CONFIG_BT_MRVL`,
  `CONFIG_BT_MRVL_SDIO`. Firmware already loaded. Power sequencing is shared with WiFi.
- **Proper I2C driver** — Replace raw MMIO I2C0 access in syscon with a proper platform
  I2C driver. Would enable DT-based clockgen binding and other I2C peripherals.
- **USB controller RE** — Find UDC MMIO base from os0/kd/usbstor.skprx via Ghidra.
  Would enable USB gadget networking as alternative to WiFi.
- **SD2Vita** — Install YAMT on VitaOS, verify adapter works, then revisit Linux.
  SDIF1 currently disabled in DTS.
- **Add tools to rootfs** — devmem2, evtest, strace via buildroot packages
- **Contribute upstream** — L2 cache fix + SDHCI driver + SCE partition parser to xerpi's repo
