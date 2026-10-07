//
//  VirtualDeviceEngine.swift
//  Nativerate
//
//  Exclusive Mode, virtual-device path. Music plays to "Nativerate" (the virtual device), a HAL plug-in
//  (LSOutput.driver in /Library/Audio/Plug-Ins/HAL) that loops its output mix back to its input.
//  IOProc A reads that input into a ring; IOProc B plays the ring directly on the DAC, which this
//  engine hogs and puts in a non-mixable (integer) format. The virtual device's clock is steered to
//  the DAC's through the plug-in's rate scalar property ('LSrs'), so nothing is resampled and the
//  ring's fill stays put. While the engine runs the virtual device is the default output; the DAC
//  is the device that was the default before (restored on stop, never to the virtual device).
//
//  Rate switches (Music can't be made to wait from the device side, so it is paused and rewound):
//  - Music sets up a local next track's decoder 8-12 s early and logs its rate. If it differs, the
//    "boundary latch" is armed 1.5 s before the current track's end: A marks the ring at the first
//    10 ms of exact zeros (Music's inter-track zeros) and B stops there.
//  - On the new track's Playing: pause Music, switch the virtual device (~0.02 s) and the DAC (B
//    keeps it running with silence; waitUntilReady), drop everything in the ring (the new track's
//    wrong-rate start and the pause fade), rewind Music to where the play started, play.
//  - A play from paused/stopped waits at the ring's "gate" (A marks the first nonzero frame) until
//    the new track's rate is known, so a wrong-rate start never reaches the DAC.
//  Same-rate changes, gapless albums and pause/resume pass through untouched.
//  Volume keys: the virtual device's volume and mute drive the DAC's own controls (VolumeForwarder). A DAC
//  with no volume gets silence for mute, and, if Settings > Exclusive Mode > Software volume is on, a gain in B (SoftwareVolume).
//  Music only (plug-in 1.1.4, 'LSmx' = Music's pid): the plug-in moves every other app's output to the
//  loopback's channels 3-4, so the DAC gets Music alone; OthersPlayer plays those on the built-in
//  speakers, and alert sounds move there too (restored on stop and at launch after an unclean exit).
//  Research and measurements: github.com/dizzysound/music-tap-spike (branch vdevice), log.md.
//
//  Needs Microphone (reading the virtual device's input) and Automation (Music) permissions.
//

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import SimplyCoreAudio
import Synchronization
import SwiftUI
import UserNotifications

final class VirtualDeviceEngine {

    static let deviceUID = "LSOutput_UID" // shown as "Nativerate" (plug-in 1.2+; 1.1: "LosslessSwitcher", 1.0: "LosslessSwitcher Output")
    static let pluginPath = "/Library/Audio/Plug-Ins/HAL/LSOutput.driver"
    private static let dacUIDKey = "RendererDACUID"
    private static let kRateScalar: AudioObjectPropertySelector = 0x4C53_7273 // 'LSrs'
    /// 'LSac': the renderer's pid while it plays the device out (0 = none). Plug-in 1.1+ can be the
    /// default output only while it is set, and clears it when that process stops being a client.
    private static let kAttached: AudioObjectPropertySelector = 0x4C53_6163
    /// 'LSmx' (plug-in 1.1.4): Music's pid (0 = off). Every other client's output then goes to the
    /// loopback's channels 3-4 instead of into the mix, and the engine plays it on the built-in
    /// speakers (OthersPlayer); channels 1-2 carry Music alone.
    private static let kMusicOnly: AudioObjectPropertySelector = 0x4C53_6D78
    private static let kStatus: AudioObjectPropertySelector = 0x4C53_7374 // 'LSst'
    /// The alert-sound device before the engine moved it to the speakers, and where it moved it
    /// (two device UIDs); restored on stop and, after an unclean exit, at launch.
    private static let alertsMovedKey = "RendererAlertsMoved"

