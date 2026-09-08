#!/usr/bin/env python3
"""
Speech Detection Test
=====================
Standalone test using:
  - PyAudio       : capture mic audio
  - SpeechRecognition : detect speech energy
  - Google Speech API : transcribe speech to text

Run:
    python python/test_speech.py

No FPGA needed — just tests mic + Google STT on your PC.
"""

import speech_recognition as sr
import pyaudio

# ─────────────────────────────────────────────
# Step 1: List all available input microphones
# ─────────────────────────────────────────────
def list_mics():
    print("\n" + "=" * 60)
    print("  AVAILABLE MICROPHONE INPUT DEVICES")
    print("=" * 60)
    p = pyaudio.PyAudio()
    found = []
    for i in range(p.get_device_count()):
        try:
            info = p.get_device_info_by_index(i)
            if info.get("maxInputChannels", 0) > 0:
                found.append((i, info.get("name", "Unknown")))
                print(f"  [{i:2d}]  {info.get('name', 'Unknown')}")
        except Exception:
            pass
    p.terminate()
    print("=" * 60)
    return found


# ─────────────────────────────────────────────
# Step 2: Pick best mic (Realtek internal first)
# ─────────────────────────────────────────────
def pick_mic(mics):
    for idx, name in mics:
        if "realtek" in name.lower() and "mic" in name.lower() and "stereo" not in name.lower():
            print(f"\n[AUTO] Selected: [{idx}] {name}")
            return idx
    for idx, name in mics:
        if "mic" in name.lower() and "mapper" not in name.lower():
            print(f"\n[AUTO] Selected: [{idx}] {name}")
            return idx
    print("\n[AUTO] Using system default microphone.")
    return None


# ─────────────────────────────────────────────
# Step 3: Calibrate + Transcribe Loop
# ─────────────────────────────────────────────
def run_speech_test(device_index):
    r = sr.Recognizer()
    r.dynamic_energy_threshold = True
    r.pause_threshold = 0.8   # seconds of silence to stop listening

    mic = sr.Microphone(device_index=device_index)

    print("\n" + "─" * 60)
    print("  [STEP 1]  Calibrating for ambient noise (stay quiet 1.5s)...")
    with mic as source:
        r.adjust_for_ambient_noise(source, duration=1.5)
    print(f"  [DONE]    Energy threshold = {int(r.energy_threshold)}")
    print("─" * 60)

    print("\n  Say one of these smart home commands:")
    print("     • turn on the lights")
    print("     • turn off the lights")
    print("     • increase the volume")
    print("     • decrease the volume")
    print("     • turn on the heat")
    print("     • turn off the heat")
    print("\n  Press Ctrl+C at any time to stop.\n")

    while True:
        input("  [ENTER]  Press ENTER then speak your command...")
        print("  [MIC]    🎤 Listening... SPEAK NOW!")

        try:
            with mic as source:
                audio = r.listen(source, timeout=7, phrase_time_limit=8)

            print("  [STT]    ⏳ Sending to Google Speech API...")
            text = r.recognize_google(audio)
            print(f"\n  ✅ RECOGNIZED:  \"{text}\"\n")

        except sr.WaitTimeoutError:
            print("  ⚠️  Timeout — no speech detected. Try again.\n")
        except sr.UnknownValueError:
            print("  ❓ Could not understand. Speak more clearly.\n")
        except sr.RequestError as e:
            print(f"  ❌ Google STT API error: {e}")
            print("     Check your internet connection.\n")
        except KeyboardInterrupt:
            print("\n\n  [EXIT]  Stopped by user.")
            break


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("   SPEECH DETECTION TEST")
    print("   Libraries: PyAudio + SpeechRecognition + Google STT")
    print("=" * 60)

    mics = list_mics()
    if not mics:
        print("[ERROR] No microphone input devices found!")
        exit(1)

    device_index = pick_mic(mics)

    # Allow user to override mic selection
    override = input(f"\n  Press ENTER to use auto-selected mic,\n"
                     f"  OR type a device number from the list above: ").strip()
    if override.isdigit():
        device_index = int(override)
        print(f"  [MANUAL] Using device [{device_index}]")

    run_speech_test(device_index)
