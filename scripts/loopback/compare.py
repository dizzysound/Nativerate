#!/usr/bin/env python3
"""Compare a loopback recording with its reference file, sample by sample (GIL-391).

Usage: compare.py ref_<rate>_<bits>.wav recording.wav [--channels 1,2]

Finds the reference's marker (impulse + 4096 noise samples) in the recording by
exact match, then compares every sample from the impulse to the end of the sine.
Exit code 0 = bit-perfect, 1 = differences, 2 = marker not found / format error.
--channels picks which recording channels (1-based) carry the loopback L,R.
"""
import argparse, sys
import wavio

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("rec")
    ap.add_argument("--channels", default="1,2")
    a = ap.parse_args()
    cl, cr = (int(c) - 1 for c in a.channels.split(","))

    rrate, _, rbits, ref = wavio.read(a.ref)
    crate, cch, cbits, rec = wavio.read(a.rec)
    if crate != rrate:
        print(f"FAIL: rate mismatch, ref {rrate} Hz, recording {crate} Hz"); return 2
    # Bring the recording to the reference depth. Extra low bits must be zero.
    shift = cbits - rbits
    if shift < 0:
        print(f"FAIL: recording is {cbits}-bit, reference {rbits}-bit"); return 2
    mask = (1 << shift) - 1
    lowbits = 0
    cap = []
    for fr in rec:
        l, r = fr[cl], fr[cr]
        if (l & mask) or (r & mask):
            lowbits += 1
        cap.append((l >> shift, r >> shift))

    start = next(i for i, fr in enumerate(ref) if fr != (0, 0))  # impulse
    end = max(i for i, fr in enumerate(ref) if fr != (0, 0)) + 1
    marker = ref[start:start + 4097]
    imp = ref[start]
    off = None
    for i in range(len(cap) - len(marker) + 1):
        if cap[i] == imp and cap[i:i + len(marker)] == marker:
            off = i - start; break
    if off is None:
        print("FAIL: marker not found (wrong channels, gain not at unity, or not bit-perfect)")
        return 2

    body = range(start, end)
    if off + end > len(cap):
        print(f"FAIL: recording ends {off + end - len(cap)} frames too early"); return 2
    bad, first, maxd = 0, None, 0
    for i in body:
        for c in (0, 1):
            d = abs(cap[i + off][c] - ref[i][c])
            if d:
                bad += 1; maxd = max(maxd, d)
                if first is None: first = (i - start, c)
    n = len(body) * 2
    print(f"rate {rrate} Hz, {rbits}-bit, offset {off + start} frames, {n} samples compared")
    if lowbits:
        print(f"note: {lowbits} recorded frames had non-zero bits below {rbits}-bit (dither?)")
    if bad:
        print(f"FAIL: {bad} samples differ, first at frame {first[0]} ch {'LR'[first[1]]}, max {maxd} LSB")
        return 1
    print("PASS: bit-perfect")
    return 0

if __name__ == "__main__":
    sys.exit(main())
