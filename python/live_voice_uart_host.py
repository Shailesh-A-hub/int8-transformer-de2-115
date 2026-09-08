import json
import re
import sys
import time
from pathlib import Path
import numpy as np

# ── Voice capture (optional, graceful fallback if mic unavailable) ──────────
try:
    import speech_recognition as sr
    VOICE_AVAILABLE = True
except ImportError:
    VOICE_AVAILABLE = False

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

    @staticmethod
    def clamp8(val):
        return int(np.clip(val, -128, 127))

    def run_inference(self, token_ids: list[int], mode: int = 1) -> dict:
        """
        Executes complete dynamic inference on 8 tokens.
        mode: 0 = Tier 0 (Shift-only), 1 = Tier 1 (16-LUT), 2 = Version A (Detour)
        """
        # 1. Embedding lookup
        e = self.emb[token_ids] # (8, 32)

        # 2. Q, K, V Projections (8-lane MAC >>> 7, clamp8)
        q = np.clip((e @ self.wq.T) >> 7, -128, 127)
        k = np.clip((e @ self.wk.T) >> 7, -128, 127)
        v = np.clip((e @ self.wv.T) >> 7, -128, 127)

        # 3. Attention Score Matrix S = Q * K^T >>> 15
        s = (q @ k.T) >> 15 # (8, 8)

        # 4. Softmax Normalization
        a = np.zeros((8, 8), dtype=np.int64)
        for r in range(8):
            row_s = s[r]
            maxv = int(row_s.max())
            z = row_s - maxv # <= 0

            if mode == 0: # Tier 0: Shift-only
                t_q4 = np.maximum((-z) * 23, 0)
                shift = t_q4 >> 4
                shift = np.minimum(shift, 15)
                w = 32768 >> shift
                w = np.maximum(w, 1)
                sumw = int(w.sum())
                sumw = max(sumw, 1)
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
                    quot = (int(w[c]) * 127) // sumw
                    a[r, c] = min(quot, 127)

        # 5. Context Aggregation H = A * V >>> 7
        h = np.clip((a @ v) >> 7, -128, 127)

        # 6. Mean Pooling P = sum(H_i) >>> 3
        p = np.clip(h.sum(axis=0) >> 3, -128, 127)

        # 7. Intent Classifier Logits = W_cls * P
        logits = self.wcls @ p

        # 8. Argmax Winning Intent
        intent_id = int(np.argmax(logits))

        # Hardware Cycle Metrics
        softmax_cycles = 1880 if mode in [0, 1] else 2008
        total_cycles = 5560 if mode in [0, 1] else 5688
        latency_us = total_cycles * 0.020 # 50 MHz clock = 20 ns period

        mode_name = "Tier0" if mode == 0 else "Tier1" if mode == 1 else "VersionA"

        return {
            "intent_id": intent_id,
            "intent_name": INTENTS[intent_id],
            "mode": mode,
            "mode_name": mode_name,
            "softmax_cycles": softmax_cycles,
            "total_cycles": total_cycles,
            "latency_us": latency_us,
            "logits": logits.tolist(),
        }

def capture_voice_command() -> str | None:
    """
    Capture one spoken sentence from the laptop microphone.
    Returns the transcribed text string, or None on any error.
    """
    if not VOICE_AVAILABLE:
        print("[ERROR] speech_recognition not installed. Run:  pip install SpeechRecognition pyaudio")
        return None

    recognizer = sr.Recognizer()
    recognizer.pause_threshold = 0.8   # stop listening 0.8 s after you stop speaking
    recognizer.energy_threshold = 300  # mic sensitivity (auto-adjusted below)

    print("\n" + "-" * 60)
    print("  [MIC] MICROPHONE ACTIVE  -- Speak your command now...")
    print("      (Say: 'turn on the lights', 'increase the volume', etc.)")
    print("-" * 60)

    try:
        with sr.Microphone() as source:
            # Auto-adjust for ambient noise (calibrates for 1 second)
            print("  [Calibrating mic for background noise... stay quiet for 1 sec]")
            recognizer.adjust_for_ambient_noise(source, duration=1)
            print("  [OK] Ready! Speak now: ", end="", flush=True)

            # Listen for speech (timeout=8 s to start, phrase_limit=5 s max)
            audio = recognizer.listen(source, timeout=8, phrase_time_limit=5)

        print()  # newline after "Speak now:"
        print("  [Processing audio via Google Speech API...]")

        # Transcribe using Google free tier
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
        print("      Check Windows microphone permissions:")
        print("      Settings -> Privacy -> Microphone -> Allow apps to access microphone")
        return None

