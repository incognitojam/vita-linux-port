#!/bin/sh
# Post-build script for Vita rootfs
# Runs after packages are installed and overlays are applied, but before
# the rootfs image is created.
# $1 = path to target rootfs (e.g. output/target)

set -e

TARGET_DIR="$1"

# --- WiFi firmware (Marvell SD8787) ---
FIRMWARE_DIR="${TARGET_DIR}/lib/firmware/mrvl"
FIRMWARE_FILE="${FIRMWARE_DIR}/sd8787_uapsta.bin"

if [ ! -f "${FIRMWARE_FILE}" ]; then
    echo ">>> Downloading Marvell SD8787 WiFi firmware..."
    mkdir -p "${FIRMWARE_DIR}"
    FIRMWARE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mrvl/sd8787_uapsta.bin"
    FIRMWARE_TMP="${FIRMWARE_FILE}.tmp"
    DOWNLOAD_OK=0
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${FIRMWARE_TMP}" "${FIRMWARE_URL}" && DOWNLOAD_OK=1
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "${FIRMWARE_TMP}" "${FIRMWARE_URL}" && DOWNLOAD_OK=1
    else
        echo "WARNING: Neither wget nor curl available — cannot download WiFi firmware"
        echo "  Download manually from: ${FIRMWARE_URL}"
        echo "  Place at: ${FIRMWARE_FILE}"
    fi
    if [ "${DOWNLOAD_OK}" = "1" ] && [ -s "${FIRMWARE_TMP}" ]; then
        mv "${FIRMWARE_TMP}" "${FIRMWARE_FILE}"
        echo ">>> WiFi firmware installed ($(wc -c < "${FIRMWARE_FILE}") bytes)"
    else
        rm -f "${FIRMWARE_TMP}"
        echo "WARNING: WiFi firmware download failed — WiFi will not work without it"
        echo "  Download manually from: ${FIRMWARE_URL}"
        echo "  Place at: ${FIRMWARE_FILE}"
    fi
fi

# --- Vita eMMC mountpoint directories ---
for part in os0 vs0 sa0 tm0 vd0 ud0 pd0 ur0 emmc; do
    mkdir -p "${TARGET_DIR}/mnt/${part}"
done
