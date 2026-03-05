#!/usr/bin/env bash
# serial-bridge.sh — bridge serial console from this Mac to a remote build VM.
#
# Runs on the Mac where serial_log.py + Tigard are local. Creates a transparent
# bridge so that the VM's boot_watch.sh, vita_cmd.sh, and Makefile targets
# work as if the serial adapter were attached locally.
#
# What it does:
#   1. Streams logs/latest.log to the VM in real-time (→ VM:logs/latest.log)
#   2. Opens an SSH reverse tunnel so the VM can send pipe commands back
#   3. Runs a small relay on the VM: local FIFO → TCP → Mac → /tmp/serial.pipe
#
# Prerequisites:
#   - serial_log.py running locally (provides /tmp/serial.pipe + logs/latest.log)
#   - SSH access to the VM (key-based recommended)
#   - The repo checked out on the VM at the same relative path, or REMOTE_DIR set
#
# Usage:
#   ./serial-bridge.sh <vm-host> [--remote-dir /path/on/vm] [--relay-port 9101]
#
# Examples:
#   ./serial-bridge.sh submarine
#   ./serial-bridge.sh submarine --remote-dir /home/user/vita-linux-port
#   REMOTE_DIR=/home/user/vita-linux-port ./serial-bridge.sh submarine

set -euo pipefail

# --- Defaults ---
RELAY_PORT="${RELAY_PORT:-9101}"
REMOTE_DIR="${REMOTE_DIR:-}"
LOCAL_PIPE="/tmp/serial.pipe"
LOCAL_LOG="logs/latest.log"
REMOTE_PID_FILE="/tmp/serial-bridge-relay.pid"

# --- Colors ---
BOLD='\033[1m'
GREEN='\033[32;1m'
RED='\033[31;1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Parse args ---
VM_HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-dir)  REMOTE_DIR="$2"; shift 2 ;;
    --relay-port)  RELAY_PORT="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 <vm-host> [--remote-dir /path/on/vm] [--relay-port PORT]"
      echo ""
      echo "Bridge local serial console (Tigard + serial_log.py) to a remote build VM."
      echo "Requires serial_log.py to be running locally."
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$VM_HOST" ]]; then
        VM_HOST="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$VM_HOST" ]]; then
  echo "Usage: $0 <vm-host> [--remote-dir /path/on/vm] [--relay-port PORT]" >&2
  exit 1
fi

# --- Preflight ---
if [[ ! -p "$LOCAL_PIPE" ]]; then
  echo -e "${RED}No pipe at $LOCAL_PIPE — is serial_log.py running?${RESET}" >&2
  exit 1
fi

if [[ ! -f "$LOCAL_LOG" ]]; then
  echo -e "${RED}No $LOCAL_LOG — is serial_log.py running?${RESET}" >&2
  exit 1
fi