    /// The plug-in's device, if the HAL has it.
    static func findDevice() -> AudioObjectID? {
        CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == deviceUID }
    }

    /// Set while the engine owns the output (virtual device default, DAC hogged non-mixable),
    /// cleared on a clean stop: still set at launch = the last run died.
    private static let ownsOutputKey = "RendererEngineOwnsOutput"
    private static let recoveryNoteKey = "RendererRecoveryNote"

    /// After a crash or a kill: the HAL releases the hog, but the DAC stays in its non-mixable format
    /// (unusable for everything else) and the default output is the virtual device (plug-in 1.0) or
    /// whatever coreaudiod fell back to (1.1: MacBook Pro Speakers in the kill test). Give the DAC its
    /// mixable format back and make it the default again. Harmless when the engine starts next.
    static func recoverOutput() {
        let notes = [VolumeForwarder.recover(), restoreAlerts()].compactMap { $0 }.joined(separator: "; ")
        let volumeNote = notes.isEmpty ? nil : notes
        let unclean = UserDefaults.standard.bool(forKey: ownsOutputKey)
        let ls = findDevice()
        let current = CA.defaultOutput()
        guard unclean || (ls != nil && current == ls) else {
            if let volumeNote { UserDefaults.standard.set("[Exclusive Mode] " + volumeNote, forKey: recoveryNoteKey) }
            return
        }
        let saved = UserDefaults.standard.string(forKey: dacUIDKey).flatMap { uid in CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == uid } }
        guard let dac = saved ?? ls.flatMap({ fallbackOutput(excluding: $0) }) else { return }
        var msg = "[Exclusive Mode] recovering the output after \(unclean ? "an unclean exit" : "a default left on the virtual device"): DAC \(CA.string(dac, kAudioObjectPropertyName))"
        if CA.hogOwner(dac) == -1 { msg += ", mixable \(CA.setMixable(dac))" }
        if current != dac { msg += ", default output (was \(CA.string(current, kAudioObjectPropertyName))) \(CA.setDefaultOutput(dac))" }
        if let volumeNote { msg += "; " + volumeNote }
        print(msg)
        UserDefaults.standard.set(msg, forKey: recoveryNoteKey) // the next engine run logs it
        UserDefaults.standard.removeObject(forKey: ownsOutputKey)
    }

    /// Puts the alert-sound device back where it was before the engine moved it, if it is still where
    /// the engine put it (a later choice of the user's stays). Nil when there is nothing to say.
    static func restoreAlerts() -> String? {
        guard let moved = UserDefaults.standard.stringArray(forKey: alertsMovedKey), moved.count == 2 else { return nil }
        UserDefaults.standard.removeObject(forKey: alertsMovedKey)
        func find(_ uid: String) -> AudioObjectID? { CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == uid } }
        let cur = CA.systemOutput()
        guard let back = find(moved[0]) else { return "alert sounds: \(moved[0]) is gone; left on \(CA.string(cur, kAudioObjectPropertyName))" }
        // macOS itself moves them back once the DAC's hog is released (pastor Mac, Babyface)
        if cur == back { return "alert sounds on \(CA.string(back, kAudioObjectPropertyName)) again (as before)" }
        guard let to = find(moved[1]), cur == to else { return "alert sounds: left on \(CA.string(cur, kAudioObjectPropertyName)) (changed since the engine moved them)" }
        return "alert sounds back to \(CA.string(back, kAudioObjectPropertyName)): \(CA.setSystemOutput(back))"
    }

    /// The aggregate Core Audio makes for one process's AVAudioEngine ("CADefaultDeviceAggregate-<pid>-N":
    /// ours, for the other-apps player). Private to that process; never an output to offer or pick.
    static func isPrivateAggregate(_ name: String) -> Bool { name.hasPrefix("CADefaultDeviceAggregate") }

    /// The Mac's built-in output (speakers), if it isn't `dac`: where other apps play while the engine
    /// holds the DAC for Music.
    static func builtInSpeakers(excluding dac: AudioObjectID) -> AudioObjectID? {
        CA.devices().first { $0 != dac && CA.transport($0) == kAudioDeviceTransportTypeBuiltIn && CA.hasOutput($0) && CA.string($0, kAudioDevicePropertyDeviceUID) != deviceUID }
    }

    /// The device the system would pick: built-in output first, else any other output.
    static func fallbackOutput(excluding ls: AudioObjectID) -> AudioObjectID? {
        let outs = CA.devices().filter { $0 != ls && CA.hasOutput($0) && CA.string($0, kAudioDevicePropertyDeviceUID) != deviceUID && !isPrivateAggregate(CA.string($0, kAudioObjectPropertyName)) }
        return outs.first { CA.transport($0) == kAudioDeviceTransportTypeBuiltIn } ?? outs.first
    }

    private unowned let outputDevices: OutputDevices

    // main thread
    private var observer: NSObjectProtocol?
    private var thread: Thread?
    private var logProcess: Process?
    private var finished: DispatchSemaphore?

    // inbox, under inboxLock: main thread / log reader -> engine thread
    private let inboxLock = NSLock()
    private var infoInbox: [(Date, [AnyHashable: Any])] = []
    private var lineInbox: [(Date, String)] = []
    private var stopRequested = false

    // engine thread
    private var ls = AudioObjectID(0)
    private var dac = AudioObjectID(0)
    private var dacUID = ""
    private var defaultBefore = AudioObjectID(0) // the default output before the engine took it; restored on stop
    private var dacOut = AudioStreamID(0)
    private var procA: AudioDeviceIOProcID?
    private var procB: AudioDeviceIOProcID?
    private var hogged = false
    private var nonMixable = false
    private var curRate: Float64 = 0
    private var playing = false
    private var lastTrackID: Int64?
    private typealias DecoderLine = (date: Date, rate: Float64, bits: Int?, lossless: Bool)
    private var decoderRates: [DecoderLine] = []
    /// Lossless lines with a depth that came while a track played and are not its own setup: the next
    /// track's pre-roll (local files 8-12 s before the end, streams up to ~265 s), so their depth is that
    /// track's. A lossless line at the rate of a still-lossy track is its own late upgrade, not a
    /// pre-roll (Coffee bench: Hey Jack Kerouac's 16-bit upgrade, 15 s before the 24-bit Mountains).
    private var preRollLines: [Date] = []
    private var lossyTrackAt: Date?
    private var lossyStartAt: Date? // like lossyTrackAt, but the first lossless line does not clear it
    private var pendingUpgrade: (rate: Float64, bits: Int?)?
    private var armAt: Date?
    private var armedAt: Date?
    private var lateArmAt: Date? // a pre-roll line that came early: arm again 1.5 s before the end
    private var armForSkip = false
    // Source depth from the samples themselves (A counts Music's nonzero samples off the 16- and 24-bit
    // grids; Music at volume 100 hands its decoder's samples through unchanged, so a 16-bit source sits
    // on multiples of 2^-15 and a 24-bit one on 2^-23). The log's depth shows until this has 2 s.
    private let gridNZ = Atomic<Int>(0), gridOff16 = Atomic<Int>(0), gridOff24 = Atomic<Int>(0)
    // off the 16-bit grid by more than 1/64 of a step (macOS 26 rounds local 16-bit ALAC to within
    // 0.003 of a step: Executor, 2026-09-30, Flambe recorded against the file, residual -166 dBFS)
    private let gridFar16 = Atomic<Int>(0)
    // Nonzero samples under 1/16 FS, and those more than 3/8 of a 24-bit step off its grid. macOS 26
    // moves 24-bit ALAC too (Executor, 2026-10-04, Hang 'em High recorded against the file: gain
    // 0.999999967, 62% off the 24-bit grid), but at low level by little: 0.00% of them past 3/8 of a
    // step, against 23-25% for any real level change down to -0.01 dB (simulated on the same file).
    private let gridLow = Atomic<Int>(0), gridFar24 = Atomic<Int>(0)
    private var gridLast = (0, 0, 0, 0, 0, 0)     // A's counters at the last check
    private var gridLastAt = Date.distantPast     // and when
    private var gridTotal = (0, 0, 0, 0, 0, 0)    // clean windows of this track
    private var gridPending: (Int, Int, Int, Int, Int, Int)? // the last clean window, counted once the next is clean too
    private var gridNear = false // the verdict's depth is near its grid (rounded in the playback path), not on it
    private var lastInfoAt = Date.distantPast
    private var gridSince: Date?
    private var gridVerdict: Int? // 16, 24, or 0 = on neither grid
    // after a lossless upgrade: skip windows until one is on the 24-bit grid (Music still plays the
    // buffered lossy start for a second or two after the ALAC line), at most until this time
    private var gridAwaitClean: Date?
    private var logBits: Int?     // the depth Music's log gave for the track
    private var wantBits: Int?    // 16/24/32: the track plays in the DAC's non-mixable integer format of that depth (Integer Mode)
    private var appliedWant: Int? // wantBits when the DAC's format was last set (nil: the option's format isn't on the DAC)
    private var sourceLossy = false // armAt is for a skip (the gap already went through A)
    // false: no decoder line of the track's own or file header said what the source is (coffee,
    // 2026-09-29: 12 iTunes Match AAC uploads logged none, were taken as lossless, and the Bit-Perfect
    // Check blamed Music for their off-grid samples)
    private var sourceKnown = true
    private var trackStartedLossy = false // this track had a lossy decoder of its own (a stream's start)
    private var gridInferredLossy = false // off every grid with nothing in Music changing samples: lossy
    private var latchedAt: Date?
    private var gatePending = false
    private var lastNewTrackAt: Date?
    // Decoder lines up to this time belong to the playing track: its own setup just after Playing
    // (streams and skips, ~0.4 s late) or the decoder a switch's rewind re-creates.
    private var ownLinesUntil: Date?
    private var trackRate: Float64? // the decoder rate decided for the playing track
    // a new track whose decoder line hasn't come yet; fallback: the line to use if none comes
    private var awaiting: (name: String, tPlay: Date, until: Date, fallback: DecoderLine?)?
    private var gateMarkedAt: Date?
    private var gateWaitsForMusic = false // after Music quit: the gate waits longer for its Playing
    private var regateOnSilence = false   // the gate let another sound through: close it when that ends
    private var musicPID: pid_t = 0
    // idle step-aside: Music not playing for RendererIdleSeconds -> DAC and default output given back
    private var steppedAside = false
    private var idleSince: Date?
    private var resumeInfo: (info: [AnyHashable: Any], at: Date)?
    private var resumeRetryAt: Date? // after a failed take-back: Music plays to the DAC; no retry before this
    private var musicListWrong = false
    // Music only (plug-in 1.1.4): what 'LSmx' holds (0 = off), the other apps' player
    private var musicOnlyPID: pid_t = 0
    private var alertsBefore = AudioObjectID(0) // the alert-sound device before this DAC was hogged
    private var musicOnlyMissingLogged = false
    private let others = OthersPlayer()
    private var othersDevice = AudioObjectID(0) // where other apps should play (0: nowhere); kept while the player is down
    private var othersChoice: String? // the Other apps and alerts choice startOthers followed
    private var othersRestartAt = Date.distantPast
    private let othersFeed = Atomic<Int>(0) // 1: A writes loopback channels 3-4 into others.ring
    private let othersPeakA = Atomic<UInt32>(0) // A: peak |sample| on channels 3-4 since the last meter line (Float bits)
    private var othersMeterAt = Date()

    /// NSRunningApplication once said Music wasn't running while it played on as the same process
    /// (Babyface bench, twice; the "quit" held its audio at the gate for 4 s and dropped the next
    /// track's decoder line). Its pid decides: Music quit only when that process is gone.
    private func musicRunning() -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first {
            musicPID = app.processIdentifier; musicListWrong = false
            return true
        }
        guard musicPID > 0, kill(musicPID, 0) == 0 || errno == EPERM else { musicPID = 0; return false }
        if !musicListWrong { musicListWrong = true; log("NSRunningApplication lists no Music, but pid \(musicPID) is alive: still running") }
        return true
    }
    private var strayMarkerAt: Date?
    private var setUpAt: Date?
    private var inputSeen = false
    private var inRoutine = false
    private var switches = 0
    private var scripts: RendererScripts!
    private let log = RendererLog()
    /// Frames B trails A by: ~0.35 s at the current rate (RendererTargetFrames overrides). A skip is
    /// reported ~0.25-0.3 s after the new track's audio started (Music's log line and Playing; pastor
    /// Mac, data/2026-09-29-pastor-skips): with 2048 frames (~46 ms) its start had already played at the
    /// old rate by then (5-260 ms leaked). 0.35 s keeps the gap between the tracks ahead of B.
    private let fixedTarget: Int?
    private let targetFillA = Atomic<Int>(2048)
    private var targetFill: Int { targetFillA.load(ordering: .relaxed) }
    // A's history of gaps (>= 10 ms of exact zeros): the ring position where each gap reached 10 ms
    private let gapHist = UnsafeMutablePointer<Int>.allocate(capacity: 32)
    private let gapCount = Atomic<Int>(0)
    private let gapLen = Atomic<Int>(441)
    private var gapRun = 0 // A only
    // clock lock (PLL on the phase between the two devices' time lines)
    private let tau = 5.0
    private var phase0: Double?
    private var dacScalarEst = 0.0, integ = 0.0, lsScalar = 1.0
    private var lockAfterCycles = (0, 0)
    private var waitingForScalar = false
    private var scalarHistory: [(t: Double, r: Double)] = [] // the DAC's HAL scalar at each pll() since the last reset
    private var waitingSince: Double?
    private var refillAsked = false
    private var scriptRate: Float64 = 0 // the rate the user's script (Scripting menu) last heard
    private var overshootLogged: Bool?
    private var ditherLogged: Bool?
    private var softwareVolumeLogged: Bool?
    private var ticksPerSec = 0.0

    // shared with the IO threads
    private let ring = VRing(frames: 1 << 20)
    private let stampA = VStamp(), stampB = VStamp()
    private let marker = Atomic<Int>(-1)      // ring position B doesn't read past; -1 none
    private let atBoundary = Atomic<Int>(0)   // B reached the marker
    private let command = Atomic<Int>(0)      // engine -> B: 1 go on past the marker, 2 flush and refill
    private let latchZeros = Atomic<Int>(0)   // > 0: latch armed, zero run (frames) that marks the boundary
    private let gate = Atomic<Int>(0)         // 1: A marks the ring at the first nonzero frame
    private let trimIdle = Atomic<Int>(0)     // 1: Music isn't playing; B keeps the ring at the target
    private let lastNZ = Atomic<Int>(0)       // ring position after the last nonzero frame A wrote
    private let outFormat = Atomic<Int>(0)    // packed OutFormat for B; 0 = mute
    private let formatDirty = Atomic<Int>(0)
    private let refill = Atomic<Int>(0)       // engine -> B: output silence until the ring is back at the target
    private let dropInput = Atomic<Int>(0)    // 1: A doesn't fill the ring (inside a switch; Music is paused)  // listener -> engine: the DAC's format changed
    private var writtenFormat = AudioStreamBasicDescription()
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var listenedStream = AudioStreamID(0)
    private let listenerQueue = DispatchQueue(label: "RendererEngine.formatListener")
    private lazy var volume = VolumeForwarder(log: { [unowned self] in self.log($0) })
    private var settingsCheckDue = true
    private let aCycles = Atomic<Int>(0), bCycles = Atomic<Int>(0)
    private let inFrames = Atomic<Int>(0), outFrames = Atomic<Int>(0)
    private let outSegmentAt = Atomic<Int>(-1) // B: outFrames where a flush took effect
    // IO-thread-only
    private var zeroRun = 0
    private var bPlaying = false
    private var ditherRNG: UInt32 = 0x9E3779B9 // TPDF dither state (xorshift32, never 0)
    private var softGain: Float = 1 // B: the software volume applied to the previous buffer (0 while muted)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: VirtualDeviceEngine.maxFrames * 2)
    private let scratchA = UnsafeMutablePointer<Float>.allocate(capacity: VirtualDeviceEngine.maxFrames * 2)  // A: Music (ch 1-2)
    private let scratchO = UnsafeMutablePointer<Float>.allocate(capacity: VirtualDeviceEngine.maxFrames * 2)  // A: the others (ch 3-4)
    private static let maxFrames = 16384
    private var recorder: VRecorder?

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        let t = UserDefaults.standard.integer(forKey: "RendererTargetFrames")
        fixedTarget = t > 0 ? t : nil
        targetFillA.store(t > 0 ? t : 2048, ordering: .relaxed)
        gapHist.initialize(repeating: -1, count: 32)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
        scratchA.initialize(repeating: 0, count: Self.maxFrames * 2)
        scratchO.initialize(repeating: 0, count: Self.maxFrames * 2)
    }

    deinit { scratch.deallocate(); scratchA.deallocate(); scratchO.deallocate(); gapHist.deallocate() }

    // MARK: - Lifecycle (main thread)

    var isRunning: Bool { thread != nil }

    func start() {
        guard thread == nil else { return }
        print("[Exclusive Mode] virtual-device engine: start requested")
        inboxLock.lock(); stopRequested = false; infoInbox = []; lineInbox = []; inboxLock.unlock()
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.inboxLock.lock(); self.infoInbox.append((Date(), note.userInfo ?? [:])); self.inboxLock.unlock()
        }
        startDecoderLog()
        let done = DispatchSemaphore(value: 0)
        finished = done
        let t = Thread { [weak self] in
            self?.run()
            done.signal()
        }
        t.name = "RendererEngine (virtual device)"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Stops the IO, gives the DAC back (mixable, hog released) and restores the default output.
    /// Waits for a switch in progress (up to 20 s).
    func stop() {
        guard thread != nil else { return }
        inboxLock.lock(); stopRequested = true; inboxLock.unlock()
        if finished?.wait(timeout: .now() + 20) == .timedOut {
            print("[Exclusive Mode] engine thread did not stop within 20 s")
            Self.recoverOutput()
        }
        thread = nil
        finished = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        logProcess?.terminate()
        logProcess = nil
    }

    private func startDecoderLog() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", "process == \"Music\" AND eventMessage CONTAINS \"Input format:\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var partial = "" // only touched by the serial readability handler
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self, let chunk = String(data: h.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            partial += chunk
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            let now = Date()
            self.inboxLock.lock(); self.lineInbox += lines.map { (now, $0) }; self.inboxLock.unlock()
        }
        do { try p.run(); logProcess = p } catch { print("[Exclusive Mode] could not start log stream: \(error)") }
    }

    // MARK: - Engine thread

    private var shouldStop: Bool { inboxLock.lock(); defer { inboxLock.unlock() }; return stopRequested }

    private func run() {
        log.start()
        log("engine started (virtual device)")
        if let note = UserDefaults.standard.string(forKey: Self.recoveryNoteKey) {
            log(note.replacingOccurrences(of: "[Exclusive Mode] ", with: "at launch: "))
            UserDefaults.standard.removeObject(forKey: Self.recoveryNoteKey)
        }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        ticksPerSec = 1e9 * Double(tb.denom) / Double(tb.numer)
        scripts = RendererScripts()
        recorder = VRecorder.fromDefaults(log: { [unowned self] in self.log($0) })
        guard checkMicrophone() else {
            log("engine idle until it is turned off; the output is unchanged")
            while !shouldStop { Thread.sleep(forTimeInterval: 0.1) }
            log.close()
            return
        }
        // Music's notices from before setup are stale (pastor Mac: queued while the Microphone prompt
        // waited ~5 min, then taken as a new track after setup: a switch for a track no longer playing).
        // setUp reads Music's state itself.
        inboxLock.lock(); let stale = infoInbox.count; infoInbox = []; inboxLock.unlock()
        if stale > 0 { log("dropped \(stale) Music notices from before setup") }
        guard setUp() else {
            log("setup failed; engine idle until it is turned off")
            while !shouldStop { Thread.sleep(forTimeInterval: 0.1) }
            log.close()
            return
        }
        var lastCheck = Date(), lastPLL = Date(), lastStatus = Date(), lastFormatCheck = Date(), lastMusicOnly = Date()
        while !shouldStop {
            pump()
            recorder?.drain()
            let now = Date()
            if now.timeIntervalSince(lastCheck) >= 1 { lastCheck = now; checkDevicesAndMusic(); followOthersChoice() }
            // Music relaunched (new pid): its first audio must not go to the speakers for long
            if now.timeIntervalSince(lastMusicOnly) >= 0.25 { lastMusicOnly = now; if !inRoutine { syncMusicOnly() } }
            tickLatchAndGate()
            if formatDirty.load(ordering: .acquiring) != 0 || now.timeIntervalSince(lastFormatCheck) >= 1 { lastFormatCheck = now; checkFormat() }
            if let up = pendingUpgrade, playing, !inRoutine {
                pendingUpgrade = nil
                trackRate = up.rate
                resetGrid()
                gridAwaitClean = Date().addingTimeInterval(5)
                setSource(up.bits, lossy: false)
                setWantBits(up.bits, lossless: true)
                if let r = neededRate(up.rate) {
                    log("lossless decoder at \(up.rate) Hz after a lossy start; switching again")
                    switchRate(r, name: "(lossless upgrade)", tPlay: Date())
                }
            }
            if now.timeIntervalSince(lastPLL) >= 0.5 { lastPLL = now; pll(); steerOthers(); checkGrid() }
            if playing { idleSince = nil } else if idleSince == nil { idleSince = now }
            let isp = OvershootProtection.shared.isOn
            if isp != overshootLogged {
                if overshootLogged != nil || isp { log("inter-sample overshoot protection \(isp ? "on: output -3.0 dB, not bit-perfect" : "off: output unchanged")") }
                overshootLogged = isp
            }
            let dth = TPDFDither.shared.isOn
            if dth != ditherLogged {
                if ditherLogged != nil || dth { log("TPDF dither \(dth ? "on: integer output under 32 bits is dithered when it can't be written exactly" : "off")") }
                ditherLogged = dth
            }
            let swv = SoftwareVolume.shared.isOn
            if swv != softwareVolumeLogged {
                if softwareVolumeLogged != nil || swv { log("software volume \(swv ? "on: a DAC with no volume control follows the volume keys; below 0 dB the output is not bit-perfect" : "off: output unchanged")") }
                softwareVolumeLogged = swv
                volume.softwareVolumeChanged()
            }
            if let r = resumeInfo { resumeInfo = nil; resumeFromIdle(r.info, at: r.at) }
            if !steppedAside, !inRoutine, !playing, let since = idleSince, UserDefaults.standard.bool(forKey: Defaults.kRendererReleaseWhenIdle) {
                let limit = max(UserDefaults.standard.double(forKey: "RendererIdleSeconds"), 0) > 0 ? UserDefaults.standard.double(forKey: "RendererIdleSeconds") : 60
                if now.timeIntervalSince(since) >= limit { stepAside(after: limit) }
            }
            if !inRoutine, settingsCheckDue || MusicSettingsCheck.shared.recheck.exchange(0, ordering: .acquiringAndReleasing) != 0 {
                settingsCheckDue = false
                MusicSettingsCheck.shared.check(scripts, musicRunning: musicRunning(), log: { [unowned self] in self.log($0) })
            }
            if now.timeIntervalSince(lastStatus) >= 30 {
                lastStatus = now
                // wall clock and clock-lock state: the overnight coffee log needed both
                let dacScalar = stampB.get().map { String(format: "%.6f", $0.2) } ?? "-"
                let clock = procB == nil ? "stepped aside" : phase0 != nil ? "locked" : waitingForScalar ? "waiting (DAC scalar not steady, following it)" : "not locked"
                log("\(Int(curRate)) Hz fill \(ring.fill) scalar \(String(format: "%.9f", lsScalar)) under \(ring.underruns.load(ordering: .relaxed)) over \(ring.overruns.load(ordering: .relaxed)); clock \(clock), DAC scalar \(dacScalar); \(RendererLog.wallClock.string(from: now))")
                if musicOnlyPID != 0 { log("music only: \(musicOnlyStatus())") }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        tearDown(restoreDefault: true, resumeMusic: true)
        MusicSettingsCheck.shared.clear()
        recorder?.finish()
        log("engine stopped")
        log.close()
    }

    /// Reading the virtual device's input needs the Microphone permission. Nothing is touched until
    /// it is answered: on the first launch of a new copy (Babyface bench) the default was already the
    /// virtual device while the prompt was open, each HAL call on its input blocked ~60 s, and setup
    /// failed after 3.5 min of silence. Without the permission the engine stays idle and the output
    /// is left as it was.
    private func checkMicrophone() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            log("microphone permission: granted")
            return true
        case .notDetermined:
            log("microphone permission: not determined; asking, and leaving the output alone until it is answered")
            final class Answer: @unchecked Sendable { var granted = false }
            let answer = Answer(), done = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { ok in answer.granted = ok; done.signal() }
            while done.wait(timeout: .now() + 0.2) == .timedOut {
                if shouldStop { log("turned off while the microphone prompt was open"); return false }
            }
            log("microphone permission \(answer.granted ? "granted" : "denied")")
            return answer.granted
        default:
            log("microphone permission DENIED: the engine can't read the virtual device. Allow Nativerate in System Settings > Privacy & Security > Microphone, then turn the engine off and on.")
            return false
        }
    }

    /// Drains the inbox; call instead of sleeping while waiting for Music's notifications.
    private func pump() {
        inboxLock.lock()
        let infos = infoInbox, lines = lineInbox
        infoInbox = []; lineInbox = []
        inboxLock.unlock()
        // in arrival order: a track's decoder line usually comes just before its Playing
        var events = infos.map { (at: $0.0, info: Optional($0.1), line: String?.none) } + lines.map { (at: $0.0, info: nil, line: Optional($0.1)) }
        events.sort { $0.at < $1.at }
        for e in events {
            if let info = e.info { handleInfo(info, at: e.at) } else if let line = e.line { handleLine(line, at: e.at) }
        }
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            pump()
            recorder?.drain()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return done()
    }

    // MARK: - Setup and teardown

    private func setUp() -> Bool {
        guard let l = Self.findDevice() else { log("virtual device not found"); return false }
        ls = l
        guard let d = chooseDAC() else { log("no output device to play to"); return false }
        let wasPlaying = musicPlaying()
        if wasPlaying {
            _ = scripts.pause()
            _ = wait(1) { !self.playing }
        }
        // a play while the DAC comes up (up to 12 s) waits at the gate
        playing = false
        gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing); trimIdle.store(1, ordering: .releasing)
        attach(true)
        // before the default moves here: no other app's audio may reach Music's channels meanwhile
        syncMusicOnly()
        UserDefaults.standard.set(true, forKey: Self.ownsOutputKey)
        if CA.defaultOutput() != ls { defaultBefore = CA.defaultOutput() }
        if CA.defaultOutput() != ls { log("default output -> virtual device: \(CA.setDefaultOutput(ls))") }
        guard startLS(), setUpDAC(d) else {
            tearDown(restoreDefault: true, resumeMusic: wasPlaying)
            return false
        }
        if wasPlaying { playChecked() }
        return true
    }

    /// The device chosen in the menu's Selected Device, if one is chosen and present (never the
    /// virtual device). The engine plays to it instead of the default output.
    private func selectedDAC() -> AudioObjectID? {
        guard let uid = Defaults.shared.selectedDeviceUID, uid != Self.deviceUID else { return nil }
        return CA.devices().first { CA.string($0, kAudioDevicePropertyDeviceUID) == uid && CA.hasOutput($0) }
    }

    /// The Selected Device, else the device Music played to before: the default output, or the saved
    /// DAC if the default is already the virtual device (an earlier run didn't restore it), or the
    /// system's fallback.
    private func chooseDAC() -> AudioObjectID? {
        if let s = selectedDAC() { return s }
        let d = CA.defaultOutput()
        if d != ls, d != 0 { return d }
        if let uid = UserDefaults.standard.string(forKey: Self.dacUIDKey),
           let saved = CA.devices().first(where: { CA.string($0, kAudioDevicePropertyDeviceUID) == uid }) { return saved }
        return Self.fallbackOutput(excluding: ls)
    }

    /// IOProc A: the virtual device's loopback input -> ring.
    private func startLS() -> Bool {
        var st = CA.setScalar(ls, 1.0, Self.kRateScalar)
        lsScalar = 1
        log("virtual device \(ls) @ \(CA.nominal(ls)) Hz; scalar reset \(st)")
        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, ls, nil) { [unowned self] _, inInput, inTime, _, _ in
            self.renderA(inInput, inTime)
        }
        guard st == noErr, let proc else { log("IOProc A: \(st)"); return false }
        procA = proc
        log("A: output streams off: \(CA.streamUsageOff(ls, proc, kAudioObjectPropertyScopeOutput))")
        st = AudioDeviceStart(ls, proc)
        log("start A: \(st)")
        return st == noErr
    }

    /// Hog + non-mixable on the DAC, virtual device at the DAC's rate, IOProc B on the DAC.
    private func setUpDAC(_ d: AudioObjectID) -> Bool {
        // before the hog: macOS moves alert sounds off a hogged device by itself (pastor Mac: to the
        // speakers, and back on release), so what the user had is only visible now
        alertsBefore = CA.systemOutput()
        dac = d
        dacUID = CA.string(d, kAudioDevicePropertyDeviceUID)
        UserDefaults.standard.set(dacUID, forKey: Self.dacUIDKey)
        guard let s = CA.streams(d, kAudioObjectPropertyScopeOutput).first else { log("DAC has no output stream"); return false }
        dacOut = s
        log("DAC \(CA.string(d, kAudioObjectPropertyName)) (\(dacUID)) @ \(CA.nominal(d)) Hz, hog owner \(CA.hogOwner(d)), my pid \(getpid())")
        // Coffee bench (DragonFly Black): taken right after Music had played to it directly (the
        // idle step-aside's resume), start B blocked 7.3 s and failed (35), every time. Let another
        // client's IO wind down first.
        if CA.runningSomewhere(d) {
            let t = Date()
            var stopped = waitPlain(2) { !CA.runningSomewhere(d) }
            log("DAC was still running for another client; \(stopped ? "stopped" : "STILL running") after \(ms(t))")
            // Coffee, 08:13:59 (take-back) and 08:17:13 (Exclusive Mode turned on): Music's stream to
            // the DAC was still running after 2 s; hog and the non-mixable format went ahead and the
            // left channel was distorted for as long as the engine held the DAC (clean with Exclusive
            // Mode off). Pause Music again and wait; never take a DAC another client still plays to.
            if !stopped {
                _ = scripts.pause()
                let t2 = Date()
                stopped = waitPlain(3) { !CA.runningSomewhere(d) }
                log("paused Music again: DAC \(stopped ? "stopped" : "STILL running") after \(ms(t2))")
                if !stopped {
                    log("not taking the DAC while another client plays to it")
                    return false
                }
            }
        }
        var me = getpid()
        var a = CA.addr(kAudioDevicePropertyHogMode)
        let st = AudioObjectSetPropertyData(d, &a, 0, nil, 4, &me)
        hogged = CA.hogOwner(d) == getpid()
        log("hog DAC: \(st), \(hogged ? "hogged" : "NOT hogged (shared mode, mixable)")")
        RendererOutput.shared.set(dacName: CA.string(d, kAudioObjectPropertyName), id: d)
        let rate = CA.nominal(d)
        if !CA.nominalRates(ls).contains(rate) { log("virtual device can't run at \(rate) Hz; Music will be resampled into it") }
        applyRate(rate)
        var proc: AudioDeviceIOProcID?
        let cst = AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { [unowned self] _, _, _, outOutput, outTime in
            self.renderB(outOutput, outTime)
        }
        guard cst == noErr, let proc else { log("IOProc B: \(cst)"); return false }
        procB = proc
        log("B: DAC inputs off: \(CA.streamUsageOff(d, proc, kAudioObjectPropertyScopeInput))")
        bPlaying = false
        outFormat.store(0, ordering: .releasing) // muted until the format is confirmed
        let bst = AudioDeviceStart(d, proc)
        log("start B: \(bst)")
        if bst == noErr, let target = dacFormat(curRate) {
            let t = Date()
            let ready = DeviceFormat.waitUntilReady(d, format: target, checkBitDepth: true, timeout: 12, stalled: { AudioDeviceStop(d, proc); AudioDeviceStart(d, proc) })
            log("DAC \(ready ? "ready" : "NOT ready") after \(ms(t)): \(CA.formats(dacOut))")
        }
        volume.start(virtual: ls, dac: d) // the gain is published while B is still muted (outFormat 0)
        updateOutFormat()
        listenForFormatChanges()
        startOthers()
        setUpAt = Date(); inputSeen = false
        recorder?.segmentOut(outFrames.load(ordering: .acquiring), curRate)
        recorder?.segmentIn(inFrames.load(ordering: .acquiring), curRate)
        resetLock()
        return bst == noErr
    }

    /// Sets both devices to `rate` (the DAC in its best format for it) without waiting for the DAC.
    private func applyRate(_ rate: Float64) {
        if CA.nominal(ls) != rate, CA.nominalRates(ls).contains(rate) {
            let st = CA.setNominal(ls, rate)
            let ok = waitPlain(2) { CA.nominal(self.ls) == rate }
            log("virtual device -> \(Int(rate)): \(st)\(ok ? "" : " (NOT confirmed)")")
        }
        if let f = dacFormat(rate) {
            var pf = f
            var a = CA.addr(kAudioStreamPropertyPhysicalFormat)
            let st = AudioObjectSetPropertyData(dacOut, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pf)
            nonMixable = f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
            log("DAC format -> \(CA.fmt(f)): \(st)")
            runUserScript(rate, bits: Int(f.mBitsPerChannel))
            appliedWant = wantBits
        } else if CA.nominal(dac) != rate {
            log("DAC has no listed format at \(rate) Hz; nominal rate -> \(CA.setNominal(dac, rate))")
            runUserScript(rate, bits: nil)
        }
        curRate = rate
        let margin = (SwitchGap(rawValue: UserDefaults.standard.string(forKey: Defaults.kSwitchMargin) ?? "") ?? .normal).margin
        targetFillA.store(fixedTarget ?? Int(rate * margin), ordering: .releasing)
        gapLen.store(max(Int(0.01 * rate), 1), ordering: .releasing)
        // the menu bar's rate: with Exclusive Mode on, OutputDevices' own detection is off and it only
        // re-reads a device when the default output changes, so a switch mid-session never reached it
        // (pastor Mac: "it's clearly switching but the taskbar is not")
        outputDevices.updateSampleRate(rate, bitDepth: nil)
        if others.isRunning, others.rate != rate { restartOthers("the virtual device's rate is now \(Int(rate)) Hz") }
        refreshReportedLatency()
    }

    /// Scripting menu: the regular path runs the user's script (rate, bit depth) when it sets a new
    /// rate; the engine owns rate changes while it runs, so it does the same, once per new rate.
    private func runUserScript(_ rate: Float64, bits: Int?) {
        guard rate != scriptRate else { return }
        scriptRate = rate
        guard let path = Defaults.shared.shellScriptPath else { return }
        log("script: \(path) \(Int(rate))\(bits.map { " \($0)" } ?? "")")
        let devices = outputDevices
        DispatchQueue.main.async { devices.runUserScript(rate, bitDepth: bits) }
    }

    /// Non-mixable first when hogged (exclusive integer output), then the most bits. With `wantBits`
    /// set, a non-mixable format of exactly that depth comes first.
    private func dacFormat(_ rate: Float64) -> AudioStreamBasicDescription? { dacFormat(rate, want: wantBits) }

    private func dacFormat(_ rate: Float64, want: Int?) -> AudioStreamBasicDescription? {
        let all = CA.availablePhysicalFormats(dacOut).filter {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM && ($0.mFormat.mSampleRate == rate || ($0.mSampleRateRange.mMinimum <= rate && rate <= $0.mSampleRateRange.mMaximum))
        }.map { r -> AudioStreamBasicDescription in var f = r.mFormat; f.mSampleRate = rate; return f }
        let usable = hogged ? all : all.filter { $0.mFormatFlags & kAudioFormatFlagIsNonMixable == 0 }
        if hogged, let w = want, let f = usable.first(where: {
            $0.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 && $0.mFormatFlags & kAudioFormatFlagIsFloat == 0 && Int($0.mBitsPerChannel) == w
        }) { return f }
        return usable.max { a, b in
            let na = a.mFormatFlags & kAudioFormatFlagIsNonMixable != 0, nb = b.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
            if na != nb { return !na }
            return a.mBitsPerChannel < b.mBitsPerChannel
        }
    }

    /// What B writes: the IOProc sees the stream's virtual format. Right after a physical format
    /// change the virtual format can still be the old one (in the first build it read float32 while
    /// the MT 48 already ran int32 non-mixable, and B wrote float bits into an integer stream), so B
    /// stays muted (outFormat 0) until the virtual format agrees with the physical one: equal when
    /// non-mixable, float32 at the same rate when mixable.
    private func updateOutFormat() {
        outFormat.store(0, ordering: .releasing)
        formatDirty.store(0, ordering: .releasing)
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription()
        let end = Date().addingTimeInterval(3)
        var confirmed = false
        while Date() < end {
            (pf, vf) = CA.physicalAndVirtual(dacOut)
            let nm = pf.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
            confirmed = pf.mSampleRate == vf.mSampleRate && pf.mSampleRate == curRate && (nm
                ? vf.mFormatFlags == pf.mFormatFlags && vf.mBitsPerChannel == pf.mBitsPerChannel && vf.mBytesPerFrame == pf.mBytesPerFrame
                : vf.mFormatFlags & kAudioFormatFlagIsFloat != 0 && vf.mBitsPerChannel == 32)
            if confirmed { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard confirmed else {
            log("B MUTED: DAC format not settled (phys \(CA.fmt(pf)) / virt \(CA.fmt(vf)), expected \(Int(curRate)) Hz)")
            return
        }
        var ch = [UInt32](repeating: 0, count: 2)
        var a = CA.addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var z = UInt32(8)
        let stereo = AudioObjectGetPropertyData(dac, &a, 0, nil, &z, &ch) == noErr && ch[0] >= 1 && ch[1] >= 1 ? (Int(ch[0]) - 1, Int(ch[1]) - 1) : (0, 1)
        let f = OutFormat(asbd: vf, left: stereo.0, right: stereo.1)
        writtenFormat = vf
        outFormat.store(f.packed, ordering: .releasing)
        let bits = f.isFloat ? 32 : f.bits
        let hasInt = CA.availablePhysicalFormats(dacOut).contains {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM
                && $0.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 && $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0
        }
        DispatchQueue.main.async { TPDFDither.shared.dacBits = bits; TPDFDither.shared.dacHasInt = hasInt }
        log("B writes \(f) (virtual format \(CA.fmt(vf)))")
    }

    /// Any change of the DAC stream's format mutes B at once; the engine thread re-confirms it.
    private func listenForFormatChanges() {
        var a = CA.addr(kAudioStreamPropertyVirtualFormat)
        let stream = dacOut
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let cur = self.outFormat.load(ordering: .acquiring)
            guard cur != 0 else { return } // already muted
            let now = OutFormat(packed: cur)
            let (pf, vf) = CA.physicalAndVirtual(stream)
            let fresh = OutFormat(asbd: vf, left: now.left, right: now.right)
            // B's format still describes the buffers (and the physical side agrees): nothing to do
            if fresh.packed == cur && pf.mSampleRate == vf.mSampleRate { return }
            self.outFormat.store(0, ordering: .releasing)
            self.formatDirty.store(1, ordering: .releasing)
        }
        formatListener = block
        listenedStream = dacOut
        let st = AudioObjectAddPropertyListenerBlock(dacOut, &a, listenerQueue, block)
        a = CA.addr(kAudioStreamPropertyPhysicalFormat)
        let st2 = AudioObjectAddPropertyListenerBlock(dacOut, &a, listenerQueue, block)
        log("format listeners: \(st) \(st2)")
    }

    private func removeFormatListener() {
        guard let block = formatListener else { return }
        var a = CA.addr(kAudioStreamPropertyVirtualFormat)
        AudioObjectRemovePropertyListenerBlock(listenedStream, &a, listenerQueue, block)
        a = CA.addr(kAudioStreamPropertyPhysicalFormat)
        AudioObjectRemovePropertyListenerBlock(listenedStream, &a, listenerQueue, block)
        formatListener = nil
    }

    /// Engine thread: a format change seen by the listener (or the periodic check) is re-confirmed.
    private func checkFormat() {
        guard procB != nil, !inRoutine else { return }
        let (_, vf) = CA.physicalAndVirtual(dacOut)
        let changed = formatDirty.load(ordering: .acquiring) != 0 || !CA.same(vf, writtenFormat)
        guard changed else { return }
        log("DAC format changed (virt \(CA.fmt(vf))); B muted, re-confirming")
        outFormat.store(0, ordering: .releasing)
        curRate = CA.nominal(dac)
        updateOutFormat()
    }

    private func tearDownDAC(keepOthers: Bool = false) {
        if !keepOthers { stopOthers() }
        outFormat.store(0, ordering: .releasing) // B silent before the volume forwarder lets go
        volume.stop()
        removeFormatListener()
        DispatchQueue.main.async { TPDFDither.shared.dacBits = nil }
        if let p = procB {
            AudioDeviceStop(dac, p)
            AudioDeviceDestroyIOProcID(dac, p)
            procB = nil
        }
        if nonMixable {
            log("DAC mixable again: \(CA.setMixable(dac))")
            nonMixable = false
        }
        if hogged {
            var none = pid_t(-1)
            var a = CA.addr(kAudioDevicePropertyHogMode)
            let st = AudioObjectSetPropertyData(dac, &a, 0, nil, 4, &none)
            log("hog released: \(st), owner \(CA.hogOwner(dac))")
            hogged = false
        }
        RendererOutput.shared.set(dacName: nil, id: nil)
    }

    /// Every exit path: IO stopped, DAC mixable and released, scalar reset, default output restored.
    private func tearDown(restoreDefault: Bool, resumeMusic: Bool) {
        let wasPlaying = resumeMusic && musicPlaying()
        if wasPlaying { _ = scripts.pause(); _ = wait(1) { !self.playing } }
        if let p = procA {
            AudioDeviceStop(ls, p)
            AudioDeviceDestroyIOProcID(ls, p)
            procA = nil
        }
        tearDownDAC()
        clearMusicOnly()
        setReportedLatency(0)
        if ls != 0 { log("virtual device scalar reset: \(CA.setScalar(ls, 1.0, Self.kRateScalar))") }
        // the default the user had (with a Selected Device the DAC can be another device)
        let back = defaultBefore != 0 && defaultBefore != ls && CA.hasOutput(defaultBefore) ? defaultBefore : dac
        if restoreDefault, back != 0, back != ls, CA.defaultOutput() == ls {
            log("default output restored to \(CA.string(back, kAudioObjectPropertyName)): \(CA.setDefaultOutput(back))")
            // coreaudiod re-evaluates its preferred default after the hog release and format change,
            // with the virtual device still first in its list (the update is asynchronous): in trial
            // m3 it put the virtual device back 48 ms after the restore. Hold the restore for 3 s.
            var resets = 0
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.05)
                if CA.defaultOutput() == ls {
                    resets += 1
                    log("coreaudiod put the virtual device back as the default; restoring again: \(CA.setDefaultOutput(back))")
                }
            }
            log("default output after 3 s: \(CA.string(CA.defaultOutput(), kAudioObjectPropertyName))\(resets > 0 ? " (\(resets) re-restores)" : "")")
        }
        if restoreDefault {
            if let note = Self.restoreAlerts() { log(note) }
            attach(false)
            UserDefaults.standard.removeObject(forKey: Self.ownsOutputKey)
        }
        if wasPlaying { playChecked() }
    }

    /// True with plug-in 1.0 (no 'LSac': nothing to lose).
    private func isAttached() -> Bool {
        var a = CA.addr(Self.kAttached)
        guard ls != 0, AudioObjectHasProperty(ls, &a) else { return true }
        var v: Unmanaged<CFPropertyList>?; var z = UInt32(MemoryLayout<CFPropertyList?>.size)
        guard AudioObjectGetPropertyData(ls, &a, 0, nil, &z, &v) == noErr, let n = v?.takeRetainedValue() as? NSNumber else { return false }
        return n.int32Value == getpid()
    }

    /// Attached, and the virtual device is the default output (before Music plays again).
    private func reclaimDefault() {
        if !isAttached() { attach(true) }
        if CA.defaultOutput() != ls { log("default output was \(CA.string(CA.defaultOutput(), kAudioObjectPropertyName)); back to the virtual device: \(CA.setDefaultOutput(ls))") }
    }

    /// Plug-in 1.1+: the device can be the default output only while attached.
    private func attach(_ on: Bool) {
        var a = CA.addr(Self.kAttached)
        guard ls != 0, AudioObjectHasProperty(ls, &a) else {
            if on { log("virtual device has no 'LSac' (plug-in older than 1.1): it stays eligible as the default output after the engine stops; update it from the menu") }
            return
        }
        log("\(on ? "attached" : "detached") (pid \(on ? getpid() : 0)): \(CA.setCFNumber(ls, Self.kAttached, NSNumber(value: on ? Int32(getpid()) : 0)))")
    }

    /// Music may not start when told to play right after the default output changed: check, retry.
    /// Asks Music, not the notices: they can arrive seconds late and in a burst (Executor,
    /// 2026-10-03), so `playing` still read false after Music had started, the retries went on, and
    /// the next one undid the listener's pause.
    private func playChecked() {
        for attempt in 1...4 {
            _ = scripts.play()
            if wait(2, until: { self.scripts.playerState() == "playing" }) { return }
            log("play attempt \(attempt): Music isn't playing")
        }
    }

    // MARK: - Music only: other apps to the built-in speakers (plug-in 1.1.4)

    /// 'LSmx' = Music's pid while the engine plays; our own pid while Music isn't running (no client
    /// of ours plays into the device, so every app goes to the speakers). Plug-in older than 1.1.4:
    /// other apps still mix into Music (logged once; the Bit-perfect check says so).
    private func syncMusicOnly() {
        guard procA != nil, ls != 0 else { return }
        var a = CA.addr(Self.kMusicOnly)
        guard AudioObjectHasProperty(ls, &a) else {
            if !musicOnlyMissingLogged {
                musicOnlyMissingLogged = true
                log("virtual device has no 'LSmx' (plug-in older than 1.1.4): other apps mix into Music; update it from the menu")
            }
            return
        }
        let want: pid_t = musicRunning() && musicPID > 0 ? musicPID : getpid()
        guard want != musicOnlyPID else { return }
        let st = CA.setCFNumber(ls, Self.kMusicOnly, NSNumber(value: want))
        log("music only: 'LSmx' = \(want) (\(want == getpid() ? "Music isn't running: every app goes to the other-apps path" : "Music"); was \(musicOnlyPID)): \(st)")
        if st == noErr { musicOnlyPID = want }
    }

    private func clearMusicOnly() {
        guard musicOnlyPID != 0, ls != 0 else { return }
        log("music only off ('LSmx' = 0): \(CA.setCFNumber(ls, Self.kMusicOnly, NSNumber(value: Int32(0))))")
        musicOnlyPID = 0
    }

    /// The plug-in's per-client counters (ProcessOutput calls, Music's share, frames moved) and the
    /// others path: the bench's proof that coreaudiod hands each client's buffer to the plug-in.
    private func musicOnlyStatus() -> String {
        var a = CA.addr(Self.kStatus)
        var v: Unmanaged<CFPropertyList>?; var z = UInt32(MemoryLayout<CFPropertyList?>.size)
        var plug = "plug-in status unreadable"
        if AudioObjectGetPropertyData(ls, &a, 0, nil, &z, &v) == noErr, let d = v?.takeRetainedValue() as? [String: NSNumber], let calls = d["processOutputCalls"] {
            plug = "ProcessOutput calls \(calls.int64Value), Music's \(d["musicClientCalls"]?.int64Value ?? -1), other apps' frames \(d["othersFramesMoved"]?.int64Value ?? -1), pid \(d["musicPID"]?.int32Value ?? -1)"
            // 1.1.5: peaks since the last read (handed in by other apps / read back on ch 3-4) and how far
            // a ProcessOutput's sample time was from its cycle's WriteMix
            if let pin = d["othersPeakIn"]?.doubleValue, let pr = d["othersPeakRead"]?.doubleValue {
                plug += String(format: "; peak in %.4f, read back %.4f; time delta max %.0f frames in %lld cycles", pin, pr, d["othersMaxTimeDelta"]?.doubleValue ?? -1, d["othersTimeDeltaCycles"]?.int64Value ?? -1)
            }
        }
        return plug + "; " + others.status
    }

    /// With the DAC set up: other apps' audio to the built-in speakers, alert sounds there too. No
    /// speakers besides the DAC: other apps are muted ('LSmx' keeps them out of Music).
    private func startOthers() {
        var a = CA.addr(Self.kMusicOnly)
        guard ls != 0, AudioObjectHasProperty(ls, &a), CA.streams(ls, kAudioObjectPropertyScopeInput).first.map({ CA.channels($0) == 4 }) ?? false else {
            RendererOutput.shared.set(othersRoute: "Other apps mix into Music (update the Exclusive Mode driver)", ok: false)
            return
        }
        let (target, note) = OtherAppsOutput.resolve(dac: dac)
        othersChoice = UserDefaults.standard.string(forKey: OtherAppsOutput.choiceKey)
        if let t = target, t == othersDevice, others.isRunning {
            othersFeed.store(1, ordering: .releasing)
            moveAlerts(to: t)
            refreshReportedLatency()
            return
        }
        guard let sp = target else {
            log("other apps: MUTED (\(note)); Music alone reaches the DAC")
            RendererOutput.shared.set(othersRoute: "Other apps muted", ok: true)
            refreshReportedLatency()
            // alert sounds still leave the DAC: to the built-in speakers if there are any
            if let b = Self.builtInSpeakers(excluding: dac) { moveAlerts(to: b) }
            return
        }
        let name = CA.string(sp, kAudioObjectPropertyName)
        othersDevice = sp
        othersRestartAt = Date()
        log("other apps and alert sounds: \(name) (\(note))")
        if others.start(device: sp, rate: curRate, log: { [unowned self] in self.log($0) }) {
            othersFeed.store(1, ordering: .releasing)
            RendererOutput.shared.set(othersRoute: "Other apps play on \(name)", ok: true)
            refreshReportedLatency()
        } else {
            log("other apps: MUTED (the player on \(name) didn't start)")
            RendererOutput.shared.set(othersRoute: "Other apps muted (\(name) didn't start)", ok: true)
            refreshReportedLatency()
        }
        OtherAppsOutput.shared.setActive(sp)
        moveAlerts(to: sp)
    }

    /// Engine thread, each second: the Other apps and alerts choice changed, or the chosen device came
    /// back or went away: play other apps (and alerts) where it now says.
    private func followOthersChoice() {
        guard procB != nil, !inRoutine else { return }
        var a = CA.addr(Self.kMusicOnly)
        guard ls != 0, AudioObjectHasProperty(ls, &a) else { return }
        let choice = UserDefaults.standard.string(forKey: OtherAppsOutput.choiceKey)
        let target = OtherAppsOutput.resolve(dac: dac).device ?? 0
        guard choice != othersChoice || target != othersDevice else { return }
        log("other apps: the choice is now \(choice ?? "automatic"); moving")
        stopOthers()
        startOthers()
    }

    private func stopOthers() {
        othersDevice = 0
        OtherAppsOutput.shared.setActive(0)
        othersFeed.store(0, ordering: .releasing)
        if others.isRunning { log("other apps: player stopped (\(others.status))") }
        others.stop()
        RendererOutput.shared.set(othersRoute: nil, ok: true)
    }

    private func restartOthers(_ why: String) {
        let d = othersDevice
        guard d != 0 else { return }
        othersRestartAt = Date()
        log("other apps: restarting the player (\(why))")
        othersFeed.store(0, ordering: .releasing)
        if others.start(device: d, rate: curRate, log: { [unowned self] in self.log($0) }) { othersFeed.store(1, ordering: .releasing); refreshReportedLatency() }
    }

    /// Every 0.5 s: the speakers' varispeed follows the others ring's fill (the two clocks drift).
    /// The player is rebuilt only when it stopped or left the speakers, at most every 2 s: AVAudioEngine
    /// posts a configuration change right after every start while it keeps running (pastor Mac, 48k:
    /// restarting on each notice looped 19 times and left it stopped; other apps were silent).
    private func steerOthers() {
        guard othersDevice != 0 else { return }
        // meter: where other apps' audio is lost, if it is (pastor: YouTube silent on the speakers)
        if Date().timeIntervalSince(othersMeterAt) >= 10 {
            othersMeterAt = Date()
            let a = Float(bitPattern: othersPeakA.exchange(0, ordering: .relaxed)), p = others.takePeak()
            func db(_ x: Float) -> String { x > 0 ? String(format: "%.1f dBFS", 20 * log10(x)) : "silent" }
            log("other apps meter (10 s): loopback ch 3-4 peak \(db(a)), player out peak \(db(p)); \(others.status); plug-in: \(musicOnlyStatus().components(separatedBy: "; other apps:").first ?? "")")
        }
        if let why = others.problem() {
            if Date().timeIntervalSince(othersRestartAt) >= 2 { restartOthers(why) }
            return
        }
        others.steer(gain: OtherAppsOutput.shared.softwareGain)
    }

    /// Alert sounds to the speakers while the engine holds the DAC; the device before is saved (for
    /// the restore and the unclean-exit recovery) unless an earlier move is still unrestored.
    private func moveAlerts(to sp: AudioObjectID) {
        let cur = CA.systemOutput()
        let before = alertsBefore != 0 ? alertsBefore : cur
        let saved = UserDefaults.standard.stringArray(forKey: Self.alertsMovedKey) != nil
        if before != sp, !saved {
            UserDefaults.standard.set([CA.string(before, kAudioDevicePropertyDeviceUID), CA.string(sp, kAudioDevicePropertyDeviceUID)], forKey: Self.alertsMovedKey)
        }
        if cur != sp {
            log("alert sounds -> \(CA.string(sp, kAudioObjectPropertyName)) (were on \(CA.string(cur, kAudioObjectPropertyName))): \(CA.setSystemOutput(sp))")
        } else if before != sp {
            log("alert sounds on \(CA.string(sp, kAudioObjectPropertyName)) (macOS moved them off the hogged DAC; were on \(CA.string(before, kAudioObjectPropertyName)))")
        }
    }

    // MARK: - Music events

    private func handleInfo(_ info: [AnyHashable: Any], at: Date) {
        lastInfoAt = at
        let state = info["Player State"] as? String ?? "?"
        let name = info["Name"] as? String ?? ""
        // stations and Browse streams have no PersistentID: tell tracks apart by name
        let pid = (info["PersistentID"] as? NSNumber)?.int64Value ?? (name.isEmpty ? nil : Int64(truncatingIfNeeded: name.hashValue))
        log("playerInfo: \(state) \(name)")
        playing = state == "Playing"
        guard !inRoutine else { return } // our own pause/play
        if steppedAside {
            // Music plays straight to the DAC now; the run loop takes the output back
            if playing, resumeInfo == nil {
                if let r = resumeRetryAt, Date() < r { return } // our own play after a failed take-back
                resumeInfo = (info, at)
            }
            return
        }
        // Music can post Playing with no name and no PersistentID just before the real track's
        // (Babyface bench, before YYZ). It is not a track: taking a decoder line for it released the
        // gate, and the real track played at the old rate until its own line came. If no real one
        // follows, the next decoder line (or 3 s) decides for it.
        if playing, name.isEmpty, info["PersistentID"] == nil {
            if gatePending, awaiting == nil { awaiting = ("(no name)", at, Date().addingTimeInterval(3), nil) }
            log("playerInfo without a name or PersistentID: not a track; gate \(gatePending ? "held" : "open")")
            return
        }
        if playing { gateWaitsForMusic = false; regateOnSilence = false }
        let armedOrLatched = armAt != nil || latchZeros.load(ordering: .acquiring) > 0 || latchedAt != nil
        if !playing {
            if pid == lastTrackID, armedOrLatched { disarm("\(state) on the same track") }
            // the next play waits at the gate until its track's rate is known
            if !gatePending { gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing) }
            trimIdle.store(1, ordering: .releasing)
            return
        }
        trimIdle.store(0, ordering: .releasing)
        if pid == lastTrackID { // resume or seek
            let late = lateArmAt != nil
            if armedOrLatched { disarm("seek on the same track") }
            // the second arm's time moved with the pause or seek: take it from Music again
            if late, let left = scripts.remaining(), left > 1.5 { lateArmAt = Date().addingTimeInterval(left - 1.5); log("boundary latch re-timed: \(String(format: "%.2f", left - 1.5)) s") }
            releaseGate("same track")
            return
        }
        lastTrackID = pid
        settingsCheckDue = true // after the rate decision below: the loop runs it
        lateArmAt = nil
        lossyTrackAt = nil; lossyStartAt = nil
        awaiting = nil
        // Only a decoder line that came after the previous track began can be this track's (its
        // pre-roll, or its own setup). In trial m1 an Apple Music stream reported Playing before its
        // decoder line, and the previous track's 20 s old line was taken for it.
        let prev = lastNewTrackAt
        let prevOwnUntil = ownLinesUntil
        lastNewTrackAt = at
        ownLinesUntil = max(at.addingTimeInterval(2), prevOwnUntil ?? .distantPast)
        trackRate = nil
        // Music's own rate for the track decides when it gives one: on skips forward and back Music logs
        // decoder lines for the track it leaves, the one it goes to and its pre-roll, and the newest
        // line was another track's (pastor Mac, 2026-09-29: As Alive As You Need Me To Be, 48k, played
        // at 44.1k on a line 15.5 s old; Afraid of Time, 44.1k, switched to 48k on a line 0.4 s after
        // its Playing). Polled every 0.3 s over 3 min of skipping, Music's rate for the current track
        // was right at once for every track; once "missing value" right at the change.
        if let r = musicTrackRate(name: name) {
            let newest = decoderRates.last(where: { prev == nil || $0.date > prev! })
            // not a line from the previous track's own window: that's its setup or lossless upgrade
            // (coffee: Little Martha took the line of the track before, 203 s old, as its own 24 bit)
            let own = decoderRates.last(where: { (prev == nil || $0.date > prev!) && (prevOwnUntil == nil || $0.date > prevOwnUntil!) && $0.rate == r })
            if let n = newest, n.rate != r { log("new track \(name): the newest decoder line says \(Int(n.rate)) Hz, Music says \(Int(r)) Hz for the track; Music's decides") }
            let libLossy = own == nil && libraryLossy(name: name)
            decide(r, bits: own.flatMap { depthTrusted($0.date, tPlay: at) ? $0.bits : nil }, lossless: own?.lossless ?? !libLossy, seenAgo: own.map { at.timeIntervalSince($0.date) } ?? 0,
                   name: name + (own == nil ? " (Music's rate for the track; no decoder line at it yet)" : " (Music's rate for the track)"), tPlay: at,
                   sourceKnown: own != nil || libLossy)
            return
        }
        guard let line = decoderRates.last(where: { prev == nil || $0.date > prev! }) else {
            // A gapless successor can have its decoder set up before the previous track began (trial
            // m2: none logged for Wish You Were Here after Have a Cigar). A local file's own header
            // decides; a stream waits for its line.
            if let st = LocalTrack.currentStats(attempts: 3) {
                // lossless: true as before (a lossy mark would arm the stream upgrade path); the menu
                // still learns the file is lossy
                decide(st.sampleRate, bits: st.sourceBits, lossless: true, seenAgo: 0, name: name + " (file header, no decoder line)", tPlay: at)
                if st.lossy { setSource(nil, lossy: true) }
                return
            }
            awaiting = (name, at, Date().addingTimeInterval(3), nil)
            log("new track \(name): no decoder line for it yet; \(gatePending ? "holding at the gate" : "playing on at \(Int(curRate)) Hz") until one comes (3 s)")
            return
        }
        // A line from the previous track's own window may be that track's late setup, not this one's
        // (Executor bench: two skips ~12 s apart each took the track before's line, so Deadbeat Drag
        // played at 48k and Earth was switched to 44.1k; each track's own line came ~0.4 s after its
        // Playing). Wait briefly for a newer line; if none comes, this one decides.
        if let own = prevOwnUntil, line.date <= own {
            awaiting = (name, at, Date().addingTimeInterval(1), line)
            log("new track \(name): the newest decoder line (\(Int(line.rate)) Hz, \(String(format: "%.3f", at.timeIntervalSince(line.date))) s before Playing) may be the previous track's; waiting 1 s for its own")
            return
        }
        decide(line.rate, bits: depthTrusted(line.date, tPlay: at) ? line.bits : nil, lossless: line.lossless, seenAgo: at.timeIntervalSince(line.date), name: name, tPlay: at)
    }

    /// A line's depth is the new track's if it came within 3 s of its Playing, or as a pre-roll while the
    /// track before played. Else Integer Mode asks for nothing (widest format). The latch arm in
    /// handleLine uses the same pre-roll test, so it and decide() agree on the wanted format.
    private func depthTrusted(_ date: Date, tPlay: Date) -> Bool {
        tPlay.timeIntervalSince(date) <= 3 || preRollLines.contains(date)
    }

    /// Music's sample rate for the current track, if the current track is `name` (up to ~1 s of retries:
    /// it can read "missing value", or still the previous track, right at a change). Nil: Music didn't
    /// say; the decoder lines decide.
    private func musicTrackRate(name: String) -> Double? {
        let t0 = Date()
        for attempt in 0..<6 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
            guard let t = scripts.trackRate() else { continue }
            if !name.isEmpty, t.name != name { continue }
            if let r = t.rate { return r }
        }
        log("new track \(name): Music gave no sample rate for it within \(ms(t0)); using the decoder lines")
        return nil
    }

    /// The menu's source depth: measured from the samples once known, else Music's log.
    private func setSource(_ bits: Int?, lossy: Bool, known: Bool = true) {
        logBits = bits; sourceLossy = lossy; sourceKnown = known
        if lossy { trackStartedLossy = true }
        publishSource()
    }

    private func publishSource() {
        let shown = gridVerdict.flatMap { $0 == 0 ? nil : $0 } ?? logBits
        let lossy = sourceLossy || (gridVerdict == 0 && gridInferredLossy)
        RendererOutput.shared.set(sourceBits: lossy ? nil : shown, lossy: lossy)
        // only a source known to be lossless on no grid means Music changes the samples
        RendererOutput.shared.set(offGrid: !lossy && sourceKnown && gridVerdict == 0)
        RendererOutput.shared.set(nearGrid: !sourceLossy && gridNear ? gridVerdict ?? 0 : 0)
    }

    private func gridCounters() -> (Int, Int, Int, Int, Int, Int) {
        (gridNZ.load(ordering: .acquiring), gridOff16.load(ordering: .acquiring), gridOff24.load(ordering: .acquiring), gridFar16.load(ordering: .acquiring),
         gridLow.load(ordering: .acquiring), gridFar24.load(ordering: .acquiring))
    }

    /// A new track (or decoder): measure its depth from here.
    private func resetGrid() {
        gridLast = gridCounters(); gridLastAt = Date()
        gridTotal = (0, 0, 0, 0, 0, 0); gridPending = nil
        gridSince = Date(); gridVerdict = nil; gridNear = false; gridAwaitClean = nil; gridInferredLossy = false
        RendererOutput.shared.set(offGrid: false)
        RendererOutput.shared.set(nearGrid: 0)
    }

    /// No decoder line of its own: Music's library can still say the track is lossy, when it's an AAC or
    /// MP3 file on disk or an iCloud upload (pastor, 2026-09-30: 5 of 8 "? bit" tracks were uploaded AAC).
    /// Matched and Apple Music tracks stream lossless or AAC, so they stay unknown.
    private func libraryLossy(name: String) -> Bool {
        guard let s = scripts.trackSource(), name.isEmpty || s.name == name else { return false }
        let lossyKind = s.kind.contains("AAC") || s.kind == "MPEG audio file"
        let lossy = lossyKind && (s.localFile || s.cloud == "uploaded")
        log("library: \(s.kind), \(s.cloud.isEmpty ? "no cloud status" : s.cloud), \(s.localFile ? "file on disk" : "no file on disk")\(lossy ? ": lossy" : "")")
        return lossy
    }

    /// Every 0.5 s: counts the window if Music played steadily through it (Music ramps the level at a
    /// pause, ~50 ms off every grid on the pastor Mac: a window within 1 s of a play, pause or track
    /// notice is dropped, and so is the window before a pause). From 2 s into the track, with 0.5 s of
    /// nonzero samples counted, the depth the samples need; only ever up (16 -> 24 -> neither).
    private func checkGrid() {
        let snap = gridCounters()
        let win = (snap.0 &- gridLast.0, snap.1 &- gridLast.1, snap.2 &- gridLast.2, snap.3 &- gridLast.3, snap.4 &- gridLast.4, snap.5 &- gridLast.5)
        let now = Date()
        let span = now.timeIntervalSince(gridLastAt)
        gridLast = snap; gridLastAt = now
        guard let since = gridSince else { return }
        // A window over 1 s long spans a switch (the routine blocks this loop, then watches Music for
        // 1 s while its notices still come in, so the notice test alone passes). It holds the track's
        // first ~0.07 s played into the old rate and Music's first buffer after the rewind, both off
        // every grid (Executor, 2026-10-04, Kind & Generous after a 96k track: 9368 and 706 samples past
        // 1/64 of a 16-bit step, every later buffer within 0.002 of one): "neither", not 16 bit.
        let clean = playing && !inRoutine && span <= 1 && now.timeIntervalSince(lastInfoAt) > 1 && now.timeIntervalSince(since) >= 1
        if let until = gridAwaitClean {
            if clean && win.0 > 0 && (win.2 == 0 || win.3 == 0) { // on the 24-bit grid, or near the 16-bit one
                gridAwaitClean = nil
                log("source depth: on the 24-bit grid \(String(format: "%.1f", now.timeIntervalSince(since))) s after the lossless decoder; measuring")
            } else if now < until {
                gridPending = nil
                return
            } else {
                gridAwaitClean = nil
                log("source depth: no window on the 24-bit grid within 5 s of the lossless decoder; measuring anyway")
            }
        }
        if clean {
            if let p = gridPending { gridTotal = (gridTotal.0 + p.0, gridTotal.1 + p.1, gridTotal.2 + p.2, gridTotal.3 + p.3, gridTotal.4 + p.4, gridTotal.5 + p.5) }
            gridPending = win
        } else {
            gridPending = nil
        }
        guard now.timeIntervalSince(since) >= 2 else { return }
        let (nz, o16, o24, f16, low, f24) = gridTotal
        guard nz >= Int(curRate) else { return }
        // Off every grid but all within 1/64 of a 16-bit step: a 16-bit source rounded on the way
        // (macOS 26), not a level change. Still 16 bit, just not bit-exact.
        let near16 = o24 > 0 && f16 == 0
        // The same for a 24-bit source: under 1% of the low-level samples past 3/8 of a step (a real
        // level change puts ~24% there), with enough of them to tell.
        let near24 = o24 > 0 && !near16 && low >= 2000 && f24 * 100 < low
        let near = near16 || near24
        let v = near16 ? 16 : near24 ? 24 : o24 > 0 ? 0 : o16 > 0 ? 24 : 16
        // only ever up: 16 -> 16 near -> 24 -> 24 near -> neither
        let rank = { (v: Int, n: Bool) in v == 16 ? (n ? 1 : 0) : v == 24 ? (n ? 3 : 2) : 4 }
        if let g = gridVerdict, rank(v, near) <= rank(g, gridNear) { return }
        gridVerdict = v; gridNear = near
        // Off every grid, and it's not known to be lossless: lossy if the track started on a lossy
        // decoder (it can stay on it after a lossless line: coffee, "Me and My Nothin'"), or if nothing
        // readable in Music changes samples (Music reuses a decoder across same-format tracks and logs
        // no line: coffee, "Get Behind the Mule" on Another Day's AAC decoder; showed "? bit").
        if v == 0, !sourceLossy {
            gridInferredLossy = trackStartedLossy || (!sourceKnown && musicLeavesSamplesAlone())
        }
        let why = v == 0 ? "on neither the 16- nor the 24-bit grid (\(o24) of \(nz) samples): \(sourceLossy ? "lossy" : gridInferredLossy ? (trackStartedLossy ? "lossy (it started on a lossy decoder)" : "lossy (no decoder line of its own; Music's volume 100, Sound Check and Sound Enhancer off)") : !sourceKnown ? "no decoder line of its own, so lossy or changed by Music" : "Music changes them (volume, Sound Check, EQ) or the source is float")"
            : near16 ? "\(o24) of \(nz) samples within 1/64 of a 16-bit step but not on it: rounded in the playback path, not bit-exact"
            : near24 ? "\(o24) of \(nz) samples off the 24-bit grid, \(f24) of \(low) low-level ones past 3/8 of a step: rounded in the playback path, not bit-exact"
            : v == 24 ? "\(o16) of \(nz) samples off the 16-bit grid, all on the 24-bit grid" : "all \(nz) on the 16-bit grid"
        log("source depth from the samples: \(v == 0 ? "neither 16 nor 24 bit" : "\(v) bit") (\(why))\(logBits.map { $0 != v ? "; Music's log said \($0) bit" : "" } ?? "")")
        publishSource()
    }

    /// Music's readable settings that change samples are all off: volume 100, Sound Check and Sound
    /// Enhancer off (EQ can't be read; the Bit-perfect check asks to check it).
    private func musicLeavesSamplesAlone() -> Bool {
        let app = "com.apple.Music" as CFString
        CFPreferencesAppSynchronize(app)
        // 0 or false when off (macOS 27 on coffee stores a Bool), absent when on
        let sc = CFPreferencesCopyAppValue("optimizeSongVolume" as CFString, app) as? NSNumber
        let en = CFPreferencesCopyAppValue("soundEnhancerEnabled" as CFString, app) as? NSNumber
        let vol = scripts.volume()
        let alone = sc?.intValue == 0 && (en?.intValue ?? 0) == 0 && vol == 100
        log("source depth: Music's settings: Sound Check \(sc.map { "\($0)" } ?? "absent (on)"), Sound Enhancer \(en.map { "\($0)" } ?? "absent (off)"), volume \(vol.map(String.init) ?? "?"): \(alone ? "nothing readable changes the samples" : "may change them")")
        return alone
    }

    private func decide(_ rate: Float64, bits: Int?, lossless: Bool, seenAgo: TimeInterval, name: String, tPlay: Date, sourceKnown: Bool = true) {
        resetGrid()
        trackStartedLossy = false
        trackRate = rate
        setSource(bits, lossy: !lossless, known: sourceKnown)
        setWantBits(bits, lossless: lossless)
        if !lossless { lossyTrackAt = Date() }
        lossyStartAt = lossless ? nil : Date()
        let need = neededRate(rate)
        log("new track \(name): decoder \(rate) Hz \(lossless ? "lossless" : "lossy") (seen \(String(format: "%.3f", seenAgo)) s before Playing), DAC \(Int(curRate)) Hz\(need.map { " -> switch to \(Int($0))" } ?? "")")
        if let r = need {
            switchRate(r, name: name, tPlay: tPlay, newTrack: true)
        } else {
            if latchedAt != nil || latchZeros.load(ordering: .acquiring) > 0 || armAt != nil { disarm("same rate after all") }
            releaseGate("same rate", name: name, tPlay: tPlay)
        }
    }

    private func handleLine(_ line: String, at: Date) {
        guard let r = line.range(of: "Input format:") else { return }
        let rest = line[r.upperBound...]
        guard let hz = rest.range(of: #"[0-9]+ Hz"#, options: .regularExpression), let rate = Float64(rest[hz].dropLast(3)) else { return }
        let lossless = line.contains("lac")
        let bits = rest.range(of: #"from [0-9]+-bit source"#, options: .regularExpression).flatMap { Int(rest[$0].dropFirst(5).prefix { $0.isNumber }) }
        if decoderRates.last?.rate != rate || at.timeIntervalSince(decoderRates.last!.date) > 0.5 {
            log("decoder: \(rate) Hz \(bits.map { "\($0)-bit " } ?? "")(\(lossless ? "lossless" : "lossy"))")
        }
        // Apple Music streams can start on a lossy 48k decoder and set up the lossless one seconds later.
        let ownUpgrade = lossless && (lossyStartAt.map { at.timeIntervalSince($0) < 10 } ?? false) // timed only: a lossless next track at the same rate is a pre-roll
        if lossless, let t = lossyTrackAt, at.timeIntervalSince(t) < 10 { pendingUpgrade = (rate, bits); lossyTrackAt = nil }
        decoderRates.append((at, rate, bits, lossless))
        let preRoll = bits != nil && lossless && !ownUpgrade && playing && !inRoutine && awaiting == nil && at > (ownLinesUntil ?? .distantPast)
        if preRoll {
            preRollLines.removeAll { at.timeIntervalSince($0) > 600 }
            preRollLines.append(at)
        }
        if decoderRates.count > 200 { decoderRates.removeFirst(100) }
        // ALAC logs a 'qlac' line without the depth, then 'alac ... from N-bit source': a line in the
        // track's own window at its rate fills in the depth the menu shows
        if let b = bits, lossless, rate == trackRate, let own = ownLinesUntil, at <= own {
            setSource(b, lossy: false)
        }
        // The track's own decoder can come just after the decision, which took it as lossless for want
        // of a line (pastor: "Uniform", lossy line 18 ms later; its samples fit no grid and the
        // Bit-perfect check blamed Music). A lossy line at its rate in its own window says otherwise;
        // a later lossless line upgrades it as usual (lossyTrackAt).
        if !lossless, !sourceLossy, rate == trackRate, let own = ownLinesUntil, at <= own {
            log("the track's own decoder is lossy (\(Int(rate)) Hz)")
            lossyTrackAt = at; lossyStartAt = at
            setSource(nil, lossy: true)
        }
        if let aw = awaiting, !inRoutine {
            awaiting = nil
            decide(rate, bits: bits, lossless: lossless, seenAgo: -at.timeIntervalSince(aw.tPlay), name: aw.name, tPlay: aw.tPlay)
            return
        }
        // A decoder for another rate while playing: the next track's pre-roll (8-12 s before the end:
        // arm the latch 1.5 s before it) or a user skip (arm now; Music leaves zeros between tracks).
        // Lines right after a track began are its own decoder (streams set it up after Playing).
        guard !inRoutine, playing, awaiting == nil, pendingUpgrade == nil, armAt == nil, latchedAt == nil,
              latchZeros.load(ordering: .acquiring) == 0, marker.load(ordering: .acquiring) < 0,
              at.timeIntervalSince(lastNewTrackAt ?? .distantPast) > 2,
              neededRate(rate) != nil || (rate == curRate && !(lossless && bits == nil) && formatDiffers(curRate, want: wantInt(preRoll ? bits : nil, lossless: lossless))) else { return }
        let left = scripts.remaining() ?? 0
        let delay = left > 13 ? 0 : max(0, left - 1.5)
        armAt = Date().addingTimeInterval(delay)
        armForSkip = left > 13
        // More than 13 s left: a skip (Music leaves zeros now), or a pre-roll set up early (Babyface
        // bench: 105 s before the end of a streamed track; the 5 s arm expired and the boundary cut
        // at the play position). Cover both: arm now, and again 1.5 s before the end.
        lateArmAt = left > 13 ? Date().addingTimeInterval(left - 1.5) : nil
        log("next track needs \(Int(rate)) Hz; \(String(format: "%.2f", left)) s left, arming the boundary latch in \(String(format: "%.2f", delay)) s\(lateArmAt != nil ? " and again in \(String(format: "%.2f", left - 1.5)) s" : "")")
    }

    private func tickLatchAndGate() {
        if let aw = awaiting, Date() > aw.until {
            awaiting = nil
            if let f = aw.fallback {
                log("no newer decoder line for \(aw.name) within 1 s; the earlier one decides")
                // the fallback line is from the previous track's window: its depth may be that track's
                decide(f.rate, bits: nil, lossless: f.lossless, seenAgo: aw.tPlay.timeIntervalSince(f.date), name: aw.name, tPlay: aw.tPlay)
            } else {
                log("no decoder line for \(aw.name) within 3 s; playing at \(Int(curRate)) Hz")
                let ll = libraryLossy(name: aw.name)
                setSource(nil, lossy: ll, known: ll)
                if latchedAt != nil || armAt != nil || latchZeros.load(ordering: .acquiring) > 0 { disarm("no rate") }
                releaseGate("no decoder line")
            }
        }
        regateIfSilent()
        if let l = lateArmAt, Date() >= l, armAt == nil, armedAt == nil, latchedAt == nil, !inRoutine {
            lateArmAt = nil
            armAt = Date()
            log("pre-roll came early; arming the boundary latch again")
        }
        if let a = armAt, Date() >= a {
            armAt = nil
            armedAt = Date()
            // a skip is reported after its gap went through A: stop at that gap if B hasn't played it
            if armForSkip, marker.load(ordering: .acquiring) < 0, let g = retroGap() {
                atBoundary.store(0, ordering: .relaxed)
                marker.store(g, ordering: .releasing)
                log("boundary latch: the skip's gap is \(ring.written - g) frames back, B \(g - ring.readPos) frames before it; latched there")
            } else {
                latchZeros.store(max(Int(0.01 * curRate), 1), ordering: .releasing)
                log("boundary latch armed at in frame \(inFrames.load(ordering: .relaxed))")
            }
            armForSkip = false
        }
        let m = marker.load(ordering: .acquiring)
        if let a = armedAt, m < 0, Date().timeIntervalSince(a) > 5 {
            latchZeros.store(0, ordering: .releasing); armedAt = nil
            log("no boundary within 5 s; disarmed")
        }
        if m >= 0, armedAt != nil, latchedAt == nil, !gatePending {
            armedAt = nil; latchedAt = Date()
            log("latched at ring \(m) (fill \(ring.fill))")
        }
        if let l = latchedAt, Date().timeIntervalSince(l) > 4 { disarm("latched 4 s without a new track") }
        // a marker nobody owns (A set it just as the gate or latch was released): let B go on
        if m >= 0, !gatePending, latchedAt == nil, armedAt == nil {
            if let s = strayMarkerAt { if Date().timeIntervalSince(s) > 0.5 { strayMarkerAt = nil; command.store(1, ordering: .releasing); log("stray marker at ring \(m); released") } }
            else { strayMarkerAt = Date() }
        } else { strayMarkerAt = nil }
        if procA != nil, !inputSeen, let s = setUpAt, Date().timeIntervalSince(s) > 3 {
            inputSeen = true
            if aCycles.load(ordering: .relaxed) == 0 { log("no input IO from the virtual device 3 s after setup (Microphone permission prompt pending?)") }
        }
        if gatePending, m >= 0 {
            if gateMarkedAt == nil { gateMarkedAt = Date(); log("gate: output started at ring \(m); waiting for the track's rate") }
            // another app's sound, or Music never reported Playing
            let limit = gateWaitsForMusic ? 4.0 : 1.5
            if !playing, let g = gateMarkedAt, Date().timeIntervalSince(g) > limit { releaseGate("no Playing within \(limit) s"); regateOnSilence = true }
        }
    }

    /// Another app's sound (or Music's tail after a quit) opened the gate while Music wasn't playing:
    /// Babyface bench, Kashmir then started ungated. Close the gate after 0.3 s of silence.
    private func regateIfSilent() {
        guard regateOnSilence, !gatePending, !playing, !inRoutine else { return }
        let silent = ring.written - lastNZ.load(ordering: .acquiring)
        guard silent >= Int(0.3 * curRate) else { return }
        regateOnSilence = false
        gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing)
        log("gate closed again after \(silent * 1000 / max(Int(curRate), 1)) ms of silence")
    }

    /// Music idle for `after` seconds: release the DAC (hog released, mixable, emulated mute undone), so
    /// it's free for other apps that pick it, and the Sound menu works (picking a hogged DAC there
    /// hangs Control Center). The default output stays on the virtual device, A keeps reading it and
    /// other apps keep playing where Other apps and alerts says. It used to give the default back too:
    /// then a play started Music on that device until the take-back paused it (pastor Mac, 2026-09-30:
    /// ~1 s of Music on the MacBook Pro speakers, the default from before). Now Music's first moments
    /// go into the virtual device, where A drops them, and the take-back rewinds.
    private func stepAside(after: TimeInterval) {
        if armAt != nil || armedAt != nil || latchedAt != nil || latchZeros.load(ordering: .acquiring) > 0 { disarm("stepping aside") }
        lateArmAt = nil; awaiting = nil; pendingUpgrade = nil
        log("Music idle \(Int(after)) s: stepping aside (DAC released; the default output stays on the virtual device)")
        dropInput.store(1, ordering: .releasing) // nothing reads the ring until the take-back
        tearDownDAC(keepOthers: true)
        if ls != 0 { log("virtual device scalar reset: \(CA.setScalar(ls, 1.0, Self.kRateScalar))"); lsScalar = 1 }
        resetLock()
        steppedAside = true
        probeAfterStepAside()
        othersToDACWhileIdle()
        refreshReportedLatency()
    }

    /// While stepped aside the DAC is free and Music is idle: other apps play on it (shared, mixable),
    /// as before the release-only step-aside (owner, coffee 2026-10-01: YouTube while Music is idle
    /// belongs on the DAC). "Mute other apps" stays muted. The take-back moves them off it first.
    private func othersToDACWhileIdle() {
        guard dac != 0, CA.string(dac, kAudioDevicePropertyDeviceUID) == dacUID,
              UserDefaults.standard.string(forKey: OtherAppsOutput.choiceKey) != OtherAppsOutput.mute else { return }
        var a = CA.addr(Self.kMusicOnly)
        guard ls != 0, AudioObjectHasProperty(ls, &a) else { return }
        let name = CA.string(dac, kAudioObjectPropertyName)
        othersFeed.store(0, ordering: .releasing)
        othersDevice = dac
        othersRestartAt = Date()
        if others.start(device: dac, rate: curRate, log: { [unowned self] in self.log($0) }) {
            othersFeed.store(1, ordering: .releasing)
            OtherAppsOutput.shared.setActive(dac)
            RendererOutput.shared.set(othersRoute: "Other apps play on \(name) (Music idle)", ok: true)
            log("other apps -> \(name) while Music is idle")
            refreshReportedLatency()
        } else {
            log("other apps: couldn't play on \(name) while idle; staying where they were")
            othersDevice = 0
        }
    }

    /// The take-back after a release-only step-aside: A still runs and the default is still the virtual
    /// device (unless the user picked another output meanwhile: that one becomes the DAC, as when the
    /// engine runs). False if the DAC can't be set up.
    private func takeBackDAC() -> Bool {
        if !isAttached() { attach(true) }
        let d0 = CA.defaultOutput()
        let picked = d0 != ls && d0 != 0 ? d0 : nil
        if let p = picked { defaultBefore = p; log("default output was set to \(CA.string(p, kAudioObjectPropertyName)) while stepped aside") }
        let dacOK = dac != 0 && CA.string(dac, kAudioDevicePropertyDeviceUID) == dacUID
        guard let d = selectedDAC() ?? picked ?? (dacOK ? dac : chooseDAC()) else { log("no output device to play to"); return false }
        reclaimDefault()
        // other apps were on the DAC while idle: off it before it's taken (setUpDAC refuses a DAC
        // another client still plays to); setUpDAC puts them back where Other apps and alerts says
        if othersDevice == d || othersDevice == dac { stopOthers() }
        // a gate or latch from before the step-aside can't be reached (A dropped everything since):
        // the switch would wait 1 s for it (pastor, 2026-09-30: "boundary NOT reached 1.009 s")
        gatePending = false; gateMarkedAt = nil
        gate.store(0, ordering: .releasing); latchZeros.store(0, ordering: .releasing)
        marker.store(-1, ordering: .releasing); atBoundary.store(0, ordering: .releasing)
        return setUpDAC(d)
    }

    /// Coffee bench (DragonFly Black, data/2026-09-28-coffee-5d75e9a): the step-aside's config changes
    /// on the DAC (mixable format, hog released) make coreaudiod pause and resume this process's IO
    /// context for the DAC, and the HAL client handles those on several threads. A resume handled
    /// before its pause is clamped at 0 and the pause stays. The context outlives the IOProcs, so every
    /// later start on that DAC in this process blocks 7.5 s and fails (35, "IO is still disabled
    /// after waiting"). Nothing in the process clears it (stop+start, setting up again,
    /// AudioHardwareUnload); a new process does. A short silent start here, while Music is paused and
    /// after tearDown's 3 s hold, finds it before a take-back would; then the app relaunches.
    private func probeAfterStepAside() {
        let d = dac
        guard d != 0, CA.devices().contains(d) else { return }
        var proc: AudioDeviceIOProcID?
        let cst = AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, _, _, out, _ in
            for b in UnsafeMutableAudioBufferListPointer(out) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
        }
        guard cst == noErr, let proc else { log("DAC probe: IOProc \(cst)"); return }
        let t = Date()
        var st = AudioDeviceStart(d, proc)
        let took = ms(t)
        AudioDeviceStop(d, proc)
        AudioDeviceDestroyIOProcID(d, proc)
        // bench hook (one shot): `defaults write <bundle id> RendererProbeForceStuck -bool true` makes
        // this probe act as if it got 35, to test the relaunch
        if UserDefaults.standard.bool(forKey: "RendererProbeForceStuck") {
            UserDefaults.standard.removeObject(forKey: "RendererProbeForceStuck")
            log("DAC probe: start \(st) after \(took); RendererProbeForceStuck set: acting as if it were 35 (once)")
            st = 35
        }
        guard st == 35 else {
            log("DAC probe: start \(st) after \(took)\(st == noErr ? "" : " (not the stuck context; no relaunch)")")
            return
        }
        let last = UserDefaults.standard.object(forKey: Self.lastRelaunchKey) as? Date
        if let last, Date().timeIntervalSince(last) < 600 {
            log("DAC probe: start 35 after \(took): the DAC's IO context is stuck, but the app relaunched \(Int(Date().timeIntervalSince(last))) s ago; not again within 10 min (a take-back will fail)")
            return
        }
        log("DAC probe: start 35 after \(took): the DAC's IO context is stuck in this process; relaunching the app")
        UserDefaults.standard.set(Date(), forKey: Self.lastRelaunchKey)
        UserDefaults.standard.set("[Exclusive Mode] relaunched after a step-aside left the DAC's IO context paused (probe: start 35 after \(took)); the run before it is Nativerate-ExclusiveMode.1.log", forKey: Self.recoveryNoteKey)
        DispatchQueue.main.async { Self.relaunch() }
    }

    private static let lastRelaunchKey = "RendererLastRelaunch"

    /// A detached shell waits for this process to exit and opens the app again (the new run's log
    /// start keeps this run's as .1); the quit itself is the normal one (the engine stops and
    /// restores the output).
    private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"", "relaunch", Bundle.main.bundlePath]
        do { try p.run() } catch { print("[Exclusive Mode] relaunch failed: \(error)"); return }
        NSApp.terminate(nil)
    }

    /// Music started playing while stepped aside (straight to the DAC): pause it, take the output
    /// back, then the switch routine sets the track's rate, rewinds to where the play began and plays.
    private func resumeFromIdle(_ info: [AnyHashable: Any], at: Date) {
        let name = info["Name"] as? String ?? "(current track)"
        log("playback began while stepped aside (\(name)); taking the output back")
        inRoutine = true
        _ = scripts.pause()
        let pausedAt = Date()
        _ = wait(1) { !self.playing }
        // Music's notices stay ignored through the setup and the rate decision: they echo our own
        // pause, which can take over 1 s (pastor Mac: Badlands' late Playing came after the wait, was
        // taken as a new track, and switched before the DAC was set up: NOT ready after 12 s).
        // switchRate below pauses, rewinds and plays anyway.
        steppedAside = false
        let aliveA = procA != nil && CA.string(ls, kAudioDevicePropertyDeviceUID) == Self.deviceUID
        if !aliveA, procA != nil { log("virtual device gone while stepped aside; setting up again"); tearDown(restoreDefault: false, resumeMusic: false) }
        let ok = aliveA ? takeBackDAC() : setUp()
        if !ok, aliveA {
            // Music would play into a virtual device nobody plays out: give everything back instead
            log("taking the DAC back failed; giving the default output back as well")
            tearDownDAC()
            tearDown(restoreDefault: true, resumeMusic: false)
        }
        if !ok { procA = nil }
        guard ok else {
            inRoutine = false
            // Music plays to the DAC directly. Its Playing must not start another take-back: on the
            // coffee bench that looped every 11 s (and Music's pause didn't stop it, the play did).
            resumeRetryAt = Date().addingTimeInterval(30)
            log("setup failed; staying stepped aside, Music plays to the DAC directly; no take-back for 30 s")
            steppedAside = true
            _ = scripts.play()
            return
        }
        resumeRetryAt = nil
        // the rate this track needs: the rate decided for it if it's the track that was playing (the
        // newest line can be the next track's pre-roll: Executor bench, Earth resumed on the next
        // track's 48k line), else its newest decoder line (Music decoded it before pausing), else the
        // local file's header; the DAC's current rate if none says
        let pid = (info["PersistentID"] as? NSNumber)?.int64Value ?? (name.isEmpty ? nil : Int64(truncatingIfNeeded: name.hashValue))
        let recent = decoderRates.last.flatMap { Date().timeIntervalSince($0.date) < 30 ? $0.rate : nil }
        let rate: Float64?
        if pid != nil && pid == lastTrackID, let r = trackRate {
            rate = r
        } else if pid != nil && pid == lastTrackID {
            rate = recent ?? LocalTrack.currentStats(attempts: 2)?.sampleRate
        } else {
            // Another track: its own line can come after the take-back's setup (pastor Mac: Badlands'
            // 44.1k line 1.1 s after its Playing, after the rate was chosen; it played at the hymn's
            // 96k). Take a line from its Playing on (or just before), waiting up to 2 s for one.
            let since = at.addingTimeInterval(-2)
            // Music's own rate for the track answers at once (as for a new track); the decoder-line
            // wait below cost 2 s on a take-back where Music logged none (pastor, 2026-09-30)
            let musicRate = musicTrackRate(name: name)
            if musicRate == nil, decoderRates.last.map({ $0.date <= since }) ?? true {
                let t0 = Date()
                _ = wait(2) { self.decoderRates.last.map { $0.date > since } ?? false }
                log("resume: \(decoderRates.last.map { $0.date > since } ?? false ? "decoder line after \(String(format: "%.2f", Date().timeIntervalSince(t0))) s" : "no decoder line within 2 s")")
            }
            let ownLine = decoderRates.last.flatMap { $0.date > since ? $0 : nil }
            let own = ownLine?.rate
            let fileStats = own == nil && musicRate == nil ? LocalTrack.currentStats(attempts: 2) : nil
            let file = fileStats?.sampleRate
            rate = musicRate ?? own ?? file ?? recent
            resetGrid()
            trackStartedLossy = false
            if let l = ownLine { setSource(l.bits, lossy: !l.lossless) }
            else { setSource(fileStats?.sourceBits, lossy: fileStats?.lossy ?? false, known: fileStats != nil) }
            log("resume: \(name) at \(rate.map { "\(Int($0)) Hz" } ?? "the DAC's rate") (\(musicRate != nil ? "Music's rate for the track" : own != nil ? "its decoder line" : file != nil ? "file header" : recent != nil ? "newest decoder line, may be another track's" : "nothing says"))")
        }
        setWantBits(logBits, lossless: !sourceLossy)
        let target = rate.flatMap { neededRate($0) } ?? curRate
        if pid != lastTrackID { trackRate = rate }
        lastTrackID = pid
        lastNewTrackAt = at
        inRoutine = false
        switchRate(target, name: name, tPlay: at, pausedAt: pausedAt)
    }

    private func disarm(_ why: String) {
        let wasLatched = latchedAt != nil || marker.load(ordering: .acquiring) >= 0
        armAt = nil; armedAt = nil; latchedAt = nil; lateArmAt = nil
        latchZeros.store(0, ordering: .releasing)
        if wasLatched || marker.load(ordering: .acquiring) >= 0 { command.store(1, ordering: .releasing) }
        log("\(why); \(wasLatched ? "latch released" : "disarmed")")
    }

    private func releaseGate(_ why: String, name: String = "(current track)", tPlay: Date? = nil) {
        guard gatePending else { return }
        if playing, marker.load(ordering: .acquiring) >= 0, let g = gateMarkedAt, Date().timeIntervalSince(g) > 0.5 {
            // held long (the DAC coming up, a stream's late decoder line): continuing would keep that
            // much latency until the next pause, so start over from where the play began
            log("gate held \(String(format: "%.0f", Date().timeIntervalSince(g) * 1000)) ms (\(why)); restarting the play")
            switchRate(curRate, name: name, tPlay: tPlay ?? g)
            return
        }
        gatePending = false
        gate.store(0, ordering: .releasing)
        if marker.load(ordering: .acquiring) >= 0 {
            command.store(1, ordering: .releasing)
            let held = gateMarkedAt.map { String(format: "%.0f ms", Date().timeIntervalSince($0) * 1000) } ?? "< 10 ms"
            log("gate released (\(why)) \(held) after the output started")
        }
        gateMarkedAt = nil
    }

    /// The DAC rate the track needs (this app's format choice: nearest supported, multiples
    /// preference), or nil if the devices already run at it.
    private func neededRate(_ rate: Float64) -> Float64? {
        guard let device = AudioDevice.lookup(by: dac),
              let fmt = outputDevices.suitableFormat(for: CMPlayerStats(sampleRate: rate, bitDepth: 24, date: Date(), priority: 5), device: device) else { return nil }
        guard fmt.mSampleRate != curRate || formatDiffers(curRate, want: wantBits) else { return nil }
        guard CA.nominalRates(ls).contains(fmt.mSampleRate) else {
            log("track needs \(Int(fmt.mSampleRate)) Hz, which the virtual device can't run at; staying at \(Int(curRate)) Hz")
            return nil
        }
        return fmt.mSampleRate
    }

    /// Integer Mode changes the DAC's depth at `rate`: a track that wants an integer depth and the DAC isn't
    /// at the format picked for it, or the DAC is at a format the option set and this track
    /// doesn't want it. False whenever the option plays no part (only depth and int/float compared:
    /// a DAC that reads its format back with other flags must not restart every same-rate track).
    private func formatDiffers(_ rate: Float64, want: Int?) -> Bool {
        guard hogged, want != nil || appliedWant != nil, let f = dacFormat(rate, want: want) else { return false }
        let p = CA.physicalAndVirtual(dacOut).0
        return f.mBitsPerChannel != p.mBitsPerChannel || (f.mFormatFlags ^ p.mFormatFlags) & kAudioFormatFlagIsFloat != 0
    }

    /// The track's depth (16, 24 or 32, Music's log) if Integer Mode is on and the track is lossless, else nil.
    private func wantInt(_ bits: Int?, lossless: Bool) -> Int? {
        guard UserDefaults.standard.bool(forKey: Defaults.kIntegerMode), lossless, let b = bits, [16, 24, 32].contains(b) else { return nil }
        return b
    }

    private func setWantBits(_ bits: Int?, lossless: Bool) {
        let w = wantInt(bits, lossless: lossless)
        if w != wantBits {
            let has = w.map { w in dacFormat(trackRate ?? curRate, want: w).map { Int($0.mBitsPerChannel) == w } ?? false } ?? false
            log("Integer Mode: \(w.map { w in has ? "\(w)-bit integer for this track" : "\(w)-bit asked for, but the DAC has no \(w)-bit integer format; current format" } ?? "off")")
        }
        wantBits = w
    }

    /// Where B should stop for a skip reported late: the earliest gap A saw in the last 0.6 s that B
    /// hasn't played yet (nil: none; B then stops where it is, as before).
    private func retroGap() -> Int? {
        let c = gapCount.load(ordering: .acquiring)
        let rd = ring.readPos, w = ring.written, window = Int(0.6 * curRate)
        var best: Int?
        for k in max(0, c - 32)..<c {
            let p = gapHist[k & 31]
            if p > rd, p >= w - window, p <= w { best = min(best ?? p, p) }
        }
        return best
    }

    /// Plug-in 1.1.6: the device reports B's trail as its output latency, so video stays in sync.
    private static let kLatency: AudioObjectPropertySelector = 0x4C53_6C74 // 'LSlt'
    private var reportedLatency = -1
    /// What video apps playing to the virtual device should assume: Music's switch margin when other apps
    /// share Music's path (old driver), else the way other apps really go: the loopback read, the
    /// player's ring, and the output device's own presentation delay (the app can't know that one).
    /// `LipSyncTrimMs` (hidden) shifts it for a bench.
    private func refreshReportedLatency() {
        guard others.isRunning, othersDevice != 0, othersFeed.load(ordering: .relaxed) != 0, curRate > 0 else {
            setReportedLatency(isMusicOnlyDriver ? 0 : targetFill)
            return
        }
        let rate = curRate
        let destRate = max(CA.nominal(othersDevice), 1)
        let dest = Int(Double(CA.presentationFrames(othersDevice, kAudioObjectPropertyScopeOutput)) * rate / destRate)
        let loop = Int(Double(CA.presentationFrames(ls, kAudioObjectPropertyScopeInput)) * rate / max(CA.nominal(ls), 1))
        let trim = Int(UserDefaults.standard.double(forKey: "LipSyncTrimMs") * rate / 1000)
        let total = max(0, others.latencyFrames + dest + loop + trim)
        if total != reportedLatency {
            log("lip sync: other apps' delay \(total) frames = player ring \(others.latencyFrames) + \(CA.string(othersDevice, kAudioObjectPropertyName)) \(dest) + loopback read \(loop)\(trim != 0 ? " + trim \(trim)" : "")")
        }
        setReportedLatency(total)
    }

    private var isMusicOnlyDriver: Bool {
        var a = CA.addr(Self.kMusicOnly)
        return ls != 0 && AudioObjectHasProperty(ls, &a)
    }

    private func setReportedLatency(_ frames: Int) {
        guard ls != 0, frames != reportedLatency else { return }
        var a = CA.addr(Self.kLatency)
        guard AudioObjectHasProperty(ls, &a) else { return }
        let st = CA.setCFNumber(ls, Self.kLatency, NSNumber(value: Int32(frames)))
        if st == noErr { reportedLatency = frames }
        log("virtual device latency -> \(frames) frames: \(st)")
    }

    // MARK: - The switch routine

    /// `pausedAt`: when Music was paused, if a caller paused it already (resume from idle).
    private func switchRate(_ r: Float64, name: String, tPlay: Date, pausedAt: Date? = nil, newTrack: Bool = false) {
        inRoutine = true
        defer { inRoutine = false }
        switches += 1
        let t = Date()
        let pauseTime = pausedAt ?? t // Music's position stops here; what it played is measured to here
        // Music can start playing before it posts Playing (after a relaunch): the gate saw the first
        // frame earlier, and that is where the play began
        let tPlay = gatePending ? min(tPlay, gateMarkedAt ?? tPlay) : tPlay
        // Music already paused, and not by a caller: the listener paused after the Playing that
        // brought us here. The rate still switches; Music stays paused (it used to play again here).
        let listenerPaused = pausedAt == nil && scripts.playerState().map { $0 != "playing" } == true
        _ = scripts.pause()
        var m = marker.load(ordering: .acquiring)
        // a new track reported late (a skip): the gap before it, if B hasn't played it yet
        let retro = m < 0 && newTrack ? retroGap() : nil
        let how = m >= 0 ? (gatePending ? "held at the gate" : "latched at the old track's end")
            : retro.map { "latched at the gap before it (after the fact, \(ring.written - $0) frames back; B \($0 - ring.readPos) frames before it)" } ?? "not latched: cut at the play position"
        if m < 0 { atBoundary.store(0, ordering: .releasing); m = retro ?? ring.readPos; marker.store(m, ordering: .releasing) }
        latchZeros.store(0, ordering: .releasing); gate.store(0, ordering: .releasing)
        gatePending = false; gateMarkedAt = nil; armAt = nil; armedAt = nil; latchedAt = nil
        let reached = wait(1) { self.atBoundary.load(ordering: .acquiring) != 0 }
        let change = r != curRate || CA.nominal(dac) != r || formatDiffers(r, want: wantBits)
        log("switch \(switches): \(name) \(change ? "needs \(Int(r)) Hz (DAC \(Int(curRate)))" : "restarts at \(Int(r)) Hz (no rate change)"); \(how); paused; boundary \(reached ? "reached" : "NOT reached") \(ms(t))")
        dropInput.store(1, ordering: .releasing) // the DAC can take seconds; don't let the ring overflow with zeros
        if change { outFormat.store(0, ordering: .releasing); applyRate(r) }
        recorder?.segmentIn(inFrames.load(ordering: .acquiring), r)
        let td = Date()
        if change {
            let target = dacFormat(r) ?? AudioStreamBasicDescription(mSampleRate: r, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0)
            let ready = DeviceFormat.waitUntilReady(dac, format: target, checkBitDepth: target.mBitsPerChannel != 0, timeout: 12, stalled: { [unowned self] in
                guard let p = self.procB else { return }
                self.log("  DAC keeps stopping; restarting B")
                AudioDeviceStop(self.dac, p); AudioDeviceStart(self.dac, p)
            })
            log("  DAC \(ready ? "ready" : "NOT ready") after \(ms(td)): \(CA.formats(dacOut))")
            updateOutFormat()
        }
        command.store(2, ordering: .releasing)
        _ = wait(1) { self.command.load(ordering: .acquiring) == 0 }
        dropInput.store(0, ordering: .releasing)
        let seg = outSegmentAt.exchange(-1, ordering: .acquiringAndReleasing)
        recorder?.segmentOut(seg >= 0 ? seg : outFrames.load(ordering: .acquiring), r)
        resetLock()
        if listenerPaused {
            // as the play path does: the device poll would take a default moved during the switch
            // for the listener's pick and follow it
            reclaimDefault()
            log("  Music was paused before the switch (the listener's pause): stays paused; switch \(switches) done \(ms(t)) after the request")
            return
        }
        let pos = scripts.position() ?? 0
        // measured to the pause, not to now: the paused position doesn't advance during the switch (it
        // was measured to now, so a mid-track switch replayed the switch's own duration, ~1.5 s)
        let played = pauseTime.timeIntervalSince(tPlay) + 0.05
        var startPos = pos - played - 0.1
        // near the start is the start: the estimate can come up short (0.530 on the Babyface bench),
        // and a restart that skips a track's first half-second is heard. Not 0: a new track paused at its
        // Playing reads 0.000 with its first 0.16-0.5 s already rendered (and dropped above), and "set
        // to 0" is then a no-op: the play resumed there, every switch at a boundary (loopback bench,
        // Executor, Normal margin, 2026-10-03). Inferred, not measured: Music's position is its render
        // point less the reported latency, which is the Switch Margin (0.35-0.75 s), so the lost head
        // scales with it. 0.001 is a real seek (resumed at 1.4 ms on the bench).
        if startPos < 2 { startPos = 0.001 }
        _ = scripts.setPosition(startPos)
        reclaimDefault() // never let Music start on whatever coreaudiod fell back to
        _ = scripts.play()
        // the play re-creates this track's decoder: that line is its own, not a next track's
        ownLinesUntil = max(ownLinesUntil ?? .distantPast, Date().addingTimeInterval(1))
        log("  rewound to \(String(format: "%.3f", startPos)) (was \(String(format: "%.3f", pos)), played ~\(String(format: "%.3f", played)) s), play; switch \(switches) done \(ms(t)) after the request")
        confirmPlaying()
    }

    /// Music can end up paused after the switch's play: its late notices from our own pause arrive after
    /// the play (pastor Mac, 2026-09-30, a take-back: Paused 44 ms after the play; the owner had to
    /// press play). Watch Music's state for 1 s; play again, up to 3 times, but only if it never got
    /// going: paused after playing 0.3 s or more is the listener's pause, and stays.
    private func confirmPlaying() {
        for attempt in 1...4 {
            var since: Date?
            let end = Date().addingTimeInterval(1)
            var state = "?"
            while Date() < end {
                state = scripts.playerState() ?? "?"
                if state == "playing" {
                    if since == nil { since = Date() }
                } else if let s = since, Date().timeIntervalSince(s) >= 0.3 {
                    log("  Music played \(String(format: "%.1f", Date().timeIntervalSince(s))) s after the switch, then \(state): the listener's pause; not playing again")
                    return
                } else {
                    since = nil
                }
                _ = wait(0.1)
            }
            if state == "playing" { return }
            if attempt == 4 { log("  Music still isn't playing after 3 plays"); return }
            log("  Music is \(state) after the switch's play (check \(attempt)); play again")
            _ = scripts.play()
        }
    }

    // MARK: - Devices

    private func checkDevicesAndMusic() {
        guard !inRoutine else { return }
        if steppedAside {
            if lastTrackID != nil, !musicRunning() { log("Music quit (engine stepped aside)"); lastTrackID = nil }
            return
        }
        if lastTrackID != nil, !musicRunning() {
            log("Music quit; the next play waits at the gate for its own decoder line")
            lastTrackID = nil
            playing = false
            // Relaunched Music played ~1.6 s before posting Playing (Babyface bench), and the last
            // decoder lines belong to the old session (one was taken 264 s later): gate the next
            // play, wait longer than usual for its Playing, and forget the old lines.
            if armAt != nil || armedAt != nil || latchedAt != nil || latchZeros.load(ordering: .acquiring) > 0 { disarm("Music quit") }
            awaiting = nil; pendingUpgrade = nil; lossyTrackAt = nil; lossyStartAt = nil
            decoderRates = []; preRollLines = []; lastNewTrackAt = nil; ownLinesUntil = nil; trackRate = nil
            if !gatePending { gatePending = true; gateMarkedAt = nil; gate.store(1, ordering: .releasing) }
            gateWaitsForMusic = true
            trimIdle.store(1, ordering: .releasing)
        }
        // the plug-in's device vanished (coreaudiod restarted?): start over
        if CA.string(ls, kAudioDevicePropertyDeviceUID) != Self.deviceUID {
            log("virtual device gone; setting up again")
            procA = nil
            tearDown(restoreDefault: false, resumeMusic: false)
            if !setUp() { log("setup failed") }
            return
        }
        // The plug-in drops the attachment if it thinks we went away (it can misjudge a
        // reconfiguration); coreaudiod then moves the default off the virtual device. That move is
        // ours, not the user's: re-attach and take the default back instead of following it.
        if !isAttached() {
            log("attachment lost; re-attaching")
            reclaimDefault()
            return
        }
        let dacPresent = CA.string(dac, kAudioDevicePropertyDeviceUID) == dacUID
        let d = CA.defaultOutput()
        if !dacPresent {
            log("DAC gone")
            procB = nil; hogged = false; nonMixable = false
            if let f = Self.fallbackOutput(excluding: ls) {
                log("playing to \(CA.string(f, kAudioObjectPropertyName)) instead")
                follow(f)
            }
            return
        }
        if let s = selectedDAC() {
            // Selected Device decides: follow a new selection; a new default output doesn't move the
            // engine, it only gets the default back (the audio keeps going to the selection)
            if s != dac {
                log("Selected Device changed to \(CA.string(s, kAudioObjectPropertyName)); following it")
                follow(s)
            } else if d != ls, d != 0 {
                defaultBefore = d
                log("default output changed to \(CA.string(d, kAudioObjectPropertyName)); Selected Device \(CA.string(dac, kAudioObjectPropertyName)) stays the DAC; default -> virtual device: \(CA.setDefaultOutput(ls))")
            }
        } else if d != ls, d != 0 {
            defaultBefore = d
            if d == dac {
                // the DAC itself was picked (it stays listed in the Sound menu while hogged): it's
                // already where the audio goes; setting it up again would only cost a gap
                log("default output set to the DAC \(CA.string(d, kAudioObjectPropertyName)); default -> virtual device: \(CA.setDefaultOutput(ls))")
            } else {
                // the user (or the system) picked another output: play to it through the virtual device
                log("default output changed to \(CA.string(d, kAudioObjectPropertyName)); following it")
                follow(d)
            }
        }
    }

    /// Plays to `d` from now on: pause, give the old DAC back, set up the new one, play.
    private func follow(_ d: AudioObjectID) {
        let wasPlaying = musicPlaying()
        if wasPlaying { _ = scripts.pause(); _ = wait(1) { !self.playing } }
        tearDownDAC()
        if setUpDAC(d) {
            log("default output -> virtual device: \(CA.setDefaultOutput(ls))")
        } else {
            // never leave the system on a virtual device nobody plays out
            tearDownDAC()
            log("DAC setup failed; default output stays \(CA.string(d, kAudioObjectPropertyName)): \(CA.setDefaultOutput(d))")
        }
        if wasPlaying { playChecked() }
    }

    // MARK: - Clock lock

    private func resetLock() {
        phase0 = nil; integ = 0; dacScalarEst = 0; refillAsked = false
        scalarHistory.removeAll(); waitingSince = nil
        lockAfterCycles = (aCycles.load(ordering: .relaxed) + 8, bCycles.load(ordering: .relaxed) + 8)
    }

    /// Every 0.5 s: phase = virtual sample time now - DAC sample time now, error vs the phase at lock;
    /// virtual scalar = DAC's HAL scalar (EMA) * (1 + P + I), within +-300 ppm.
    private func pll() {
        guard procB != nil, !inRoutine, aCycles.load(ordering: .relaxed) >= lockAfterCycles.0, bCycles.load(ordering: .relaxed) >= lockAfterCycles.1,
              let (sA, hA, _) = stampA.get(), let (sB, hB, rB) = stampB.get(), rB > 0.9, rB < 1.1 else { return }
        let tpf = ticksPerSec / curRate
        let h = Double(mach_absolute_time())
        let phase = (sA + (h - hA) / (tpf * lsScalar)) - (sB + (h - hB) / (tpf * rB))
        // After a switch the DAC's HAL scalar converges for seconds (1.00115 at 88.2k in trial s2, and
        // seeding on it walked the phase to -285 frames), so the lock waits until it is steady: the
        // means of the older and newer halves of the last 4 s within 20 ppm. Steady, not near 1: the
        // DragonFly Black runs ~400 ppm fast at 44.1k and a 100 ppm gate never locked (the ring drained,
        // ~12 ms dropout every 30 s). Replayed on the MT 48 recordings: passes 3.3-5 s after the old
        // lock point, never fails once settled (worst 19 ppm at 192k). While waiting the virtual device
        // follows the DAC's scalar so the ring doesn't drain; after 30 s it locks on the 4 s mean anyway.
        if phase0 == nil {
            let t = h / ticksPerSec
            scalarHistory.append((t, rB))
            scalarHistory.removeAll { t - $0.t > 4 }
            var steady: Double?
            if let first = scalarHistory.first, t - first.t >= 3.25 {
                let mid = first.t + (t - first.t) / 2
                let older = scalarHistory.filter { $0.t < mid }.map(\.r), newer = scalarHistory.filter { $0.t >= mid }.map(\.r)
                let mo = older.reduce(0, +) / Double(older.count), mn = newer.reduce(0, +) / Double(newer.count)
                if abs(mn - mo) < 20e-6 {
                    steady = mn
                } else if let w = waitingSince, t - w >= 30 {
                    steady = mn
                    if waitingForScalar { log("clock: DAC scalar still moving after 30 s (\(String(format: "%.6f", mo)) -> \(String(format: "%.6f", mn)) over 4 s); locking on it") }
                }
            }
            guard let est = steady else {
                if waitingSince == nil { waitingSince = t }
                if !waitingForScalar { waitingForScalar = true; log("clock: DAC scalar \(String(format: "%.6f", rB)) not steady yet; following it until the lock") }
                if CA.setScalar(ls, rB, Self.kRateScalar) == noErr { lsScalar = rB }
                return
            }
            if waitingForScalar, let w = waitingSince {
                log("clock: DAC scalar steady at \(String(format: "%.6f", est)) after \(String(format: "%.1f", t - w)) s")
            }
            dacScalarEst = est
        }
        waitingForScalar = false
        // The lock holds the phase it starts from, so it holds the ring's fill too. After the follow to
        // the MacBook speakers the ring had drained (6656 frames under) and it locked at fill 0: no
        // margin, for good. Below half the target, refill first (B plays silence until it's back).
        if phase0 == nil && ring.fill < targetFill / 2 {
            if !refillAsked {
                refillAsked = true
                refill.store(1, ordering: .releasing)
                log("clock: ring at \(ring.fill) frames before the lock (target \(targetFill)); refilling first")
            }
            return
        }
        refillAsked = false
        dacScalarEst = dacScalarEst == 0 ? rB : dacScalarEst + 0.1 * (rB - dacScalarEst)
        if phase0 == nil { phase0 = phase; log("clock lock: phase0 \(String(format: "%.3f", phase)), fill \(ring.fill), cycles A \(aCycles.load(ordering: .relaxed)) B \(bCycles.load(ordering: .relaxed))") }
        let err = phase - phase0!
        if abs(err) > 1000 {
            log("clock: phase jumped \(String(format: "%.0f", err)) frames (a device restarted?); re-locking")
            resetLock()
            return
        }
        let kp = 1 / (tau * curRate)
        integ = max(-300e-6, min(300e-6, integ + kp * err * 0.5 / (4 * tau)))
        let corr = max(-300e-6, min(300e-6, kp * err + integ))
        let s = dacScalarEst * (1 + corr)
        if CA.setScalar(ls, s, Self.kRateScalar) == noErr { lsScalar = s }
        recorder?.clock(fill: ring.fill, phase: phase, err: err, dac: rB, lsSet: lsScalar,
                        over: ring.overruns.load(ordering: .relaxed), under: ring.underruns.load(ordering: .relaxed),
                        a: aCycles.load(ordering: .relaxed), b: bCycles.load(ordering: .relaxed), rate: curRate)
    }

    // MARK: - IO threads

    /// A: the virtual device's loopback input (float32; plug-in 1.1.4: 4 ch, 1-2 Music, 3-4 the other
    /// apps; older: 2 ch) -> ring, and the other apps -> others.ring.
    private func renderA(_ inInput: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        guard let b = ins.first, let d = b.mData, b.mNumberChannels == 2 || b.mNumberChannels == 4 else { return }
        let n: Int
        let f: UnsafePointer<Float>
        if b.mNumberChannels == 4 {
            n = min(Int(b.mDataByteSize) / 16, Self.maxFrames)
            let src = d.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                scratchA[i * 2] = src[i * 4]; scratchA[i * 2 + 1] = src[i * 4 + 1]
                scratchO[i * 2] = src[i * 4 + 2]; scratchO[i * 2 + 1] = src[i * 4 + 3]
            }
            var pk: Float = 0
            for i in 0..<(n * 2) { pk = max(pk, abs(scratchO[i])) }
            if pk > Float(bitPattern: othersPeakA.load(ordering: .relaxed)) { othersPeakA.store(pk.bitPattern, ordering: .relaxed) }
            if othersFeed.load(ordering: .relaxed) != 0 { others.ring.write(scratchO, n) }
            f = UnsafePointer(scratchA)
        } else {
            n = Int(b.mDataByteSize) / 8
            f = UnsafePointer(d.assumingMemoryBound(to: Float.self))
        }
        let w0 = ring.written
        var cnz = 0, c16 = 0, c24 = 0, f16 = 0, low = 0, f24 = 0
        for i in 0..<(n * 2) {
            let x = f[i]
            if x != 0 {
                cnz += 1
                let isLow = abs(x) < 1.0 / 16
                if isLow { low += 1 }
                let a = x * 32768
                if a != a.rounded() {
                    c16 += 1
                    if abs(a - a.rounded()) > 1.0 / 64 { f16 += 1 }
                    let b = x * 8388608
                    if b != b.rounded() {
                        c24 += 1
                        if isLow && abs(b - b.rounded()) > 0.375 { f24 += 1 }
                    }
                }
            }
        }
        if cnz > 0 {
            gridNZ.wrappingAdd(cnz, ordering: .releasing); gridOff16.wrappingAdd(c16, ordering: .releasing)
            gridOff24.wrappingAdd(c24, ordering: .releasing); gridFar16.wrappingAdd(f16, ordering: .releasing)
            gridLow.wrappingAdd(low, ordering: .releasing); gridFar24.wrappingAdd(f24, ordering: .releasing)
        }
        let gl = gapLen.load(ordering: .relaxed)
        for i in 0..<n {
            if f[i * 2] == 0 && f[i * 2 + 1] == 0 {
                gapRun += 1
                if gapRun == gl {
                    let c = gapCount.load(ordering: .relaxed)
                    gapHist[c & 31] = w0 + i + 1
                    gapCount.store(c + 1, ordering: .releasing)
                }
            } else { gapRun = 0 }
        }
        if marker.load(ordering: .acquiring) < 0 {
            let lz = latchZeros.load(ordering: .acquiring)
            if lz > 0 {
                for i in 0..<n {
                    if f[i * 2] == 0 && f[i * 2 + 1] == 0 { zeroRun += 1 } else { zeroRun = 0 }
                    if zeroRun >= lz {
                        zeroRun = 0
                        if latchZeros.compareExchange(expected: lz, desired: 0, ordering: .acquiringAndReleasing).exchanged {
                            atBoundary.store(0, ordering: .relaxed)
                            marker.store(w0 + i + 1, ordering: .releasing)
                        }
                        break
                    }
                }
            } else if gate.load(ordering: .acquiring) != 0 {
                zeroRun = 0
                for i in 0..<n where f[i * 2] != 0 || f[i * 2 + 1] != 0 {
                    if gate.compareExchange(expected: 1, desired: 0, ordering: .acquiringAndReleasing).exchanged {
                        atBoundary.store(0, ordering: .relaxed)
                        marker.store(w0 + i, ordering: .releasing)
                    }
                    break
                }
            } else { zeroRun = 0 }
        }
        var i = n - 1
        while i >= 0 && f[i * 2] == 0 && f[i * 2 + 1] == 0 { i -= 1 }
        if i >= 0 { lastNZ.store(w0 + i + 1, ordering: .releasing) }
        if dropInput.load(ordering: .relaxed) == 0 { ring.write(f, n) }
        let t = inTime.pointee
        stampA.put(t.mSampleTime + Double(n), Double(t.mHostTime), t.mRateScalar) // end of this buffer
        recorder?.input(f, n, sample: t.mSampleTime, host: t.mHostTime)
        inFrames.wrappingAdd(n, ordering: .releasing)
        aCycles.wrappingAdd(1, ordering: .relaxed)
    }

    /// B: ring -> the DAC's stereo pair, in its virtual format.
    private func renderB(_ outOutput: UnsafeMutablePointer<AudioBufferList>, _ outTime: UnsafePointer<AudioTimeStamp>) {
        let t = outTime.pointee
        stampB.put(t.mSampleTime, Double(t.mHostTime), t.mRateScalar)
        let outs = UnsafeMutableAudioBufferListPointer(outOutput)
        let fmt = OutFormat(packed: outFormat.load(ordering: .acquiring))
        let muted = fmt.bytes == 0 // format not confirmed: run the ring as usual, write zeros
        guard let b0 = outs.first, b0.mNumberChannels > 0 else { return }
        let n = min(Int(b0.mDataByteSize) / (muted ? 4 : fmt.bytes) / Int(b0.mNumberChannels), Self.maxFrames)
        switch command.exchange(0, ordering: .acquiringAndReleasing) {
        case 1: // go on past the marker
            marker.store(-1, ordering: .releasing); atBoundary.store(0, ordering: .releasing)
        case 2: // the DAC runs at the new rate: drop the wrong-rate start and the pause fade, refill
            marker.store(-1, ordering: .releasing); atBoundary.store(0, ordering: .releasing)
            ring.trim(keep: 0); bPlaying = false
            outSegmentAt.store(outFrames.load(ordering: .relaxed), ordering: .releasing)
        default: break
        }
        if refill.exchange(0, ordering: .acquiringAndReleasing) != 0 { bPlaying = false }
        let m = marker.load(ordering: .acquiring)
        // drop only zeros: the startup backlog, and Music's silence while it isn't playing
        if (!bPlaying || trimIdle.load(ordering: .relaxed) != 0), m < 0, lastNZ.load(ordering: .acquiring) <= ring.readPos, ring.fill > targetFill {
            ring.trim(keep: targetFill)
        }
        if !bPlaying && ring.fill >= targetFill { bPlaying = true }
        if bPlaying {
            ring.read(scratch, n, limit: m)
            if m >= 0 && ring.readPos >= m { atBoundary.store(1, ordering: .releasing) }
        } else {
            scratch.update(repeating: 0, count: n * 2)
            // not playing: nothing past the marker can reach the DAC, so B is at it (a take-back after the
            // release-only step-aside waited out the switch's 1 s for this: "boundary NOT reached")
            if m >= 0 && ring.readPos >= m { atBoundary.store(1, ordering: .releasing) }
        }
        if muted {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        } else {
            // software volume / mute (a DAC with no volume control): a ramp over the buffer, so a step or a mute doesn't click
            let target = SoftwareVolume.shared.effectiveGain
            var scaled = false
            if target != 1 || softGain != 1 {
                let from = softGain
                let step = (target - from) / Float(n)
                for k in 0..<n {
                    let g = k == n - 1 ? target : from + step * Float(k + 1)
                    scratch[k * 2] *= g; scratch[k * 2 + 1] *= g
                }
                softGain = target
                scaled = target > 0 || from > 0
            }
            fmt.write(outs, scratch, n, &ditherRNG, scaled: scaled)
        }
        recorder?.output(scratch, n, sample: t.mSampleTime, host: t.mHostTime)
        outFrames.wrappingAdd(n, ordering: .releasing)
        bCycles.wrappingAdd(1, ordering: .relaxed)
    }

    // MARK: - Helpers

    private func musicPlaying() -> Bool {
        musicRunning() && scripts.playerState() == "playing"
    }

    private func waitPlain(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        return cond()
    }

    private func ms(_ t: Date) -> String { String(format: "%.3f s", Date().timeIntervalSince(t)) }

    private func log(_ s: String) { log.write(s) }
}

