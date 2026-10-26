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
check("untouched: no re-pause", w.observe(notices: [(playing: false, at: at(-5))], now: at(1)), false)
check("untouched: not paused by listener", w.listenerPaused, false)

// the Playing that brought the switch here (before it started) is not the listener playing during it
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("old Playing: no re-pause", w.observe(notices: [(playing: true, at: at(-1))], now: at(0.1)), false)
check("old Playing: its echo, then nothing", w.observe(notices: [(playing: false, at: at(0.05))], now: at(0.2)), false)
check("old Playing: not a play", w.listenerPaused, false)

// play: paused again once, not on every poll; the echo of our pause is not a listener pause
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("play: paused again", w.observe(notices: [(playing: true, at: at(10))], now: at(10)), true)
check("play: not again at once", w.observe(notices: [], now: at(10.01)), false)
check("play: echo", w.observe(notices: [(playing: false, at: at(10.2))], now: at(10.3)), false)
check("play: later poll", w.observe(notices: [], now: at(12)), false)
check("play only: plays at the end", w.listenerPaused, false)

// play, then pause (the reviewer's sequence): stays paused
check("pause after play", w.observe(notices: [(playing: false, at: at(20))], now: at(20.01)), false)
check("pause after play: listener paused", w.listenerPaused, true)

// play again after that: wants playback again
check("play again", w.observe(notices: [(playing: true, at: at(30))], now: at(30)), true)
check("play again: plays at the end", w.listenerPaused, false)

// play, our pause, its echo, and the listener's pause inside the echo window of our pause (re-review)
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("quick pause: paused again", w.observe(notices: [(playing: true, at: at(10))], now: at(10.02)), true)
check("quick pause: our echo", w.observe(notices: [(playing: false, at: at(10.1))], now: at(10.15)), false)
check("quick pause: still ours", w.listenerPaused, false)
check("quick pause: listener's pause", w.observe(notices: [(playing: false, at: at(10.6))], now: at(10.65)), false)
check("quick pause: listener paused", w.listenerPaused, true)
check("quick pause: stays so on later polls", w.observe(notices: [], now: at(13)) == false && w.listenerPaused, true)

// the switch's own pause echoes before the listener's play (Music posts in order); then the re-pause's echo
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("two echoes: switch's echo", w.observe(notices: [(playing: false, at: at(0.05))], now: at(0.06)), false)
check("two echoes: play", w.observe(notices: [(playing: true, at: at(0.1))], now: at(0.12)), true)
check("two echoes: re-pause's echo", w.observe(notices: [(playing: false, at: at(0.25))], now: at(0.27)), false)
check("two echoes: not a listener pause", w.listenerPaused, false)

// Music playing at the start, the switch's own pause posted no notice: the listener's play and pause, in
// one batch or apart, are not taken for its echo (Review 7)
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("no switch echo: batch ends paused", w.observe(notices: [(playing: true, at: at(0.3)), (playing: false, at: at(0.6))], now: at(0.7)), false)
check("no switch echo: listener paused", w.listenerPaused, true)
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("no switch echo, apart: play", w.observe(notices: [(playing: true, at: at(0.3))], now: at(0.31)), true)
check("no switch echo, apart: re-pause's echo", w.observe(notices: [(playing: false, at: at(0.4))], now: at(0.41)), false)
check("no switch echo, apart: not yet", w.listenerPaused, false)
check("no switch echo, apart: listener's pause", w.observe(notices: [(playing: true, at: at(5)), (playing: false, at: at(5.5))], now: at(5.6)), false)
check("no switch echo, apart: listener paused", w.listenerPaused, true)

// a re-pause's echo that comes after the old echo window, while the DAC is still waiting, is still ours
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("late echo: switch's echo", w.observe(notices: [(playing: false, at: at(0.05))], now: at(0.06)), false)
check("late echo: play", w.observe(notices: [(playing: true, at: at(10))], now: at(10.01)), true)
check("late echo: echo 3 s later", w.observe(notices: [(playing: false, at: at(13))], now: at(13.01)), false)
check("late echo: not a listener pause", w.listenerPaused, false)
check("late echo: stays so", w.observe(notices: [], now: at(20)) == false && w.listenerPaused, false)

