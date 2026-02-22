#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyserial"]
# ///
"""Tigard serial console — bidirectional logging with external input support."""

import os
import sys
import time
import select
import signal
import termios
import tty
import argparse
import atexit
from datetime import datetime
from pathlib import Path

import serial
import serial.tools.list_ports

DEFAULT_PIPE = "/tmp/tigard.pipe"


def find_tigard_ports():
    """Find Tigard serial ports, return sorted list (channel 0 first).

    Matches on product name, serial number prefix, or FTDI VID/PID fallback.
    On macOS, deduplicates aliased ports (prefers ones with serial in the path).
    """
    specific = []
    ftdi_fallback = []
    for port in serial.tools.list_ports.comports():
        # Skip tty.* on macOS — they block on open waiting for DCD
        if sys.platform == "darwin" and "/dev/tty." in port.device:
            continue
        product = (port.product or "").lower()
        serial_number = port.serial_number or ""
        hwid = (port.hwid or "").lower()
        if "tigard" in product or serial_number.startswith("TG"):
            specific.append(port)
        elif "0403:6010" in hwid:
            ftdi_fallback.append(port)

    ports = specific or ftdi_fallback

    # macOS creates duplicate ports for FT2232H — e.g. both cu.usbserial-4
    # and cu.usbserial-TG110fda0 for the same channel. Prefer the ones with
    # the serial number in the device path, they're more stable names.
    named = [p for p in ports if (p.serial_number or "") in p.device and p.serial_number]
    if named:
        ports = named

    ports.sort(key=lambda p: p.device)
    return ports


def pick_channel(ports):
    """Prompt user to pick UART (ch0) or JTAG/SWD (ch1)."""
    print("Tigard detected. Select interface:\n")
    labels = ["UART (channel 0)", "JTAG/SWD (channel 1)"]
    for i, port in enumerate(ports):
        label = labels[i] if i < len(labels) else f"Channel {i}"
        print(f"  [{i + 1}] {label}  —  {port.device}")
    print()
    while True:
        try:
            choice = input(f"Choice [1]: ").strip() or "1"
            idx = int(choice) - 1
            if 0 <= idx < len(ports):
                return ports[idx].device
        except (ValueError, EOFError):
            pass
        print("Invalid choice.")


def setup_pipe(pipe_path):
    """Create a named pipe for external input."""
    pipe = Path(pipe_path)
    if pipe.exists():
        if pipe.is_fifo():
            return pipe_path
        pipe.unlink()
    os.mkfifo(pipe_path)
    return pipe_path


def main():
    parser = argparse.ArgumentParser(description="Tigard serial console with logging")
    parser.add_argument("-p", "--port", help="Serial port (auto-detects Tigard)")
    parser.add_argument("-c", "--channel", type=int, choices=[0, 1],
                        help="Tigard channel: 0=UART (default), 1=JTAG/SWD")
    parser.add_argument("-b", "--baud", type=int, default=115200)
    parser.add_argument("-o", "--output", default=None, help="Log file (default: serial_TIMESTAMP.log)")
    parser.add_argument("--timestamps", action="store_true", help="Prefix lines with timestamps")
    parser.add_argument("--pipe", default=DEFAULT_PIPE,
                        help=f"Named pipe for external input (default: {DEFAULT_PIPE})")
    parser.add_argument("--no-pipe", action="store_true", help="Disable the named pipe")
    args = parser.parse_args()

    # --- Port selection ---
    port = args.port
    if not port:
        ports = find_tigard_ports()
        if not ports:
            print("No Tigard found. Is it plugged in?", file=sys.stderr)
            sys.exit(1)

        if args.channel is not None and args.channel < len(ports):
            port = ports[args.channel].device
        elif len(ports) == 1:
            port = ports[0].device
        else:
            port = pick_channel(ports)

    # --- Setup ---
    outfile = args.output or f"serial_{datetime.now():%Y%m%d_%H%M%S}.log"
    pipe_path = None if args.no_pipe else setup_pipe(args.pipe)

    # Symlink latest.log -> current log file
    latest = "latest.log"
    try:
        os.remove(latest)
    except FileNotFoundError:
        pass
    os.symlink(outfile, latest)

    print(f"Port:   {port}")
    print(f"Baud:   {args.baud}")
    print(f"Log:    {outfile}")
    if pipe_path:
        print(f"Pipe:   {pipe_path}")
        print(f"        (other processes can: printf 'cmd\\n' > {pipe_path})")
    print("Ctrl+] to quit.\n")

    ser = serial.Serial(port, args.baud, timeout=0)

    # Put terminal in raw mode so keystrokes go straight through
    old_termios = None
    stdin_fd = sys.stdin.fileno()
    if sys.stdin.isatty():
        old_termios = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)

    # Open pipe fd in non-blocking mode (open read+write so it doesn't block)
    pipe_fd = None
    if pipe_path:
        pipe_fd = os.open(pipe_path, os.O_RDONLY | os.O_NONBLOCK)

    def cleanup(*_):
        if old_termios:
            termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_termios)
        ser.close()
        if pipe_fd is not None:
            os.close(pipe_fd)
        if pipe_path:
            try:
                os.unlink(pipe_path)
            except OSError:
                pass
        try:
            os.unlink(latest)
        except OSError:
            pass
        # If the log file was deleted while we were running, recover from the fd
        log.flush()
        if not os.path.exists(outfile):
            size = log.seek(0, 2)
            if 0 < size < 10 * 1024 * 1024:  # recover up to 10MB
                log.seek(0)
                with open(outfile, "wb") as f:
                    f.write(log.read())
                print(f"\r\nLog file was deleted — recovered {size} bytes to {outfile}")
            elif size >= 10 * 1024 * 1024:
                print(f"\r\nLog file was deleted — too large to recover ({size} bytes)")
            else:
                print("\r\nNo data logged.")
        else:
            print(f"\r\nLog written to {outfile}")
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)
    atexit.register(lambda: old_termios and termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_termios))

    log = open(outfile, "a+b")
    line_buf = bytearray()  # for timestamp mode

    def log_data(data):
        """Write received data to log file (and terminal)."""
        if args.timestamps:
            line_buf.extend(data)
            while b"\n" in line_buf:
                line, _, rest = line_buf.partition(b"\n")
                ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
                log.write(f"[{ts}] ".encode() + line + b"\n")
                line_buf[:] = rest
        else:
            log.write(data)
        log.flush()
        # Echo to terminal
        os.write(sys.stdout.fileno(), data)

    def send_to_serial(data, paced=False):
        """Send data to serial port. If paced, add inter-byte delay."""
        if paced:
            for byte in data:
                ser.write(bytes([byte]))
                ser.flush()
                time.sleep(0.005)  # 5ms per byte
        else:
            ser.write(data)

    # Build the poll list
    read_fds = [ser.fileno(), stdin_fd]
    if pipe_fd is not None:
        read_fds.append(pipe_fd)

    try:
        while True:
            readable, _, _ = select.select(read_fds, [], [], 0.1)

            for fd in readable:
                if fd == ser.fileno():
                    data = ser.read(ser.in_waiting or 1)
                    if data:
                        log_data(data)

                elif fd == stdin_fd:
                    data = os.read(stdin_fd, 1024)
                    if not data:
                        continue
                    # Ctrl+] (0x1d) to quit, like screen/telnet
                    if b"\x1d" in data:
                        cleanup()
                    send_to_serial(data)

                elif fd == pipe_fd:
                    data = os.read(pipe_fd, 4096)
                    if data:
                        send_to_serial(data, paced=True)
    except Exception:
        cleanup()


if __name__ == "__main__":
    main()