// MARK: - Output format for B

/// Settings > Exclusive Mode > Software volume: for a DAC with no settable volume, B scales its
/// output by the virtual device's volume (linear in dB, 0 to -64 dB, the slider VolumeForwarder
/// maps), and mutes by writing silence (the mute works with the setting off too). At 0 dB nothing is
/// multiplied, so the output stays bit-perfect; below it the samples are scaled and dithered when
/// they're written to an integer DAC. Off by default. VolumeForwarder sets the gain (it stays 1 on a
/// DAC with a volume); B reads it.
final class SoftwareVolume: @unchecked Sendable {
    static let shared = SoftwareVolume()
    private let on = Atomic<Int>(0)
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let silent = Atomic<Int>(0)
    var isOn: Bool { on.load(ordering: .relaxed) != 0 }
    func set(_ value: Bool) { on.store(value ? 1 : 0, ordering: .relaxed) }
    func set(gain: Float, muted: Bool) {
        gainBits.store(gain.bitPattern, ordering: .relaxed)
        silent.store(muted ? 1 : 0, ordering: .relaxed)
    }
    /// What B multiplies by: 1 is unity, 0 while muted.
    var effectiveGain: Float { silent.load(ordering: .relaxed) != 0 ? 0 : Float(bitPattern: gainBits.load(ordering: .relaxed)) }
}

