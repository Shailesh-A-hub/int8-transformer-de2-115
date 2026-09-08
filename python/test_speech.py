#!/usr/bin/env python3
"""
Speech Detection Test
=====================
Uses PyAudio + SpeechRecognition + Google Speech API.

Features:
  - Automatically checks and un-mutes microphone if muted in Windows
  - Automatically selects the active DirectSound recording device (avoids silent MME)
  - Uses Google Speech API for real-time speech-to-text
"""

import sys
import time
import speech_recognition as sr
import pyaudio

try:
    import audioop
except ImportError:
    import pyaudio.audioop as audioop

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
                print(f"[MIC SETUP] Microphone volume was low ({int(level*100)}%). Boosting to 85%...")
                vol.SetMasterVolumeLevelScalar(0.85, None)
    except Exception as e:
        pass


def get_best_microphone():
    """
    Scans input devices and selects the one with live audio signal.
    On Windows 10/11, DirectSound devices capture audio whereas legacy MME can return 0.
    """
    p = pyaudio.PyAudio()
    best_idx = None
    best_score = 0
    
    for i in range(p.get_device_count()):
        try:
            info = p.get_device_info_by_index(i)
            if info.get('maxInputChannels', 0) > 0:
                api_name = p.get_host_api_info_by_index(info['hostApi'])['name']
                rate = int(info.get('defaultSampleRate', 44100))
                stream = p.open(
                    input_device_index=i,
                    channels=1,
                    format=pyaudio.paInt16,
                    rate=rate,
                    frames_per_buffer=1024,
                    input=True
                )
                data = stream.read(1024, exception_on_overflow=False)
                stream.close()
                rms = audioop.rms(data, 2)
                score = rms * (2.0 if "DirectSound" in api_name else 1.0)
                if score > best_score and rms > 50:
                    best_score = score
                    best_idx = i
        except Exception:
            pass
    p.terminate()

    if best_idx is not None:
        return best_idx
    # Default fallback: device 5 (DirectSound Realtek) or None
    return 5


def capture_voice_command(device_index=None):
    """
    Capture one spoken sentence and transcribe using Google Speech API.
    """
    ensure_microphone_unmuted()

    if device_index is None:
        device_index = get_best_microphone()

    recognizer = sr.Recognizer()
    recognizer.pause_threshold = 0.8
    recognizer.energy_threshold = 300

    print("\n" + "-" * 60)
    print("  [MIC] MICROPHONE ACTIVE  -- Speak your command now...")
    print("      (Say: 'turn on the lights', 'increase the volume', etc.)")
    print("-" * 60)

    try:
        with sr.Microphone(device_index=device_index, sample_rate=44100) as source:
            print("  [Calibrating mic for background noise... stay quiet for 1 sec]")
            recognizer.adjust_for_ambient_noise(source, duration=1)
            print(f"  [OK] Ready! Speak now (threshold={int(recognizer.energy_threshold)}): ", end="", flush=True)

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
        return None
    except OSError as e:
        print(f"\n  [!] Microphone error: {e}")
        return None


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("   SPEECH DETECTION TEST")
    print("   PyAudio + SpeechRecognition + Google Speech API")
    print("=" * 60)

    ensure_microphone_unmuted()
    dev_idx = get_best_microphone()
    p = pyaudio.PyAudio()
    dev_name = p.get_device_info_by_index(dev_idx)['name'].splitlines()[0]
    p.terminate()
    print(f"\n[MIC AUTO-DETECT] Using Device [{dev_idx}]: {dev_name}")

    print("\nSay one of these smart home commands:")
    print("  turn on the lights  |  turn off the lights")
    print("  increase the volume |  decrease the volume")
    print("  turn on the heat    |  turn off the heat")
    print("\nPress Ctrl+C at any time to stop.\n")

    while True:
        try:
            input("  [ENTER]  Press ENTER then speak your command...")
            result = capture_voice_command(device_index=dev_idx)
            if result:
                print(f"\n  >>> SUCCESS! Recognized: \"{result}\"\n")
        except KeyboardInterrupt:
            print("\n\n  [EXIT] Stopped by user.")
            break
