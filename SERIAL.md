# serial_log.py

Bidirectional serial console with logging. Auto-detects common USB-UART adapters (e.g. [Tigard](https://github.com/tigard-tools/tigard), FTDI). Runs via `uv` with no manual dependency install.

## Usage

```bash
./serial_log.py              # auto-detect adapter, pick channel interactively
./serial_log.py -c 0         # skip prompt, use UART (channel 0)
./serial_log.py -b 9600      # custom baud rate (default: 115200)
./serial_log.py -o boot.log  # custom log file (default: logs/serial_TIMESTAMP.log)
./serial_log.py -p /dev/...  # skip auto-detection, use specific port
```

Ctrl+] to quit. Ctrl+C passes through to the target.

## External input

By default, a named pipe is created at `/tmp/serial.pipe`. Other processes can send commands to the serial device:

```bash
printf 'uname -a\n' > /tmp/serial.pipe
```

Disable with `--no-pipe`, or change the path with `--pipe /tmp/other.pipe`.

## Reading the log

`logs/latest.log` is a symlink that always points to the current session's log file (all logs are written to the `logs/` directory):

```bash
tail -f logs/latest.log      # follow output from another terminal
cat logs/latest.log          # read the full log
```

## Notes

- Log file is written continuously
- On macOS, only `cu.*` devices are used (`tty.*` block on open waiting for DCD)
- Multi-channel adapters: channel 0 = UART, channel 1 = JTAG/SWD
