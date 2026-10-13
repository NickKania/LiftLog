"""Generate Lift Log's original two-note chime (mono, 16-bit PCM WAV)."""

import math
from pathlib import Path
import struct
import wave


def main():
    sample_rate = 44100
    duration = 1.1
    notes = [(0.0, 1046.502), (0.22, 1318.510)]
    frames = bytearray()
    for index in range(round(duration * sample_rate)):
        time = index / sample_rate
        sample = 0.0
        for onset, frequency in notes:
            elapsed = time - onset
            if elapsed < 0:
                continue
            envelope = min(1.0, elapsed / 0.008) * math.exp(-elapsed * 7)
            fade_out = min(1.0, (duration - time) / 0.08)
            fundamental = math.sin(2 * math.pi * frequency * elapsed)
            overtone = 0.2 * math.sin(2 * math.pi * frequency * 2 * elapsed)
            sample += 0.3 * envelope * fade_out * (fundamental + overtone)
        frames.extend(struct.pack("<h", round(sample * 32767)))

    output = Path(__file__).resolve().parents[1] / "LiftLog/App/Resources/rest-complete.wav"
    output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output), "wb") as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(sample_rate)
        sound.writeframes(frames)


if __name__ == "__main__":
    main()
