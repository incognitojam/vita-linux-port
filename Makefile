# Vita Linux Port — local orchestration Makefile
# Builds locally (macOS with LLVM/Clang, Linux with Bootlin GCC), deploys to Vita
#
# Multi-device support:
#   VITA_HOST  — hostname or IP of the Vita (default: vita)
#   VITA_IP    — alias for VITA_HOST (legacy / explicit IP override)
#
# Kernel directory:
#   LINUX_VITA_DIR — override kernel source directory (env var or Make arg)
#   .linux-vita-dir — file containing kernel path (per-worktree, gitignored)
#   Falls back to ./linux_vita (submodule default)
#
# Set the DHCP hostname on the Vita's Wi-Fi config to "vita" so it resolves by name.
#
# Examples:
#   make deploy                          # default "vita" host
#   make deploy VITA_HOST=pstv           # target PSTV
#   make push VITA_IP=192.168.1.100      # push to explicit IP
#   make build LINUX_VITA_DIR=../vita-kernel-wt/mmc-dma

VITA_HOST ?= vita
VITA_IP   ?= $(VITA_HOST)
FTP_PORT  := 1337
CMD_PORT  := 1338
NC        := nc

# --- Kernel directory resolution (first wins) ---
# 1. LINUX_VITA_DIR env/cmdline  2. .linux-vita-dir file  3. ./linux_vita

ifndef LINUX_VITA_DIR
  ifneq ($(wildcard .linux-vita-dir),)
    LINUX_VITA_DIR := $(shell cat .linux-vita-dir)
  else
    LINUX_VITA_DIR := ./linux_vita
  endif
endif

LOCAL_KERNEL_DIR := $(LINUX_VITA_DIR)
ZIMAGE           := $(LOCAL_KERNEL_DIR)/arch/arm/boot/zImage
DTS_PATH         := arch/arm/boot/dts/sony
DTS_DIR          := $(LOCAL_KERNEL_DIR)/$(DTS_PATH)
VITA_MODELS      := vita1000 vita2000 pstv
DTBS             := $(foreach m,$(VITA_MODELS),$(DTS_DIR)/$(m).dtb)

# Validation marker — targets that need a kernel tree check this
KERNEL_MARKER := $(LOCAL_KERNEL_DIR)/arch/arm/configs/vita_defconfig
define check-kernel-dir
	@if [ ! -f "$(KERNEL_MARKER)" ]; then \
		echo "ERROR: LINUX_VITA_DIR=$(LOCAL_KERNEL_DIR) does not contain a kernel tree."; \
		echo "  Missing: $(KERNEL_MARKER)"; \
		echo "  Run 'make kernel-worktree' or 'make kernel-use' to configure."; \
		exit 1; \
	fi
endef

# --- Platform detection ---

UNAME_S := $(shell uname -s)

# --- ccache (used if available) ---
CCACHE := $(shell command -v ccache 2>/dev/null)

ifeq ($(UNAME_S),Darwin)
  # macOS: LLVM/Clang from Homebrew
  BREW_LLVM   := $(shell brew --prefix llvm)
  BREW_LLD    := $(shell brew --prefix lld)
  BREW_FIND   := $(shell brew --prefix findutils)/libexec/gnubin
  BREW_SED    := $(shell brew --prefix gnu-sed)/libexec/gnubin
  BREW_LIBELF := $(shell brew --prefix libelf)/include
  export PATH := $(BREW_FIND):$(BREW_SED):$(BREW_LLVM)/bin:$(BREW_LLD)/bin:$(PATH)
  KMAKE       := gmake ARCH=arm LLVM=1 HOSTCFLAGS="-Iscripts/macos-include -I$(BREW_LIBELF)"
  CPP         := clang -E
  NPROC       := $(shell sysctl -n hw.ncpu)
  ifneq ($(CCACHE),)
    KMAKE += CC="ccache clang" HOSTCC="ccache clang"
  endif
else
  # Linux: Bootlin cross-compiler (arm-buildroot-linux-gnueabihf-* must be on PATH)
  CROSS_COMPILE ?= arm-buildroot-linux-gnueabihf-
  KMAKE         := make ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE)
  CPP           := $(CROSS_COMPILE)cpp
  NPROC         := $(shell nproc)
  ifneq ($(CCACHE),)
    KMAKE += CC="ccache $(CROSS_COMPILE)gcc" HOSTCC="ccache gcc"
  endif
