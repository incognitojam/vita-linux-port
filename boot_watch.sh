#!/usr/bin/env bash
# Watch latest.log for boot progress after launching Linux on Vita.
# Streams all serial output, injects stage markers, exits on login prompt or timeout.
# Expects serial_log.py to be running in another terminal.
set -euo pipefail

LOGFILE="latest.log"
GREEN='\033[32;1m'
RED='\033[31;1m'
RESET='\033[0m'

if [[ ! -f "$LOGFILE" ]]; then
  echo "No $LOGFILE found — is serial_log.py running?" >&2
  exit 1
fi

# Accept starting line as arg (from Makefile, captured before launch)
start_line="${1:-$(wc -l < "$LOGFILE" | tr -d ' ')}"
start_time=$(date +%s)
stage_time=$start_time

elapsed() {
  echo $(( $(date +%s) - start_time ))
}

stage_elapsed() {
  echo $(( $(date +%s) - stage_time ))
}

# Per-stage timeouts (seconds since previous stage)
#   Observed deltas: 8s, 1s, 13s, 1s, 5s, 2s — totals ~30s
#   Timeouts set to ~2x observed to allow variance
#   0: waiting for baremetal loader     — 15s (vita app launch + standby)
#   1: waiting for linux loader         — 10s (device reset + loader start)
#   2: waiting for zImage load          —  5s
#   3: waiting for jump to linux        — 25s (loading 15MB zImage from SD)
#   4: waiting for kernel boot msg      —  5s (decompression)
#   5: waiting for userspace init       — 10s (kernel init + drivers)
#   6: waiting for login prompt         — 10s (userspace services)
stage_timeouts=(15 10 5 25 5 10 10)

seen=0

echo -e "\033[1mWaiting for boot (per-stage timeouts)...\033[0m"

while true; do
  current_lines=$(wc -l < "$LOGFILE" | tr -d ' ')

  if (( current_lines > start_line )); then
    while IFS= read -r line; do
      # Check stages in order
      advance() {
        local target=$2
        # Skip-ahead: if we see a later stage, mark all earlier ones as passed
        while (( seen < target )); do
          seen=$((seen + 1))
        done
        printf "${GREEN}--- [%ss] %s ---${RESET}\n" "$(elapsed)" "$1"
        stage_time=$(date +%s)
      }

      # Check all stages at or above current — allows skipping missed ones
      # Stages 0-1 can match freely (they indicate boot has started)
      [[ "$line" == *"Baremetal loader by xerpi"* ]] && (( seen < 1 )) && advance "Baremetal loader" 1
      [[ "$line" == *"Vita baremetal Linux loader started"* ]] && (( seen < 2 )) && advance "Linux loader started" 2
      [[ "$line" == *"Loading '/linux/zImage'"* ]] && (( seen < 3 )) && advance "Loading zImage" 3
      [[ "$line" == *"Jumping to Linux"* ]] && (( seen < 4 )) && advance "Jumping to Linux" 4
      [[ "$line" == *"Booting Linux on physical CPU"* ]] && (( seen < 5 )) && advance "Kernel booting" 5
      # Only match late stages after boot has started (seen >= 1) to avoid
      # matching stale output from a previous boot in the same log
      [[ "$line" == *"Run /init as init process"* ]] && (( seen >= 1 && seen < 6 )) && advance "Userspace init" 6
      [[ "$line" == *"Welcome to Buildroot"* ]] && (( seen >= 1 && seen < 7 )) && advance "Login prompt reached" 7

      # Check for kernel panic at any stage
      if [[ "$line" == *"Kernel panic"* ]]; then
        echo "$line"
        printf "${RED}--- KERNEL PANIC ---${RESET}\n"
        exit 1
      fi

      echo "$line"

      # Exit successfully on login prompt
      if (( seen >= 7 )); then
        echo -e "${GREEN}Boot complete in $(elapsed)s${RESET}"
        exit 0
      fi
    done < <(tail -n +"$((start_line + 1))" "$LOGFILE" | head -n "$((current_lines - start_line))")

    start_line=$current_lines
  fi

  if (( seen < ${#stage_timeouts[@]} )) && (( $(stage_elapsed) >= stage_timeouts[seen] )); then
    labels=("Baremetal loader" "Linux loader" "Loading zImage" "Jumping to Linux" "Kernel booting" "Userspace init" "Login prompt")
    echo -e "${RED}Timed out waiting for: ${labels[$seen]} (${stage_timeouts[$seen]}s)${RESET}"
    exit 1
  fi

  sleep 0.2
done
