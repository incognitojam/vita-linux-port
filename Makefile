# Vita Linux Port — local orchestration Makefile
# Builds locally (macOS with LLVM/Clang, Linux with Bootlin GCC), deploys to Vita

VITA_IP   := $(shell ssh -G vita 2>/dev/null | awk '/^hostname / {print $$2}')
ifeq ($(VITA_IP),)
  $(error Could not resolve VITA_IP — add "Host vita" to ~/.ssh/config)
endif
FTP_PORT  := 1337
CMD_PORT  := 1338

LOCAL_KERNEL_DIR := linux_vita
ZIMAGE           := $(LOCAL_KERNEL_DIR)/arch/arm/boot/zImage
DTB              := $(LOCAL_KERNEL_DIR)/arch/arm/boot/dts/vita1000.dtb

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
  # Linux: Bootlin cross-compiler (arm-linux-* must be on PATH)
  CROSS_COMPILE ?= arm-linux-
  KMAKE         := make ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE)
  CPP           := $(CROSS_COMPILE)cpp
  NPROC         := $(shell nproc)
  ifneq ($(CCACHE),)
    KMAKE += CC="ccache $(CROSS_COMPILE)gcc" HOSTCC="ccache gcc"
  endif
endif

.PHONY: config savedefconfig build build-zimage build-dtb dtb push boot deploy help watch serial lsp clean

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk -F ':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ------- Config -------

VITA_DEFCONFIG := $(LOCAL_KERNEL_DIR)/arch/arm/configs/vita_defconfig

KCONFIG := $(LOCAL_KERNEL_DIR)/.config

config: ## apply vita_defconfig → .config (overwrites)
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) vita_defconfig

$(KCONFIG):
	@echo ".config missing — generating from vita_defconfig"
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) vita_defconfig

savedefconfig: ## update vita_defconfig from current .config
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) savedefconfig
	@mv $(LOCAL_KERNEL_DIR)/defconfig $(VITA_DEFCONFIG)
	@echo "vita_defconfig updated ($(shell wc -l < $(VITA_DEFCONFIG)) lines)"

# ------- Clean -------

clean: ## remove kernel build artifacts (works around macOS case-sensitivity bug)
	$(KMAKE) -C $(LOCAL_KERNEL_DIR) clean 2>/dev/null || true
	@find $(LOCAL_KERNEL_DIR) \( -name '*.o' -o -name '*.o.cmd' -o -name '*.ko' \
		-o -name '.*.cmd' -o -name '*.a' -o -name '*.order' -o -name '*.symvers' \) \
		-delete 2>/dev/null || true
	@rm -f $(ZIMAGE) $(LOCAL_KERNEL_DIR)/vmlinux $(LOCAL_KERNEL_DIR)/System.map
	@echo "Clean complete"

# ------- Build -------

build: $(KCONFIG) build-zimage build-dtb ## compile zImage + DTB locally

build-zimage:
	$(KMAKE) -C $(LOCAL_KERNEL_DIR) zImage -j$(NPROC)

build-dtb dtb: ## compile device tree only
	cd $(LOCAL_KERNEL_DIR) && \
		$(CPP) -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
			-undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
		scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -

# ------- LSP / clangd -------

lsp: build ## generate compile_commands.json + .clangd for clangd
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

# ------- Transfer -------

push: ## upload zImage + DTB to Vita via FTP
	curl -s -T $(ZIMAGE) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/zImage"
	curl -s -T $(DTB) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/vita1000.dtb"

# ------- Boot -------

boot: ## launch Plugin Loader on Vita (boots Linux)
	@echo "destroy" | nc -w 3 $(VITA_IP) $(CMD_PORT) > /dev/null 2>&1 || \
		{ echo "Vita not reachable on port $(CMD_PORT) — is it in VitaOS?"; exit 1; }; \
	start_line=$$(wc -l < logs/latest.log 2>/dev/null | tr -d ' ' || echo 0); \
	sleep 1; \
	echo "Launching Plugin Loader..."; \
	echo "launch PLGINLDR0" | nc -w 3 $(VITA_IP) $(CMD_PORT); \
	./boot_watch.sh $$start_line

watch: ## watch an in-progress boot
	@./boot_watch.sh

serial: ## start serial console (Tigard)
	./serial_log.py

# ------- Full pipeline -------

deploy: build push boot ## full pipeline: build → push → boot