/// How B writes a stereo float frame into the DAC's buffers, packed into one Int for the IO thread.
/// Settings > Exclusive Mode > Inter-sample overshoot protection: a fixed -3.0 dB (x0.7079) on Exclusive Mode's output
/// to the DAC, for loud masters whose reconstructed waveform peaks above full scale between samples
/// (clipping in the DAC's filter). Off by default; when on, the output is no longer bit-perfect.
/// Off, nothing is multiplied. Read by both engines' IO threads.
final class OvershootProtection: @unchecked Sendable {
    static let shared = OvershootProtection()
    static let gain: Float = 0.70794578 // 10^(-3/20)
    private let on = Atomic<Int>(0)
    var isOn: Bool { on.load(ordering: .relaxed) != 0 }
    func set(_ value: Bool) { on.store(value ? 1 : 0, ordering: .relaxed) }
}

/// Settings > Exclusive Mode > TPDF dither: triangular (±1 LSB) dither when B requantizes to an integer DAC under 32
/// bits. Only a buffer that can't be written exactly gets it (the overshoot gain is on, or the source
/// has more bits than the DAC), so bit-perfect output and digital silence stay untouched. Off by
/// default. Exclusive Mode only: the process-tap engine writes float and the HAL converts.
/// `dacBits` (main thread) is the integer depth B writes, 32 for float, nil while no DAC is confirmed.
final class TPDFDither: ObservableObject, @unchecked Sendable {
    static let shared = TPDFDither()
    private let on = Atomic<Int>(0)
    var isOn: Bool { on.load(ordering: .relaxed) != 0 }
    func set(_ value: Bool) { on.store(value ? 1 : 0, ordering: .relaxed) }
    @Published var dacBits: Int?
    /// The last confirmed DAC offers at least one integer non-mixable format (Integer Mode is shown);
    /// nil until a DAC is confirmed. Kept while the DAC is released.
    @Published var dacHasInt: Bool?

