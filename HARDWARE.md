# Vita Hardware Reference for Linux Driver Development

## SoC Overview

Codename: **Kermit**
- 4x ARM Cortex-A9 cores
- PowerVR SGX543MP4+ GPU
- 512 MB RAM, 128 MB VRAM (CDRAM)
- Private peripheral base: `0x1A000000`

## Confirmed Peripheral Address Map

### ARM Private Peripherals (0x1A00xxxx)

| Component | Address | Status |
|-----------|---------|--------|
| SCU | `0x1A000000` | Working (SMP) |
| GIC CPU Interface | `0x1A000100` | Working |
| ARM TWD Timer | `0x1A000600` | Working |
| GIC Distributor | `0x1A001000` | Working |
| PL310 L2 Cache | `0x1A002000` | Working |

### I/O Peripherals

| Peripheral | Address | Size | Linux Status |
|-----------|---------|------|--------------|
| SPI0 (Syscon) | `0xE0A00000` | 0x1000 | Working |
| DMAC4 | `0xE0400000` | - | Not started |
| DMAC5 | `0xE0410000` | - | Not started |
| Bigmac (crypto) | `0xE0050000` | - | Not started |
| I2C0 | `0xE0500000` | 0x1000 | Raw MMIO (clockgen access for WiFi) |
| MSIF (MemoryStick) | `0xE0900000` | - | Not started (needs auth) |
| SDIF0 (eMMC) | `0xE0B00000` | 0x1000 | Working (SDHCI, ADMA) |
| SDIF1 (GameCard) | `0xE0C00000` | 0x1000 | Driver works, card init fails |
| SDIF2 (WLAN/BT) | `0xE0C10000` | 0x1000 | **Working** (mwifiex SDIO) |
| SDIF3 (microSD) | `0xE0C20000` | 0x1000 | Driver works, no card |
| UART0 | `0xE2030000` | 0x10000 | Working |
| UART(n) | `0xE2030000 + n*0x10000` | 0x10000 | - |
| GPIO | `0xE20A0000` | 0x1000 | Working |
| DMAC0 | `0xE3000000` | - | Not started |
| DMAC1 | `0xE3010000` | - | Not started |
| Pervasive Misc | `0xE3100000` | 0x1000 | - |
| Pervasive Reset | `0xE3101000` | 0x1000 | Working (reset controller) |
| Pervasive Gate | `0xE3102000` | 0x1000 | - |
| Pervasive BaseClk | `0xE3103000` | 0x1000 | - |
| Pervasive Vid | `0xE3104000` | 0x1000 | - |
| UART Clock Gen | `0xE3105000` | - | - |
| Pervasive2 | `0xE3110000` | - | - |
| DMAC2 | `0xE5000000` | - | Not started |
| DMAC3 | `0xE5010000` | - | Not started |
| Mailbox | `0xE5070000` | - | Not started |

### Other

| Component | Address | Notes |
|-----------|---------|-------|
| Secondary CPU boot | `0x1F007F00` | Used by SMP startup |
| Framebuffer (CDRAM) | `0x20000000` | 960x544x4 = 0x1FE000 bytes |
| DRAM start | `0x40200000` | 510 MB (to 0x5FFFFFFF) |

## Pervasive Reset/Gate Offsets

Relative to `0xE3101000` (reset) or `0xE3102000` (gate):

| Peripheral | Offset | Notes |
|-----------|--------|-------|
| DSI(bus) | `0x80 + bus*4` | Display Serial Interface |
| UDC(bus) | `0x90 + bus*4` | USB Device Controller (3 buses: 0,1,2) |
| SDIF(bus) | `0xA0 + bus*4` | SD Host (4 buses: 0-3) |
| MSIF | `0xB0` | Memory Stick |
| GPIO | `0x100` | |
| SPI(bus) | `0x104 + bus*4` | |
| I2C(bus) | `0x110 + bus*4` | |
| UART(bus) | `0x120 + bus*4` | |

