#!/bin/sh
# Post-build script for Vita rootfs
# Runs after packages are installed and overlays are applied, but before
# the rootfs image is created.
# $1 = path to target rootfs (e.g. output/target)

set -e

TARGET_DIR="$1"

# --- Vita eMMC mountpoint directories ---
for part in os0 vs0 sa0 tm0 vd0 ud0 pd0 ur0 emmc; do
    mkdir -p "${TARGET_DIR}/mnt/${part}"
done