    /// One TPDF sample in LSBs: the difference of two uniforms in [0, 1), range (-1, 1).
    @inline(__always)
    static func noise(_ state: inout UInt32) -> Double {
        (Double(next(&state)) - Double(next(&state))) / 4294967296.0
    }

    @inline(__always)
    private static func next(_ x: inout UInt32) -> UInt32 { // xorshift32
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        return x
    }
}

struct OutFormat: CustomStringConvertible {
    var isFloat = true
    var bytes = 4          // per sample
    var bits = 32
    var alignedHigh = false
    var nonInterleaved = false
    var left = 0, right = 1

    init(asbd f: AudioStreamBasicDescription, left: Int, right: Int) {
        isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let ch = max(Int(f.mChannelsPerFrame), 1)
        bytes = nonInterleaved ? Int(f.mBytesPerFrame) : Int(f.mBytesPerFrame) / ch
        if bytes <= 0 { bytes = isFloat ? 4 : max(Int(f.mBitsPerChannel) / 8, 2) }
        bits = f.mBitsPerChannel > 0 ? Int(f.mBitsPerChannel) : bytes * 8
        alignedHigh = f.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        self.left = left; self.right = right
    }

    init(packed p: Int) {
        isFloat = p & 1 != 0
        nonInterleaved = p & 2 != 0
        alignedHigh = p & 4 != 0
        bytes = (p >> 4) & 0xF
        bits = (p >> 8) & 0x3F
        left = (p >> 16) & 0xFF
        right = (p >> 24) & 0xFF
    }

