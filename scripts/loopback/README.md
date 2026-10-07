# Bit-perfect loopback test (GIL-391)

Plays test files through Music and Nativerate into an RME Babyface Pro FS, records the digital
loopback with `rec.swift`, and compares every sample. Stdlib Python 3 plus `swiftc`; no sox, no numpy.

## Requirements
- A Mac with a Babyface Pro FS and TotalMix FX. Run in Terminal on that Mac, not over SSH
  (macOS gives SSH sessions silence from audio inputs).
- macOS 25 or earlier for a strict bit-perfect result. On macOS 26 Music scales its output by
  about 0.99999997 (up to 1 LSB at 24-bit), so no run is exactly bit-perfect there. `run_all.sh`
  then sets `TOL=1` and labels passes "within tolerance, not bit-perfect".
- Nativerate running, **Exclusive Mode on**, the Babyface chosen as Music's output.

## Set up
1. TotalMix: on the output pair Music plays to (for example AN 1/2), click **Loopback** in the
   channel settings. Its signal goes to the matching input pair.
2. TotalMix: output fader for that pair at 0 dB. No EQ, no dynamics (compressor/expander/autolevel),
   no room FX, no trim on the loopback input.
3. Music: volume at maximum, Sound Check off, Sound Enhancer off, EQ off, crossfade off.
4. Audio MIDI Setup: leave the rate to Nativerate.

## Run
```sh
./run_all.sh              # all rates, 24-bit then 16-bit, played through Music
./run_all.sh 96000        # one rate
```
`run_all.sh` builds `recorder` from `rec.swift`, makes `signals/`, deletes the old
`rec/rec_<rate>_<bits>.wav` before each case, records, plays via AppleScript to Music, asserts the
device's output stream is the case's rate and depth (integer), compares, and prints a summary table.
It exits non-zero if any case failed. `PLAYER=manual` has you press play in Music yourself.
`PLAYER=afplay` bypasses Music and Nativerate and is only a harness smoke test.

Manual steps for one file: `swiftc -O rec.swift -o recorder`; `./recorder "Babyface Pro" 96000 20 rec/rec_96000_24.wav 24`
(last argument = expected output bits, optional); play `signals/ref_96000_24.wav` in Music;
`python3 compare.py signals/ref_96000_24.wav rec/rec_96000_24.wav --channels 1,2`.

## What compare.py checks
- Marker (impulse + 4096 noise samples) found by exact match, then every sample from the start of the
  file to its end: lead-in silence, signal, tail silence. Silence must be exactly zero.
- A 16-bit file recorded at 24-bit: any non-zero low 8 bits in a compared frame is a FAIL.
- `--tolerance N` accepts up to N LSB and prints "NOT bit-perfect". `--probe` only locates the marker.
Exit 0 = PASS, 1 = samples differ, 2 = marker not found / format error.

## Controls
- **Positive control:** a normal 24-bit run at a rate you trust (44.1 kHz) must PASS before you
  believe a FAIL elsewhere.
- **Negative control:** set the TotalMix output fader to -0.1 dB and run `CONTROL=neg ./run_all.sh 96000`.
  The case must FAIL; the run is OK only if it does. Put the fader back to 0 dB afterwards.

## Not scripted yet
Rate switch (play two files at different rates back to back with one recording running) is still a
manual check; see the PR for the follow-up.