// a play and a pause that arrive in one batch (the reviewer's case): the listener's pause stands
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("batch: no re-pause (it ends paused)", w.observe(notices: [(playing: true, at: at(10)), (playing: false, at: at(10.6))], now: at(10.7)), false)
check("batch: listener paused", w.listenerPaused, true)

// a batch that ends playing is paused again, and the listener has not paused
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("batch: pause, play: paused again", w.observe(notices: [(playing: false, at: at(10)), (playing: true, at: at(10.6))], now: at(10.7)), true)
check("batch: pause, play: not a listener pause", w.listenerPaused, false)

// the switch's tap runs from its first line: the echo of its own pause, then a listener play and pause in
// the boundary wait or the rate change (before any DAC wait), all delivered in one batch later
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("early gap: no re-pause (it ends paused)", w.observe(notices: [(playing: false, at: at(0.05)), (playing: true, at: at(0.3)), (playing: false, at: at(0.9))], now: at(2)), false)
check("early gap: listener paused", w.listenerPaused, true)

// Music already paused (a caller paused it; the switch's pause posts no notice): the listener's play, then
// pause, before any echo arrives, must not be taken for the switch's echo
w = StallPolicy.ListenerWatch(startedAt: at(0), ownPauseEchoes: false)
check("caller-paused: play is paused again", w.observe(notices: [(playing: true, at: at(0.3))], now: at(0.31)), true)
check("caller-paused: our re-pause's echo", w.observe(notices: [(playing: false, at: at(0.4))], now: at(0.41)), false)
check("caller-paused: only our echo so far", w.listenerPaused, false)
check("caller-paused: listener's pause", w.observe(notices: [(playing: false, at: at(0.6))], now: at(0.61)), false)
check("caller-paused: listener paused", w.listenerPaused, true)

// the same with a play and a pause arriving together and no echo at all
w = StallPolicy.ListenerWatch(startedAt: at(0), ownPauseEchoes: false)
check("no echo: batch ends paused", w.observe(notices: [(playing: true, at: at(0.3)), (playing: false, at: at(0.6))], now: at(0.7)), false)
check("no echo: listener paused", w.listenerPaused, true)

// a re-pause that finds Music already paused posts no echo: the listener's pause behind it still counts
w = StallPolicy.ListenerWatch(startedAt: at(0))
check("empty re-pause: first notice (switch's echo)", w.observe(notices: [(playing: false, at: at(0.05))], now: at(0.06)), false)
check("empty re-pause: play", w.observe(notices: [(playing: true, at: at(5))], now: at(5.01)), true)
w.repauseFoundPaused()
check("empty re-pause: listener's pause", w.observe(notices: [(playing: false, at: at(5.02))], now: at(5.03)), false)
check("empty re-pause: listener paused", w.listenerPaused, true)

// Music paused by the listener before the switch: that stands until the listener plays, and a later play
// replaces it (the latest action wins)
w = StallPolicy.ListenerWatch(startedAt: at(0), pausedAtStart: true, ownPauseEchoes: false)
check("paused at start: listener paused", w.listenerPaused, true)
check("paused at start: its late notice changes nothing", w.observe(notices: [(playing: false, at: at(0.02))], now: at(0.03)), false)
check("paused at start: still paused", w.listenerPaused, true)
check("paused at start: play during the wait is paused again", w.observe(notices: [(playing: true, at: at(10))], now: at(10.01)), true)
check("paused at start: play replaces it", w.listenerPaused, false)
check("paused at start: our re-pause's echo", w.observe(notices: [(playing: false, at: at(10.1))], now: at(10.2)), false)
check("paused at start: still plays at the end", w.listenerPaused, false)
check("paused at start: pause again", w.observe(notices: [(playing: false, at: at(20))], now: at(20.01)), false)
check("paused at start: paused at the end", w.listenerPaused, true)

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