    var packed: Int {
        (isFloat ? 1 : 0) | (nonInterleaved ? 2 : 0) | (alignedHigh ? 4 : 0) | (bytes << 4) | (bits << 8) | (left << 16) | (right << 24)
    }

    var description: String { "\(isFloat ? "float" : "int")\(bits) in \(bytes) bytes\(nonInterleaved ? " non-interleaved" : ""), channels \(left + 1)/\(right + 1)" }

    @inline(__always)
    func write(_ outs: UnsafeMutableAudioBufferListPointer, _ src: UnsafePointer<Float>, _ n: Int, _ rng: inout UInt32, scaled: Bool = false) {
        let scale = isFloat || bits < 2 ? 1 : Double(Int64(1) << (bits - 1))
        let lo = -scale, hi = scale - 1
        let reduce = OvershootProtection.shared.isOn, gain = OvershootProtection.gain
        let shift = alignedHigh ? bytes * 8 - bits : 0
        // dither the whole buffer if any sample lands between the DAC's steps
        var dither = false
        if !isFloat, bits < 32, TPDFDither.shared.isOn || scaled {
            dither = reduce
            if !dither {
                for i in 0..<(n * 2) {
                    let y = Double(src[i]) * scale
                    if y != y.rounded() { dither = true; break }
                }
            }
        }
        var base = 0
        for buf in outs {
            guard let d = buf.mData else { continue }
            memset(d, 0, Int(buf.mDataByteSize))
            let ch = Int(buf.mNumberChannels)
            let frames = min(n, Int(buf.mDataByteSize) / bytes / max(ch, 1))
            for c in 0..<ch {
                let g = base + c
                guard g == left || g == right else { continue }
                let s = g == left ? 0 : 1
                if isFloat {
                    let o = d.assumingMemoryBound(to: Float.self)
                    if reduce { for k in 0..<frames { o[k * ch + c] = src[k * 2 + s] * gain } }
                    else { for k in 0..<frames { o[k * ch + c] = src[k * 2 + s] } }
                } else {
                    for k in 0..<frames {
                        let x = reduce ? src[k * 2 + s] * gain : src[k * 2 + s]
                        let y = dither ? Double(x) * scale + TPDFDither.noise(&rng) : Double(x) * scale
                        let v = Int64(min(hi, max(lo, y.rounded()))) << shift
                        let at = d + (k * ch + c) * bytes
                        switch bytes {
                        case 2: at.storeBytes(of: Int16(truncatingIfNeeded: v), as: Int16.self)
                        case 3:
                            at.storeBytes(of: UInt8(truncatingIfNeeded: v), as: UInt8.self)
                            (at + 1).storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), as: UInt8.self)
                            (at + 2).storeBytes(of: UInt8(truncatingIfNeeded: v >> 16), as: UInt8.self)
                        default: at.storeBytes(of: Int32(truncatingIfNeeded: v), as: Int32.self)
                        }
                    }
                }
            }
            base += ch
        }
    }
}

// MARK: - Other apps on the built-in speakers

/// Music only (plug-in 1.1.4): what every app but Music played into the virtual device (loopback
/// channels 3-4, written by A into `ring`) plays on the built-in speakers. Not bit-perfect and not
/// meant to be: AVAudioEngine converts the virtual device's rate to the speakers', and a varispeed
/// absorbs the drift between the two clocks (the virtual clock follows the DAC, the speakers have
/// their own), steered from the ring's fill by a slow P loop.
final class OthersPlayer {
    let ring = VRing(frames: 1 << 17)
    private(set) var device = AudioObjectID(0)
    private(set) var rate: Double = 0
    let configChanged = Atomic<Int>(0) // AVAudioEngine stopped itself (the speakers' configuration changed)
    private var engine: AVAudioEngine?
    private var varispeed: AVAudioUnitVarispeed?
    private var observer: NSObjectProtocol?
    private var target = 2048
    private var fillAvg = -1.0
    private var lastRate: Float = 1
    private final class RenderState: @unchecked Sendable {
        let started = Atomic<Int>(0)  // 1 once the ring reached the target
        let restarts = Atomic<Int>(0) // pre-rolls after running dry
        let peak = Atomic<UInt32>(0)  // peak |sample| played since the last takePeak (Float bits)
    }

