# Bit-perfect loopback test

Plays test files through Music and Nativerate into an RME Babyface Pro FS, records the digital
loopback with `rec.swift`, and compares every sample. Stdlib Python 3 plus `swiftc`; no sox, no numpy.

## Result
**Bit-perfect: all 12 cases pass with 0 differing samples** (44.1, 48, 88.2, 96, 176.4 and 192 kHz,
16 and 24 bit). Babyface Pro FS with its optical output cabled to its optical input, Nativerate in
Exclusive Mode. The audio leaves the interface as real S/PDIF and comes back unchanged.

## Requirements
- A Mac with a Babyface Pro FS and TotalMix FX. Run in Terminal on that Mac, not over SSH
  (macOS gives SSH sessions silence from audio inputs).
- macOS 15 or earlier, or 27 or later, for a strict bit-perfect result. On macOS 26 only, Music
  scales its output by about 0.99999997 (up to 1 LSB at 24-bit), so no run is exactly bit-perfect
  there. `run_all.sh` then sets `TOL=1` and labels passes "within tolerance, not bit-perfect".
- A Nativerate build that has Integer Mode (branch `feat/16bit-exclusive` or later; main does not have it yet, and on a main build the format check always FAILs on a DAC that offers integer formats).
- Nativerate running, **Exclusive Mode on and Integer Mode on** (Integer Mode is off by default; without it the DAC stays float and the format check reports FAIL), the Babyface chosen as Music's output.
- A DAC with no integer output format (for example the Babyface on macOS 27 per Nativerate's menu, which shows no Integer Mode) reports `format SKIP`, and the sample compare still runs. A DAC that offers integer formats but not 16-bit makes the 16-bit cases report `format FAIL`: Nativerate then logs "no 16-bit integer format" and keeps the current format, which is correct behavior.

## Set up
1. TotalMix: on the output pair Music plays to (for example AN 1/2), click **Loopback** in the
   channel settings (for an optical self-loop, see below: Loopback stays off). Its signal goes to the matching input pair.
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

## Optical self-loop on the Babyface (setup used for the result)
1. Cable the Babyface optical out to its optical in.
2. TotalMix Settings: optical out and in = **SPDIF** (ADAT cannot carry 176.4/192 kHz), clock **Internal**.
3. Loopback **off** on every output.
4. Select the SPDIF output. Software playback AN 1/2 send **0.0**; every hardware input **-oo**,
   the optical input too (else it feeds back). SPDIF output fader **0.0**, EQ off.
5. Run `./run_all.sh`. The marker search finds the optical pair (inputs 5/6) by itself.

## Testing a second DAC
Two environment variables: `DEV` is the **input** that is recorded (the Babyface), `OUT_DEV` is the
**output** DAC whose rate and format are checked and which Music plays to. Pick the case that matches
the DAC.

**(a) DAC with a digital output (optical/coax)**
1. Cable the DAC's optical out to the Babyface optical in. In TotalMix FX set the Babyface clock
   source to Optical/S/PDIF (Settings), and make sure the optical input is the pair you record.
2. Choose the DAC as Music's output (Nativerate on that DAC, Exclusive and Integer Mode as above).
3. Run `OUT_DEV="<DAC name>" DEV="Babyface Pro" ./run_all.sh`. The recorder records the Babyface
   inputs (the optical pair among them), the format check reads the DAC's output stream, and the same
   marker search and sample compare run. No TotalMix loopback is needed; the pair is found by the marker.
4. Limits: many optical (S/PDIF) ports stop at 96 kHz (the Babyface does 192 kHz). If yours does,
   run only rates up to 96000 (`./run_all.sh 44100 48000 96000`) and 24-bit or 16-bit. If the DAC's volume is not fixed or its
   digital out is processed, expect sample differences that are not Nativerate's.

**(b) Analog-only DAC (no digital out, no cable)**
There is nothing to record, so only the output-format check runs (Integer Mode 16-bit and 24-bit):
```sh
FORMAT_ONLY=1 OUT_DEV="<DAC name>" ./run_all.sh
```
`FORMAT_ONLY=1` skips the recorder and the sample compare. It plays each file through Music and samples
the DAC's output stream format while it plays; the summary reads `samples not run (FORMAT_ONLY); format OK`
(or `format FAIL` / `format SKIP` for a float-only DAC). It cannot show bit-perfect samples, only that
the DAC was put in the integer format at the right rate and depth. It cannot be combined with
`CONTROL=neg`.

## Rate priming and the recorder
Nativerate switches the DAC rate when playback starts, so `run_all.sh` first starts the file in
Music, waits until the device reports the case rate (`./recorder DEV RATE --wait-rate`), stops Music,
and only then starts the recorder. Music acts on the stop a couple of seconds late, so the script polls until
the player state is `stopped`, waits 1 s more, and fails the case with `FAIL prime stop` if Music never stops.
The recorder itself also waits up to 30 s for the rate. If the rate falls
back after Music stops, the recording may start late and compare reports "starts inside the lead-in".
The recorder exits 2 on timeout or a file write error. The hardware run confirmed that the recorder
can open the Babyface input while Nativerate holds the device in Exclusive Mode.

Tip: a constant level error (for example -64 dB) means a TotalMix fader or send is not at 0.0.

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
Rate switch (play two files at different rates back to back with one recording running) has not
been run yet, scripted or by hand.
