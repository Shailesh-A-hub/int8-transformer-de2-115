#!/usr/bin/env python3
"""
Raw Microphone Level Test
Tests if your mic is actually capturing audio at all.
Watch the LEVEL bar - it should move when you speak!
"""
import pyaudio
import struct
import math
import time

CHUNK = 1024
FORMAT = pyaudio.paInt16
CHANNELS = 1
RATE = 16000
DURATION = 10  # seconds to test

p = pyaudio.PyAudio()

# Print all INPUT devices
print("\n=== ALL INPUT DEVICES ===")
for i in range(p.get_device_count()):
    try:
        info = p.get_device_info_by_index(i)
        if info['maxInputChannels'] > 0:
            print(f"  [{i}] {info['name']}  (channels={info['maxInputChannels']}, rate={int(info['defaultSampleRate'])})")
    except:
        pass

# Try device index 1 (Realtek Microphone) - most common for your system
DEVICE_INDEX = 1
print(f"\n=== TESTING DEVICE [{DEVICE_INDEX}] for {DURATION} seconds ===")
print(">>> SPEAK LOUDLY into your mic and watch the LEVEL bar <<<\n")

try:
    stream = p.open(
        format=FORMAT,
        channels=CHANNELS,
        rate=RATE,
        input=True,
        input_device_index=DEVICE_INDEX,
        frames_per_buffer=CHUNK
    )

    start = time.time()
    max_seen = 0
    while time.time() - start < DURATION:
        data = stream.read(CHUNK, exception_on_overflow=False)
        samples = struct.unpack('<' + 'h' * CHUNK, data)
        peak = max(abs(s) for s in samples)
        rms = math.sqrt(sum(s*s for s in samples) / CHUNK)
        max_seen = max(max_seen, peak)

        bar_len = int(rms / 500)
        bar = '#' * min(bar_len, 40)
        status = "<<< DETECTED!" if rms > 200 else "        (silence)"
        print(f"\r  Level: [{bar:<40}] RMS={int(rms):5d}  {status}", end="", flush=True)

    stream.stop_stream()
    stream.close()
    print(f"\n\n=== RESULT ===")
    print(f"  Max peak seen: {max_seen}")
    if max_seen < 500:
        print("  ❌ No audio captured! Mic is NOT working.")
        print("     Try these fixes:")
        print("     1. Windows Settings > Privacy > Microphone > Allow apps: ON")
        print("     2. Right-click speaker icon > Sounds > Recording > set Microphone as Default")
        print("     3. Check mic is not muted (look for mic icon in taskbar)")
    else:
        print("  ✅ Mic IS capturing audio! Google STT should work.")

except Exception as e:
    print(f"\n  ❌ Cannot open device [{DEVICE_INDEX}]: {e}")
    print("  Try changing DEVICE_INDEX at the top of this script to another input device number.")

p.terminate()
