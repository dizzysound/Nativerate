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

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
