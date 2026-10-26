import Foundation
// Run: scripts/tests/run.sh
var failed = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got != want { print("FAIL \(name): got \(got), want \(want)"); failed += 1 } else { print("ok   \(name)") }
}

// the free slot: a start begins a loop, a second start while it runs does nothing
var s = EngineSlot()
check("free slot begins", s.requestStart(), .begin)
check("running slot is not started twice", s.requestStart(), .running)

// a stop that sees the end frees the slot
check("stop waits for a live thread", s.requestStop(), true)
check("the end frees the slot", s.ended(), false)
check("slot is free after a clean stop", s.occupied, false)
check("start after a clean stop begins", s.requestStart(), .begin)

// the reported state: stop() times out with the old thread alive, then start() is called
check("stop waits", s.requestStop(), true)
s.stopTimedOut()
check("timed-out thread keeps the slot", s.occupied, true)
check("start while the old thread lives is deferred, not begun", s.requestStart(), .deferred)
check("a second start is deferred too", s.requestStart(), .deferred)
check("the old thread's end asks for the deferred start", s.ended(), true)
check("slot is free after the late end", s.occupied, false)
check("the deferred start now begins", s.requestStart(), .begin)

// a stop after the timeout does not wait again, and cancels the deferred start
var t = EngineSlot()
_ = t.requestStart(); _ = t.requestStop(); t.stopTimedOut()
check("deferred start is recorded", t.requestStart(), .deferred)
check("a repeated stop does not wait again", t.requestStop(), false)
check("the stop cancelled the deferred start", t.ended(), false)

// the thread ends by itself with nothing deferred
var u = EngineSlot()
_ = u.requestStart()
check("an end with nothing deferred does not restart", u.ended(), false)
check("slot is free after a self-ended thread", u.occupied, false)

// the same with a real thread that outlives the 20 s wait (here 0.2 s): the group can be waited on again
var v = EngineSlot()
let group = DispatchGroup()
check("real thread: begin", v.requestStart(), .begin)
group.enter()
Thread { Thread.sleep(forTimeInterval: 0.2); group.leave() }.start()
check("real thread: stop waits", v.requestStop(), true)
let ended1 = group.wait(timeout: .now() + 0.05) == .success
check("real thread: wait times out while it lives", ended1, false)
v.stopTimedOut()
check("real thread: start is deferred", v.requestStart(), .deferred)
check("real thread: still alive for a repeated stop", group.wait(timeout: .now()) == .success, false)
let ended2 = group.wait(timeout: .now() + 2) == .success
check("real thread: the same group reports the end later", ended2, true)
check("real thread: the end restarts", v.ended(), true)

if failed > 0 { print("\(failed) failed"); exit(1) }
