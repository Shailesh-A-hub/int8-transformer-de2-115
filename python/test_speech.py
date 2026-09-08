#!/usr/bin/env python3
"""
Standalone Speech Detection Test
==================================
Uses PyAudio + SpeechRecognition + Google Speech API.
Matches the working reference implementation:
  - Default sr.Microphone() (opens Windows active recording device)
  - Auto-unmutes Windows microphone if muted
  - Clamps energy threshold to prevent false-triggering on background noise
  - pause_threshold = 1.0s to allow full sentence speaking without premature cutoff

Run:
    python python/test_speech.py
"""

import speech_recognition as sr
import pyaudio

# Optional Windows unmute check
try:
    from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
    import comtypes
    from ctypes import cast, POINTER
    PYCAW_AVAILABLE = True
except Exception:
    PYCAW_AVAILABLE = False


def ensure_microphone_unmuted():
    """Ensure the default Windows microphone is not muted."""
    if not PYCAW_AVAILABLE:
        return
    try:
        mic = AudioUtilities.GetMicrophone()
        if mic:
            interface = mic.Activate(IAudioEndpointVolume._iid_, comtypes.CLSCTX_ALL, None)
            vol = cast(interface, POINTER(IAudioEndpointVolume))
            if vol.GetMute():
                print("[MIC SETUP] Microphone was muted in Windows. Unmuting now...")
                vol.SetMute(0, None)
            level = vol.GetMasterVolumeLevelScalar()
            if level < 0.5:
                print(f"[MIC SETUP] Microphone volume was low ({int(level*100)}%). Setting to 85%...")
                vol.SetMasterVolumeLevelScalar(0.85, None)
    except Exception:
        pass


def list_mics():
    """List available audio input devices for user reference."""
    print("\n" + "=" * 60)
    print("  AVAILABLE MICROPHONE INPUT DEVICES")
    print("=" * 60)
    p = pyaudio.PyAudio()
    found = []
    for i in range(p.get_device_count()):
        try:
            info = p.get_device_info_by_index(i)
            if info.get("maxInputChannels", 0) > 0:
                name = info.get("name", "Unknown").splitlines()[0]
                found.append((i, name))
                print(f"  [{i:2d}]  {name}")
        except Exception:
            pass
    p.terminate()
    print("=" * 60)
    return found


def capture_voice_command(device_index=None):
    """
    Capture one spoken sentence and transcribe using Google Speech API.
    Uses default sr.Microphone() if device_index is None.
    """
    ensure_microphone_unmuted()

    recognizer = sr.Recognizer()
    recognizer.pause_threshold = 1.0     # wait 1.0 s of silence before ending speech
    recognizer.non_speaking_duration = 0.5
    recognizer.energy_threshold = 300    # baseline sensitivity

    print("\n" + "-" * 60)
    print("  [MIC] MICROPHONE ACTIVE  -- Speak your command now...")
    print("      (Say: 'turn on the lights', 'increase the volume', etc.)")
    print("-" * 60)

    try:
        mic_kwargs = {}
        if device_index is not None:
            mic_kwargs["device_index"] = device_index

        with sr.Microphone(**mic_kwargs) as source:
            print("  [Calibrating mic for background noise... stay quiet for 1 sec]")
            recognizer.adjust_for_ambient_noise(source, duration=1)

            # Prevent runaway threshold from fan/keyboard noise
            if recognizer.energy_threshold < 200:
                recognizer.energy_threshold = 300
            elif recognizer.energy_threshold > 2000:
                recognizer.energy_threshold = 1000

            print(f"  [OK] Ready! Speak now (sensitivity threshold={int(recognizer.energy_threshold)}): ", end="", flush=True)

            # Listen for up to 8s to start speaking, 6s max sentence length
            audio = recognizer.listen(source, timeout=8, phrase_time_limit=6)

        print()
        print("  [Audio captured! Sending to Google Speech API...]")

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
    except OSError as e:
        print(f"\n  [!] Microphone access error: {e}")
        print("      Settings -> Privacy -> Microphone -> Allow desktop apps")
        return None


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("   SPEECH DETECTION TEST")
    print("   PyAudio + SpeechRecognition + Google Speech API")
    print("=" * 60)

    ensure_microphone_unmuted()
    list_mics()

    print("\nUsing system default microphone.")
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
                print(f"\n  >>> SUCCESS! Recognized: \"{result}\"\n")
        except KeyboardInterrupt:
            print("\n\n  [EXIT] Stopped by user.")
            break
