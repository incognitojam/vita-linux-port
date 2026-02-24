#!/usr/bin/env bash
# Run a command on the Vita via serial and print its output.
# Blocks until the shell prompt returns (or timeout).
# Requires serial_log.py to be running (provides /tmp/tigard.pipe and logs/latest.log).
set -euo pipefail

LOGFILE="logs/latest.log"
PIPE="/tmp/tigard.pipe"
TIMEOUT="${2:-10}"
PROMPT_PATTERN='# $'  # root prompt (no trailing newline, so appears at end of file)

if [[ -z "${1:-}" ]]; then
  echo "Usage: vita_cmd.sh <command> [timeout_secs]" >&2
  exit 1
fi

if [[ ! -p "$PIPE" ]]; then
  echo "No pipe at $PIPE — is serial_log.py running?" >&2
  exit 1
fi

if [[ ! -f "$LOGFILE" ]]; then
  echo "No $LOGFILE found — is serial_log.py running?" >&2
  exit 1
fi

# Snapshot log position (bytes) before sending command
start_bytes=$(wc -c < "$LOGFILE" | tr -d ' ')

# Send command
printf '%s\n' "$1" > "$PIPE"

# Wait for output, print it, exit when prompt returns
start_time=$(date +%s)
printed=0

while true; do
  current_bytes=$(wc -c < "$LOGFILE" | tr -d ' ')

  if (( current_bytes > start_bytes )); then
    # Read new bytes
    new_data=$(tail -c +"$((start_bytes + 1))" "$LOGFILE")
    new_len=${#new_data}

    # Print only the portion we haven't printed yet
    if (( new_len > printed )); then
      echo -n "${new_data:$printed}"
      printed=$new_len
    fi

    # Check if prompt has returned (last bytes are "# ")
    if [[ "$new_data" =~ $PROMPT_PATTERN ]]; then
      echo  # newline after prompt
      exit 0
    fi
  fi

  if (( $(date +%s) - start_time >= TIMEOUT )); then
    echo -e "\n(timed out after ${TIMEOUT}s)" >&2
    exit 1
  fi

  sleep 0.1
done