    func takePeak() -> Float { Float(bitPattern: rs.peak.exchange(0, ordering: .relaxed)) }
    private let rs = RenderState()
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)

    init() { scratch.initialize(repeating: 0, count: 16384 * 2) }
    deinit { stop(); scratch.deallocate() }

    var isRunning: Bool { engine?.isRunning ?? false }
    var latencyFrames: Int { engine == nil ? 0 : target }
    var status: String {
        guard engine != nil else { return "other apps: no player" }
        return "other apps: fill \(ring.fill) (target \(target)), varispeed \(String(format: "%.6f", lastRate)), dry \(rs.restarts.load(ordering: .relaxed))x, over \(ring.overruns.load(ordering: .relaxed))"
    }

    /// Plays `ring` (stereo at `rate`) on `device`. False (and stopped) if it can't, or if the output
    /// isn't `device`: playing into the virtual device would feed the other apps back into themselves.
    func start(device d: AudioObjectID, rate r: Double, log: (String) -> Void) -> Bool {
        stop()
        guard r > 0, let fmt = AVAudioFormat(standardFormatWithSampleRate: r, channels: 2) else { log("other apps: no format at \(r) Hz"); return false }
        let e = AVAudioEngine()
        guard let au = e.outputNode.audioUnit else { log("other apps: no output unit"); return false }
        var dev = d
        var st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
        guard st == noErr else { log("other apps: output device -> \(CA.string(d, kAudioObjectPropertyName)): \(st)"); return false }
        target = max(2048, Int(r * 0.05))
        rs.started.store(0, ordering: .releasing)
        let ring = self.ring, rs = self.rs, scratch = self.scratch, target = self.target
        let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let n = min(Int(frameCount), 16384)
            guard bufs.count >= 2, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self), let rt = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if rs.started.load(ordering: .relaxed) == 0 {
                // pre-roll (at start and after running dry): wait for the target, then drop any excess
                if ring.fill < target { l.update(repeating: 0, count: n); rt.update(repeating: 0, count: n); return noErr }
                ring.trim(keep: target)
                rs.started.store(1, ordering: .relaxed)
            }
            let got = ring.read(scratch, n)
            if got < n { rs.started.store(0, ordering: .relaxed); rs.restarts.wrappingAdd(1, ordering: .relaxed) }
            var pk: Float = 0
            for i in 0..<n { l[i] = scratch[i * 2]; rt[i] = scratch[i * 2 + 1]; pk = max(pk, abs(l[i]), abs(rt[i])) }
            if pk > Float(bitPattern: rs.peak.load(ordering: .relaxed)) { rs.peak.store(pk.bitPattern, ordering: .relaxed) }
            return noErr
        }
        let vs = AVAudioUnitVarispeed()
        e.attach(src); e.attach(vs)
        e.connect(src, to: vs, format: fmt)
        e.connect(vs, to: e.mainMixerNode, format: fmt)
        e.prepare()
        do { try e.start() } catch { log("other apps: player start failed: \(error)"); e.stop(); return false }
        var cur = AudioObjectID(0); var z = UInt32(4)
        st = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &z)
        guard st == noErr, cur == d else {
            log("other apps: player output is \(CA.string(cur, kAudioObjectPropertyName)), not \(CA.string(d, kAudioObjectPropertyName)); stopped")
            e.stop(); return false
        }
        engine = e; varispeed = vs; device = d; rate = r; fillAvg = -1; lastRate = 1
        configChanged.store(0, ordering: .releasing)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            self?.configChanged.store(1, ordering: .releasing)
        }
        log("other apps -> \(CA.string(d, kAudioObjectPropertyName)) at \(Int(r)) Hz (AVAudioEngine + varispeed; target fill \(target) frames)")
        return true
    }

    /// Why the player needs a rebuild, if it does: stopped, or its output isn't `device` any more. A
    /// configuration-change notice alone isn't a reason (one comes after every start).
    func problem() -> String? {
        let notice = configChanged.exchange(0, ordering: .acquiringAndReleasing) != 0
        guard let e = engine else { return "the player isn't running" }
        guard e.isRunning else { return notice ? "the speakers' configuration changed; the player stopped" : "the player stopped" }
        var cur = AudioObjectID(0); var z = UInt32(4)
        if let au = e.outputNode.audioUnit, AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &z) == noErr, cur != device {
            e.stop() // never play into another device (the virtual one would feed back)
            return "its output moved to \(CA.string(cur, kAudioObjectPropertyName))"
        }
        return nil
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil; varispeed = nil; device = 0; rate = 0
        rs.started.store(0, ordering: .releasing)
        ring.trim(keep: 0) // the reader is gone: the consumer side is ours
    }

    /// Every 0.5 s: varispeed = 1 + k (fill - target), smoothed, within +-2000 ppm (a few cents; the
    /// clocks differ by a few hundred ppm). Fill above target -> play faster.
    func steer(gain: Float) {
        if let e = engine, e.mainMixerNode.outputVolume != gain { e.mainMixerNode.outputVolume = gain }
        guard let vs = varispeed, rs.started.load(ordering: .relaxed) != 0 else { return }
        let f = Double(ring.fill)
        fillAvg = fillAvg < 0 ? f : fillAvg + 0.2 * (f - fillAvg)
        let r = 1 + max(-0.002, min(0.002, 5e-7 * (fillAvg - Double(target))))
        lastRate = Float(r)
        vs.rate = lastRate
    }
}

// MARK: - Ring and time stamps

/// Single-producer single-consumer stereo float ring (A writes, B reads; the consumer alone trims).
final class VRing: @unchecked Sendable {
    let size: Int
    private let data: UnsafeMutablePointer<Float>
    private let w = Atomic<Int>(0), r = Atomic<Int>(0)
    let overruns = Atomic<Int>(0), underruns = Atomic<Int>(0)

    init(frames: Int) {
        size = frames
        data = .allocate(capacity: frames * 2)
        data.initialize(repeating: 0, count: frames * 2)
    }

    deinit { data.deallocate() }

    var written: Int { w.load(ordering: .acquiring) }
    var readPos: Int { r.load(ordering: .acquiring) }
    var fill: Int { written - readPos }

    func write(_ src: UnsafePointer<Float>, _ count: Int) {
        let wi = w.load(ordering: .relaxed), rd = r.load(ordering: .acquiring)
        var n = count
        let space = size - (wi - rd)
        if n > space { overruns.wrappingAdd(n - space, ordering: .relaxed); n = space }
        let mask = size - 1
        for i in 0..<n { let k = ((wi + i) & mask) * 2; data[k] = src[i * 2]; data[k + 1] = src[i * 2 + 1] }
        w.store(wi + n, ordering: .releasing)
    }

    /// Reads n frames, never at or past `limit` (>= 0); zeros for the rest. Underruns count only
    /// frames missing below the limit.
    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, _ n: Int, limit: Int = -1) -> Int {
        let rd = r.load(ordering: .relaxed), wi = w.load(ordering: .acquiring)
        let allowed = limit >= 0 ? max(0, min(n, limit - rd)) : n
        let take = min(allowed, wi - rd)
        let mask = size - 1
        for i in 0..<take { let k = ((rd + i) & mask) * 2; dst[i * 2] = data[k]; dst[i * 2 + 1] = data[k + 1] }
        if take < n { (dst + take * 2).update(repeating: 0, count: (n - take) * 2) }
        if take < allowed { underruns.wrappingAdd(allowed - take, ordering: .relaxed) }
        r.store(rd + take, ordering: .releasing)
        return take
    }

    /// Consumer side: drop the oldest frames so at most `keep` remain.
    func trim(keep: Int) {
        let rd = r.load(ordering: .relaxed), wi = w.load(ordering: .acquiring)
        if wi - rd > keep { r.store(wi - keep, ordering: .releasing) }
    }
}

/// (sample time, host time, rate scalar) from an IO thread for the control thread; a seqlock so a
/// reader never pairs one cycle's sample time with another's host time.
final class VStamp: @unchecked Sendable {
    private let seq = Atomic<UInt64>(0)
    private let v = UnsafeMutablePointer<Double>.allocate(capacity: 3)

    init() { v.initialize(repeating: 0, count: 3) }
    deinit { v.deallocate() }

    func put(_ sample: Double, _ host: Double, _ scalar: Double) {
        let q = seq.load(ordering: .relaxed)
        seq.store(q + 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        v[0] = sample; v[1] = host; v[2] = scalar
        seq.store(q + 2, ordering: .releasing)
    }

    func get() -> (Double, Double, Double)? {
        for _ in 0..<100 {
            let q1 = seq.load(ordering: .acquiring)
            if q1 & 1 != 0 { continue }
            let a = v[0], b = v[1], c = v[2]
            atomicMemoryFence(ordering: .acquiring)
            if seq.load(ordering: .relaxed) == q1 { return q1 == 0 ? nil : (a, b, c) }
        }
        return nil
    }
}

// MARK: - Debug recording

/// vrender's format (research repo: vcheck.py, outcheck.py): <prefix>.in.f32 (what A read),
/// .out.f32 (what B played, as float), .cycles.txt / .in.cycles.txt (sample frames 0 host),
/// .segments.txt / .in.segments.txt (first frame, rate), .clock.csv. Streams to disk; enabled with
/// `defaults write <bundle id> RendererDebugRecord <prefix>` (+ RendererDebugRecordSeconds, 330).
final class VRecorder {
    private let prefix: String
    private let maxFrames: Int
    private let inRing = VRing(frames: 1 << 21), outRing = VRing(frames: 1 << 21)
    private let fIn: FileHandle, fOut: FileHandle, csv: FileHandle
    private let buf = UnsafeMutablePointer<Float>.allocate(capacity: (1 << 21) * 2)
    private let maxCycles: Int
    private let cycA: UnsafeMutablePointer<Double>, cycB: UnsafeMutablePointer<Double>
    private var nA = 0, nB = 0          // IO threads
    private var framesIn = 0, framesOut = 0
    private var segIn: [String] = [], segOut: [String] = []
    private let t0 = Date()

    static func fromDefaults(log: (String) -> Void) -> VRecorder? {
        guard let prefix = UserDefaults.standard.string(forKey: "RendererDebugRecord"), !prefix.isEmpty else { return nil }
        let seconds = UserDefaults.standard.object(forKey: "RendererDebugRecordSeconds") as? Double ?? 330
        log("debug recording to \(prefix).* (\(Int(seconds)) s)")
        return VRecorder(prefix: prefix, seconds: seconds)
    }

    private init?(prefix: String, seconds: Double) {
        self.prefix = prefix
        maxFrames = Int(seconds * 192_000)
        maxCycles = Int(seconds * 192_000 / 64)
        for ext in ["in.f32", "out.f32"] { FileManager.default.createFile(atPath: "\(prefix).\(ext)", contents: nil) }
        FileManager.default.createFile(atPath: prefix + ".clock.csv", contents: "t,fill,phase,err,dacScalarHAL,lsScalarHAL,lsScalarSet,overruns,underruns,aCycles,bCycles,rate\n".data(using: .utf8))
        guard let a = FileHandle(forWritingAtPath: prefix + ".in.f32"), let b = FileHandle(forWritingAtPath: prefix + ".out.f32"),
              let c = FileHandle(forWritingAtPath: prefix + ".clock.csv") else { return nil }
        fIn = a; fOut = b; csv = c; csv.seekToEndOfFile()
        cycA = .allocate(capacity: maxCycles * 3); cycB = .allocate(capacity: maxCycles * 3)
    }

    @inline(__always) func input(_ f: UnsafePointer<Float>, _ n: Int, sample: Double, host: UInt64) {
        inRing.write(f, n)
        if nA < maxCycles { cycA[nA * 3] = sample; cycA[nA * 3 + 1] = Double(n); cycA[nA * 3 + 2] = Double(host); nA += 1 }
    }

    @inline(__always) func output(_ f: UnsafePointer<Float>, _ n: Int, sample: Double, host: UInt64) {
        outRing.write(f, n)
        if nB < maxCycles { cycB[nB * 3] = sample; cycB[nB * 3 + 1] = Double(n); cycB[nB * 3 + 2] = Double(host); nB += 1 }
    }

    deinit { buf.deallocate(); cycA.deallocate(); cycB.deallocate() }

    func segmentIn(_ frame: Int, _ rate: Double) { segIn.append("\(frame) \(rate)") }
    func segmentOut(_ frame: Int, _ rate: Double) { segOut.append("\(frame) \(rate)") }

    func clock(fill: Int, phase: Double, err: Double, dac: Double, lsSet: Double, over: Int, under: Int, a: Int, b: Int, rate: Double) {
        let line = String(format: "%.2f,%d,%.2f,%.3f,%.9f,%.9f,%.9f,%d,%d,%d,%d,%.0f\n", Date().timeIntervalSince(t0), fill, phase, err, dac, lsSet, lsSet, over, under, a, b, rate)
        csv.write(line.data(using: .utf8)!)
    }

    func drain() {
        for (r, f, isIn) in [(inRing, fIn, true), (outRing, fOut, false)] {
            let n = r.fill
            guard n > 0 else { continue }
            r.read(buf, n)
            let done = isIn ? framesIn : framesOut
            let keep = max(0, min(n, maxFrames - done))
            if keep > 0 { f.write(Data(bytes: buf, count: keep * 8)) }
            if isIn { framesIn += n } else { framesOut += n }
        }
    }

    func finish() {
        drain()
        func cycles(_ c: UnsafeMutablePointer<Double>, _ n: Int, _ path: String) {
            var s = ""
            for i in 0..<n { s += String(format: "%.0f %.0f 0 %.0f\n", c[i * 3], c[i * 3 + 1], c[i * 3 + 2]) }
            FileManager.default.createFile(atPath: path, contents: s.data(using: .utf8))
        }
        cycles(cycB, nB, prefix + ".cycles.txt")
        cycles(cycA, nA, prefix + ".in.cycles.txt")
        FileManager.default.createFile(atPath: prefix + ".segments.txt", contents: (segOut.joined(separator: "\n") + "\n").data(using: .utf8))
        FileManager.default.createFile(atPath: prefix + ".in.segments.txt", contents: (segIn.joined(separator: "\n") + "\n").data(using: .utf8))
        try? fIn.close(); try? fOut.close(); try? csv.close()
    }
}

// MARK: - Core Audio helpers

enum CA {
    static func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func array<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _: T.Type) -> [T] {
        var a = a; var z: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &z) == noErr, z > 0 else { return [] }
        let n = Int(z) / MemoryLayout<T>.stride
        let p = UnsafeMutablePointer<T>.allocate(capacity: n); defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, p) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    static func string(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
        guard obj != 0 else { return "" }
        var a = addr(s); var v: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v) == noErr else { return "" }
        return (v?.takeRetainedValue() as String?) ?? ""
    }

    static func devices() -> [AudioObjectID] { array(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self) }
    static func streams(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioStreamID] { array(d, addr(kAudioDevicePropertyStreams, scope), AudioStreamID.self) }
    static func hasOutput(_ d: AudioObjectID) -> Bool { !streams(d, kAudioObjectPropertyScopeOutput).isEmpty }

    static func transport(_ d: AudioObjectID) -> UInt32 {
        var t = UInt32(0); var a = addr(kAudioDevicePropertyTransportType); var z = UInt32(4)
        AudioObjectGetPropertyData(d, &a, 0, nil, &z, &t); return t
    }

    static func defaultOutput() -> AudioObjectID {
        var d = AudioObjectID(0); var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var z = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d); return d
    }

    static func setDefaultOutput(_ d: AudioObjectID) -> OSStatus {
        var d = d; var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &d)
    }

    /// The alert-sound device.
    static func systemOutput() -> AudioObjectID {
        var d = AudioObjectID(0); var a = addr(kAudioHardwarePropertyDefaultSystemOutputDevice); var z = UInt32(4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d); return d
    }

    static func setSystemOutput(_ d: AudioObjectID) -> OSStatus {
        var d = d; var a = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &d)
    }

    /// A stream's channel count (its virtual format).
    static func channels(_ s: AudioStreamID) -> UInt32 {
        var f = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyVirtualFormat)
        return AudioObjectGetPropertyData(s, &a, 0, nil, &z, &f) == noErr ? f.mChannelsPerFrame : 0
    }

    static func nominal(_ d: AudioObjectID) -> Float64 { DeviceFormat.nominalSampleRate(d) ?? 0 }

    static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var v = UInt32(0); var a = addr(sel, scope); var z = UInt32(4)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v) == noErr ? v : 0
    }

    /// What an app playing to `d` assumes of it: latency + safety offset + stream latency + buffer (frames).
    static func presentationFrames(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        let st = streams(d, scope).first.map { uint32($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? 0
        return Int(uint32(d, kAudioDevicePropertyLatency, scope) + uint32(d, kAudioDevicePropertySafetyOffset, scope)
            + st + uint32(d, kAudioDevicePropertyBufferFrameSize, scope))
    }

    static func setNominal(_ d: AudioObjectID, _ hz: Float64) -> OSStatus {
        var r = hz; var a = addr(kAudioDevicePropertyNominalSampleRate)
        return AudioObjectSetPropertyData(d, &a, 0, nil, 8, &r)
    }

    static func nominalRates(_ d: AudioObjectID) -> [Float64] {
        array(d, addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self).map { $0.mMinimum }
    }

    static func hogOwner(_ d: AudioObjectID) -> pid_t {
        var h = pid_t(0); var a = addr(kAudioDevicePropertyHogMode); var z = UInt32(4)
        AudioObjectGetPropertyData(d, &a, 0, nil, &z, &h); return h
    }

    /// Some process (Music, stepped aside) still has IO running on the device.
    static func runningSomewhere(_ d: AudioObjectID) -> Bool {
        var v = UInt32(0); var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere); var z = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr && v != 0
    }

    static func availablePhysicalFormats(_ s: AudioStreamID) -> [AudioStreamRangedDescription] {
        array(s, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self)
    }

    static func fmt(_ f: AudioStreamBasicDescription) -> String {
        "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel) bit flags \(f.mFormatFlags)"
    }

    static func formats(_ s: AudioStreamID) -> String {
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &pf)
        a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &vf)
        return "phys \(fmt(pf)) / virt \(fmt(vf))"
    }

    static func physicalAndVirtual(_ s: AudioStreamID) -> (AudioStreamBasicDescription, AudioStreamBasicDescription) {
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &pf)
        a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &vf)
        return (pf, vf)
    }

    static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatFlags == b.mFormatFlags && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mFormatID == b.mFormatID
    }

    /// The mixable twin of the output stream's current physical format (never a saved struct: it carries a rate).
    static func setMixable(_ d: AudioObjectID) -> OSStatus {
        guard let s = streams(d, kAudioObjectPropertyScopeOutput).first else { return -1 }
        var f = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat)
        AudioObjectGetPropertyData(s, &a, 0, nil, &z, &f)
        guard f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 else { return noErr }
        f.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        return AudioObjectSetPropertyData(s, &a, 0, nil, z, &f)
    }

    static func setCFNumber(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ n: NSNumber) -> OSStatus {
        var a = addr(sel); let num: CFNumber = n
        var ref = Unmanaged.passUnretained(num)
        return withExtendedLifetime(num) { AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref) }
    }

    /// The plug-in's custom properties take a CFPropertyListRef.
    static func setScalar(_ d: AudioObjectID, _ s: Double, _ sel: AudioObjectPropertySelector) -> OSStatus {
        var a = addr(sel); let num: CFNumber = s as NSNumber
        var ref = Unmanaged.passUnretained(num)
        return withExtendedLifetime(num) { AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref) }
    }

    /// Turns a scope's streams off for one IOProc (so it isn't a client of them).
    static func streamUsageOff(_ dev: AudioObjectID, _ proc: AudioDeviceIOProcID, _ scope: AudioObjectPropertyScope) -> OSStatus {
        var a = addr(kAudioDevicePropertyIOProcStreamUsage, scope); var z: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &z) == noErr, z > 0 else { return -1 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(z), alignment: 8); defer { raw.deallocate() }
        let u = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        u.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        var st = AudioObjectGetPropertyData(dev, &a, 0, nil, &z, raw)
        guard st == noErr else { return st }
        let flags = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        for i in 0..<Int(u.pointee.mNumberStreams) { flags[i] = 0 }
        st = AudioObjectSetPropertyData(dev, &a, 0, nil, z, raw)
        return st
    }
}

// MARK: - Volume forwarding

/// The volume keys and the sound menu change the default output's volume and mute: while the
/// engine runs that is the virtual device, which passes audio at unity. Its volume and mute are
/// forwarded to the DAC's own controls, so the stream to the DAC stays bit-perfect. The DAC's master
/// element (0) if it has a volume there, else the stereo pair's channel elements (Babyface Pro:
/// channels 1/2, no master, no mute).
/// Mapping: the slider is linear in dB from 0 dB down to -64 dB (4 dB per key step, 1 dB per
/// Option+Shift step), the same mapping plug-in 1.1.3 reports, so the virtual device reads the DAC's
/// own level and never above 0 dB; the bottom is the DAC's minimum. The DAC's own taper made one step
/// 8-9.5 dB on the Babyface. A DAC without dB controls gets the slider's value as its scalar.
/// A DAC with no settable volume: mute outputs silence (SoftwareVolume, B). With Settings > Exclusive Mode > Software
/// volume on, the slider scales B's output by the same mapping (0 dB is unity and untouched); with it
/// off, the virtual device is held at 0 dB, nothing attenuates, and the first volume key press that changes
/// the volume or the mute shows a notice that says so. Stop leaves the virtual device at 0 dB, unmuted.
/// A DAC without a mute is muted by setting its volume to the minimum; unmute and stop restore the
/// level it had. A change made on the DAC itself (Audio MIDI Setup, TotalMix) moves the slider to
/// match. Comparisons are in slider units, so the DAC's own rounding (0.5 dB on the RME) doesn't echo.
/// Listeners run on their own queue: the keys keep working while a rate switch holds the engine thread.
final class VolumeForwarder {
    /// Set while a DAC without a mute is at its minimum for a mute: [UID, DAC scalar to restore].
    private static let mutedKey = "RendererDACMutedByVolume"
    private static let tolerance: Float32 = 0.01 // slider units (1/16 per key step)
    private static let noticeKey = "VolumeNoticeDACs" // UIDs of DACs without volume that have had the notice

    private let queue = DispatchQueue(label: "RendererEngine.volume")
    private let log: (String) -> Void
    // on the queue
    private var active = false
    private var ls = AudioObjectID(0), dac = AudioObjectID(0), dacUID = ""
    private var volumeEls: [UInt32] = [], muteEls: [UInt32] = []
    private var emulatedMute = false
    private var mutedLevel: Float32 = 0 // DAC scalar before an emulated mute
    private static let topDB: Float32 = 0, rangeDB: Float32 = 64 // LSOutput.driver's kVolume_MaxDB, -kVolume_MinDB
    private var topDB: Float32 { Self.topDB }
    private var rangeDB: Float32 { Self.rangeDB }
    private var useDB = false
    private var dbDirect = false // the DAC has a dB range but no dB -> scalar conversion (DragonFly Black): set its dB
    private var pinned = false // the DAC has no volume: mute is silence; the slider scales B's output only with Software Volume on, else it's held at 0 dB
    private var pinnedLevel: Float32 = 1 // slider, kept across engine restarts while the setting is on
    private var pinnedMuted = false
    private var pinnedUID = "" // the DAC pinnedLevel and pinnedMuted belong to
    private var noticePending = false
    // engine thread
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(log: @escaping (String) -> Void) { self.log = log }

