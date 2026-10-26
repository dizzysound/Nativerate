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

// the listener's play and pause while Music is held paused. Paused notices are not read at all (Music posts
// them in twos and threes, and late); what the listener did is read from the state the pause script reports.
let t0 = Date(timeIntervalSinceReferenceDate: 1000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
typealias Watch = StallPolicy.ListenerWatch
// the switch's first pause script returns at 0.03 s, Music's state read by it is `prior`
func watch(prior: String? = "playing", byCaller: Bool = false) -> Watch {
    var w = Watch()
    w.pauseSent(prior: prior, to: at(0.03), byCaller: byCaller)
    return w
}
// what the engine does at each look: observe, and run the script (reporting `prior`) when asked
@discardableResult
func look(_ w: inout Watch, _ notices: [(playing: Bool, at: TimeInterval)], now: TimeInterval, prior: String?, final: Bool = false) -> Bool {
    let ran = w.observe(notices: notices.map { (playing: $0.playing, at: at($0.at)) }, now: at(now), final: final)
    if ran { w.pauseSent(prior: prior, to: at(now + 0.05)) }
    return ran
}

var w = watch()
check("untouched: not paused by listener", w.listenerPaused, false)
check("untouched: first poll is due at once", look(&w, [(playing: false, at: 0.05)], now: 0.1, prior: "paused"), true)
check("untouched: a Paused notice and a paused poll are not the listener's", w.listenerPaused, false)
check("untouched: next poll not before the interval", look(&w, [], now: 1.0, prior: "paused"), false)
check("untouched: polls again after it", look(&w, [], now: 1.7, prior: "paused"), true)
check("untouched: still not the listener's", w.listenerPaused, false)

// Music already paused when the first script runs, and not by a caller: the listener paused
w = watch(prior: "paused")
check("paused at start: listener's", w.listenerPaused, true)
w = watch(prior: "paused", byCaller: true)
check("paused by the caller: not the listener's", w.listenerPaused, false)
w = watch(prior: "stopped")
check("stopped at start: not playing", w.listenerPaused, true)

// the Playing that brought the switch here arrives before the first script returned: covered by it
w = watch()
_ = look(&w, [(playing: true, at: 0.01)], now: 0.1, prior: "paused") // a poll, not a re-pause for the old Playing
check("old Playing: not a play", w.listenerPaused, false)

// play: paused again once, Music playing again means the listener wants it playing
w = watch()
check("play: script runs", look(&w, [(playing: true, at: 10)], now: 10.01, prior: "playing"), true)
check("play: not asked again at once", look(&w, [], now: 10.1, prior: "paused"), false)
check("play: our pause's Paused notices are nothing", look(&w, [(playing: false, at: 10.2), (playing: false, at: 10.2), (playing: false, at: 10.3)], now: 10.4, prior: "paused"), false)
check("play only: plays at the end", w.listenerPaused, false)

// play, then pause before the script runs (also the notices arriving as one batch): stays paused
check("pause after play: script runs", look(&w, [(playing: true, at: 20), (playing: false, at: 20.01)], now: 20.02, prior: "paused"), true)
check("pause after play: listener paused", w.listenerPaused, true)
look(&w, [], now: 25, prior: "paused")
check("pause after play: stays so on later polls", w.listenerPaused, true)

// play again after that: wants playback again
check("play again: script runs", look(&w, [(playing: true, at: 30)], now: 30, prior: "playing"), true)
check("play again: plays at the end", w.listenerPaused, false)

// Re-review 9, finding 1: our pause went out, the listener plays and pauses at once. The Playing is new
// (after the command returned); the state is paused, so the listener's pause stands
w = watch()
check("quick play and pause: script runs", look(&w, [(playing: true, at: 0.1), (playing: false, at: 0.11)], now: 0.12, prior: "paused"), true)
check("quick play and pause: listener paused", w.listenerPaused, true)

// Re-review 9, finding 2: Music was paused at the read, the listener plays before the pause, so the pause
// held a playing Music: nothing of this is the listener's pause
w = watch(prior: "playing")
check("play before the first pause: plays at the end", w.listenerPaused, false)
// in the DAC wait: the listener pauses before our pause runs, the script finds it paused
w = watch()
check("pause before the re-pause: script runs", look(&w, [(playing: true, at: 5)], now: 5.01, prior: "paused"), true)
check("pause before the re-pause: listener paused", w.listenerPaused, true)

// Re-review 8, finding 1: the listener's Pause and Play land before our first pause; the pause finds Music
// playing, so the listener's last action was Play
w = watch(prior: "playing")
check("pause+play before the first pause: not paused", w.listenerPaused, false)
look(&w, [(playing: false, at: 0.001), (playing: true, at: 0.002), (playing: false, at: 0.04)], now: 0.1, prior: "paused") // all covered by the first script
check("pause+play before the first pause: still not paused", w.listenerPaused, false)

// duplicate Playing notices (one batch, or the second one after the script covered the first) are one play
w = watch()
check("duplicate Playing: one script", look(&w, [(playing: true, at: 10), (playing: true, at: 10.001)], now: 10.01, prior: "playing"), true)
check("duplicate Playing: late copy covered by the script", look(&w, [(playing: true, at: 10.04)], now: 10.1, prior: "paused"), false)
check("duplicate Playing: not a listener pause", w.listenerPaused, false)

// a script that failed (nil): the Playing stays pending and is asked again after the interval, not before
w = watch()
check("failed script: asked", look(&w, [(playing: true, at: 10)], now: 10.01, prior: nil), true)
check("failed script: not at once", look(&w, [], now: 10.5, prior: "playing"), false)
check("failed script: asked again", look(&w, [], now: 11.6, prior: "paused"), true)
check("failed script: the listener paused meanwhile", w.listenerPaused, true)

// a failed first script: the first poll finds Music paused and no caller paused it: the listener's
w = watch(prior: nil)
check("failed first script: not known yet", w.listenerPaused, false)
check("failed first script: poll", look(&w, [], now: 0.5, prior: "paused"), true)
check("failed first script: paused by the listener", w.listenerPaused, true)

// a poll finds Music playing with no Playing notice seen (it came in the window after the script read
// the state): paused, and the listener wants it playing
w = watch()
check("poll finds playing: script runs", look(&w, [], now: 3, prior: "playing"), true)
check("poll finds playing: listener wants it playing", w.listenerPaused, false)

// last look before Music is played: only a pending Playing asks for a script, and the throttle is off
w = watch()
check("final: nothing pending, no script", look(&w, [], now: 9, prior: "playing", final: true), false)
check("final: pending Playing, script", look(&w, [(playing: true, at: 9.5)], now: 9.6, prior: "paused", final: true), true)
check("final: the listener paused", w.listenerPaused, true)
w = watch()
look(&w, [(playing: true, at: 9)], now: 9.01, prior: nil) // failed
check("final: pending after a failure, inside the interval", look(&w, [], now: 9.2, prior: "playing", final: true), true)
check("final: wants it playing", w.listenerPaused, false)

// fast forwarding or rewinding counts as playing
check("fast forwarding is playing", Watch.wasPlaying("fast forwarding"), true)
check("paused is not playing", Watch.wasPlaying("paused"), false)

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
