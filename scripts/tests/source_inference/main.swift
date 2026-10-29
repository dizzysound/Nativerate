import Foundation
// Run: scripts/tests/run.sh
var failed = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    if got != want { print("FAIL \(name): got \(got), want \(want)"); failed += 1 } else { print("ok   \(name)") }
}
let alone = { true }
let changed = { false }

// the first track after launch: no decoder line was ever seen, the source is unknown, the samples are off both grids
check("no decoder history is not lossy", SourceInference.offGridIsLossy(trackStartedLossy: false, sourceKnown: false, newestDecoderLossy: false, musicLeavesSamplesAlone: alone), false)
// Music reused a lossy decoder (AAC) for the track
check("reused lossy decoder is lossy", SourceInference.offGridIsLossy(trackStartedLossy: false, sourceKnown: false, newestDecoderLossy: true, musicLeavesSamplesAlone: alone), true)
// the reused AAC decoder, but Music's volume / Sound Check / Enhancer can change the samples
check("settings that change samples are not lossy", SourceInference.offGridIsLossy(trackStartedLossy: false, sourceKnown: false, newestDecoderLossy: true, musicLeavesSamplesAlone: changed), false)
// a stream that started on a lossy decoder stays lossy whatever else is known
check("started lossy is lossy", SourceInference.offGridIsLossy(trackStartedLossy: true, sourceKnown: true, newestDecoderLossy: false, musicLeavesSamplesAlone: changed), true)
// pastor Mac, Love In The Past Tense (24 bit, 96k): AAC start, then the lossless decoder took over. Plain 24-bit
// tracks there are off both grids too, so the start alone says nothing once the lossless decoder plays
check("lossless upgrade, settings change samples: not lossy", SourceInference.offGridIsLossy(trackStartedLossy: true, upgradedToLossless: true, sourceKnown: true, newestDecoderLossy: false, musicLeavesSamplesAlone: changed), false)
// the same, but nothing readable in Music changes samples: off every grid on the lossless decoder is still lossy
check("lossless upgrade, nothing changes samples: lossy", SourceInference.offGridIsLossy(trackStartedLossy: true, upgradedToLossless: true, sourceKnown: true, newestDecoderLossy: false, musicLeavesSamplesAlone: alone), true)
// a source a decoder line or the library already told is never turned lossy by the samples
check("known source is not guessed", SourceInference.offGridIsLossy(trackStartedLossy: false, sourceKnown: true, newestDecoderLossy: true, musicLeavesSamplesAlone: alone), false)
// the settings are only read when they can matter
var reads = 0
_ = SourceInference.offGridIsLossy(trackStartedLossy: false, sourceKnown: false, newestDecoderLossy: false, musicLeavesSamplesAlone: { reads += 1; return true })
check("settings not read without a lossy decoder", reads == 0, true)

// Music's Sound Check line (pastor Mac, macOS 27.2, 2026-10-29): on with a scalar below 1 scales the samples
let onLine = "2026-10-29 11:21:07.748 Df Music[37604:1d7372] [com.apple.coreaudio:aqme]        MEMixerChannel.cpp:4969  ionc@0x797c9b9400 offline false, Sound Check on, flags 0x0, err 0, scalar 0.434"
let offLine = "2026-10-29 10:59:02.100 Df Music[37604:1d7372] [com.apple.coreaudio:aqme]        MEMixerChannel.cpp:4969  ionc@0x797c9b9400 offline false, Sound Check off, flags 0x0, err 0, scalar 1.000"
check("Sound Check on line parses", SoundCheckLine.parse(onLine) == SoundCheckLine(on: true, scalar: 0.434), true)
check("Sound Check off line parses", SoundCheckLine.parse(offLine) == SoundCheckLine(on: false, scalar: 1.0), true)
check("other lines do not parse", SoundCheckLine.parse("MEMixerChannel.cpp:4476  mForceSoundCheck 0, gSoundCheckEnabled 1, mLoudnessDict {") == nil, true)
check("scalar 0.434 changes samples", SoundCheckLine(on: true, scalar: 0.434).changesSamples, true)
check("scalar 1.000 leaves samples alone", SoundCheckLine(on: true, scalar: 1.0).changesSamples, false)
let t0 = Date()
let scaled = SoundCheckLine(on: true, scalar: 0.434)
let unity = SoundCheckLine(on: true, scalar: 1.0)
var history = SoundCheckHistory()
check("no line: unknown", history.changesSamples() == nil, true)
history.record(scaled, at: t0)
check("a line but no track start: unknown", history.changesSamples() == nil, true)
check("latest is the newest line", history.latest == scaled, true)
history.trackStarted(at: t0.addingTimeInterval(2))
check("the line logged before the track started is its line", history.forTrack() == scaled, true)
// pre-roll: the next track's line (scalar 1.000) lands long before the current track ends
history.record(unity, at: t0.addingTimeInterval(200))
check("a later line is the next track's: the playing track stays scaled", history.changesSamples() == true, true)
check("the menu line stays the scaled one", history.forTrack() == scaled, true)
check("the switch reads from the newest line", history.latest == unity, true)
history.trackStarted(at: t0.addingTimeInterval(240))
check("the next track starts: its own line (pre-rolled) is unity", history.changesSamples() == false, true)
// a setup that comes after Playing
history.trackStarted(at: t0.addingTimeInterval(300))
history.record(scaled, at: t0.addingTimeInterval(302))
check("a line within the grace after the start is the track's", history.changesSamples() == true, true)
history.trackStarted(at: t0.addingTimeInterval(400))
history.record(scaled, at: t0.addingTimeInterval(410))
check("a line past the grace is the next track's", history.changesSamples() == true, true)
var late = SoundCheckHistory()
late.record(unity, at: t0)
late.trackStarted(at: t0.addingTimeInterval(100))
late.record(scaled, at: t0.addingTimeInterval(160))
check("the prior line, not a late one, stands for a track with none of its own", late.changesSamples() == false, true)
var both = SoundCheckHistory()
both.record(unity, at: t0)
both.trackStarted(at: t0.addingTimeInterval(1))
both.record(scaled, at: t0.addingTimeInterval(3))
check("scaled wins among the track's lines", both.changesSamples() == true, true)
check("and is the menu's line", both.forTrack() == scaled, true)
var quit = history
quit.clear()
check("after Music quits: nothing known", quit.changesSamples() == nil && quit.latest == nil && quit.forTrack() == nil, true)
quit.record(unity, at: t0.addingTimeInterval(500))
check("the new process's first line, no track yet: unknown, not the old scalar", quit.changesSamples() == nil, true)
quit.trackStarted(at: t0.addingTimeInterval(501))
check("then its own line decides", quit.changesSamples() == false, true)

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
