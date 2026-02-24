# Vita Linux Port — local orchestration Makefile
# Builds locally (macOS with LLVM/Clang, Linux with Bootlin GCC), deploys to Vita

VITA_IP   := 192.168.1.34
FTP_PORT  := 1337
CMD_PORT  := 1338

LOCAL_KERNEL_DIR := linux_vita
ZIMAGE           := $(LOCAL_KERNEL_DIR)/arch/arm/boot/zImage
DTB              := $(LOCAL_KERNEL_DIR)/arch/arm/boot/dts/vita1000.dtb

# --- Platform detection ---

UNAME_S := $(shell uname -s)

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
else
  # Linux: Bootlin cross-compiler (arm-linux-* must be on PATH)
  CROSS_COMPILE ?= arm-linux-
  KMAKE         := make ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE)
  CPP           := $(CROSS_COMPILE)cpp
  NPROC         := $(shell nproc)
endif

.PHONY: config build build-zimage build-dtb dtb push boot deploy help watch

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk -F ':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ------- Config -------

config: ## copy kernel.config → .config and run olddefconfig
	@cp kernel.config $(LOCAL_KERNEL_DIR)/.config
	@$(KMAKE) -C $(LOCAL_KERNEL_DIR) olddefconfig

# ------- Build -------

build: build-zimage build-dtb ## compile zImage + DTB locally

build-zimage:
	$(KMAKE) -C $(LOCAL_KERNEL_DIR) zImage -j$(NPROC)

build-dtb dtb: ## compile device tree only
	cd $(LOCAL_KERNEL_DIR) && \
		$(CPP) -nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
			-undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
		scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -

# ------- Transfer -------

push: ## upload zImage + DTB to Vita via FTP
	curl -s -T $(ZIMAGE) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/zImage"
	curl -s -T $(DTB) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/vita1000.dtb"

# ------- Boot -------

boot: ## launch Plugin Loader on Vita (boots Linux)
	@echo "destroy" | nc -w 3 $(VITA_IP) $(CMD_PORT) > /dev/null 2>&1 || \
		{ echo "Vita not reachable on port $(CMD_PORT) — is it in VitaOS?"; exit 1; }; \
	start_line=$$(wc -l < latest.log 2>/dev/null | tr -d ' ' || echo 0); \
	sleep 1; \
	echo "Launching Plugin Loader..."; \
	echo "launch PLGINLDR0" | nc -w 3 $(VITA_IP) $(CMD_PORT); \
	./boot_watch.sh $$start_line

watch: ## watch an in-progress boot
	@./boot_watch.sh

# ------- Full pipeline -------

deploy: build push boot ## full pipeline: build → push → boot