endif

# --- Device locking (prevents concurrent deploy to same Vita) ---

LOCK_FILE := /tmp/vita-deploy-$(VITA_HOST).lock
ifeq ($(UNAME_S),Darwin)
  # lockf -t 0: non-blocking (fail immediately if locked)
  LOCK_CMD = lockf -t 0 $(LOCK_FILE)
else
  # flock -n: non-blocking
  LOCK_CMD = flock -n $(LOCK_FILE)
endif
define lock-fail-msg
	echo "ERROR: Device $(VITA_HOST) is locked by another process."; \
	echo "  Wait or use a different device with VITA_HOST=<other>."
endef

# --- Bare cache mirror ---

CACHE_DIR      := $(HOME)/.cache/vita-linux/linux.git

# Remote list for bare cache: name=url pairs
CACHE_REMOTES := \
	origin=https://github.com/incognitojam/linux_vita.git \
	upstream=https://github.com/xerpi/linux_vita.git \
	techflashYT=https://github.com/techflashYT/linux-custom.git

.PHONY: config olddefconfig savedefconfig build build-zimage build-dtb dtb push push-setup boot deploy help watch serial serial-bridge lsp clean
.PHONY: rootfs rootfs-config rootfs-savedefconfig rootfs-menuconfig rootfs-clean
.PHONY: setup-cache update-cache worktree kernel-worktree kernel-use kernel-bump setup-git-config

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk -F ':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ------- Config -------

VITA_DEFCONFIG := $(LOCAL_KERNEL_DIR)/arch/arm/configs/vita_defconfig

KCONFIG := $(LOCAL_KERNEL_DIR)/.config

config: ## apply vita_defconfig → .config (overwrites)
	$(check-kernel-dir)
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) vita_defconfig

$(KCONFIG):
	$(check-kernel-dir)
	@echo ".config missing — generating from vita_defconfig"
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) vita_defconfig

olddefconfig: ## update .config with defaults for new symbols (no prompt)
	$(check-kernel-dir)
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) olddefconfig

savedefconfig: ## update vita_defconfig from current .config
	$(check-kernel-dir)
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) savedefconfig
	@mv $(LOCAL_KERNEL_DIR)/defconfig $(VITA_DEFCONFIG)
	@echo "vita_defconfig updated ($(shell wc -l < $(VITA_DEFCONFIG)) lines)"

# ------- Clean -------

clean: ## remove kernel build artifacts (works around macOS case-sensitivity bug)
	$(check-kernel-dir)
	$(KMAKE) -C $(LOCAL_KERNEL_DIR) clean 2>/dev/null || true
	@find $(LOCAL_KERNEL_DIR) \( -name '*.o' -o -name '*.o.cmd' -o -name '*.ko' \
		-o -name '.*.cmd' -o -name '*.a' -o -name '*.order' -o -name '*.symvers' \) \
		-delete 2>/dev/null || true
	@rm -f $(ZIMAGE) $(DTBS) $(LOCAL_KERNEL_DIR)/vmlinux $(LOCAL_KERNEL_DIR)/System.map
	@echo "Clean complete"

# ------- Build -------

build: $(KCONFIG) build-zimage build-dtb ## compile zImage + DTB locally
	@echo "Kernel dir: $(LOCAL_KERNEL_DIR)"

build-zimage:
	$(check-kernel-dir)
	$(KMAKE) -C $(LOCAL_KERNEL_DIR) zImage -j$(NPROC)

build-dtb dtb: ## compile all device trees (vita1000, vita2000, pstv)
	$(check-kernel-dir)
	@for model in $(VITA_MODELS); do \
		echo "  DTB     $$model.dtb"; \
		(cd $(LOCAL_KERNEL_DIR) && \
		$(CPP) -nostdinc -I include -I arch/arm/boot/dts -I $(DTS_PATH) -I include/dt-bindings \
			-undef -x assembler-with-cpp $(DTS_PATH)/$$model.dts | \
		scripts/dtc/dtc -I dts -O dtb -o $(DTS_PATH)/$$model.dtb -) || exit 1; \
	done

# ------- LSP / clangd -------

