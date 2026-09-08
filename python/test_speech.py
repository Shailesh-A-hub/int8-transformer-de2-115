#!/usr/bin/env python3
"""
Standalone Speech Detection Test
==================================
Uses the EXACT same pattern as the working reference implementation:
  - energy_threshold = 300 set manually before calibration
  - adjust_for_ambient_noise() + listen() in ONE single 'with Microphone()' block
  - Clear "[OK] Ready! Speak now:" prompt before listening

Libraries:
  - PyAudio           : audio capture from microphone
  - SpeechRecognition : speech energy detection & Google STT integration
  - Google Speech API : free online transcription (needs internet)

Run:
    python python/test_speech.py

No FPGA needed -- just tests mic + Google STT on your PC.
"""

import speech_recognition as sr
import pyaudio


# ─────────────────────────────────────────────────────────
# List all available input devices (for reference)
# ─────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────
# Core voice capture (matches friend's working reference)
# ─────────────────────────────────────────────────────────
def capture_voice_command():
    """
    Capture one spoken command from the system default microphone.

    Key pattern (same as working reference):
      1. Set energy_threshold = 300 manually first
      2. Open ONE 'with sr.Microphone() as source:' block
      3. Call adjust_for_ambient_noise() inside that block
      4. Print 'Speak now:' THEN call listen() in the SAME block
    """
    recognizer = sr.Recognizer()
    recognizer.pause_threshold = 0.8   # stop after 0.8 s of silence
    recognizer.energy_threshold = 300  # manual baseline before auto-adjust

    print("\n" + "-" * 60)
    print("  [MIC] MICROPHONE ACTIVE  -- Speak your command now...")
    print("      (Say: 'turn on the lights', 'increase the volume', etc.)")
    print("-" * 60)

    try:
        with sr.Microphone() as source:
            # Step 1: calibrate for ambient noise (stay quiet for 1 sec)
            print("  [Calibrating mic for background noise... stay quiet for 1 sec]")
            recognizer.adjust_for_ambient_noise(source, duration=1)

            # Step 2: prompt then listen -- in the SAME with-block
            print("  [OK] Ready! Speak now: ", end="", flush=True)
            audio = recognizer.listen(source, timeout=8, phrase_time_limit=5)

        print()  # newline after "Speak now:"
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
        return None
    except OSError:
        print("\n  [!] Microphone not found or access denied.")
        print("      Go to: Settings -> Privacy -> Microphone -> Allow apps")
        return None


# ─────────────────────────────────────────────────────────
# Main test loop
# ─────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("   SPEECH DETECTION TEST")
    print("   PyAudio + SpeechRecognition + Google Speech API")
    print("=" * 60)

    mics = list_mics()
    if not mics:
        print("[ERROR] No microphone input devices found!")
        exit(1)

    print("\nUsing system default microphone.")
    print("(If wrong mic is selected, change your Windows default recording device)")
    print("\nSay one of these smart home commands:")
    print("  turn on the lights  |  turn off the lights")
    print("  increase the volume |  decrease the volume")
    print("  turn on the heat    |  turn off the heat")
    print("\nPress Ctrl+C at any time to stop.\n")

    while True:
        try:
            input("  [ENTER]  Press ENTER then speak your command...")
            result = capture_voice_command()
            if result:
                print(f"\n  >>> RESULT: \"{result}\"\n")
        except KeyboardInterrupt:
            print("\n\n  [EXIT]  Stopped by user.")
            break
