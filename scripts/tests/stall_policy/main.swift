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

// Re-review 9, finding 1: our pause went out, the listener plays and pauses. The Playing is new (after
// the command returned and its echo window); the state is paused, so the listener's pause stands
w = watch()
check("quick play and pause: script runs", look(&w, [(playing: true, at: 3), (playing: false, at: 3.01)], now: 3.02, prior: "paused"), true)
check("quick play and pause: listener paused", w.listenerPaused, true)

// Nativerate 0.1.10 on the coffee Mac (switches 1 and 2): Music posts its own Playing 0.26-0.35 s after our
// pause, then the Paused for it. Music is paused at the read: the switch's pause, not the listener's
w = watch()
check("echo Playing: script runs", look(&w, [(playing: true, at: 0.29), (playing: false, at: 0.30)], now: 0.30, prior: "paused"), true)
check("echo Playing: not the listener's pause", w.listenerPaused, false)
look(&w, [(playing: false, at: 0.8)], now: 2, prior: "paused")
check("echo Playing: still not, on later polls", w.listenerPaused, false)

// an echo-window Playing that really is Music playing (switch 3 of that log) is still paused again
w = watch()
check("echo Playing, playing: script runs", look(&w, [(playing: true, at: 0.4)], now: 0.6, prior: "playing"), true)
check("echo Playing, playing: wants it playing", w.listenerPaused, false)

// the window is measured from the last pause command that found Music playing, not the first
w = watch()
look(&w, [(playing: true, at: 10)], now: 10.01, prior: "playing") // command ends 10.06
check("echo after a re-pause: script runs", look(&w, [(playing: true, at: 10.3)], now: 11.6, prior: "paused"), true)
check("echo after a re-pause: not the listener's", w.listenerPaused, false)
w = watch()
look(&w, [(playing: true, at: 10)], now: 10.01, prior: "playing") // command ends 10.06
check("play after the window: script runs", look(&w, [(playing: true, at: 12.5)], now: 12.5, prior: "paused"), true)
check("play after the window: listener paused", w.listenerPaused, true)

// polls that find Music paused are no pause: they do not move the window. Polls at 1.8 s and 3.3 s, then the
// listener plays (3.5 s) and pauses (3.51 s): the Playing is past the first pause's window, so the pause stands
w = watch()
look(&w, [], now: 1.8, prior: "paused")
look(&w, [], now: 3.3, prior: "paused")
check("play and pause after polls: script runs", look(&w, [(playing: true, at: 3.5), (playing: false, at: 3.51)], now: 3.52, prior: "paused"), true)
check("play and pause after polls: listener paused", w.listenerPaused, true)
// the same polls, then the echo of a pause that did land (Music was playing at 3.3 s): still not the listener's
w = watch()
look(&w, [], now: 1.8, prior: "paused")
look(&w, [], now: 3.3, prior: "playing")
check("echo after polls: script runs", look(&w, [(playing: true, at: 3.6), (playing: false, at: 3.7)], now: 3.8, prior: "paused"), true)
check("echo after polls: not the listener's", w.listenerPaused, false)

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

// last look before Music is played: always a script, the throttle is off
w = watch()
check("final: nothing pending, still a script", look(&w, [], now: 9, prior: "paused", final: true), true)
check("final: Music paused, not the listener's", w.listenerPaused, false)
check("final: pending Playing, script", look(&w, [(playing: true, at: 12)], now: 12.1, prior: "paused", final: true), true)
check("final: the listener paused", w.listenerPaused, true)
w = watch()
look(&w, [(playing: true, at: 9)], now: 9.01, prior: nil) // failed
check("final: pending after a failure, inside the interval", look(&w, [], now: 9.2, prior: "playing", final: true), true)
check("final: wants it playing", w.listenerPaused, false)

// Re-review 10, finding 2: the Playing notice was missed during the command wait (no look in it); the
// final look finds Music playing from the state
w = watch()
look(&w, [], now: 1, prior: "paused")
check("missed Playing at the end: final look runs", look(&w, [], now: 1.2, prior: "playing", final: true), true)
check("missed Playing at the end: wants it playing", w.listenerPaused, false)

// Re-review 10, finding 1: the caller paused Music and the first script failed; the poll finds Music
// paused, which is the caller's, not the listener's
w = Watch()
w.pauseSent(prior: nil, to: at(0.03), byCaller: true)
check("caller pause, first script failed: poll", look(&w, [], now: 0.5, prior: "paused"), true)
check("caller pause, first script failed: not the listener's", w.listenerPaused, false)
check("caller pause, first script failed: final look", look(&w, [], now: 1, prior: "paused", final: true), true)
check("caller pause, first script failed: still not the listener's", w.listenerPaused, false)

// fast forwarding or rewinding counts as playing
check("fast forwarding is playing", Watch.wasPlaying("fast forwarding"), true)
check("paused is not playing", Watch.wasPlaying("paused"), false)


