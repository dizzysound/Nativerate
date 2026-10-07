# Bit-perfect loopback test (GIL-391)

Plays test files through Music and Nativerate into an RME Babyface Pro FS, records the digital
loopback with `rec.swift`, and compares every sample. Stdlib Python 3 plus `swiftc`; no sox, no numpy.

## Requirements
- A Mac with a Babyface Pro FS and TotalMix FX. Run in Terminal on that Mac, not over SSH
  (macOS gives SSH sessions silence from audio inputs).
- macOS 15 or earlier, or 27 or later, for a strict bit-perfect result. On macOS 26 only, Music
  scales its output by about 0.99999997 (up to 1 LSB at 24-bit), so no run is exactly bit-perfect
  there. `run_all.sh` then sets `TOL=1` and labels passes "within tolerance, not bit-perfect".
- Nativerate running, **Exclusive Mode on and Integer Mode on** (Integer Mode is off by default; without it the DAC stays float and the format check reports FAIL), the Babyface chosen as Music's output.

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
`rec/rec_<rate>_<bits>.wav` before each case, records, plays via AppleScript to Music, samples every output
stream of the device during the recording and checks that one was the case's rate and depth (integer),
compares (a format FAIL does not skip the compare; the summary shows both results), and prints a summary table.
It exits non-zero if any case failed. `PLAYER=manual` has you press play in Music yourself.
`PLAYER=afplay` bypasses Music and Nativerate and is only a harness smoke test.

Manual steps for one file: `swiftc -O rec.swift -o recorder`; `./recorder "Babyface Pro" 96000 20 rec/rec_96000_24.wav 24`
(last argument = expected output bits, optional); play `signals/ref_96000_24.wav` in Music;
`python3 compare.py signals/ref_96000_24.wav rec/rec_96000_24.wav --channels 1,2`.

## Rate priming and the recorder
Nativerate switches the DAC rate when playback starts, so `run_all.sh` first starts the file in
Music, waits until the device reports the case rate (`./recorder DEV RATE --wait-rate`), stops Music,
and only then starts the recorder, which itself also waits up to 30 s for the rate. If the rate falls
back after Music stops, the recording may start late and compare reports "starts inside the lead-in".
The recorder exits 2 on timeout or a file write error. Unverified until the hardware run: whether a
second process can open the input of a device Nativerate holds in Exclusive Mode (hog). If it cannot,
the recorder fails at "cannot select device" or records silence, and the marker search fails.

## What compare.py checks
- Marker (impulse + 4096 noise samples) found by exact match, then every sample from the start of the
  file to its end: lead-in silence, signal, tail silence. Silence must be exactly zero.
- A 16-bit file recorded at 24-bit: any non-zero low 8 bits in a compared frame is a FAIL.
- `--tolerance N` accepts up to N LSB and prints "NOT bit-perfect". `--probe` only locates the marker.
Exit 0 = PASS, 1 = samples differ, 2 = marker not found / format error.

## Controls
- **Positive control:** a normal 24-bit run at a rate you trust (44.1 kHz) must PASS before you
  believe a FAIL elsewhere.
- **Negative control:** `CONTROL=neg ./run_all.sh 96000` runs one case twice. It first finds the pair
  and must PASS at 0 dB, then asks you to set the TotalMix output fader to -0.1 dB and runs it again;
  compare must exit 1 (samples differ). A marker or format error (exit 2) does not count. It then
  asks you to put the fader back to 0 dB.

## Not scripted yet
Rate switch (play two files at different rates back to back with one recording running) is still a
manual check; see the PR for the follow-up.
