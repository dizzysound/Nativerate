# Bit-perfect loopback test (GIL-391)

Stdlib Python 3 only. No numpy needed.

## Set up (RME Babyface Pro FS + TotalMix FX)
1. In TotalMix, on the output channel pair Nativerate plays to (for example AN 1/2), click **Loopback** in the channel settings. Its signal now goes to the matching input pair.
2. Set the playback fader for that pair to 0 dB. No EQ, no dynamics, no room FX.
3. In Audio MIDI Setup, set Babyface to the test rate and 24-bit.

## Run
```sh
python3 make_signal.py signals          # writes signals/ref_<rate>_<bits>.wav
```
For each file:
1. Start recording the loopback input at the same rate, 24-bit WAV, for example:
   `sox -t coreaudio "Babyface Pro" -b 24 -r 96000 rec_96000_24.wav`
   (or Audacity / QuickTime).
2. Play `ref_<rate>_<bits>.wav` through Nativerate, volume at unity. Stop the recording after it ends.
3. Compare:
   `python3 compare.py signals/ref_96000_24.wav rec_96000_24.wav --channels 1,2`

`--channels` = the 1-based recorded channels that carry the loopback L,R.
Exit 0 = PASS, 1 = samples differ, 2 = marker not found.

A 16-bit file recorded at 24-bit passes only if the low 8 bits are zero.
For the rate-switch check, play two files at different rates back to back while one recording runs at the second rate, then compare against the second file.
