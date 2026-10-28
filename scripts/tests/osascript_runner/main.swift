import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1; print("FAIL \(name) \(detail())") }
}

check("output", OsascriptRunner.run("return \"100\" as string", timeout: 10) == .output("100"))

check("edge whitespace kept", OsascriptRunner.run("return \" /tmp/x \"", timeout: 10) == .output(" /tmp/x "))

if case .failed = OsascriptRunner.run("this is not applescript (", timeout: 10) {} else { check("syntax error fails", false) }

let started = Date()
check("timeout", OsascriptRunner.run("delay 30", timeout: 1) == .timedOut)
check("timeout returns promptly", Date().timeIntervalSince(started) < 5, "\(Date().timeIntervalSince(started)) s")

// Concurrent callers on background queues (the crash was in-process NSAppleScript on a background queue)
let group = DispatchGroup()
let lock = NSLock()
var results = [OsascriptRunner.Outcome]()
for i in 0..<16 {
    group.enter()
    DispatchQueue.global().async {
        let r = OsascriptRunner.run("return \"\(i)\"", timeout: 10)
        lock.lock(); results.append(r); lock.unlock()
        group.leave()
    }
}
group.wait()
check("concurrent count", results.count == 16)
check("concurrent outputs", Set(results) == Set((0..<16).map { OsascriptRunner.Outcome.output("\($0)") }), "\(results)")

if failures == 0 { print("osascript_runner: ok") } else { exit(1) }