# Detect remote project dir if not specified
if [[ -z "$REMOTE_DIR" ]]; then
  echo -e "${DIM}Detecting remote project directory...${RESET}"
  REMOTE_DIR=$(ssh -o ConnectTimeout=5 "$VM_HOST" \
    'for d in ~/vita-linux-port /home/*/vita-linux-port; do
       [ -f "$d/boot_watch.sh" ] && realpath "$d" && exit 0
     done
     echo ""' 2>/dev/null) || true
  if [[ -z "$REMOTE_DIR" ]]; then
    echo -e "${RED}Could not detect vita-linux-port on $VM_HOST.${RESET}" >&2
    echo "Specify with: --remote-dir /path/to/vita-linux-port" >&2
    exit 1
  fi
  echo -e "${DIM}Found: $REMOTE_DIR${RESET}"
fi

# --- Cleanup on exit ---
PIDS=()
cleanup() {
  echo ""
  echo -e "${DIM}Shutting down bridge...${RESET}"
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # Clean up remote relay process and FIFO
  ssh -o ConnectTimeout=5 "$VM_HOST" "
    if [ -f $REMOTE_PID_FILE ]; then
      kill \$(cat $REMOTE_PID_FILE) 2>/dev/null || true
      rm -f $REMOTE_PID_FILE
    fi
    rm -f /tmp/serial.pipe 2>/dev/null
  " 2>/dev/null || true
  echo -e "${DIM}Bridge stopped.${RESET}"
}
trap cleanup EXIT INT TERM

# --- Component 1: Pipe relay (VM → Mac) ---
#
# SSH reverse tunnel: VM:$RELAY_PORT → Mac:localhost:$RELAY_PORT
# Mac-side: socat listens on loopback:$RELAY_PORT and writes to /tmp/serial.pipe
# VM-side:  socat reads the FIFO and forwards to the tunnel

echo -e "${BOLD}Starting serial bridge to ${VM_HOST}...${RESET}"
echo -e "  Relay port: ${RELAY_PORT}"
echo -e "  Remote dir: ${REMOTE_DIR}"
echo ""

# Start local listener: TCP → pipe writer (binds to loopback only)
# Each incoming connection delivers one command batch to the FIFO.
# The subshell opens the pipe once (>> holds the fd), so individual
# nc/socat iterations don't need to reopen it (avoids FIFO race conditions).
(exec >> "$LOCAL_PIPE" 2>/dev/null; while true; do
  if command -v socat &>/dev/null; then
    socat -u "TCP-LISTEN:${RELAY_PORT},bind=127.0.0.1,reuseaddr" STDOUT
  else
    nc -l "$RELAY_PORT"
  fi || true
done) &
PIDS+=($!)

echo -e "${GREEN}[pipe]${RESET} Relay listening on 127.0.0.1:${RELAY_PORT} → ${LOCAL_PIPE}"

# Start SSH tunnel + remote FIFO relay
# The SSH session:
#   - Opens a reverse tunnel: VM:RELAY_PORT → Mac:localhost:RELAY_PORT
#   - Sets up a FIFO at /tmp/serial.pipe on the VM
#   - Runs socat (preferred) or a netcat relay loop to forward FIFO → tunnel
#
# The remote relay writes its PID to a file for clean shutdown.
ssh -o ConnectTimeout=10 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -R "127.0.0.1:${RELAY_PORT}:127.0.0.1:${RELAY_PORT}" \
    "$VM_HOST" \
    bash -s -- "$RELAY_PORT" "$REMOTE_PID_FILE" <<'REMOTE_SCRIPT'
RELAY_PORT="$1"
PID_FILE="$2"

# Create FIFO if needed
[ -p /tmp/serial.pipe ] || { rm -f /tmp/serial.pipe; mkfifo /tmp/serial.pipe; }

echo "[pipe] FIFO relay active on VM — /tmp/serial.pipe → localhost:${RELAY_PORT}"

# Write our PID for cleanup
echo $$ > "$PID_FILE"

# Relay loop: read FIFO → buffer to temp file → send via TCP tunnel.
# Buffering to a temp file prevents data loss if the network send fails
# (the FIFO is already drained, so we can't re-read it).
# Detect nc close flag: GNU/traditional netcat has -q (quit after EOF delay),
# BSD/nmap netcat uses -w (idle timeout). Probe via -h (portable).
if nc -h 2>&1 | grep -q -- '-q'; then
  NC_CMD="nc -q0"
else
  NC_CMD="nc -w1"
fi

while true; do
  TMP=$(mktemp)
  # cat blocks until a writer opens+closes the FIFO
  cat /tmp/serial.pipe > "$TMP"
  if [ -s "$TMP" ]; then
    $NC_CMD 127.0.0.1 "$RELAY_PORT" < "$TMP" 2>/dev/null || \
      { sleep 0.1; $NC_CMD 127.0.0.1 "$RELAY_PORT" < "$TMP" 2>/dev/null || true; }
  fi
  rm -f "$TMP"
done
REMOTE_SCRIPT
PIPE_SSH_PID=$!
PIDS+=($PIPE_SSH_PID)

# Give the tunnel a moment to establish
sleep 1

# --- Component 2: Log streaming (Mac → VM) ---
#
# Stream the local serial log to the VM in real-time via polling rsync.
# -L follows the logs/latest.log symlink to the actual log file.
# Polls every 0.5s — rsync only transfers changed bytes, so each call is fast.
# This avoids SSH pipe buffering issues entirely.

REMOTE_LOG="${REMOTE_DIR}/logs/latest.log"

# Ensure remote dir exists
ssh -o ConnectTimeout=10 "$VM_HOST" "mkdir -p '${REMOTE_DIR}/logs'"

# --checksum: detect changes by content, not just size+mtime (handles
#   serial_log.py restarts where the new file may be smaller)
# --inplace: overwrite the file directly (no temp file + rename, which
#   could confuse scripts reading the file mid-transfer)
# -L: follow symlinks (logs/latest.log is a symlink)
(while true; do
  rsync -Lq --checksum --inplace "$LOCAL_LOG" "${VM_HOST}:${REMOTE_LOG}" 2>/dev/null || true
  sleep 0.5
done) &
LOG_SYNC_PID=$!
PIDS+=($LOG_SYNC_PID)

echo -e "${GREEN}[log]${RESET}  Streaming ${LOCAL_LOG} → ${VM_HOST}:${REMOTE_DIR}/logs/latest.log"

echo ""
echo -e "${GREEN}Bridge active.${RESET} The VM can now use:"
echo -e "  ${DIM}make boot${RESET}        — boot monitoring via serial"
echo -e "  ${DIM}make deploy${RESET}      — full build+push+boot pipeline"
echo -e "  ${DIM}./vita_cmd.sh${RESET}    — run commands on Vita"
echo -e "  ${DIM}./boot_watch.sh${RESET}  — watch boot progress"
echo ""
echo -e "Press Ctrl+C to stop the bridge."

# --- Wait for any component to exit ---
# If either SSH session dies, the bridge is broken — clean up and exit.
while true; do
  for pid in "$PIPE_SSH_PID" "$LOG_SYNC_PID"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo -e "\n${RED}Bridge component (PID $pid) exited unexpectedly.${RESET}"
      exit 1
    fi
  done
  sleep 2
done