## USB

### Known Facts
- 3 UDC (USB Device Controller) buses (0, 1, 2)
- USB 2.0 (bcdUSB = 0x0200)
- VID/PID: `0x054C:0x04E4` (Sony)
- Default UDC bus for serial: bus 2
- Pervasive reset offsets: UDC0=0x90, UDC1=0x94, UDC2=0x98
- UDC0 reset mask: `0xB`

### Unknown
- **UDC MMIO base address(es)** — needs RE from SceUdcd kernel module
- **GIC interrupt number(s)** for USB
- **Controller IP type** — could be Synopsys DWC2, ChipIdea, or custom Sony

### Connector Pinouts

#### Multi-Connector (PCH-1000, 20-pin proprietary)
| Pin | Signal |
|-----|--------|
| 6 | UART RX |
| 7 | UART TX |
| 8 | UART CTS |
| 9 | UART RTS |
| 11 | Accessory Enable/OTG |
| 14, 16, 19 | GND |
| 17-18 | VCC (+5V) |
| 20 | USB D- |
| 21 | USB D+ |

#### Accessory Port (PCH-1000 only, 5-pin)
| Pin | Signal | Voltage |
|-----|--------|---------|
| 1 | GND | |
| 2 | ID (OTG) | 1.8V |
| 3 | D- | |
| 4 | D+ | |
| 5 | VBUS | 3.3V (not 5V!) |

## SDIF (SD Host Controller) — Most Promising for Networking

All 4 SDIF controllers use **standard SDHCI** register layout. Base clock: 48 MHz.
Confirmed by SonicMastr (HENkaku Discord, Sep 2024) — registers map 1:1 to the
SD Host Controller Simplified Specification.

| Bus | Address | Device | SDIO VID:PID | Notes |
|-----|---------|--------|-------------|-------|
| 0 | `0xE0B00000` | eMMC | - | Internal storage |
| 1 | `0xE0C00000` | GameCard | - | MMC interface |
| 2 | `0xE0C10000` | WLAN/BT | `02DF:911A` / `02DF:9119` | **Marvell SD8787** (SDIO) |
| 3 | `0xE0C20000` | microSD | - | SD2Vita hardware mod only |

### SDHCI Register Map (standard, confirmed by SonicMastr)
```c
// Offsets match SD Host Controller Simplified Specification exactly
0x00  SDMA System Address / Argument 2
0x04  Block Size
0x06  Block Count
0x08  Argument 1
0x0C  Transfer Mode
0x0E  Command
0x10  Response[0..7] (16 bytes)
0x20  Buffer Data Port
0x24  Present State
0x28  Host Control 1
0x29  Power Control
0x2A  Block Gap Control
0x2B  Wakeup Control
0x2C  Clock Control
0x2E  Timeout Control
0x2F  Software Reset
0x30  Normal Interrupt Status
0x32  Error Interrupt Status
0x34  Normal Interrupt Status Enable
0x36  Error Interrupt Status Enable
0x38  Normal Interrupt Signal Enable
0x3A  Error Interrupt Signal Enable
0x3C  Auto CMD Error Status
0x3E  Host Control 2
0x40  Capabilities (64-bit)
0x48  Maximum Current Capabilities (64-bit)
0x50  Force Event Auto CMD Error Status
0x52  Force Event Error Interrupt Status
0x54  ADMA Error Status
0x58  ADMA System Address (64-bit)
0x60  Preset Values (16 bytes)
0xE0  Shared Bus Control
0xFC  Slot Interrupt Status
0xFE  Host Controller Version
```

### Pervasive Clock/Reset for SDIF
Offsets relative to reset (`0xE3101000`) or gate (`0xE3102000`):
- SDIF(bus): `0xA0 + bus*4`
- Additional misc registers at `0xE3100000` offsets: `0x110-0x11C`, `0x124`, `0x310`