lsp: build ## generate compile_commands.json + .clangd for clangd
	$(check-kernel-dir)
	$(KMAKE) -C $(LOCAL_KERNEL_DIR) compile_commands.json
	@printf '%s\n' \
		'CompileFlags:' \
		'  Remove:' \
		'    - -mno-fdpic' \
		'    - -fno-allow-store-data-races' \
		'    - -fconserve-stack' \
		'    - -mno-thumb-interwork' \
		'' \
		'Diagnostics:' \
		'  ClangTidy:' \
		'    Remove: ["*"]' \
		> $(LOCAL_KERNEL_DIR)/.clangd
	@echo "LSP ready: $(LOCAL_KERNEL_DIR)/compile_commands.json + .clangd"

# ------- Buildroot (rootfs) -------

BUILDROOT_DIR     := ./buildroot
BUILDROOT_EXT     := ./buildroot-vita
BUILDROOT_OUT     := $(BUILDROOT_DIR)/output
ROOTFS_CPIO       := $(BUILDROOT_OUT)/images/rootfs.cpio.zst
ROOTFS_DEST       := $(LOCAL_KERNEL_DIR)/rootfs.cpio.zst

# Buildroot make wrapper — sets external tree and output dir
BRMAKE = $(MAKE) -C $(BUILDROOT_DIR) BR2_EXTERNAL=$(abspath $(BUILDROOT_EXT)) O=$(abspath $(BUILDROOT_OUT))

define check-buildroot
	@if [ ! -f "$(BUILDROOT_DIR)/Makefile" ]; then \
		echo "ERROR: buildroot/ not found. Run: git submodule update --init buildroot"; \
		exit 1; \
	fi
endef

rootfs: ## build rootfs (initramfs) via buildroot
	$(check-buildroot)
	$(check-kernel-dir)
	@if [ ! -f "$(BUILDROOT_OUT)/.config" ]; then \
		echo "No buildroot .config — running vita_defconfig first..."; \
		$(BRMAKE) vita_defconfig; \
	fi
	$(BRMAKE) -j$(NPROC)
	@cp "$(ROOTFS_CPIO)" "$(ROOTFS_DEST)"
	@echo "rootfs.cpio.zst installed to $(ROOTFS_DEST) ($$(du -h "$(ROOTFS_DEST)" | cut -f1))"

rootfs-config: ## apply vita_defconfig for buildroot
	$(check-buildroot)
	$(BRMAKE) vita_defconfig

rootfs-menuconfig: ## interactive buildroot config
	$(check-buildroot)
	$(BRMAKE) menuconfig

rootfs-savedefconfig: ## save buildroot .config → vita_defconfig
	$(check-buildroot)
	$(BRMAKE) savedefconfig BR2_DEFCONFIG=$(abspath $(BUILDROOT_EXT)/configs/vita_defconfig)
	@echo "vita_defconfig updated ($$(wc -l < $(BUILDROOT_EXT)/configs/vita_defconfig) lines)"

rootfs-clean: ## clean buildroot output
	@if [ -d "$(BUILDROOT_OUT)" ]; then \
		$(BRMAKE) clean; \
		echo "Buildroot output cleaned"; \
	else \
		echo "Nothing to clean"; \
	fi

# ------- Transfer -------

push: ## upload zImage + all DTBs to Vita via FTP
	curl -s --ftp-create-dirs -T $(ZIMAGE) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/zImage"
	@for model in $(VITA_MODELS); do \
		echo "  PUSH    $$model.dtb"; \
		curl -s --ftp-create-dirs -T $(DTS_DIR)/$$model.dtb "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/$$model.dtb" || exit 1; \
	done

LOADER_PLUGIN := kplugin.skprx
LOADER_PAYLOAD := payload.bin
LOADER_VPK := plugin_loader.vpk

push-setup: ## one-time setup: push loader files + VPK to a new device
	@echo "Pushing bootstrap files to $(VITA_IP)..."
	curl -s --ftp-create-dirs -T $(LOADER_PLUGIN) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/data/tai/kplugin.skprx"
	curl -s --ftp-create-dirs -T $(LOADER_PAYLOAD) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/baremetal/payload.bin"
	curl -s --ftp-create-dirs -T $(LOADER_VPK) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/plugin_loader.vpk"
	@echo ""
	@echo "Done. Loader + payload are in place."
	@echo "  1. Install ux0:/plugin_loader.vpk via VitaShell (one-time)"
	@echo "  2. Run 'make push' to upload the kernel + DTBs"
	@echo "  3. Launch Plugin Loader from LiveArea (or 'make boot') to boot Linux"

