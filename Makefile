# Vita Linux Port — local orchestration Makefile
# Runs on macOS, drives remote build (periscope) and Vita deployment

VITA_IP   := 192.168.1.34
FTP_PORT  := 1337
CMD_PORT  := 1338
BUILD_HOST := periscope

CROSS_COMPILE_PATH := /opt/armv7-eabihf--glibc--bleeding-edge-2025.08-1/bin
REMOTE_KERNEL_DIR  := ~/linux_vita
REMOTE_MAKE        := export PATH=$(CROSS_COMPILE_PATH):$$PATH && cd $(REMOTE_KERNEL_DIR) && make ARCH=arm CROSS_COMPILE=arm-linux-

LOCAL_KERNEL_DIR := linux_vita
ZIMAGE           := $(LOCAL_KERNEL_DIR)/arch/arm/boot/zImage
DTB              := $(LOCAL_KERNEL_DIR)/arch/arm/boot/dts/vita1000.dtb

.PHONY: sync build pull push boot deploy dtb help watch

help:
	@echo "Targets:"
	@echo "  sync    — rsync kernel source to build VM"
	@echo "  build   — compile zImage on build VM"
	@echo "  dtb     — compile device tree on build VM"
	@echo "  pull    — fetch built zImage + DTB from build VM"
	@echo "  push    — upload zImage + DTB to Vita via FTP"
	@echo "  boot    — launch Plugin Loader on Vita (boots Linux)"
	@echo "  deploy  — full pipeline: sync → build → pull → push → boot"

sync:
	rsync -az --delete \
		--exclude='.git' \
		--exclude='*.o' \
		--exclude='*.cmd' \
		--exclude='.tmp_*' \
		$(LOCAL_KERNEL_DIR)/ $(BUILD_HOST):$(REMOTE_KERNEL_DIR)/

build:
	ssh $(BUILD_HOST) '$(REMOTE_MAKE) zImage -j6'

dtb:
	ssh $(BUILD_HOST) 'cd $(REMOTE_KERNEL_DIR) && \
		$(CROSS_COMPILE_PATH)/arm-linux-cpp \
			-nostdinc -I include -I arch/arm/boot/dts -I include/dt-bindings \
			-undef -x assembler-with-cpp arch/arm/boot/dts/vita1000.dts | \
		scripts/dtc/dtc -I dts -O dtb -o arch/arm/boot/dts/vita1000.dtb -'

pull:
	scp $(BUILD_HOST):$(REMOTE_KERNEL_DIR)/arch/arm/boot/zImage $(ZIMAGE)
	scp $(BUILD_HOST):$(REMOTE_KERNEL_DIR)/arch/arm/boot/dts/vita1000.dtb $(DTB)

push:
	curl -s -T $(ZIMAGE) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/zImage"
	curl -s -T $(DTB) "ftp://$(VITA_IP):$(FTP_PORT)/ux0:/linux/vita1000.dtb"

boot:
	@echo "destroy" | nc -w 3 $(VITA_IP) $(CMD_PORT) > /dev/null 2>&1 || \
		{ echo "Vita not reachable on port $(CMD_PORT) — is it in VitaOS?"; exit 1; }; \
	start_line=$$(wc -l < latest.log 2>/dev/null | tr -d ' ' || echo 0); \
	sleep 1; \
	echo "Launching Plugin Loader..."; \
	echo "launch PLGINLDR0" | nc -w 3 $(VITA_IP) $(CMD_PORT); \
	./boot_watch.sh $$start_line

watch:
	@./boot_watch.sh

deploy: sync build pull push boot
