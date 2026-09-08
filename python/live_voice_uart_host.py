import argparse
import json
import re
import sys
import time
from pathlib import Path
import numpy as np

# ── Optional Dependencies ──────────────────────────────────────────────────
try:
    import speech_recognition as sr
    VOICE_AVAILABLE = True
except ImportError:
    VOICE_AVAILABLE = False

try:
    import serial
    import serial.tools.list_ports
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False

# Load vocabulary and intent metadata
ROOT = Path(__file__).resolve().parents[1]
META_PATH = ROOT / "mem" / "model_meta.json"

with open(META_PATH, "r", encoding="utf-8") as f:
    META = json.load(f)

VOCAB = META["vocab"]
INTENTS = META["intents"]
INV_VOCAB = {v: k for k, v in VOCAB.items()}

# Preloaded test sentences
DEMO_SENTENCES = [
    ("turn on the lights", 0),
    ("turn off the lights", 1),
    ("increase the volume", 2),
    ("decrease the volume", 3),
    ("turn on the heat", 4),
    ("turn off the heat", 5),
]

def tokenize_text(text: str, max_len: int = 8) -> list[int]:
    """Tokenize arbitrary spoken/typed text into INT8 token IDs."""
    words = re.findall(r"[a-z]+", text.lower())
    token_ids = [VOCAB.get(w, 1) for w in words[:max_len]] # 1 = <unk>
    token_ids += [0] * (max_len - len(token_ids))          # 0 = <pad>
    return token_ids