# ------- Boot (with device locking) -------

boot: ## launch Plugin Loader on Vita (boots Linux)
	@$(LOCK_CMD) sh -c ' \
		echo "destroy" | $(NC) -w 3 $(VITA_IP) $(CMD_PORT) > /dev/null 2>&1 || \
			{ echo "Vita not reachable on port $(CMD_PORT) — is it in VitaOS?"; exit 1; }; \
		start_line=$$(wc -l < logs/latest.log 2>/dev/null | tr -d " " || echo 0); \
		sleep 1; \
		echo "Launching Plugin Loader..."; \
		echo "launch PLGINLDR0" | $(NC) -w 3 $(VITA_IP) $(CMD_PORT); \
		./boot_watch.sh $$start_line \
	'; rc=$$?; \
	if [ $$rc -ne 0 ] && ! $(LOCK_CMD) true 2>/dev/null; then \
		$(lock-fail-msg); \
	fi; \
	exit $$rc

watch: ## watch an in-progress boot
	@./boot_watch.sh

serial: ## start serial console (UART)
	./serial_log.py

serial-bridge: ## bridge local serial to a remote VM (run on Mac)
	@if [ -z "$(BUILD_HOST)" ]; then \
		echo "Usage: make serial-bridge BUILD_HOST=<vm-hostname>"; \
		echo "  Bridges local serial console to a remote build VM."; \
		exit 1; \
	fi
	./serial-bridge.sh $(BUILD_HOST)

# ------- Full pipeline (with device locking) -------

deploy: build push ## full pipeline: build → push → boot
	@$(LOCK_CMD) sh -c ' \
		echo "destroy" | $(NC) -w 3 $(VITA_IP) $(CMD_PORT) > /dev/null 2>&1 || \
			{ echo "Vita not reachable on port $(CMD_PORT) — is it in VitaOS?"; exit 1; }; \
		start_line=$$(wc -l < logs/latest.log 2>/dev/null | tr -d " " || echo 0); \
		sleep 1; \
		echo "Launching Plugin Loader..."; \
		echo "launch PLGINLDR0" | $(NC) -w 3 $(VITA_IP) $(CMD_PORT); \
		./boot_watch.sh $$start_line \
	'; rc=$$?; \
	if [ $$rc -ne 0 ] && ! $(LOCK_CMD) true 2>/dev/null; then \
		$(lock-fail-msg); \
	fi; \
	exit $$rc

# ------- Bare cache mirror -------

setup-cache: ## create/update bare cache at ~/.cache/vita-linux/linux.git
	@if [ ! -d "$(CACHE_DIR)" ]; then \
		echo "Creating bare cache at $(CACHE_DIR)..."; \
		mkdir -p "$$(dirname "$(CACHE_DIR)")"; \
		git clone --bare https://github.com/incognitojam/linux_vita.git "$(CACHE_DIR)"; \
	fi
	@$(foreach pair,$(CACHE_REMOTES), \
		name=$$(echo "$(pair)" | cut -d= -f1); \
		url=$$(echo "$(pair)" | cut -d= -f2-); \
		if ! git -C "$(CACHE_DIR)" remote | grep -qx "$$name"; then \
			echo "  Adding remote $$name → $$url"; \
			git -C "$(CACHE_DIR)" remote add "$$name" "$$url"; \
		fi; \
	)
	@echo "Fetching all remotes..."
	@git -C "$(CACHE_DIR)" fetch --all
	@echo "Bare cache ready at $(CACHE_DIR)"

update-cache: ## fetch all remotes into the bare cache
	@if [ ! -d "$(CACHE_DIR)" ]; then \
		echo "ERROR: Cache not found at $(CACHE_DIR). Run 'make setup-cache' first."; \
		exit 1; \
	fi
	git -C "$(CACHE_DIR)" fetch --all

# ------- Outer worktree helper -------

# Usage: make worktree NAME=fix-boot-watch [BASE=HEAD] [INIT_SUBMODULES=0]
WORKTREE_BASE_DIR := ../vita-wt
INIT_SUBMODULES   ?= 0
BASE              ?= HEAD

