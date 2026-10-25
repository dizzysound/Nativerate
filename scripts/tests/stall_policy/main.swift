import Foundation
// Run: scripts/tests/run.sh
var failed = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got != want { print("FAIL \(name): got \(got), want \(want)"); failed += 1 } else { print("ok   \(name)") }
}

// a DAC that settles within the first wait costs no extra wait
var waits: [TimeInterval] = [], said = 0
var ready = StallPolicy.settle(first: 12, attempt: { waits.append($0); return true }, stillWaiting: { said += 1 })
check("ready at once", ready, true)
check("ready at once: one wait", waits, [12])
check("ready at once: nothing said", said, 0)

// a DAC that settles during the extra wait (the MT 48 restart loop ended after 45-55 s)
waits = []; said = 0
var calls = 0
ready = StallPolicy.settle(first: 12, attempt: { waits.append($0); calls += 1; return calls == 2 }, stillWaiting: { said += 1 })
check("settles late", ready, true)
check("settles late: waits", waits, [12, StallPolicy.dacSettleExtraWait])
check("settles late: said once", said, 1)

// a DAC that never settles: gives up after the extra wait, so the switch still ends
waits = []; said = 0
ready = StallPolicy.settle(first: 12, attempt: { waits.append($0); return false }, stillWaiting: { said += 1 })
check("never settles", ready, false)
check("never settles: two waits", waits, [12, StallPolicy.dacSettleExtraWait])
check("never settles: said once", said, 1)

// the extra wait covers the longest restart loop seen (54.8 s from the switch request, 12 s already waited)
check("extra wait covers 54.8 s", 12 + StallPolicy.dacSettleExtraWait >= 54.8, true)

// a ring at its target locks as it is; a full ring (10.9 s at 96 kHz, target 0.5 s) is cut back
check("normal fill", StallPolicy.shouldTrimBeforeLock(fill: 47616, target: 48000, boundaryPending: false), false)
check("twice the target", StallPolicy.shouldTrimBeforeLock(fill: 96000, target: 48000, boundaryPending: false), false)
check("past twice the target", StallPolicy.shouldTrimBeforeLock(fill: 96001, target: 48000, boundaryPending: false), true)
check("full ring", StallPolicy.shouldTrimBeforeLock(fill: 1048576, target: 48000, boundaryPending: false), true)
check("full ring, boundary pending", StallPolicy.shouldTrimBeforeLock(fill: 1048576, target: 48000, boundaryPending: true), false)
check("no target", StallPolicy.shouldTrimBeforeLock(fill: 1048576, target: 0, boundaryPending: false), false)

// turned off during the first wait: no "still waiting" line, no extra wait
waits = []; said = 0
ready = StallPolicy.settle(first: 12, cancelled: { true }, attempt: { waits.append($0); return false }, stillWaiting: { said += 1 })
check("cancelled", ready, false)
check("cancelled: one wait", waits, [12])
check("cancelled: nothing said", said, 0)

// the listener's play and pause while Music is held paused
let t0 = Date(timeIntervalSinceReferenceDate: 1000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
var w = StallPolicy.ListenerWatch(startedAt: at(0))
check("untouched: no re-pause", w.observe(playing: false, lastNoticeAt: at(-5), now: at(1)), false)
check("untouched: not paused by listener", w.listenerPaused, false)

// the Playing that brought the switch here (before it started) is not the listener playing during it
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("old Playing: no re-pause", w.observe(playing: true, lastNoticeAt: at(-1), now: at(0.1)), false)
check("old Playing: its echo, then nothing", w.observe(playing: false, lastNoticeAt: at(0.05), now: at(0.2)), false)
check("old Playing: not a play", w.listenerPaused, false)

// play: paused again once, not on every poll; the echo of our pause is not a listener pause
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("play: paused again", w.observe(playing: true, lastNoticeAt: at(10), now: at(10)), true)
check("play: not again at once", w.observe(playing: true, lastNoticeAt: at(10), now: at(10.01)), false)
check("play: echo", w.observe(playing: false, lastNoticeAt: at(10.2), now: at(10.3)), false)
check("play: later poll", w.observe(playing: false, lastNoticeAt: at(10.2), now: at(12)), false)
check("play only: plays at the end", w.listenerPaused, false)

// play, then pause (the reviewer's sequence): stays paused
check("pause after play", w.observe(playing: false, lastNoticeAt: at(20), now: at(20.01)), false)
check("pause after play: listener paused", w.listenerPaused, true)

// play again after that: wants playback again
check("play again", w.observe(playing: true, lastNoticeAt: at(30), now: at(30)), true)
check("play again: plays at the end", w.listenerPaused, false)

// play, our pause, its echo, and the listener's pause inside the echo window of our pause (re-review)
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("quick pause: paused again", w.observe(playing: true, lastNoticeAt: at(10), now: at(10.02)), true)
check("quick pause: our echo", w.observe(playing: false, lastNoticeAt: at(10.1), now: at(10.15)), false)
check("quick pause: still ours", w.listenerPaused, false)
check("quick pause: listener's pause", w.observe(playing: false, lastNoticeAt: at(10.6), now: at(10.65)), false)
check("quick pause: listener paused", w.listenerPaused, true)
check("quick pause: stays so on later polls", w.observe(playing: false, lastNoticeAt: at(10.6), now: at(13)) == false && w.listenerPaused, true)

// the switch's own pause echoes after the listener's play: both echoes are ours
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("two echoes: play", w.observe(playing: true, lastNoticeAt: at(0.1), now: at(0.12)), true)
check("two echoes: switch's echo", w.observe(playing: false, lastNoticeAt: at(0.2), now: at(0.22)), false)
check("two echoes: re-pause's echo", w.observe(playing: false, lastNoticeAt: at(0.25), now: at(0.27)), false)
check("two echoes: not a listener pause", w.listenerPaused, false)

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