    /// Engine thread, after the DAC is set up.
    func start(virtual ls: AudioObjectID, dac: AudioObjectID) {
        stop()
        let vols = Self.elements(dac, kAudioDevicePropertyVolumeScalar)
        let mutes = Self.elements(dac, kAudioDevicePropertyMute)
        queue.sync {
            self.ls = ls; self.dac = dac; self.dacUID = CA.string(dac, kAudioDevicePropertyDeviceUID)
            volumeEls = vols; muteEls = mutes; emulatedMute = false
            pinned = vols.isEmpty
            let owner = vols.isEmpty ? dacUID : ""
            if pinnedUID != owner { pinnedLevel = 1; pinnedMuted = false; pinnedUID = owner }
            guard !vols.isEmpty else {
                let soft = SoftwareVolume.shared.isOn
                let level: Float32 = soft ? pinnedLevel : 1
                log("volume: DAC has no settable output volume; \(soft ? "software volume on (the keys scale the output)" : "the volume keys change nothing (audio stays at unity)"); mute outputs silence; slider -> \(String(format: "%.4f", level)): \(Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, level)), mute -> \(pinnedMuted ? 1 : 0): \(Self.set(ls, kAudioDevicePropertyMute, 0, pinnedMuted ? 1 : 0))")
                applySoftware(level: level, muted: pinnedMuted)
                active = true
                return
            }
            applySoftware(level: 1, muted: false)
            let hasRange = Self.dbRange(dac, vols[0]) != nil
            dbDirect = hasRange && Self.dbToScalar(dac, vols[0], topDB) == nil && Self.settable(dac, kAudioDevicePropertyVolumeDecibels, vols[0])
            useDB = hasRange && (dbDirect || Self.dbToScalar(dac, vols[0], topDB) != nil)
            // start from the DAC's level, so nothing jumps
            let level = currentSlider() ?? 1
            let muted = mutes.first.flatMap { Self.get(dac, kAudioDevicePropertyMute, $0) }.map { $0 != 0 } ?? false
            let st = Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, level)
            let mst = Self.set(ls, kAudioDevicePropertyMute, 0, muted ? 1 : 0)
            let map = useDB ? "linear in dB, \(Int(topDB)) to \(Int(topDB - rangeDB)) dB (\(String(format: "%.1f", rangeDB / 16)) dB per key step)\(dbDirect ? ", set in dB (no dB -> scalar on the DAC)" : "")" : "DAC scalar (no dB controls)"
            log("volume: forwarding to DAC element\(vols.count > 1 ? "s" : "") \(vols.map(String.init).joined(separator: ",")) (\(Self.db(dac, vols[0])) dB), \(map); mute \(mutes.isEmpty ? "emulated (DAC has none)" : "to element\(mutes.count > 1 ? "s" : "") \(mutes.map(String.init).joined(separator: ","))"); slider -> \(String(format: "%.4f", level)): \(st), mute -> \(muted ? 1 : 0): \(mst)")
            active = true
        }
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            listen(ls, AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)) { $0.push() }
        }
        guard !vols.isEmpty else { return }
        for e in vols {
            listen(dac, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)) { $0.pull() }
        }
    }

    /// Engine thread: listeners off; a DAC muted by volume gets its level back.
    func stop() {
        for (obj, a, block) in listeners { var a = a; AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block) }
        listeners = []
        queue.sync {
            guard active else { return }
            active = false
            if emulatedMute {
                log("volume: unmuting the DAC as the engine lets go (\(String(format: "%.4f", mutedLevel))): \(setDACScalar(mutedLevel))")
                emulatedMute = false
                UserDefaults.standard.removeObject(forKey: Self.mutedKey)
            }
            // nothing drives it now: leave it reading unity, which is what it passes
            _ = Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, 1); _ = Self.set(ls, kAudioDevicePropertyMute, 0, 0)
            RendererOutput.shared.set(softwareVolume: nil) // B's gain is left as it is: the next start() publishes the new one while B is muted
            pinned = false
        }
    }

    /// Engine thread, when Settings > Exclusive Mode > Software volume changes: a DAC with no volume starts or stops scaling.
    func softwareVolumeChanged() {
        queue.async { if self.active && self.pinned { self.pushPinned(fromKey: false) } }
    }

    /// At launch after an unclean exit: a DAC left at its minimum by an emulated mute gets its level back.
    static func recover() -> String? {
        guard let saved = UserDefaults.standard.array(forKey: mutedKey), saved.count == 2,
              let uid = saved[0] as? String, let level = (saved[1] as? NSNumber)?.floatValue else { return nil }
        UserDefaults.standard.removeObject(forKey: mutedKey)
        guard let d = CA.devices().first(where: { CA.string($0, kAudioDevicePropertyDeviceUID) == uid }) else { return nil }
        let st = elements(d, kAudioDevicePropertyVolumeScalar).map { set(d, kAudioDevicePropertyVolumeScalar, $0, level) }
        return "DAC volume restored from an emulated mute to \(String(format: "%.4f", level)): \(st)"
    }

    private func listen(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ body: @escaping (VolumeForwarder) -> Void) {
        var a = a
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in if let self, self.active { body(self) } }
        let st = AudioObjectAddPropertyListenerBlock(obj, &a, queue, block)
        if st == noErr { listeners.append((obj, a, block)) } else { log("volume: listener on \(obj) el \(a.mElement): \(st)") }
    }

    // MARK: mapping (on the queue)

    /// Slider (0...1) -> DAC scalar: linear in dB over the window; 0 is the DAC's minimum.
    private func dacScalar(forSlider v: Float32) -> Float32 {
        guard useDB else { return v }
        if v <= 0.001 { return 0 }
        let dB = topDB - (1 - v) * rangeDB
        return Self.dbToScalar(dac, volumeEls[0], dB) ?? v
    }

    /// The DAC's level in slider units (the loudest of its elements).
    private func currentSlider() -> Float32? {
        guard useDB else { return volumeEls.compactMap { Self.get(dac, kAudioDevicePropertyVolumeScalar, $0) }.max() }
        guard let dB = volumeEls.compactMap({ Self.get(dac, kAudioDevicePropertyVolumeDecibels, $0) }).max() else { return nil }
        return min(1, max(0, 1 + (dB - topDB) / rangeDB))
    }

    /// Virtual device -> DAC (a volume key, the sound menu).
    private func push() {
        if pinned { pushPinned(fromKey: true); return }
        guard let v = Self.get(ls, kAudioDevicePropertyVolumeScalar, 0) else { return }
        let m = (Self.get(ls, kAudioDevicePropertyMute, 0) ?? 0) != 0
        var did: [String] = []
        if !muteEls.isEmpty {
            for e in muteEls where (Self.get(dac, kAudioDevicePropertyMute, e) ?? 0) != (m ? 1 : 0) {
                did.append("mute el\(e) -> \(m ? 1 : 0): \(Self.set(dac, kAudioDevicePropertyMute, e, m ? 1 : 0))")
            }
        } else if m != emulatedMute {
            if m {
                mutedLevel = volumeEls.compactMap { Self.get(dac, kAudioDevicePropertyVolumeScalar, $0) }.max() ?? dacScalar(forSlider: v)
                UserDefaults.standard.set([dacUID, NSNumber(value: mutedLevel)], forKey: Self.mutedKey)
                did.append("mute (DAC to its minimum): \(setDACScalar(0))")
            } else {
                UserDefaults.standard.removeObject(forKey: Self.mutedKey)
                did.append("unmute")
            }
            emulatedMute = m
        }
        if !(muteEls.isEmpty && m), let cur = currentSlider(), abs(cur - v) > Self.tolerance || did.contains("unmute") {
            if dbDirect {
                let dB = v <= 0.001 ? (Self.dbRange(dac, volumeEls[0])?.min ?? topDB - rangeDB) : topDB - (1 - v) * rangeDB
                did.append("DAC \(volumeEls.map { Self.set(dac, kAudioDevicePropertyVolumeDecibels, $0, dB) }) -> \(Self.db(dac, volumeEls[0])) dB")
            } else {
                did.append("DAC \(setDACScalar(dacScalar(forSlider: v))) -> \(Self.db(dac, volumeEls[0])) dB")
            }
        }
        if !did.isEmpty { log("volume \(String(format: "%.4f", v))\(m ? " muted" : ""): " + did.joined(separator: ", ")) }
    }

    /// A DAC with no volume: mute is silence; the level scales B's output if Software Volume is on, else
    /// the slider goes back to 0 dB (and a lower or mute key press gets the notice, once per DAC).
    private func pushPinned(fromKey: Bool) {
        let v = Self.get(ls, kAudioDevicePropertyVolumeScalar, 0) ?? 1
        let m = (Self.get(ls, kAudioDevicePropertyMute, 0) ?? 0) != 0
        let soft = SoftwareVolume.shared.isOn
        let level: Float32 = soft ? v : 1
        if m != pinnedMuted || level != pinnedLevel {
            log("volume \(String(format: "%.4f", v))\(m ? " muted" : ""): \(soft ? "software, \(Self.softwareText(level) ?? "0 dB")" : "DAC has no volume control")\(m ? ", output silent" : "")")
        }
        let muteChanged = m != pinnedMuted
        pinnedMuted = m; pinnedLevel = level
        applySoftware(level: level, muted: m)
        if !soft {
            if v < 1 { log("volume: DAC has no volume control; virtual device back to 0 dB: \(Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, 1))") }
            if fromKey && (v < 1 || muteChanged) { noticeOnce() }
        }
    }

    /// Hands B the gain for a slider position (1 at the top, so nothing is multiplied) and the Bit-perfect check its line.
    private func applySoftware(level: Float32, muted: Bool) {
        let unity = level >= 1 - Self.tolerance
        let gain: Float = unity ? 1 : level <= 0.001 ? 0 : Float(pow(10, Double(topDB - (1 - level) * rangeDB) / 20))
        SoftwareVolume.shared.set(gain: gain, muted: muted)
        RendererOutput.shared.set(softwareVolume: unity ? nil : Self.softwareText(level))
    }

    private static func softwareText(_ level: Float32) -> String? {
        if level >= 1 - tolerance { return nil }
        if level <= 0.001 { return "Software volume at its minimum (silent; scales the samples)" }
        return "Software volume \(Int((topDB - (1 - level) * rangeDB).rounded())) dB (scales the samples)"
    }

    private func noticeOnce() {
        let shown = UserDefaults.standard.stringArray(forKey: Self.noticeKey) ?? []
        guard !shown.contains(dacUID), !noticePending else { return }
        noticePending = true
        let uid = dacUID
        let name = CA.string(dac, kAudioObjectPropertyName)
        let text = "\(name.isEmpty ? "This DAC" : name) has no volume control. Turn on Software volume under Settings, or use the DAC's knob or your amplifier."
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { [weak self] ok, _ in
            self?.queue.async {
                self?.noticePending = false
                guard ok else { return }
                var shown = UserDefaults.standard.stringArray(forKey: Self.noticeKey) ?? []
                guard !shown.contains(uid) else { return }
                self?.log("volume: notice: " + text)
                shown.append(uid)
                UserDefaults.standard.set(shown, forKey: Self.noticeKey)
                let c = UNMutableNotificationContent()
                c.title = "Nativerate: volume"
                c.body = text
                center.add(UNNotificationRequest(identifier: "volume-notice", content: c, trigger: nil))
            }
        }
    }

    /// DAC -> virtual device (changed on the DAC itself); not while an emulated mute holds it down.
    private func pull() {
        guard !emulatedMute, let v = Self.get(ls, kAudioDevicePropertyVolumeScalar, 0),
              let d = currentSlider(), abs(d - v) > Self.tolerance else { return }
        log("volume: DAC changed to \(Self.db(dac, volumeEls[0])) dB; slider follows to \(String(format: "%.4f", d)): \(Self.set(ls, kAudioDevicePropertyVolumeScalar, 0, d))")
    }

    private func setDACScalar(_ level: Float32) -> [OSStatus] {
        volumeEls.map { Self.set(dac, kAudioDevicePropertyVolumeScalar, $0, level) }
    }

    // MARK: Core Audio

    /// Settable output elements for `sel`: the master, else the stereo pair's channels.
    private static func elements(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [UInt32] {
        func settable(_ e: UInt32) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
            var s: DarwinBoolean = false
            return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &s) == noErr && s.boolValue
        }
        if settable(0) { return [0] }
        var ch = [UInt32](repeating: 0, count: 2)
        var a = CA.addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var z = UInt32(8)
        let pair: [UInt32] = AudioObjectGetPropertyData(d, &a, 0, nil, &z, &ch) == noErr && ch[0] >= 1 && ch[1] >= 1 ? ch : [1, 2]
        return Array(Set(pair)).sorted().filter(settable)
    }

    private static func dbRange(_ d: AudioObjectID, _ e: UInt32) -> (min: Float32, max: Float32)? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        var r = AudioValueRange(); var z = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &z, &r) == noErr, r.mMaximum > r.mMinimum else { return nil }
        return (Float32(r.mMinimum), Float32(r.mMaximum))
    }

    /// The DAC's own dB -> scalar translation (its taper), clamped to its range.
    private static func dbToScalar(_ d: AudioObjectID, _ e: UInt32, _ dB: Float32) -> Float32? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibelsToScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        var v = dB; if let r = dbRange(d, e) { v = min(r.max, max(r.min, v)) }
        var z = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr ? v : nil
    }

    private static func get(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32) -> Float32? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        if sel == kAudioDevicePropertyMute {
            var u = UInt32(0); var z = UInt32(4)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &u) == noErr ? Float32(u) : nil
        }
        var f = Float32(0); var z = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &f) == noErr ? f : nil
    }

    private static func set(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32, _ v: Float32) -> OSStatus {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        if sel == kAudioDevicePropertyMute { var u = UInt32(v != 0 ? 1 : 0); return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &u) }
        var f = v; return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &f)
    }

    private static func settable(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        var b: DarwinBoolean = false
        return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &b) == noErr && b.boolValue
    }

    private static func db(_ d: AudioObjectID, _ e: UInt32) -> String {
        get(d, kAudioDevicePropertyVolumeDecibels, e).map { String(format: "%.1f", $0) } ?? "?"
    }
}

// MARK: - Music settings check

/// Music settings that defeat the engine: AutoMix or crossfade (tracks blend, so a switch can't be
/// clean), Sound Check, EQ and a Music volume below 100 (not bit-perfect), Lossless off. Read at
/// engine start, at each new track and on "Check Again" only (no timer: minimal CPU; a change
/// mid-track shows at the next track). Music's preferences (keys confirmed on the Babyface bench by
/// toggling: TransitionsEnabled 0/1; optimizeSongVolume 1, absent when off) and, for EQ and volume,
/// AppleScript (the "eqEnabled" preference disagreed with Music's own "EQ enabled"). A change in the
/// set of problems is logged, shown at the top of the menu, posted as one notification, and opens a
/// window with the fixes that stays until they're done (it closes itself when a check comes back clean).
final class MusicSettingsCheck: ObservableObject {
    struct Problem: Equatable, Identifiable {
        let id: String, what: String, fix: String
    }

    static let shared = MusicSettingsCheck()
    @Published private(set) var problems: [Problem] = []
    @Published private(set) var checkedAt: Date?
    /// Main thread -> engine thread: "Check Again".
    let recheck = Atomic<Int>(0)
    private var last: [Problem] = []
    private var askedForNotifications = false
    private var window: NSWindow?

    /// Engine thread.
    func check(_ scripts: RendererScripts, musicRunning: Bool, log: (String) -> Void) {
        guard musicRunning else { return }
        let app = "com.apple.Music" as CFString
        CFPreferencesAppSynchronize(app)
        func pref(_ k: String) -> Int? { (CFPreferencesCopyAppValue(k as CFString, app) as? NSNumber)?.intValue }
        var found: [Problem] = []
        if let t = pref("TransitionsEnabled"), t != 0 {
            found.append(.init(id: "transitions", what: "AutoMix or Crossfade is on",
                               fix: "Music > Settings > Playback: turn off AutoMix and Crossfade. They blend one track into the next, so a sample-rate switch can't happen cleanly."))
        }
        if let v = pref("optimizeSongVolume"), v != 0 {
            found.append(.init(id: "soundcheck", what: "Sound Check is on",
                               fix: "Music > Settings > Playback: turn off Sound Check. It changes each track's level, so the output isn't bit-perfect."))
        }
        if let l = pref("losslessEnabled"), l == 0 {
            found.append(.init(id: "lossless", what: "Lossless Audio is off",
                               fix: "Music > Settings > Playback: turn on Lossless Audio and choose Hi-Res Lossless for streaming. Otherwise Apple Music plays lossy AAC."))
        }
        if scripts.eqEnabled() == true {
            found.append(.init(id: "eq", what: "The Equalizer is on",
                               fix: "Music > Window > Equalizer: uncheck On. EQ changes the samples, so the output isn't bit-perfect."))
        }
        if let v = scripts.volume(), v < 100 {
            found.append(.init(id: "volume", what: "Music's volume is \(v), not 100",
                               fix: "Drag Music's volume slider all the way up, or click Set to 100 below. Use the keyboard's volume keys instead: they now change the DAC's own volume."))
        }
        let changed = found != last
        last = found
        DispatchQueue.main.async {
            self.checkedAt = Date()
            self.problems = found
            if found.isEmpty { self.window?.close() } else if changed { self.showWindow() }
        }
        guard changed else { return }
        log(found.isEmpty ? "Music settings: OK" : "Music settings: " + found.map(\.what).joined(separator: "; "))
        guard !found.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let c = UNMutableNotificationContent()
            c.title = "Nativerate: Music settings"
            c.body = found.map(\.what).joined(separator: "\n") + "\nPlayback isn't bit-perfect until this is fixed."
            center.add(UNNotificationRequest(identifier: "music-settings", content: c, trigger: nil))
        }
        if askedForNotifications { post(); return }
        askedForNotifications = true
        center.requestAuthorization(options: [.alert]) { ok, _ in if ok { post() } }
    }

    func clear() {
        last = []
        DispatchQueue.main.async { self.problems = []; self.window?.close() }
    }

    /// Main thread.
    func checkAgain() { recheck.store(1, ordering: .releasing) }

    /// Main thread; the AppleScript runs off it.
    func setMusicVolumeTo100() {
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Music\" to set sound volume to 100")?.executeAndReturnError(&err)
            self.recheck.store(1, ordering: .releasing)
        }
    }

    /// Main thread.
    private func showWindow() {
        if window == nil {
            // sized by the view, and resized as problems come and go (a fixed 460 x 300 would clip
            // four or five of them, as the driver update window's 260 did on Executor)
            let host = NSHostingController(rootView: MusicSettingsView(check: self))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = "Music settings for bit-perfect playback"
            w.isReleasedWhenClosed = false
            w.setContentSize(host.view.fittingSize) // before center(): unshown, the window is 1 x 32
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MusicSettingsView: View {
    @ObservedObject var check: MusicSettingsCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exclusive Mode plays Music's output bit-perfect only when Music doesn't change it. Fix these in Music:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(check.problems) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.what).bold()
                    Text(p.fix).fixedSize(horizontal: false, vertical: true)
                    if p.id == "volume" {
                        Button("Set to 100") { check.setMusicVolumeTo100() }
                    }
                }
            }
            if check.problems.isEmpty { Text("All set.") }
            HStack {
                Button("Check Again") { check.checkAgain() }
                if let t = check.checkedAt {
                    Text("Checked \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Also checked at each new track.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true) // height = the problems listed + the buttons
    }
}

// MARK: - The DAC, for the menu

/// While the engine plays to a DAC the default output is its virtual device, so the menu would name
/// "Nativerate". The engine publishes the DAC it holds; the menu shows that, and goes back to
/// the default output's name when the engine lets the DAC go.
final class RendererOutput: ObservableObject {
    static let shared = RendererOutput()
    @Published private(set) var dacName: String?
    /// The held DAC's device ID, for Settings > Advanced > DAC info (the default output is then the virtual device).
    @Published private(set) var dacID: AudioObjectID?
    /// The playing track's source, as the engine decided it: its bit depth (nil: not known) and
    /// whether it's lossy (AAC has no bit depth). The menu shows it while the engine holds a DAC.
    @Published private(set) var sourceBits: Int?
    @Published private(set) var sourceLossy = false
    /// Music's samples fit neither the 16- nor the 24-bit grid on a lossless track: Music changes them.
    @Published private(set) var offGrid = false

    /// Any thread.
    /// The depth (16 or 24) the track measured near rather than on its grid: rounded in the playback
    /// path (macOS 26), not bit-exact, not a level change. 0 otherwise.
    @Published private(set) var nearGrid = 0

    /// Any thread.
    func set(nearGrid v: Int) {
        DispatchQueue.main.async { if self.nearGrid != v { self.nearGrid = v } }
    }

    func set(offGrid v: Bool) {
        DispatchQueue.main.async { if self.offGrid != v { self.offGrid = v } }
    }

    /// Where other apps' audio goes while the engine holds the DAC (Bit-perfect check); nil otherwise.
    @Published private(set) var othersRoute: (text: String, ok: Bool)?

    /// Any thread.
    func set(othersRoute text: String?, ok: Bool) {
        DispatchQueue.main.async { if self.othersRoute?.text != text { self.othersRoute = text.map { ($0, ok) } } }
    }

    /// Exclusive Mode's software volume while it scales the output (Bit-perfect check); nil at 0 dB.
    @Published private(set) var softwareVolume: String?

    /// Any thread.
    func set(softwareVolume text: String?) {
        DispatchQueue.main.async { if self.softwareVolume != text { self.softwareVolume = text } }
    }

    /// Any thread.
    func set(dacName name: String?, id: AudioObjectID?) {
        DispatchQueue.main.async {
            if self.dacName != name { self.dacName = name }
            if self.dacID != id { self.dacID = id }
        }
    }

    /// Any thread.
    func set(sourceBits bits: Int?, lossy: Bool) {
        DispatchQueue.main.async {
            if self.sourceBits != bits { self.sourceBits = bits }
            if self.sourceLossy != lossy { self.sourceLossy = lossy }
        }
    }

    /// "24 bit", "lossy" or "? bit".
    var sourceText: String { sourceLossy ? "lossy" : sourceBits.map { "\($0) bit" } ?? "? bit" }
}