worktree: ## create outer worktree at ../vita-wt/<NAME>
	@if [ -z "$(NAME)" ]; then \
		echo "ERROR: NAME is required. Usage: make worktree NAME=<name> [BASE=HEAD]"; \
		exit 1; \
	fi
	@DEST="$(WORKTREE_BASE_DIR)/$(NAME)"; \
	echo "Creating outer worktree at $$DEST..."; \
	if git show-ref --verify --quiet "refs/heads/$(NAME)" 2>/dev/null; then \
		echo "  Branch $(NAME) exists locally"; \
		git worktree add "$$DEST" "$(NAME)"; \
	elif git show-ref --verify --quiet "refs/remotes/origin/$(NAME)" 2>/dev/null; then \
		echo "  Branch $(NAME) exists on remote"; \
		git worktree add -b "$(NAME)" "$$DEST" "origin/$(NAME)"; \
	else \
		echo "  Creating new branch $(NAME) from $(BASE)"; \
		git worktree add -b "$(NAME)" "$$DEST" "$(BASE)"; \
	fi; \
	echo "Symlinking shared resources..."; \
	MAIN_DIR="$$(pwd)"; \
	ln -sfn "$$MAIN_DIR/logs" "$$DEST/logs"; \
	ln -sfn "$$MAIN_DIR/refs" "$$DEST/refs"; \
	if [ "$(INIT_SUBMODULES)" = "1" ]; then \
		echo "Initializing submodules (integration worktree)..."; \
		git -C "$$DEST" submodule update --init --reference-if-able "$(CACHE_DIR)"; \
		if [ "$(UNAME_S)" = "Darwin" ]; then \
			./fix_case_sensitivity.sh "$$DEST/linux_vita"; \
		fi; \
		if [ -f "linux_vita/rootfs.cpio.zst" ]; then \
			cp "linux_vita/rootfs.cpio.zst" "$$DEST/linux_vita/rootfs.cpio.zst"; \
		else \
			echo "  NOTE: rootfs.cpio.zst not found in linux_vita/ — run 'make rootfs' to build it"; \
		fi; \
		echo ""; \
		echo "Integration worktree ready at $$DEST"; \
		echo "  Run 'make config && make build' to build."; \
	else \
		echo ""; \
		echo "Worktree ready at $$DEST"; \
		echo "  To build against a kernel: make kernel-use NAME=<kernel-wt>"; \
		echo "  Or: make build LINUX_VITA_DIR=<path>"; \
	fi

# ------- Kernel worktree helper -------

# Usage: make kernel-worktree NAME=mmc-dma [BASE=HEAD] [NO_CONFIG=0] [NO_ROOTFS=0]
KERNEL_WT_BASE_DIR := ../vita-kernel-wt
NO_CONFIG          ?= 0
NO_ROOTFS          ?= 0

kernel-worktree: ## create kernel worktree at ../vita-kernel-wt/<NAME>
	@if [ -z "$(NAME)" ]; then \
		echo "ERROR: NAME is required. Usage: make kernel-worktree NAME=<name> [BASE=HEAD]"; \
		exit 1; \
	fi
	@if [ ! -d "./linux_vita/.git" ] && [ ! -f "./linux_vita/.git" ]; then \
		echo "ERROR: ./linux_vita is not a git repo. Cannot create kernel worktree."; \
		exit 1; \
	fi
	@DEST="$(KERNEL_WT_BASE_DIR)/$(NAME)"; \
	BRANCH="topic/$(NAME)"; \
	RESOLVE_BASE="$(BASE)"; \
	WT_PATH="../../vita-kernel-wt/$(NAME)"; \
	echo "Creating kernel worktree at $$DEST on branch $$BRANCH..."; \
	if git -C linux_vita show-ref --verify --quiet "refs/heads/$$BRANCH" 2>/dev/null; then \
		echo "  Branch $$BRANCH exists — checking out"; \
		git -C linux_vita worktree add "$$WT_PATH" "$$BRANCH"; \
	else \
		echo "  Creating new branch $$BRANCH from $$RESOLVE_BASE"; \
		git -C linux_vita worktree add -b "$$BRANCH" "$$WT_PATH" "$$RESOLVE_BASE"; \
	fi; \
	if [ "$(UNAME_S)" = "Darwin" ]; then \
		./fix_case_sensitivity.sh "$$DEST"; \
	fi; \
	if [ "$(NO_CONFIG)" != "1" ] && [ -f "linux_vita/.config" ]; then \
		echo "  Copying .config"; \
		cp "linux_vita/.config" "$$DEST/.config"; \
	fi; \
	if [ "$(NO_ROOTFS)" != "1" ] && [ -f "linux_vita/rootfs.cpio.zst" ]; then \
		echo "  Copying rootfs.cpio.zst"; \
		cp "linux_vita/rootfs.cpio.zst" "$$DEST/rootfs.cpio.zst"; \
	fi; \
	echo "$$DEST" > .linux-vita-dir; \
	echo ""; \
	echo "Kernel worktree ready at $$DEST on branch $$BRANCH"; \
	echo "  Current worktree now builds against it (via .linux-vita-dir)"; \
	echo "  Build: make build"

