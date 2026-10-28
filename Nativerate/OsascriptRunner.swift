import Foundation

/// Runs AppleScript in a separate `osascript` process. NSAppleScript is main-thread-only, and in-process
/// execution from a background queue crashed (EXC_BAD_ACCESS in TUASVector::_AddElement); a child process
/// is safe from any thread, can't corrupt this process, and a hung target app costs a timeout, not the UI.
enum OsascriptRunner {
    enum Outcome: Equatable {
        case output(String)
        case failed(String)
        case timedOut
    }

    static func run(_ source: String, timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failed("osascript failed to start: \(error)") }

        // Drain both pipes while the child runs, so a chatty child can't block on a full pipe.
        var outData = Data(), errData = Data()
        let drained = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = data } else { errData = data }
                drained.leave()
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            drained.wait()
            return .timedOut
        }
        drained.wait()
        let stdout = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 ? .output(stdout) : .failed(stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr)
    }
}
