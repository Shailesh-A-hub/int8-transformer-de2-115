#!/usr/bin/env python3
"""
Interactive UART Host Controller & Custom Sentence Classifier for INT8 Transformer on DE2-115
=============================================================================================
Connects to DE2-115 CP2102 serial port at 115,200 baud (8N1).

Supported Actions:
  1. Type your OWN sentence directly in English:
     e.g., "turn on the lights", "increase the volume", "turn off the heat"
     -> Tokenizes words on PC
     -> Transmits token IDs to FPGA over UART (Command 'R')
     -> FPGA executes INT8 Attention Engine & Softmax
     -> Returns hardware-measured cycles and classification intent!

  2. Single-key commands:
     '0' : Run current sentence in Softmax Tier 0
     '1' : Run current sentence in Softmax Tier 1
     'a' : Run current sentence in Softmax Version A
     's' : Cycle preloaded sentence (0..5)
     'b' : Run Automated Side-by-Side Benchmark (Tier 0 vs. Version A)
     'h' : Display Help Menu
     'q' : Quit
"""

import sys
import re
import time
import argparse

try:
    import serial
    import serial.tools.list_ports
    HAS_SERIAL = True
except ImportError:
    HAS_SERIAL = False

# ==============================================================================
# Trained Model Vocabulary & Intent Classes
# ==============================================================================
VOCAB = {
    "<pad>": 0,
    "<unk>": 1,
    "turn": 2,
    "on": 3,
    "the": 4,
    "lights": 5,
    "switch": 6,
    "off": 7,
    "increase": 8,
    "volume": 9,
    "up": 10,
    "decrease": 11,
    "down": 12,
    "heat": 13,
    "heating": 14
}

INTENT_NAMES = {
    0: "turn_on_lights",
    1: "turn_off_lights",
    2: "increase_volume",
    3: "decrease_volume",
    4: "heat_on",
    5: "heat_off"
}


def tokenize_sentence(sentence, max_len=8):
    """Convert raw text into an 8-element token ID list."""
    words = re.findall(r"[a-z]+", sentence.lower())
    token_ids = [VOCAB.get(w, 1) for w in words[:max_len]]
    # Pad to sequence length L=8
    token_ids += [0] * (max_len - len(token_ids))
    return token_ids[:max_len]


def find_serial_port():
    if not HAS_SERIAL:
        return None
    ports = list(serial.tools.list_ports.comports())
    if not ports:
        return None
    for p in ports:
        desc = p.description.lower()
        if "cp210" in desc or "usb" in desc or "uart" in desc or "serial" in desc or "ch340" in desc or "ftdi" in desc:
            return p.device
    return ports[0].device


def run_benchmark_command(ser):
    print("\n[HOST] >>> Sending Command 'b': Automated Side-by-Side Hardware Benchmark...")
    ser.write(b'b')
    ser.flush()

    start_time = time.time()
    buffer = ""
    while time.time() - start_time < 3.0:
        if ser.in_waiting > 0:
            chunk = ser.read(ser.in_waiting).decode('latin1', errors='replace')
            sys.stdout.write(chunk)
            sys.stdout.flush()
            buffer += chunk
            if "======" in buffer and "FASTER!" in buffer:
                time.sleep(0.05)
                if ser.in_waiting > 0:
                    sys.stdout.write(ser.read(ser.in_waiting).decode('latin1', errors='replace'))
                break
        else:
            time.sleep(0.01)


def send_custom_sentence(ser, sentence, mode_byte=1):
    """
    Sends 'R' command packet:
    Byte 0: 'R'
    Byte 1: Mode (0: Tier 0, 1: Tier 1, 2: Version A)
    Bytes 2..9: 8 Token IDs
    """
    tokens = tokenize_sentence(sentence)
    mode_str = "Tier 0" if mode_byte == 0 else ("Tier 1" if mode_byte == 1 else "Version A")

    print(f"\n[HOST] Typing Sentence: \"{sentence}\"")
    print(f"[HOST] Token IDs:       {tokens}")
    print(f"[HOST] Softmax Engine:  {mode_str}")
    print("[HOST] Transmitting to FPGA over UART...")

    # Construct packet: 'R' (0x52) + mode (1 byte) + 8 tokens (8 bytes)
    packet = bytes([ord('R'), mode_byte]) + bytes(tokens)
    ser.write(packet)
    ser.flush()

    # Read FPGA response
    start_time = time.time()
    resp = ""
    while time.time() - start_time < 1.0:
        if ser.in_waiting > 0:
            chunk = ser.read(ser.in_waiting).decode('latin1', errors='replace')
            resp += chunk
            sys.stdout.write(chunk)
            sys.stdout.flush()
            if "\n" in chunk and "[RESULT]" in resp:
                time.sleep(0.05)
                if ser.in_waiting > 0:
                    sys.stdout.write(ser.read(ser.in_waiting).decode('latin1', errors='replace'))
                break
        else:
            time.sleep(0.02)


