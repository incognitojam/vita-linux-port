# Building Linux for the PS Vita

There are two ways to build the kernel: **locally on macOS** using LLVM/Clang, or **remotely on a Linux VM** (periscope) using a GCC cross-compiler. Both produce a working ARM zImage + DTB.

## Option A: Local macOS build (LLVM/Clang)

Builds the kernel natively on macOS using Clang's built-in cross-compilation support (`LLVM=1`). No separate cross-compiler needed — Clang targets ARM directly.

Based on [Building Linux on macOS natively](https://seiya.me/blog/building-linux-on-macos-natively) by Seiya Nuta.

### Prerequisites

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

### Setup

The kernel tree needs a few macOS compatibility shims in `scripts/macos-include/` and a small patch to `scripts/mod/file2alias.c`. These are maintained on the `macos-build` branch (worktree at `~/Developer/linux_vita-macos`).

You also need the Buildroot initramfs, which is built on periscope:

```bash
scp periscope:~/linux_vita/rootfs.cpio.xz ~/Developer/linux_vita-macos/rootfs.cpio.xz
```

### Build

```bash
cd ~/Developer/linux_vita-macos

# Set up PATH for GNU tools and LLVM
export PATH="$(brew --prefix findutils)/libexec/gnubin:$(brew --prefix gnu-sed)/libexec/gnubin:$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$PATH"

# Generate/update config (needed once, or after config changes)
gmake ARCH=arm LLVM=1 \
  HOSTCFLAGS="-Iscripts/macos-include -I$(brew --prefix libelf)/include" \
  olddefconfig

# Build zImage
gmake ARCH=arm LLVM=1 \
  HOSTCFLAGS="-Iscripts/macos-include -I$(brew --prefix libelf)/include" \
  zImage -j$(sysctl -n hw.ncpu)

# Build DTB (clang as preprocessor, then dtc)
clang -E -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
    -undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
    scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -
```

Output:
- `arch/arm/boot/zImage` — kernel image
- `arch/arm/boot/dts/vita1000.dtb` — device tree blob

### macOS compatibility patches

macOS lacks Linux-specific headers (`<elf.h>`, `<byteswap.h>`) and has a conflicting `uuid_t` typedef. The patches only affect host build tools in `scripts/`, not the kernel itself:

- **`scripts/macos-include/elf.h`** — Wraps Homebrew's `libelf/gelf.h` (which provides the ELF struct types) and adds relocation constants (`R_ARM_*`, `R_386_*`, etc.), machine type constants (`EM_AARCH64`, `EM_RISCV`, etc.), and ARM ELF flag macros (`EF_ARM_EABI_VERSION`) that Homebrew's ancient libelf (0.8.13) is missing. These are all standard constants from glibc's `<elf.h>`.

- **`scripts/macos-include/byteswap.h`** — Maps `bswap_16/32/64` to `__builtin_bswap*` compiler intrinsics.

- **`scripts/mod/file2alias.c`** — Works around macOS system headers defining `uuid_t` as `unsigned char[16]`, which conflicts with the kernel's `struct uuid_t`. Uses `#define uuid_t int` / `#undef uuid_t` around the system header include.

### Notes

- The `.config` will be regenerated for Clang (`CONFIG_CC_IS_CLANG=y` instead of `CONFIG_CC_IS_GCC=y`). This is a separate config from `kernel.config` in the outer repo (which is the canonical GCC config for periscope builds).
- The `sorttable` host tool emits ~16 pointer type warnings due to `libelf` using `unsigned long` where `uint64_t` is expected. These are harmless (same size on 64-bit macOS) and don't affect the build.
- `CONFIG_DEBUG_INFO_BTF` must remain disabled — the BTF generation step uses GNU-only `dd` options.

## Option B: Remote build on periscope (GCC)

Uses a GCC cross-compiler on a Debian aarch64 VM. This is the original workflow managed by the outer repo's `Makefile`.

### Prerequisites

- SSH access to `periscope` (Debian 13 aarch64 VM in UTM)
- Cross-compiler at `/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1`
  - This is an x86_64 Linux binary running via Rosetta inside the aarch64 VM

### Build via Makefile

From the outer repo (`vita-linux-port/`):

```bash
make deploy   # full pipeline: sync → build → pull → push → boot
```

Or individual steps:

```bash
make sync     # fetch + reset periscope to branch, copy .config
make build    # compile zImage on periscope via SSH
make dtb      # compile device tree on periscope via SSH
make pull     # fetch built zImage + DTB from periscope
make push     # upload to Vita via FTP
make boot     # launch Linux on Vita, stream serial output
```

### Manual build on periscope

```bash
ssh periscope
export PATH=/opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1/bin:$PATH
cd ~/linux_vita
make ARCH=arm CROSS_COMPILE=arm-linux- zImage -j6
```

DTB (manual, vita1000.dts is not in `make dtbs`):
```bash
arm-linux-cpp -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
    -undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
    scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -
```

## Deploying to the Vita

After building (either method), copy the artifacts to the Vita via FTP:

```bash
curl -s -T arch/arm/boot/zImage "ftp://192.168.1.34:1337/ux0:/linux/zImage"
curl -s -T arch/arm/boot/dts/vita1000.dtb "ftp://192.168.1.34:1337/ux0:/linux/vita1000.dtb"
```

Or use `make push` (which reads from `linux_vita/arch/arm/boot/`).

The Vita must be running VitaOS (not Linux) for FTP to be available.

## Kernel config

- `kernel.config` in the outer repo is the canonical `.config` (tracked in git, GCC-oriented)
- `make sync` copies it to periscope as `~/linux_vita/.config`
- The macOS worktree maintains its own `.config` (regenerated for Clang via `olddefconfig`)
- Edit `kernel.config` locally, then sync/regenerate as needed

## Buildroot (initramfs)

The root filesystem is built on periscope using Buildroot:

```bash
ssh periscope
cd ~/buildroot && make -j6
# Output: output/images/rootfs.cpio.xz
cp output/images/rootfs.cpio.xz ~/linux_vita/
```

The kernel config embeds this as `CONFIG_INITRAMFS_SOURCE="rootfs.cpio.xz"`. For macOS builds, copy it from periscope into the worktree root.

Rootfs overlay (add files to the initramfs): `~/buildroot/rootfs-overlay/`
