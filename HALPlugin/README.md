# LSOutput.driver: Exclusive Mode's virtual output device

An AudioServerPlugIn (HAL plug-in) based on Apple's NullAudio sample (MIT, LICENSE-NullAudio.txt).
It shows up as **Nativerate** in Audio MIDI Setup: a 2-channel output whose mix is looped
back to its input, at 44.1-192 kHz, with a clock the renderer steers to the DAC. The input has 4
channels (1.1.4): 1-2 the mix (Music alone while `'LSmx'` is set), 3-4 every other app's output.

Custom properties (CFNumber / CFDictionary, device object):
- `'LSrs'` rate scalar (AudioTimeStamp.mRateScalar meaning, 0.99-1.01): the clock lock
- `'LSst'` status snapshot (clock, loopback counters)
- `'LShd'` hold experiments (research only; unused by the engine)
- `'LSac'` attached renderer pid (0 = none). The device can be the **default output only while a
  renderer is attached**; it is cleared when that process stops being a client of the device.
  Never the default input (the loopback) or the alert-sound device.
- `'LSmx'` Music's pid (1.1.4; 0 = off, as 1.1.3). In ProcessOutput (per client, before the HAL's
  mix) every client of another pid is summed into a second ring and zeroed, so the mix is exactly
  Music's; that ring is read back on input channels 3-4. Cleared when the renderer detaches.
  `'LSst'` counts it (processOutputCalls, musicClientCalls, othersFramesMoved, musicPID; 1.1.5 adds
  othersPeakIn / othersPeakRead, reset on each read, and othersMaxTimeDelta / othersTimeDeltaCycles).
  1.1.5: a client's frames are added unless they lie past everything written so far (then they
  replace an old lap); 1.1.4 replaced on each new sample time and lost other apps' audio.
- `'LSlt'` latency in frames (1.1.6; 0 = none): what the renderer adds after the loopback (its ring to
  the DAC, ~0.35 s). The output scope reports it as kAudioDevicePropertyLatency so video stays in
  sync. Cleared when the renderer detaches.

Build: `./build.sh` (clang, ad-hoc signed; the app's build scripts run it and copy the bundle into
Contents/Resources). Test in-process before installing: `clang -O1 -o harness harness.c -framework
CoreAudio -framework CoreFoundation && ./harness LSOutput.driver`. Install/update/remove from the app
(menu "Settings > Exclusive Mode driver", one administrator prompt, restarts coreaudiod) or by hand:
`sudo ditto LSOutput.driver /Library/Audio/Plug-Ins/HAL/LSOutput.driver && sudo killall coreaudiod`.
Research history: github.com/dizzysound/music-tap-spike (branch vdevice), vdev/.