### WiFi Chip: Marvell SD8787 (Avastar)
- Connected via SDIF2 at `0xE0C10000` (SDIO)
- Linux driver: `mwifiex` + `mwifiex_sdio` (mainline, `drivers/net/wireless/marvell/mwifiex/`)
- Standard firmware: `sd8787_uapsta.bin` in `/lib/firmware/mrvl/`
- Vita's WiFi firmware (`wlanbt_robin_img_ax.skprx`) is SCE-encrypted, NOT usable
- VitaOS module: SceWlanBt (NID 0x99052D93)

### WiFi Power Control — SOLVED (2026-02-25)

**Key discovery:** The SD8787 does NOT use direct GPIO pins for power/reset.
Instead, power control goes through Ernie (syscon) and an I2C clockgen chip:

| Control | Method | Details |
|---------|--------|---------|
| Power on/off | Ernie cmd `0x88A` | data: 0=off, 1=on |
| Reset assert/de-assert | Ernie cmd `0x88F` | device mask `0x10` (WLANBT), mode: 0=assert, 1=de-assert |
| 27MHz reference clock | P1P40167 clockgen on I2C0 | address `0x69`, register 1 bit 3 |

The in-tree `pwrseq_sd8787.c` driver (which expects direct GPIO) is NOT used.
Power sequencing is implemented directly in `vita-syscon.c` with a `wlan_power`
sysfs attribute.

#### P1P40167 Clockgen (I2C bus 0, address 0x69)

CY27040-compatible clock generator. Write protocol uses command byte = register - 128
(register 1 → cmd `0x81`). Register 1 bits:

| Bit | Function |
|-----|----------|
| 0 | Audio frequency select (0=44100, 1=48000) |
| 2 | MotionClk enable |
| 3 | WlanBtClk enable (27MHz buffered oscillator) |
| 4 | AudioClk enable |

Accessed via raw MMIO I2C (base `0xE0500000`) — no I2C subsystem driver yet.

#### SDHCI Reinit After Power Change

After powering on the SD8787, the SDIF2 SDHCI controller must be fully re-initialized:
pervasive gate/reset cycle, I/O voltage to 1.8V (misc register `0xE3100124` bit 2),
SDHCI software reset, interrupt configuration, bus voltage select + clock setup.
This is handled by `sdhci_vita_reinit_host()` exported from `sdhci-vita.c`.

### Storage Status (2026-02-22)

eMMC is fully working. SCE partition parser auto-creates partition devices.
All VitaOS partitions mountable (FAT16 + exFAT). See PROGRESS.md for details.

## MSIF (Memory Stick Interface)

Base: `0xE0900000`

| Register | Offset | Purpose |
|----------|--------|---------|
| Command | `0x30` | |
| Data | `0x34` | |
| Status | `0x38` | |
| System | `0x3C` | bit 15 = reset |

**Requires authentication** (3DES-CBC-CTS + ECDSA-224) before data access.
The baremetal linux-loader already handles this using a hardcoded key.
A Linux driver would need to re-authenticate or preserve state from the loader.

## Sources
- https://wiki.henkaku.xyz/vita/Pervasive
- https://wiki.henkaku.xyz/vita/SceLowio
- https://wiki.henkaku.xyz/vita/SceUdcd
- https://wiki.henkaku.xyz/vita/EHCI
- https://wiki.henkaku.xyz/vita/UART_Registers
- https://wiki.henkaku.xyz/vita/DMAC
- https://wiki.henkaku.xyz/vita/Linux_Driver_Status
- https://wiki.henkaku.xyz/vita/SceSdif
- https://www.psdevwiki.com/vita/USB
- https://www.psdevwiki.com/vita/Hardware
- https://consolemods.org/wiki/Vita:Connector_Pinouts
- https://github.com/xerpi/vita-libbaremetal
- https://gist.github.com/xerpi/0e682d594c5def602750c523ee491098