# ------- Kernel directory switching -------

kernel-use: ## switch kernel dir for current worktree
	@if [ "$(RESET)" = "1" ]; then \
		rm -f .linux-vita-dir; \
		echo "Kernel dir reset to default (./linux_vita)"; \
	elif [ -n "$(NAME)" ]; then \
		KDIR="$(KERNEL_WT_BASE_DIR)/$(NAME)"; \
		if [ ! -f "$$KDIR/arch/arm/configs/vita_defconfig" ]; then \
			echo "ERROR: $$KDIR does not contain a kernel tree."; \
			exit 1; \
		fi; \
		echo "$$KDIR" > .linux-vita-dir; \
		echo "Kernel dir set to $$KDIR. 'make build' will use it."; \
	elif [ -n "$(DIR)" ]; then \
		KDIR="$(DIR)"; \
		if [ ! -f "$$KDIR/arch/arm/configs/vita_defconfig" ]; then \
			echo "ERROR: $$KDIR does not contain a kernel tree."; \
			exit 1; \
		fi; \
		echo "$$KDIR" > .linux-vita-dir; \
		echo "Kernel dir set to $$KDIR. 'make build' will use it."; \
	else \
		echo "ERROR: Usage:"; \
		echo "  make kernel-use NAME=<worktree-name>   # uses ../vita-kernel-wt/<name>"; \
		echo "  make kernel-use DIR=/absolute/path      # arbitrary path"; \
		echo "  make kernel-use RESET=1                 # revert to ./linux_vita"; \
		exit 1; \
	fi

# ------- Kernel submodule bump -------

kernel-bump: ## pin linux_vita submodule to a commit
	@if [ ! -d "./linux_vita/.git" ] && [ ! -f "./linux_vita/.git" ]; then \
		echo "ERROR: kernel-bump must be run from a worktree with submodule checkout (main or integration)."; \
		exit 1; \
	fi
	@COMMIT="$(COMMIT)"; \
	if [ -z "$$COMMIT" ]; then \
		COMMIT=$$(git -C "$(LOCAL_KERNEL_DIR)" rev-parse HEAD); \
		echo "No COMMIT specified, using HEAD of $(LOCAL_KERNEL_DIR): $$COMMIT"; \
	fi; \
	echo "Fetching origin in linux_vita..."; \
	git -C linux_vita fetch origin; \
	REACHABLE=$$(git -C linux_vita branch -r --contains "$$COMMIT" 2>/dev/null); \
	if [ -z "$$REACHABLE" ]; then \
		echo "ERROR: Commit $$COMMIT is local-only — push it to a remote branch first,"; \
		echo "  or CI and other contributors won't be able to reach it."; \
		exit 1; \
	fi; \
	echo "Commit reachable from: $$REACHABLE"; \
	git -C linux_vita checkout "$$COMMIT"; \
	git add linux_vita; \
	echo "Submodule pinned to $$COMMIT. Review with 'git diff --cached' and commit when ready."

# ------- Git config for linux_vita -------

setup-git-config: ## enable rerere + rebase.updateRefs in linux_vita
	@if [ ! -d "./linux_vita/.git" ] && [ ! -f "./linux_vita/.git" ]; then \
		echo "ERROR: ./linux_vita is not a git repo."; \
		exit 1; \
	fi
	git -C linux_vita config rerere.enabled true
	git -C linux_vita config rebase.updateRefs true
	@echo "Git config updated in linux_vita:"
	@echo "  rerere.enabled = true"
	@echo "  rebase.updateRefs = true"
