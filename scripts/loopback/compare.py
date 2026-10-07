#!/usr/bin/env python3
"""Compare a loopback recording with its reference file, sample by sample (GIL-391).

Usage: compare.py ref_<rate>_<bits>.wav recording.wav [--channels 1,2] [--tolerance N] [--probe]

Finds the reference's marker (impulse + 4096 noise samples) in the recording by
exact match, then compares every sample of the lead-in silence, the signal and the
tail silence. Silence must be exactly zero.
A 16-bit reference recorded at 24-bit must have zero low 8 bits in every compared frame.
--channels picks which recording channels (1-based) carry the loopback L,R.
--tolerance N accepts a deviation of up to N LSB and labels the result "not bit-perfect".
  macOS 26 Music scales its output by about 0.99999997, which is up to 1 LSB at 24-bit.
--probe only locates the marker (used to find the loopback channel pair).
Exit code 0 = PASS (or LOCATED with --probe), 1 = samples differ, 2 = marker not found / format error.
"""
import argparse, sys
import wavio

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("rec")
    ap.add_argument("--channels", default="1,2")
    ap.add_argument("--tolerance", type=int, default=0)
    ap.add_argument("--probe", action="store_true")
    a = ap.parse_args()
    cl, cr = (int(c) - 1 for c in a.channels.split(","))

    rrate, _, rbits, ref = wavio.read(a.ref)
    try:
        crate, cch, cbits, cap = wavio.read(a.rec, (cl, cr))
    except ValueError as e:
        print(f"FAIL: {e}"); return 2
    if crate != rrate:
        print(f"FAIL: rate mismatch, ref {rrate} Hz, recording {crate} Hz"); return 2
    # Bring the recording to the reference depth. Extra low bits are checked below.
    shift = cbits - rbits
    if shift < 0:
        print(f"FAIL: recording is {cbits}-bit, reference {rbits}-bit"); return 2
    mask = (1 << shift) - 1

    start = next(i for i, fr in enumerate(ref) if fr != (0, 0))  # impulse
    end = max(i for i, fr in enumerate(ref) if fr != (0, 0)) + 1
    marker = ref[start:start + 4097]
    imp = ref[start]
    shifted = lambda fr: (fr[0] >> shift, fr[1] >> shift)
    off = None
    for i in range(len(cap) - len(marker) + 1):
        if shifted(cap[i]) == imp and [shifted(f) for f in cap[i:i + len(marker)]] == marker:
            off = i - start; break
    if off is None:
        print("FAIL: marker not found (wrong channels, gain not at unity, an effect in the path, "
              "or not bit-perfect)")
        return 2
    if a.probe:
        print(f"LOCATED: marker at frame {off + start} on channels {a.channels}")
        return 0

    # Lead-in and tail silence belong to the test: the whole reference length must be present.
    if off < 0:
        print(f"FAIL: recording starts {-off} frames inside the lead-in, silence cannot be verified"); return 2
    if off + len(ref) > len(cap):
        print(f"FAIL: recording ends {off + len(ref) - len(cap)} frames too early"); return 2
    bad, first, maxd, lowbits = 0, None, 0, 0
    for i in range(len(ref)):
        fr = cap[i + off]
        if (fr[0] & mask) or (fr[1] & mask):
            lowbits += 1
        for c in (0, 1):
            d = abs((fr[c] >> shift) - ref[i][c])
            if d:
                bad += 1; maxd = max(maxd, d)
                if first is None:
                    first = (i - start, c, "silence" if i < start or i >= end else "signal")
    n = len(ref) * 2
    print(f"rate {rrate} Hz, {rbits}-bit, offset {off + start} frames, {n} samples compared "
          f"(lead-in, signal and tail)")
    fail = False
    if lowbits:
        print(f"FAIL: {lowbits} recorded frames had non-zero bits below {rbits}-bit "
              f"(dither or a 24-bit path for a {rbits}-bit file)")
        fail = True
    if bad:
        print(f"{'FAIL' if maxd > a.tolerance else 'note'}: {bad} samples differ, first at frame "
              f"{first[0]} ch {'LR'[first[1]]} ({first[2]}), max {maxd} LSB")
        fail = fail or maxd > a.tolerance
    if fail:
        return 1
    if bad:
        print(f"PASS (within {a.tolerance} LSB tolerance, NOT bit-perfect): max deviation {maxd} LSB")
    else:
        print("PASS: bit-perfect")
    return 0

if __name__ == "__main__":
    sys.exit(main())
