//
//  LogExport.swift
//  Nativerate
//
//  About Nativerate > Export logs…: one zip with what the Exclusive Mode benches (MT 48, DragonFly Black) needed
//  to find a fault: the engine logs, every output device's formats, hog owner, running state and
//  volume, the app's and Music's settings, the plug-in version, filtered unified-log extracts (this
//  process's HAL client IO context: pause/resume, start, "IO is still disabled"; coreaudiod's config
//  changes, starts, stops and errors; Music's decoder lines and output selection; USB audio kernel
//  lines), sleep/wake history and recent crash reports.
//

import AppKit
import CoreAudio
import Foundation

final class LogExport: ObservableObject {
    static let shared = LogExport()
    @Published private(set) var busy = false

    /// Hours of unified log to search (the coffee failure needed 40 min of context; the overnight
    /// clock problem, hours).
    static let hours = 4

    func export() {
        guard !busy else { return }
        let stamp = Self.fileStamp.string(from: Date())
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Nativerate-Logs-\(stamp).zip"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "The zip holds the engine logs, audio device details, settings, and the last \(Self.hours) hours of audio-related system log. Track names appear in it."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        export(to: dest, stamp: stamp) { error in
            if let error {
                let alert = NSAlert()
                alert.messageText = "Export logs failed"
                alert.informativeText = "\(error)"
                alert.runModal()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    /// Main thread. `done` runs on the main thread with nil or the failure.
    func export(to dest: URL, stamp: String = fileStamp.string(from: Date()), done: @escaping (Error?) -> Void) {
        guard !busy else { done(NSError(domain: "LogExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "an export is already running"])); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.build(to: dest, stamp: stamp) }
            DispatchQueue.main.async {
                self.busy = false
                if case .failure(let error) = result { done(error) } else { done(nil) }
            }
        }
    }

    static let fileStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f }()

    private static func build(to dest: URL, stamp: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Nativerate-Logs-\(stamp)")
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ name: String, _ text: String) { try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        // the slow part first, in parallel: the unified log
        let me = ProcessInfo.processInfo.processName
        let queries: [(String, String)] = [
            ("unified-hal-client.log", "process == \"\(me)\" AND (eventMessage CONTAINS \"PauseIO\" OR eventMessage CONTAINS \"ResumeIO\" OR eventMessage CONTAINS \"IOThread\" OR eventMessage CONTAINS \"StartAndWait\" OR eventMessage CONTAINS \"StartIO\" OR eventMessage CONTAINS \"StopIO\" OR eventMessage CONTAINS \"IOWorkLoop\" OR eventMessage CONTAINS \"setPlayState\" OR eventMessage CONTAINS \"HALDefaultDevice\" OR messageType == error OR messageType == fault)"),
            ("unified-coreaudiod.log", "process == \"coreaudiod\" AND (eventMessage CONTAINS \"RequestConfigChange\" OR eventMessage CONTAINS \"StartIO\" OR eventMessage CONTAINS \"StopIO\" OR eventMessage CONTAINS \"IO Stopped\" OR eventMessage CONTAINS \"IOWorkLoop\" OR eventMessage CONTAINS[c] \"hog\" OR eventMessage CONTAINS[c] \"overload\" OR eventMessage CONTAINS \"SetDefaultDevice\" OR eventMessage CONTAINS \"_Deactivate\" OR eventMessage CONTAINS \"Activate: activating\" OR messageType == error OR messageType == fault)"),
            ("unified-music.log", "process == \"Music\" AND (eventMessage CONTAINS \"Input format:\" OR eventMessage CONTAINS \"ACAppleLosslessDecoder\" OR eventMessage CONTAINS \"SelectDevice\" OR eventMessage CONTAINS \"play> mpc> cmd>\" OR eventMessage CONTAINS \"setAudioOutputContext\")"),
            ("unified-audio-errors.log", "(process == \"coreaudiod\" OR process == \"kernel\" OR subsystem BEGINSWITH \"com.apple.coreaudio\" OR subsystem BEGINSWITH \"com.apple.audio\") AND (messageType == error OR messageType == fault)"),
        ]
        let group = DispatchGroup()
        for (name, predicate) in queries {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let out = run("/usr/bin/log", ["show", "--last", "\(hours)h", "--info", "--style", "compact", "--predicate", predicate], timeout: 180)
                write(name, out)
                group.leave()
            }
        }

        write("README.txt", readme())
        write("audio-devices.txt", AudioSnapshot.text())
        write("settings.txt", settings())
        write("system.txt", system())

        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        for f in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? [] where f.hasPrefix("Nativerate-") && f.hasSuffix(".log") {
            try? fm.copyItem(at: logs.appendingPathComponent(f), to: root.appendingPathComponent(f))
        }
        let reports = logs.appendingPathComponent("DiagnosticReports")
        let recent = ((try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Nativerate") || $0.lastPathComponent.hasPrefix("coreaudiod") }
            .compactMap { u -> (URL, Date)? in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (u, $0) } }
            .filter { Date().timeIntervalSince($0.1) < 14 * 86400 }
            .sorted { $0.1 > $1.1 }.prefix(5)
        if !recent.isEmpty {
            let dir = root.appendingPathComponent("DiagnosticReports")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (u, _) in recent { try? fm.copyItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent)) }
        }

        group.wait()
        try? fm.removeItem(at: dest)
        let zip = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, dest.path], timeout: 120)
        guard fm.fileExists(atPath: dest.path) else { throw NSError(domain: "LogExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "ditto: \(zip)"]) }
    }

    private static func readme() -> String {
        """
        Nativerate log export, \(RendererLog.wallClock.string(from: Date()))
        \(appSummary)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(sysctl("hw.model")), up \(Int(ProcessInfo.processInfo.systemUptime / 60)) min

        Files
          Nativerate-ExclusiveMode.log     engine log of the current (or last) run; seconds since the
                                                 engine started, wall clock in the first line and every 30 s
          Nativerate-ExclusiveMode.1/.2.log  the two runs before it (a relaunch starts a new run)
          audio-devices.txt                      every device: default flags, rates, hog owner, running,
                                                 stream formats (physical, virtual, available), volume, latency
          settings.txt                           this app's settings, Music's settings and state, the plug-in
          system.txt                             processes, sleep/wake history
          unified-*.log                          the last \(hours) h of the system log, filtered: this process's
                                                 HAL client (IO context pause/resume, start), coreaudiod (config
                                                 changes, starts, stops, errors), Music (decoder formats, output
                                                 device), audio errors and faults from any process
          DiagnosticReports/                     crash reports of this app or coreaudiod from the last 14 days
        """
    }

    private static func settings() -> String {
        var s = "== \(Bundle.main.bundleIdentifier ?? "?") settings\n"
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for k in domain.keys.sorted() { s += "\(k) = \(domain[k]!)\n" }
        s += "\n== Music settings (preferences)\n"
        let app = "com.apple.Music" as CFString
        CFPreferencesAppSynchronize(app)
        for k in ["TransitionsEnabled", "optimizeSongVolume", "losslessEnabled", "losslessAudioQualityStreaming", "losslessAudioQualityDownload", "dolbyAtmosEnabled"] {
            s += "\(k) = \(CFPreferencesCopyAppValue(k as CFString, app).map { "\($0)" } ?? "(unset)")\n"
        }
        s += "\n== Music state\n"
        s += run("/usr/bin/osascript", ["-e", """
            if application "Music" is running then
              tell application "Music"
                set out to "player state: " & (player state as text) & linefeed & "sound volume: " & sound volume & linefeed & "EQ enabled: " & (EQ enabled as text) & linefeed & "shuffle: " & (shuffle enabled as text)
                try
                  set out to out & linefeed & "current track: " & name of current track & " / " & artist of current track & ", " & (sample rate of current track as text) & " Hz, " & (bit rate of current track as text) & " kbps, kind " & kind of current track & linefeed & "position: " & (player position as text)
                end try
                return out
              end tell
            else
              return "Music is not running"
            end if
            """], timeout: 15)
        s += "\n== Virtual output plug-in\n\(VirtualOutputPlugin.installPath): "
        let installed = VirtualOutputPlugin.version(of: URL(fileURLWithPath: VirtualOutputPlugin.installPath))
        s += installed.map { "\($0.short) (\($0.build))\n" } ?? "not installed\n"
        let bundled = VirtualOutputPlugin.shared.bundledURL.flatMap { VirtualOutputPlugin.version(of: $0) }
        s += "bundled with this app: " + (bundled.map { "\($0.short) (\($0.build))" } ?? "none") + "\n"
        s += run("/bin/ls", ["-l", "/Library/Audio/Plug-Ins/HAL"], timeout: 10)
        return s
    }

    private static func system() -> String {
        var s = "== processes\n"
        s += run("/bin/ps", ["-axo", "pid,etime,%cpu,rss,command"], timeout: 10)
            .split(separator: "\n").filter { $0.contains("PID") || $0.contains("Nativerate") || $0.contains("run.pl") || $0.contains("Music.app") || $0.contains("coreaudiod") }
            .joined(separator: "\n")
        s += "\n\n== sleep and wake (pmset -g log, last 100)\n"
        // the event type is the column after the time zone; "Wake Lock" assertions aren't wakes
        let events = run("/usr/bin/pmset", ["-g", "log"], timeout: 60)
            .split(separator: "\n").filter { line in
                let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                return f.count > 3 && ["Sleep", "Wake", "DarkWake"].contains(f[3].trimmingCharacters(in: .whitespaces))
            }.suffix(100)
        s += events.isEmpty ? "(none in pmset's log)" : events.joined(separator: "\n")
        return s + "\n"
    }

    /// Runs a tool and returns its output (stdout and stderr), or why it couldn't.
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lsx-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        guard let h = try? FileHandle(forWritingTo: out) else { return "(no temp file)\n" }
        p.standardOutput = h; p.standardError = h
        do { try p.run() } catch { return "(\(exe) failed to start: \(error))\n" }
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        var note = ""
        if p.isRunning { p.terminate(); note = "\n(stopped after \(Int(timeout)) s)\n" }
        try? h.close()
        return ((try? String(contentsOf: out, encoding: .utf8)) ?? "") + note
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }
}