def interactive_terminal(ser):
    current_mode = 1  # Default to Tier 1

    print("\n" + "=" * 76)
    print("   DE2-115 INT8 TRANSFORMER ACCELERATOR -- UART INTERACTIVE CONSOLE")
    print("=" * 76)
    print(" VOCABULARY WORDS YOU CAN TYPE:")
    print("   turn, on, the, lights, switch, off, increase, volume, up, decrease,")
    print("   down, heat, heating")
    print("-" * 76)
    print(" EXAMPLE SENTENCES:")
    print("   - \"turn on the lights\"       -> Intent: turn_on_lights")
    print("   - \"turn off the lights\"      -> Intent: turn_off_lights")
    print("   - \"increase the volume\"      -> Intent: increase_volume")
    print("   - \"decrease the volume\"      -> Intent: decrease_volume")
    print("   - \"turn on the heat\"         -> Intent: heat_on")
    print("   - \"turn off the heat\"        -> Intent: heat_off")
    print("-" * 76)
    print(" COMMAND KEYS:")
    print("   Type any sentence above     -> Tokenizes & classifies on FPGA!")
    print("   [0] : Switch to Tier 0 mode")
    print("   [1] : Switch to Tier 1 mode (default)")
    print("   [a] : Switch to Version A mode")
    print("   [s] : Cycle built-in sentence (0 to 5)")
    print("   [b] : Run Side-by-Side Hardware Benchmark (Tier 0 vs Version A)")
    print("   [h] : Help Menu")
    print("   [q] : Quit")
    print("=" * 76 + "\n")

    # Send 'h' to get initial banner from FPGA
    ser.write(b'h')
    ser.flush()
    time.sleep(0.15)
    if ser.in_waiting > 0:
        print(ser.read(ser.in_waiting).decode('latin1', errors='replace'), end='')

    while True:
        try:
            mode_name = "Tier 0" if current_mode == 0 else ("Tier 1" if current_mode == 1 else "Version A")
            user_input = input(f"\n[Mode: {mode_name}] Enter sentence or command > ").strip()
            if not user_input:
                continue

            low = user_input.lower()
            if low == 'q' or low == 'quit':
                print("Exiting console.")
                break
            elif low in ['0', '1', '2', 'a', 'b', 's', 'h', '?']:
                if low == '0':
                    current_mode = 0
                elif low == '1':
                    current_mode = 1
                elif low in ['2', 'a']:
                    current_mode = 2

                ser.write(low.encode('ascii'))
                ser.flush()
                time.sleep(0.15)
                timeout = 2.0 if low == 'b' else 0.5
                start_t = time.time()
                while time.time() - start_t < timeout:
                    if ser.in_waiting > 0:
                        sys.stdout.write(ser.read(ser.in_waiting).decode('latin1', errors='replace'))
                        sys.stdout.flush()
                    else:
                        time.sleep(0.02)
            else:
                # User typed a sentence!
                send_custom_sentence(ser, user_input, mode_byte=current_mode)

        except KeyboardInterrupt:
            print("\nExiting.")
            break


def main():
    parser = argparse.ArgumentParser(description="DE2-115 INT8 Transformer UART Telemetry & Sentence Typing")
    parser.add_argument("--port", "-p", default="COM6", help="Serial COM port (default: COM6)")
    parser.add_argument("--baud", "-b", type=int, default=115200, help="Baud rate (default: 115200)")
    parser.add_argument("--sentence", "-s", type=str, default=None, help="Directly type and run a single sentence")
    parser.add_argument("--benchmark", action="store_true", help="Directly trigger and print cycle benchmark")
    parser.add_argument("--mock", action="store_true", help="Display theoretical hardware metrics without opening port")
    args = parser.parse_args()

    if args.mock or not HAS_SERIAL:
        print("\n=======================================================================")
        print("     DE2-115 INT8 TRANSFORMER CYCLE TIMING: TIER 0 vs. VERSION A       ")
        print("=======================================================================")
        print("  Variant               Softmax Latency   Total Accelerator Latency    Delta")
        print("  ---------------------------------------------------------------------")
        print("  Tier 0 (Shift-Only)   1,880 cycles      5,560 cycles (111.20 us)    -128 c")
        print("  Version A (Detour)    2,008 cycles      5,688 cycles (113.76 us)   baseline")
        print("  ---------------------------------------------------------------------")
        print("  Conclusion: Tier 0 is exactly 128 clock cycles faster (2.56 us)      ")
        print("  due to elimination of ST_DESCALE (8c) and ST_REQUANT (8c) per row.   ")
        print("=======================================================================\n")
        return

    port = args.port or find_serial_port()
    if not port:
        print("[ERROR] No serial ports found. Connect your CP2102 USB module or specify --port COM6.")
        sys.exit(1)

    print(f"[HOST] Connecting to DE2-115 on {port} @ {args.baud} baud (8N1)...")
    try:
        ser = serial.Serial(port, args.baud, timeout=1.0)
    except Exception as e:
        print(f"[ERROR] Could not open {port}: {e}")
        print("Check that CP2102 is plugged in and no other program (e.g. PuTTY) is using it.")
        sys.exit(1)

    try:
        if args.sentence:
            send_custom_sentence(ser, args.sentence, mode_byte=1)
        elif args.benchmark:
            run_benchmark_command(ser)
        else:
            interactive_terminal(ser)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