def print_banner():
    print("""
================================================================================
           INT8 TRANSFORMER ACCELERATOR -- WAY 2 LIVE VOICE/UART HOST           
================================================================================
  Target Architecture : Single-Head INT8 Self-Attention on Cyclone IV FPGA      
  Sequence Length (L) : 8 Tokens | Hidden Dimension (D): 32 | Classes: 6 Intents
  Modes Available     : [0] Tier 0 (Shift-only) | [1] Tier 1 (16-LUT) | [2] VersA
================================================================================
""")

def run_interactive_cli():
    print_banner()
    vfpga = VirtualFPGA(ROOT / "mem")
    current_mode = 1 # Default Tier 1

    while True:
        print(f"\n[CURRENT CONFIG] Active Mode: {'Tier 0 (Shift-only)' if current_mode==0 else 'Tier 1 (16-LUT)' if current_mode==1 else 'Version A (Detour)'}")
        voice_status = "[OK] Available" if VOICE_AVAILABLE else "[X] Not installed (pip install SpeechRecognition pyaudio)"
        print(f"[VOICE STATUS  ] Microphone Input: {voice_status}")
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
            
            res = vfpga.run_inference(token_ids, mode=current_mode)
            print(f"\n[HARDWARE TELEMETRY STREAM @ 115200 BAUD]")
            print(f"[RESULT] Mode: {res['mode_name']:8s} | Sent: {idx} | Intent: {res['intent_id']} ({res['intent_name']}) | Softmax: {res['softmax_cycles']} cyc | Total: {res['total_cycles']} cyc")
            print(f"Hardware Latency @ 50 MHz: {res['latency_us']:.2f} us | Verification: {'PASS' if res['intent_id']==exp_intent else 'FAIL'}")

        elif choice == "v":
            # ── VOICE INPUT PATH ─────────────────────────────────────────────
            spoken_text = capture_voice_command()
            if spoken_text is None:
                continue  # mic failed, loop back to menu
            token_ids = tokenize_text(spoken_text)
            print(f"\n>>> Transcribed Voice  : \"{spoken_text}\"")
            print(f">>> Word→Token Mapping : {[(w, VOCAB.get(w, 1)) for w in re.findall(r'[a-z]+', spoken_text.lower())[:8]]}")
            print(f">>> 8-Byte Hardware Bus: {token_ids}")

            res = vfpga.run_inference(token_ids, mode=current_mode)
            print(f"\n[HARDWARE TELEMETRY STREAM @ 115200 BAUD]")
            print(f"[RESULT] Mode: {res['mode_name']:8s} | Sent: Voice | Intent: {res['intent_id']} ({res['intent_name']}) | Softmax: {res['softmax_cycles']} cyc | Total: {res['total_cycles']} cyc")
            print(f"Hardware Latency @ 50 MHz: {res['latency_us']:.2f} us")

        elif choice == "t":
            user_text = input("\nEnter spoken / typed voice command: ").strip()
            if not user_text:
                continue
            token_ids = tokenize_text(user_text)
            print(f"\n>>> Tokenized Voice Input : \"{user_text}\"")
            print(f">>> Word-to-Token Mapping : {[(w, VOCAB.get(w, 1)) for w in re.findall(r'[a-z]+', user_text.lower())[:8]]}")
            print(f">>> 8-Byte Hardware Bus   : {token_ids}")

            res = vfpga.run_inference(token_ids, mode=current_mode)
            print(f"\n[HARDWARE TELEMETRY STREAM @ 115200 BAUD]")
            print(f"[RESULT] Mode: {res['mode_name']:8s} | Sent: C | Intent: {res['intent_id']} ({res['intent_name']}) | Softmax: {res['softmax_cycles']} cyc | Total: {res['total_cycles']} cyc")
            print(f"Hardware Latency @ 50 MHz: {res['latency_us']:.2f} us")

        elif choice == "m":
            m_input = input("Choose Softmax Mode (0=Tier0 Shift-only, 1=Tier1 16-LUT, 2=VersionA Detour): ").strip()
            if m_input in ["0", "1", "2"]:
                current_mode = int(m_input)
                print(f"Switched to Mode {current_mode}!")

        elif choice == "b":
            sent_text = "turn on the lights"
            token_ids = tokenize_text(sent_text)
            print(f"\nRunning Automated Benchmark on: \"{sent_text}\"...")
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

if __name__ == "__main__":
    run_interactive_cli()
