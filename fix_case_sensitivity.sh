#!/usr/bin/env bash
# Run once after cloning linux_vita/ on macOS (case-insensitive filesystem).
# Hides 13 files that have case-only counterparts in the kernel tree,
# which macOS can't distinguish, producing spurious git diffs.
#
# Usage: fix_case_sensitivity.sh [kernel-dir]
#   kernel-dir defaults to ./linux_vita relative to the script's location.
set -euo pipefail

KERNEL_DIR="${1:-$(dirname "$0")/linux_vita}"
cd "$KERNEL_DIR"

for f in \
    include/uapi/linux/netfilter/xt_CONNMARK.h \
    include/uapi/linux/netfilter/xt_DSCP.h \
    include/uapi/linux/netfilter/xt_MARK.h \
    include/uapi/linux/netfilter/xt_RATEEST.h \
    include/uapi/linux/netfilter/xt_TCPMSS.h \
    include/uapi/linux/netfilter_ipv4/ipt_ECN.h \
    include/uapi/linux/netfilter_ipv4/ipt_TTL.h \
    include/uapi/linux/netfilter_ipv6/ip6t_HL.h \
    net/netfilter/xt_DSCP.c \
    net/netfilter/xt_HL.c \
    net/netfilter/xt_RATEEST.c \
    net/netfilter/xt_TCPMSS.c \
    tools/memory-model/litmus-tests/Z6.0+pooncelock+poonceLock+pombonce.litmus; do
    git update-index --assume-unchanged "$f" 2>/dev/null
done
echo "Marked 13 case-sensitivity files as assume-unchanged."
