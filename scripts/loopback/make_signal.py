#!/usr/bin/env python3
"""Make bit-perfect loopback test files (GIL-391).

Layout per file (stereo, L and R get different noise):
  0.5 s silence | impulse | 4096-sample marker noise | 10 s white noise |
  2 s -60 dBFS 1 kHz sine | 0.5 s silence

Usage: make_signal.py [outdir]   -> writes ref_<rate>_<bits>.wav
"""
import math, os, random, sys
import wavio

RATES = [44100, 48000, 88200, 96000, 176400, 192000]
DEPTHS = [16, 24]
SEED = 391
MARKER_LEN = 4096

def build(rate, bits, seed=SEED):
    full = (1 << (bits - 1)) - 1
    rng = random.Random(seed * 1000003 + rate * 31 + bits)
    noise = lambda: (rng.randint(-full - 1, full), rng.randint(-full - 1, full))
    sil = [(0, 0)] * (rate // 2)
    frames = list(sil)
    frames.append((full, full))                      # impulse
    frames += [noise() for _ in range(MARKER_LEN)]   # alignment marker
    frames += [noise() for _ in range(rate * 10)]    # body noise
    amp = full * 10 ** (-60 / 20)
    frames += [(round(amp * math.sin(2 * math.pi * 1000 * i / rate)),) * 2
               for i in range(rate * 2)]             # low-level sine
    frames += sil
    return frames

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "loopback_signals"
    os.makedirs(out, exist_ok=True)
    for bits in DEPTHS:
        for rate in RATES:
            path = os.path.join(out, f"ref_{rate}_{bits}.wav")
            wavio.write(path, rate, bits, build(rate, bits))
            print(path)

if __name__ == "__main__":
    main()