// A start that never returns must not hold the caller: begin returns at once, take finds nothing, a second
// begin is refused, and the result is delivered once it comes
let bs = BackgroundStart<Int>()
let release = DispatchSemaphore(value: 0)
let beganAt = Date()
check("start: begin accepted", bs.begin { release.wait(); return 7 }, true)
check("start: begin returned without waiting", Date().timeIntervalSince(beganAt) < 0.5, true)
check("start: busy while running", bs.isBusy, true)
check("start: second begin refused", bs.begin { 99 }, false)
check("start: nothing to take while running", bs.take() == nil, true)
release.signal()
var got: Int?? = nil
for _ in 0..<200 { got = bs.take(); if got != nil { break }; Thread.sleep(forTimeInterval: 0.01) }
check("start: result delivered", got == .some(.some(7)), true)
check("start: free after take", bs.isBusy, false)
check("start: nothing left to take", bs.take() == nil, true)
check("start: a failed start delivers nil, not 'still running'", { () -> Bool in
    _ = bs.begin { nil }
    for _ in 0..<200 { if let r = bs.take() { return r == nil }; Thread.sleep(forTimeInterval: 0.01) }
    return false
}(), true)
check("start: begin accepted again", bs.begin { 1 }, true)

// engine loop ends while the start is still blocked: the late result is handed to orphan, once, never taken
let orphans = NSLock(); var orphaned: [Int] = []
func note(_ v: Int) { orphans.lock(); orphaned.append(v); orphans.unlock() }
func seen() -> [Int] { orphans.lock(); defer { orphans.unlock() }; return orphaned }
func waitFor(_ f: () -> Bool) { for _ in 0..<200 { if f() { return }; Thread.sleep(forTimeInterval: 0.01) } }
let late = BackgroundStart<Int>()
let lateRelease = DispatchSemaphore(value: 0)
_ = late.begin({ lateRelease.wait(); return 5 }, orphan: note)
late.abandon()
check("abandon: free at once while the work hangs", late.isBusy, false)
check("abandon: nothing orphaned yet", seen(), [])
lateRelease.signal()
waitFor { !seen().isEmpty }
check("abandon: late result goes to orphan", seen(), [5])
check("abandon: late result is not left to take", late.take() == nil, true)

let waitingStart = BackgroundStart<Int>()
_ = waitingStart.begin({ 6 }, orphan: note)
Thread.sleep(forTimeInterval: 0.2)
waitingStart.abandon()
check("abandon: a result already waiting goes to orphan", seen(), [5, 6])
check("abandon: and is gone", waitingStart.take() == nil, true)

let failedLate = BackgroundStart<Int>()
let failRelease = DispatchSemaphore(value: 0)
_ = failedLate.begin({ failRelease.wait(); return nil }, orphan: note)
failedLate.abandon(); failRelease.signal(); Thread.sleep(forTimeInterval: 0.2)
check("abandon: a failed start orphans nothing", seen(), [5, 6])

// restart while the abandoned start's work is still hung: no second work overlaps the first
let reused = BackgroundStart<Int>()
let reusedRelease = DispatchSemaphore(value: 0)
let live = NSLock(); var running = 0, maxRunning = 0
func enter() { live.lock(); running += 1; maxRunning = max(maxRunning, running); live.unlock() }
func leave() { live.lock(); running -= 1; live.unlock() }
_ = reused.begin({ enter(); reusedRelease.wait(); leave(); return 8 }, orphan: note)
reused.abandon()
check("abandon: a new start is refused while the old work still hangs", reused.begin({ enter(); defer { leave() }; return 9 }, orphan: note), false)
check("abandon: refused begin ran nothing", reused.isBusy, false)
reusedRelease.signal()
waitFor { seen().contains(8) }
check("abandon: old start's result orphaned, not taken", seen(), [5, 6, 8])
var accepted = false
waitFor { accepted = reused.begin({ enter(); defer { leave() }; return 9 }, orphan: note); return accepted }
check("abandon: a new start is accepted once the old work returned", accepted, true)
var gotReused: Int?? = nil
waitFor { gotReused = reused.take(); return gotReused != nil }
check("abandon: new start's result is taken", gotReused == .some(.some(9)), true)
check("abandon: never two works at once", maxRunning, 1)
check("abandon: nothing stale to take", reused.take() == nil, true)

// the abandoned result was waiting when the engine restarts: the next start is accepted at once
let waitedThenReused = BackgroundStart<Int>()
_ = waitedThenReused.begin({ 10 }, orphan: note)
Thread.sleep(forTimeInterval: 0.2)
waitedThenReused.abandon()
check("abandon: a start is accepted after a waiting result was orphaned", waitedThenReused.begin({ 11 }, orphan: note), true)

// a new start tries to get in while the orphan hand-over of a waiting result is still running: it is
// refused, and the hand-over's last step cannot clear the flag of a later start
let handoff = BackgroundStart<Int>()
let inHandler = DispatchSemaphore(value: 0), handlerGo = DispatchSemaphore(value: 0), abandonDone = DispatchSemaphore(value: 0)
_ = handoff.begin({ 12 }, orphan: { _ in inHandler.signal(); handlerGo.wait() })
Thread.sleep(forTimeInterval: 0.2)
DispatchQueue.global().async { handoff.abandon(); abandonDone.signal() }
inHandler.wait()
check("handoff: a new start is refused during the orphan hand-over", handoff.begin({ 13 }, orphan: note), false)
handlerGo.signal(); abandonDone.wait()
let secondRelease = DispatchSemaphore(value: 0)
check("handoff: a new start is accepted after the hand-over", handoff.begin({ secondRelease.wait(); return 14 }, orphan: note), true)
handoff.abandon()
check("handoff: still refused while the second start's work hangs", handoff.begin({ 15 }, orphan: note), false)
secondRelease.signal()
var acceptedAfter = false
waitFor { acceptedAfter = handoff.begin({ 16 }, orphan: note); return acceptedAfter }
check("handoff: accepted once the second start's work returned", acceptedAfter, true)

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
