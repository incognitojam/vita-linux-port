# Building Linux for the PS Vita

The kernel builds locally on macOS (LLVM/Clang) or Linux (Bootlin GCC cross-compiler). The `Makefile` detects your platform and uses the right toolchain automatically.

## Prerequisites

### macOS

```bash
brew install llvm lld libelf make findutils gnu-sed
```

| Package | Why |
|---------|-----|
| `llvm` | Clang compiler + LLVM tools (llvm-nm, llvm-objcopy, etc.) |
| `lld` | LLVM linker (`ld.lld`) |
| `libelf` | ELF type definitions for host tool compilation |
| `make` | GNU Make >= 4.0 (`gmake`) — macOS ships 3.81 |
| `findutils` | GNU `find`/`xargs` — kernel build expects GNU behavior |
| `gnu-sed` | GNU `sed` — some build scripts are incompatible with BSD sed |

### Linux

Install the [Bootlin](https://toolchains.bootlin.com/) ARMv7 cross-compiler:

```bash
# Download and extract (adjust version as needed)
BOOTLIN_VERSION=2025.08-1
curl -fsSL "https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs/armv7-eabihf--glibc--bleeding-edge-${BOOTLIN_VERSION}.tar.xz" | \
  sudo tar -xJC /opt

# Add to PATH (add to your .bashrc/.zshrc for persistence)
export PATH="/opt/armv7-eabihf--glibc--bleeding-edge-${BOOTLIN_VERSION}/bin:$PATH"
```

You also need standard build dependencies:

```bash
sudo apt install bc flex bison libssl-dev libelf-dev
```

## Build

From the outer repo (`vita-linux-port/`):

```bash
make config   # apply vita_defconfig → linux_vita/.config (first time or after config changes)
make build    # compile zImage + DTB
```

Or `make deploy` to build, upload to Vita, and boot in one step.

Output:
- `linux_vita/arch/arm/boot/zImage` — kernel image
- `linux_vita/arch/arm/boot/dts/vita1000.dtb` — device tree blob

### What the Makefile does

On **macOS**, it runs:
```
gmake ARCH=arm LLVM=1 HOSTCFLAGS="-Iscripts/macos-include -I..." zImage -j<ncpu>
```

On **Linux**, it runs:
```
make ARCH=arm CROSS_COMPILE=arm-linux- zImage -j<ncpu>
```

The `CROSS_COMPILE` prefix defaults to `arm-linux-` (Bootlin). Override if using a different toolchain:
```bash
make build CROSS_COMPILE=arm-linux-gnueabihf-   # Debian package
```

## Deploying to the Vita

After building, copy the artifacts to the Vita via FTP:

```bash
make push     # upload zImage + DTB to Vita via FTP
make boot     # launch Linux on Vita, stream serial output
```

Or manually:

```bash
curl -s -T linux_vita/arch/arm/boot/zImage "ftp://192.168.1.34:1337/ux0:/linux/zImage"
curl -s -T linux_vita/arch/arm/boot/dts/vita1000.dtb "ftp://192.168.1.34:1337/ux0:/linux/vita1000.dtb"
```

The Vita must be running VitaOS (not Linux) for FTP to be available.

## Kernel config

- `vita_defconfig` (`linux_vita/arch/arm/configs/vita_defconfig`) is a minimal defconfig (~100 lines, only non-default options)
- `make config` applies it via the kernel's defconfig mechanism (toolchain-agnostic — works with both GCC and Clang)
- After changing config (e.g. via menuconfig), run `make savedefconfig` to update `vita_defconfig`

## Buildroot (initramfs)

The root filesystem is built on periscope using Buildroot (Linux users can also build it locally with the same Bootlin toolchain):

```bash
ssh periscope
cd ~/buildroot && make -j6
# Output: output/images/rootfs.cpio.xz
cp output/images/rootfs.cpio.xz ~/linux_vita/
```

To fetch it from periscope for local builds:

```bash
scp periscope:~/buildroot/output/images/rootfs.cpio.xz linux_vita/rootfs.cpio.xz
```

The kernel config embeds this as `CONFIG_INITRAMFS_SOURCE="rootfs.cpio.xz"`. The file must be present in `linux_vita/` at build time for the initramfs to be included in the zImage.

Rootfs overlay (add files to the initramfs): `~/buildroot/rootfs-overlay/` on periscope.

## macOS compatibility patches

macOS lacks Linux-specific headers (`<elf.h>`, `<byteswap.h>`) and has a conflicting `uuid_t` typedef. The patches only affect host build tools in `scripts/`, not the kernel itself:

- **`scripts/macos-include/elf.h`** — Wraps Homebrew's `libelf/gelf.h` (which provides the ELF struct types) and adds relocation constants (`R_ARM_*`, `R_386_*`, etc.), machine type constants (`EM_AARCH64`, `EM_RISCV`, etc.), and ARM ELF flag macros (`EF_ARM_EABI_VERSION`) that Homebrew's ancient libelf (0.8.13) is missing. These are all standard constants from glibc's `<elf.h>`.

- **`scripts/macos-include/byteswap.h`** — Maps `bswap_16/32/64` to `__builtin_bswap*` compiler intrinsics.

- **`scripts/mod/file2alias.c`** — Works around macOS system headers defining `uuid_t` as `unsigned char[16]`, which conflicts with the kernel's `struct uuid_t`. Uses `#define uuid_t int` / `#undef uuid_t` around the system header include.

### Notes

- The `sorttable` host tool emits ~16 pointer type warnings due to `libelf` using `unsigned long` where `uint64_t` is expected. These are harmless (same size on 64-bit macOS) and don't affect the build.
- `CONFIG_DEBUG_INFO_BTF` must remain disabled — the BTF generation step uses GNU-only `dd` options.