/// Every audio device, as the benches needed to see it.
enum AudioSnapshot {
    static func text() -> String {
        let defOut = CA.defaultOutput()
        let sysOut = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
        let defIn = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0))
        var s = "Audio devices, \(RendererLog.wallClock.string(from: Date())); this process pid \(getpid())\n"
        for d in CA.devices() {
            let out = CA.streams(d, kAudioObjectPropertyScopeOutput), inp = CA.streams(d, kAudioObjectPropertyScopeInput)
            var flags: [String] = []
            if d == defOut { flags.append("DEFAULT OUTPUT") }
            if d == sysOut { flags.append("SYSTEM OUTPUT") }
            if d == defIn { flags.append("DEFAULT INPUT") }
            s += "\n== \(CA.string(d, kAudioObjectPropertyName)) (id \(d)) \(flags.joined(separator: ", "))\n"
            s += "uid \(CA.string(d, kAudioDevicePropertyDeviceUID)); model \(CA.string(d, kAudioDevicePropertyModelUID)); maker \(CA.string(d, kAudioObjectPropertyManufacturer))\n"
            s += "transport \(fourCC(CA.transport(d))); alive \(get(d, kAudioDevicePropertyDeviceIsAlive, UInt32(0))); running \(get(d, kAudioDevicePropertyDeviceIsRunning, UInt32(0))); running somewhere \(CA.runningSomewhere(d) ? 1 : 0); hog owner \(CA.hogOwner(d))\n"
            s += "nominal \(CA.nominal(d)) Hz; available \(CA.nominalRates(d).map { "\(Int($0))" }.joined(separator: " ")); clock domain \(get(d, kAudioDevicePropertyClockDomain, UInt32(0)))\n"
            for (scope, streams, label) in [(kAudioObjectPropertyScopeOutput, out, "output"), (kAudioObjectPropertyScopeInput, inp, "input")] where !streams.isEmpty {
                s += "\(label): latency \(get(d, kAudioDevicePropertyLatency, UInt32(0), scope)), safety offset \(get(d, kAudioDevicePropertySafetyOffset, UInt32(0), scope)), buffer \(get(d, kAudioDevicePropertyBufferFrameSize, UInt32(0))) frames\n"
                for st in streams {
                    s += "  stream \(st): \(CA.formats(st)); latency \(get(st, kAudioStreamPropertyLatency, UInt32(0)))\n"
                    let avail = CA.availablePhysicalFormats(st).map { r -> String in
                        let f = r.mFormat
                        let range = r.mSampleRateRange.mMinimum == r.mSampleRateRange.mMaximum ? "\(Int(r.mSampleRateRange.mMinimum))" : "\(Int(r.mSampleRateRange.mMinimum))-\(Int(r.mSampleRateRange.mMaximum))"
                        return "\(range) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel) bit flags \(f.mFormatFlags)\(f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 ? " non-mixable" : "")"
                    }
                    s += "    physical formats: \(avail.joined(separator: "; "))\n"
                }
                s += "  volume: \(volume(d, scope))\n"
            }
        }
        return s
    }

    private static func volume(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
        var parts: [String] = []
        for e in UInt32(0)...2 {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: e)
            guard AudioObjectHasProperty(d, &a) else { continue }
            var settable = DarwinBoolean(false)
            AudioObjectIsPropertySettable(d, &a, &settable)
            var v = Float32(0), z = UInt32(4)
            AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v)
            var p = "e\(e) scalar \(String(format: "%.4f", v))\(settable.boolValue ? "" : " (read-only)")"
            a.mSelector = kAudioDevicePropertyVolumeDecibels
            if AudioObjectHasProperty(d, &a) {
                var db = Float32(0); z = 4
                AudioObjectGetPropertyData(d, &a, 0, nil, &z, &db)
                p += " \(String(format: "%.1f", db)) dB"
            }
            a.mSelector = kAudioDevicePropertyVolumeRangeDecibels
            if AudioObjectHasProperty(d, &a) {
                var r = AudioValueRange(); z = UInt32(MemoryLayout<AudioValueRange>.size)
                AudioObjectGetPropertyData(d, &a, 0, nil, &z, &r)
                p += " (range \(String(format: "%.1f", r.mMinimum))..\(String(format: "%.1f", r.mMaximum)) dB)"
            }
            a.mSelector = kAudioDevicePropertyMute
            if AudioObjectHasProperty(d, &a) {
                var m = UInt32(0); z = 4
                AudioObjectGetPropertyData(d, &a, 0, nil, &z, &m)
                p += " mute \(m)"
            }
            parts.append(p)
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "; ")
    }

    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var v = initial
        var a = CA.addr(sel, scope)
        var z = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(obj, &a) else { return initial }
        AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v)
        return v
    }

    private static func fourCC(_ v: UInt32) -> String {
        let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
        return b.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(bytes: b, encoding: .ascii)! : "\(v)"
    }
}

/// AppleScript: `tell application id "<bundle id>" to export logs to "~/Desktop"` (with a timeout of a
/// few minutes). Lets a bench export over SSH when the menu-bar icon is out of reach (on a notched
/// MacBook it can sit under the notch).
final class ExportLogsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let fm = FileManager.default
        let given = (evaluatedArguments?["destination"] as? String).map { ($0 as NSString).expandingTildeInPath }
        var dest = URL(fileURLWithPath: given ?? fm.urls(for: .desktopDirectory, in: .userDomainMask).first!.path)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            dest.appendPathComponent("Nativerate-Logs-\(LogExport.fileStamp.string(from: Date())).zip")
        }
        suspendExecution()
        DispatchQueue.main.async {
            LogExport.shared.export(to: dest) { error in
                self.resumeExecution(withResult: error.map { "error: \($0.localizedDescription)" } ?? dest.path)
            }
        }
        return nil
    }
}