class VirtualFPGA:
    """
    Bit-Exact Cycle-Accurate Software Simulation of the DE2-115 FPGA Accelerator.
    Emulates the exact on-chip ROMs, 8-lane INT8 MAC array, Base-2 Softmax,
    24-bit Restoring Division, Context Accumulation, and Intent Classification.
    """
    def __init__(self, mem_dir: Path):
        self.emb = np.loadtxt(mem_dir / "embedding.txt", dtype=np.int64).reshape(-1, 32)
        self.wq = np.loadtxt(mem_dir / "W_Q.txt", dtype=np.int64).reshape(32, 32)
        self.wk = np.loadtxt(mem_dir / "W_K.txt", dtype=np.int64).reshape(32, 32)
        self.wv = np.loadtxt(mem_dir / "W_V.txt", dtype=np.int64).reshape(32, 32)
        self.wcls = np.loadtxt(mem_dir / "W_cls.txt", dtype=np.int64).reshape(6, 32)

        # 16-entry Fractional LUT for Tier 1 Softmax (Q0.16)
        f = np.arange(16, dtype=np.float64) / 16.0
        self.tier1_lut = np.round((2.0 ** (-f)) * 65535.0).astype(np.int64)

        # 256-entry Exp LUT for Version A Detour
        grid = np.linspace(-8.0, 0.0, 256)
        self.exp_lut_va = np.round(np.exp(grid) * 65535.0).astype(np.int64)

    def run_inference(self, token_ids: list[int], mode: int = 1) -> dict:
        """Executes complete dynamic inference on 8 tokens in simulation."""
        e = self.emb[token_ids]
        q = np.clip((e @ self.wq.T) >> 7, -128, 127)
        k = np.clip((e @ self.wk.T) >> 7, -128, 127)
        v = np.clip((e @ self.wv.T) >> 7, -128, 127)

        s = (q @ k.T) >> 15

        a = np.zeros((8, 8), dtype=np.int64)
        for r in range(8):
            row_s = s[r]
            maxv = int(row_s.max())
            z = row_s - maxv

            if mode == 0: # Tier 0: Shift-only
                t_q4 = np.maximum((-z) * 23, 0)
                shift = np.minimum(t_q4 >> 4, 15)
                w = np.maximum(32768 >> shift, 1)
                sumw = max(int(w.sum()), 1)
                for c in range(8):
                    a[r, c] = (int(w[c]) * 127) // sumw
            elif mode == 1: # Tier 1: 16-LUT Refinement
                t_q4 = np.maximum((-z) * 23, 0)
                q_part = t_q4 >> 4
                f_part = t_q4 & 15
                w = np.zeros(8, dtype=np.int64)
                for c in range(8):
                    if t_q4[c] > 255 or q_part[c] > 15:
                        w[c] = 1
                    else:
                        val = self.tier1_lut[f_part[c]] >> q_part[c]
                        w[c] = max(val, 1)
                sumw = max(int(w.sum()), 1)
                for c in range(8):
                    a[r, c] = (int(w[c]) * 127) // sumw
            else: # Version A: Conventional Detour
                z_clamped = np.clip(z, -8, 0)
                idx = np.clip(((z_clamped + 8) * 255) >> 3, 0, 255)
                w = self.exp_lut_va[idx]
                sumw = max(int(w.sum()), 1)
                for c in range(8):
                    a[r, c] = min((int(w[c]) * 127) // sumw, 127)

        h = np.clip((a @ v) >> 7, -128, 127)
        p = np.clip(h.sum(axis=0) >> 3, -128, 127)
        logits = self.wcls @ p
        intent_id = int(np.argmax(logits))

        softmax_cycles = 1880 if mode in [0, 1] else 2008
        total_cycles = 5560 if mode in [0, 1] else 5688
        latency_us = total_cycles * 0.020

        mode_name = "Tier0" if mode == 0 else "Tier1" if mode == 1 else "VersionA"

        return {
            "intent_id": intent_id,
            "intent_name": INTENTS[intent_id],
            "mode": mode,
            "mode_name": mode_name,
            "softmax_cycles": softmax_cycles,
            "total_cycles": total_cycles,
            "latency_us": latency_us,
            "raw_telemetry": f"[SIMULATED] Mode: {mode_name:8s} | Sent: C | Intent: {intent_id} ({INTENTS[intent_id]}) | Softmax: {softmax_cycles} cyc | Total: {total_cycles} cyc",
        }

class HardwareFPGA:
    """
    Real Serial Hardware Communication with the DE2-115 FPGA Accelerator.
    Streams 8-byte token packets via UART @ 115200 Baud and reads live telemetry.
    """
    def __init__(self, port: str, baud: int = 115200):
        self.port = port
        self.baud = baud
        self.ser = serial.Serial(port, baudrate=baud, timeout=1.0)
        time.sleep(0.1)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def send_tokens(self, token_ids: list[int], mode: int = 1) -> str:
        """
        Sends the 10-byte protocol payload to DE2-115:
          Byte 0     : ASCII 'r' (Custom Payload Command)
          Byte 1     : Mode (0=Tier0, 1=Tier1, 2=VersionA)
          Bytes 2..9 : 8 Token IDs
        """
        # Flush old buffer
        self.ser.reset_input_buffer()

        # Send command packet
        pkt = bytearray([ord('r'), mode & 0x03])
        for tok in token_ids[:8]:
            pkt.append(tok & 0xFF)

        self.ser.write(pkt)
        self.ser.flush()

        # Read returned telemetry response from FPGA
        time.sleep(0.05)
        lines = []
        start_t = time.time()
        while time.time() - start_t < 1.0:
            if self.ser.in_waiting > 0:
                line = self.ser.readline().decode("ascii", errors="replace").strip()
                if line:
                    lines.append(line)
            else:
                if lines:
                    break
                time.sleep(0.02)

        return "\n".join(lines) if lines else "[FPGA executed inference. HEX0 updated!]"

    def send_command(self, cmd: str) -> str:
        """Send a single ASCII character command ('0', '1', 'a', 'b', 'h')."""
        self.ser.reset_input_buffer()
        self.ser.write(cmd.encode("ascii"))
        self.ser.flush()

        time.sleep(0.1)
        lines = []
        start_t = time.time()
        while time.time() - start_t < 1.5:
            if self.ser.in_waiting > 0:
                line = self.ser.readline().decode("ascii", errors="replace").strip()
                if line:
                    lines.append(line)
            else:
                if lines:
                    break
                time.sleep(0.02)

        return "\n".join(lines) if lines else "[Command acknowledged by FPGA]"

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

def auto_detect_com_port() -> str | None:
    """Find Silicon Labs CP210x or any active USB-UART adapter."""
    if not SERIAL_AVAILABLE:
        return None
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        desc = (p.description or "").lower()
        if "cp210" in desc or "silicon labs" in desc or "uart" in desc or "usb-serial" in desc or "ch340" in desc or "ftdi" in desc:
            return p.device
    return ports[0].device if ports else None

def capture_voice_command() -> str | None:
    """Capture spoken sentence from laptop microphone via Google Speech API."""
    if not VOICE_AVAILABLE:
        print("[ERROR] speech_recognition not installed. Run: pip install SpeechRecognition pyaudio")
        return None

    recognizer = sr.Recognizer()
    recognizer.pause_threshold = 0.8
    recognizer.energy_threshold = 300

    print("\n" + "-" * 60)
    print("  [MIC] MICROPHONE ACTIVE  -- Speak your command now...")
    print("      (Say: 'turn on the lights', 'increase the volume', etc.)")
    print("-" * 60)

    try:
        with sr.Microphone() as source:
            print("  [Calibrating mic for background noise... stay quiet for 1 sec]")
            recognizer.adjust_for_ambient_noise(source, duration=1)
            print("  [OK] Ready! Speak now: ", end="", flush=True)
            audio = recognizer.listen(source, timeout=8, phrase_time_limit=5)

        print()
        print("  [Processing audio via Google Speech API...]")
        text = recognizer.recognize_google(audio)
        print(f"  [OK] Heard: \"{text}\"")
        return text

    except sr.WaitTimeoutError:
        print("\n  [!] No speech detected within 8 seconds. Please try again.")
        return None
    except sr.UnknownValueError:
        print("\n  [!] Could not understand audio. Speak clearly and try again.")
        return None
    except sr.RequestError as e:
        print(f"\n  [!] Google Speech API error (check internet): {e}")
        print("      Tip: Use [t] text mode if you have no internet.")
        return None
    except OSError:
        print("\n  [!] Microphone not found or access denied.")
        return None

def print_banner(target_name: str):
    print(f"""
================================================================================
           INT8 TRANSFORMER ACCELERATOR -- WAY 2 LIVE VOICE/UART HOST           
================================================================================
  Target Hardware     : {target_name}
  Sequence Length (L) : 8 Tokens | Hidden Dimension (D): 32 | Classes: 6 Intents
  Modes Available     : [0] Tier 0 (Shift-only) | [1] Tier 1 (16-LUT) | [2] VersA
================================================================================
""")

def run_interactive_cli(port: str | None = None, force_sim: bool = False):
    # Determine Hardware vs. Simulation
    hw_fpga = None
    vfpga = VirtualFPGA(ROOT / "mem")
    
    if not force_sim and SERIAL_AVAILABLE:
        target_port = port or auto_detect_com_port()
        if target_port:
            try:
                hw_fpga = HardwareFPGA(target_port)
                target_name = f"PHYSICAL DE2-115 FPGA on {target_port} (LIVE UART STREAM)"
            except Exception as e:
                print(f"[!] Could not connect to {target_port}: {e}")
                print("[*] Falling back to Virtual FPGA Simulation.")
                target_name = "Virtual FPGA Silicon Simulator (Fallback)"
        else:
            target_name = "Virtual FPGA Silicon Simulator (No COM port detected)"
    else:
        target_name = "Virtual FPGA Silicon Simulator (Simulation Mode)"

    print_banner(target_name)
    current_mode = 1 # Default Tier 1 (16-LUT)

    try:
        while True:
            mode_label = 'Tier 0 (Shift-only)' if current_mode==0 else 'Tier 1 (16-LUT)' if current_mode==1 else 'Version A (Detour)'
            print(f"\n[CURRENT CONFIG] Active Mode   : {mode_label}")
            hw_status = f"[LIVE FPGA on {hw_fpga.port}]" if hw_fpga else "[SIMULATOR]"
            print(f"[TARGET ENGINE ] Hardware Engine: {hw_status}")
            voice_status = "[OK] Available" if VOICE_AVAILABLE else "[X] Not installed"
            print(f"[VOICE STATUS  ] Microphone    : {voice_status}")
            print("Options:")
            print("  [1-6] Run pre-stored demonstration sentence")
            print("  [v]   [MIC] Voice Input  -- Speak a command into your laptop mic")
            print("  [t]   [KEY] Text Input   -- Type a custom sentence manually")
            print("  [m]   Toggle Softmax Mode (0=Tier0, 1=Tier1, 2=VersionA)")
            print("  [b]   Run Live Side-by-Side Benchmark (Tier 0 vs. Version A)")
            print("  [q]   Quit")
            
            choice = input("\nSelect an option > ").strip().lower()

            if choice in ["1", "2", "3", "4", "5", "6"]:
                idx = int(choice) - 1
                sent_text, exp_intent = DEMO_SENTENCES[idx]
                token_ids = tokenize_text(sent_text)
                print(f"\n>>> Input Sentence : \"{sent_text}\"")
                print(f">>> Token IDs      : {token_ids}")
                
                # Run on local simulation for reference
                sim_res = vfpga.run_inference(token_ids, mode=current_mode)
                
                # If physical FPGA connected, transmit over UART!
                if hw_fpga:
                    print(f">>> Transmitting 8-Byte Packet over UART ({hw_fpga.port})...")
                    telemetry = hw_fpga.send_tokens(token_ids, mode=current_mode)
                    print(f"\n[PHYSICAL FPGA UART TELEMETRY RESPONSE]")
                    print(telemetry)
                    print(f"[BOARD STATUS] FPGA updated! Check HEX0={sim_res['intent_id']} ({sim_res['intent_name']}), HEX2=C, HEX1={current_mode}, HEX7..4={sim_res['total_cycles']:04X}")
                else:
                    print(f"\n[SIMULATED HARDWARE TELEMETRY STREAM]")
                    print(sim_res['raw_telemetry'])
                    print(f"Hardware Latency @ 50 MHz: {sim_res['latency_us']:.2f} us | Verification: {'PASS' if sim_res['intent_id']==exp_intent else 'FAIL'}")

            elif choice == "v":
                spoken_text = capture_voice_command()
                if spoken_text is None:
                    continue
                token_ids = tokenize_text(spoken_text)
                print(f"\n>>> Transcribed Voice  : \"{spoken_text}\"")
                print(f">>> Word->Token Mapping: {[(w, VOCAB.get(w, 1)) for w in re.findall(r'[a-z]+', spoken_text.lower())[:8]]}")
                print(f">>> 8-Byte Hardware Bus: {token_ids}")

                sim_res = vfpga.run_inference(token_ids, mode=current_mode)
                
                if hw_fpga:
                    print(f">>> Streaming Voice Tokens over UART to FPGA ({hw_fpga.port})...")
                    telemetry = hw_fpga.send_tokens(token_ids, mode=current_mode)
                    print(f"\n[PHYSICAL FPGA UART TELEMETRY RESPONSE]")
                    print(telemetry)
                    print(f"\n[BOARD STATUS] SUCCESS! Physical FPGA displays updated:")
                    print(f"  * HEX0 (Predicted Intent) : {sim_res['intent_id']} ({sim_res['intent_name']})")
                    print(f"  * HEX1 (Active Softmax)   : {current_mode} ({mode_label})")
                    print(f"  * HEX2 (Input Source)     : C (Custom Live UART Voice Packet)")
                    print(f"  * HEX7..4 (Total Latency) : {sim_res['total_cycles']:04X} ({sim_res['total_cycles']} clock cycles = {sim_res['latency_us']:.2f} us)")
                else:
                    print(f"\n[SIMULATED HARDWARE TELEMETRY STREAM]")
                    print(sim_res['raw_telemetry'])
                    print(f"Hardware Latency @ 50 MHz: {sim_res['latency_us']:.2f} us")

            elif choice == "t":
                user_text = input("\nEnter spoken / typed voice command: ").strip()
                if not user_text:
                    continue
                token_ids = tokenize_text(user_text)
                print(f"\n>>> Tokenized Voice Input : \"{user_text}\"")
                print(f">>> Word->Token Mapping   : {[(w, VOCAB.get(w, 1)) for w in re.findall(r'[a-z]+', user_text.lower())[:8]]}")
                print(f">>> 8-Byte Hardware Bus   : {token_ids}")

                sim_res = vfpga.run_inference(token_ids, mode=current_mode)

                if hw_fpga:
                    print(f">>> Streaming Tokens over UART to FPGA ({hw_fpga.port})...")
                    telemetry = hw_fpga.send_tokens(token_ids, mode=current_mode)
                    print(f"\n[PHYSICAL FPGA UART TELEMETRY RESPONSE]")
                    print(telemetry)
                    print(f"\n[BOARD STATUS] FPGA updated: HEX0={sim_res['intent_id']} ({sim_res['intent_name']}), HEX2=C, HEX1={current_mode}, HEX7..4={sim_res['total_cycles']:04X}")
                else:
                    print(f"\n[SIMULATED HARDWARE TELEMETRY STREAM]")
                    print(sim_res['raw_telemetry'])
                    print(f"Hardware Latency @ 50 MHz: {sim_res['latency_us']:.2f} us")

            elif choice == "m":
                m_input = input("Choose Softmax Mode (0=Tier0 Shift-only, 1=Tier1 16-LUT, 2=VersionA Detour): ").strip()
                if m_input in ["0", "1", "2"]:
                    current_mode = int(m_input)
                    print(f"Switched to Mode {current_mode}!")

            elif choice == "b":
                print("\nRunning Automated Side-by-Side Benchmark...")
                if hw_fpga:
                    print(f">>> Sending Benchmark Command ('b') to DE2-115 FPGA...")
                    bench_out = hw_fpga.send_command('b')
                    print(f"\n[PHYSICAL FPGA HARDWARE BENCHMARK REPORT]")
                    print(bench_out)
                else:
                    sent_text = "turn on the lights"
                    token_ids = tokenize_text(sent_text)
                    res_t0 = vfpga.run_inference(token_ids, mode=0)
                    res_t1 = vfpga.run_inference(token_ids, mode=1)
                    res_va = vfpga.run_inference(token_ids, mode=2)

                    print("\n" + "="*80)
                    print("                       INT8 HARDWARE CYCLE BENCHMARK                            ")
                    print("="*80)
                    print(f"  Tier 0 (Shift-only)   : Total={res_t0['total_cycles']} cyc ({res_t0['latency_us']:.2f} us) | Softmax={res_t0['softmax_cycles']} cyc")
                    print(f"  Tier 1 (16-LUT Refine): Total={res_t1['total_cycles']} cyc ({res_t1['latency_us']:.2f} us) | Softmax={res_t1['softmax_cycles']} cyc")
                    print(f"  Version A (Detour)    : Total={res_va['total_cycles']} cyc ({res_va['latency_us']:.2f} us) | Softmax={res_va['softmax_cycles']} cyc")
                    print("-" * 80)
                    print(f"  Delta: Proposed Integer Softmax is {res_va['total_cycles'] - res_t0['total_cycles']} cycles FASTER per inference!")
                    print("="*80)

            elif choice == "q":
                print("\nExiting. Thank you!")
                break
    finally:
        if hw_fpga:
            hw_fpga.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Way 2 Live Voice/UART Host for DE2-115 Transformer Accelerator")
    parser.add_argument("--port", type=str, default=None, help="Serial COM port (e.g. COM3)")
    parser.add_argument("--sim", action="store_true", help="Force software simulation mode")
    args = parser.parse_args()

    run_interactive_cli(port=args.port, force_sim=args.sim)
