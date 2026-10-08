// Records all inputs of a CoreAudio device to a 24-bit WAV, without dropped or repeated blocks.
// (sox's coreaudio input repeats 4096-frame blocks and drops others at high rates.)
// Build: swiftc -O rec.swift -o recorder
// Usage: ./recorder "<device name substring>" <rate> <seconds> <out.wav> [<expected output bits>]
//        ./recorder --format-only "<output device>" <rate> <seconds> <bits>   (no recording)
// Environment OUT_DEV: output device to check when it differs from the input device (second DAC).
// With the last argument it also reads the device's OUTPUT physical stream format at the end of the
// recording (every 0.2 s, all output streams) and prints what it saw. Exit 0 if some stream was
// <rate> Hz and <bits>-bit integer at some point, 3 if never, 4 if the device offers no integer
// output format at all. Exit 2 = setup error, timeout or write error.
// It waits (up to 30 s) for the device to run at <rate> before it starts, because Nativerate
// switches the DAC rate when playback starts. Use "./recorder <device> <rate> --wait-rate [timeout s]"
// to only wait for the rate and exit 0 (used to prime the rate before a case).
import AVFoundation
import CoreAudio

func deviceID(matching name: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var n: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &s, &n) == noErr,
              let str = n?.takeRetainedValue() as String? else { continue }
        if str.contains(name) { return id }
    }
    return nil
}

func outputStreams(_ dev: AudioDeviceID) -> [AudioStreamID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioObjectPropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr else { return [] }
    return streams
}

func physicalFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    return AudioObjectGetPropertyData(stream, &addr, 0, nil, &s, &asbd) == noErr ? asbd : nil
}

/// Whether any output stream of the device offers an integer (non-float) physical format of 16 bits
/// or more. nil if the formats could not be read (no output streams or a property error), so a wrong
/// device or a read failure is never reported as "float-only".
func hasIntegerFormat(_ dev: AudioDeviceID) -> Bool? {
    let streams = outputStreams(dev)
    if streams.isEmpty { return nil }
    var found = false
    for st in streams {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(st, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var fmts = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                  count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(st, &addr, 0, nil, &size, &fmts) == noErr else { return nil }
        if fmts.contains(where: { $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0 && $0.mFormat.mBitsPerChannel >= 16 }) { found = true }
    }
    return found
}

func describe(_ f: AudioStreamBasicDescription, stream: AudioStreamID) -> String {
    "stream \(stream): \(Int(f.mSampleRate)) Hz, \(f.mBitsPerChannel)-bit, "
        + "\(f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer"), \(f.mChannelsPerFrame) ch"
}

func nominalRate(_ dev: AudioDeviceID) -> Double {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var r = Float64(0)
    var s = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &s, &r) == noErr ? r : 0
}

func waitForRate(_ dev: AudioDeviceID, _ rate: Double, timeout: Double) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if nominalRate(dev) == rate { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return nominalRate(dev) == rate
}

let a = CommandLine.arguments
// OUT_DEV (environment) names the output device whose rate and physical format are checked when it
// is not the input device, for example a second DAC fed by a digital cable into the Babyface.
func outputDevice(_ inputName: String) -> AudioDeviceID? {
    if let n = ProcessInfo.processInfo.environment["OUT_DEV"], !n.isEmpty { return deviceID(matching: n) }
    return deviceID(matching: inputName)
}

let lock = NSLock()
var seen: [String] = []        // distinct "stream N: ..." descriptions, in order of first sight
var matched = false
var sampling = true

// Nativerate sets the integer format while it plays and puts the old one back afterwards, so the
// output streams are sampled every 0.2 s while the test runs, not once at the end.
func startSampling(_ outDev: AudioDeviceID, rate: Double, want: UInt32) {
    DispatchQueue.global().async {
        while true {
            lock.lock(); let go = sampling; lock.unlock()
            if !go { break }
            for st in outputStreams(outDev) {
                guard let f = physicalFormat(st) else { continue }
                let d = describe(f, stream: st)
                lock.lock()
                if !seen.contains(d) { seen.append(d) }
                if Int(f.mSampleRate) == Int(rate) && f.mBitsPerChannel == want && f.mFormatFlags & kAudioFormatFlagIsFloat == 0 { matched = true }
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}

/// Prints what was seen and exits 0 (matched), 3 (never), 4 (no integer format offered), 2 (could not read).
func finishFormatCheck(_ outDev: AudioDeviceID, rate: Double, want: UInt32) -> Never {
    lock.lock(); sampling = false; let list = seen; let ok = matched; lock.unlock()
    for d in list { print("rec: output physical format seen: \(d)") }
    if ok { print("rec: output format OK: \(Int(rate)) Hz \(want)-bit integer seen"); exit(0) }
    switch hasIntegerFormat(outDev) {
    case nil:
        FileHandle.standardError.write("rec: cannot read the output formats (no output streams on the device?). Check DEV / OUT_DEV.\n".data(using: .utf8)!); exit(2)
    case false?:
        print("rec: SKIP integer format assert: this device offers no integer output format (float-only)"); exit(4)
    case true?:
        print("rec: FAIL output format was never \(Int(rate)) Hz \(want)-bit integer (Integer Mode on and Exclusive Mode on?)"); exit(3)
    }
}

// --format-only <output device> <rate> <seconds> <bits>: no recording; samples the output format
// while something plays (analog-only second DAC, no cable).
if a.count == 6, a[1] == "--format-only", let r = Double(a[3]), let fsecs = Double(a[4]), let fwant = UInt32(a[5]) {
    guard let od = deviceID(matching: a[2]) else {
        FileHandle.standardError.write("rec: output device not found: \(a[2])\n".data(using: .utf8)!); exit(2)
    }
    startSampling(od, rate: r, want: fwant)
    Thread.sleep(forTimeInterval: fsecs)
    finishFormatCheck(od, rate: r, want: fwant)
}
if a.count >= 4, a[3] == "--wait-rate", let r = Double(a[2]), let d = outputDevice(a[1]) {
    let t = a.count > 4 ? Double(a[4]) ?? 30 : 30
    if waitForRate(d, r, timeout: t) { exit(0) }
    FileHandle.standardError.write("rec: device did not reach \(Int(r)) Hz within \(Int(t)) s\n".data(using: .utf8)!); exit(2)
}
guard a.count == 5 || a.count == 6, let rate = Double(a[2]), let secs = Double(a[3]) else {
    FileHandle.standardError.write("usage: rec <device> <rate> <seconds> <out.wav> [expected output bits]\n".data(using: .utf8)!); exit(2)
}
guard var dev = deviceID(matching: a[1]) else {
    FileHandle.standardError.write("rec: input device not found: \(a[1])\n".data(using: .utf8)!); exit(2)
}
if !waitForRate(dev, rate, timeout: 30) {
    FileHandle.standardError.write("rec: device did not reach \(Int(rate)) Hz within 30 s\n".data(using: .utf8)!); exit(2)
}
let engine = AVAudioEngine()
let input = engine.inputNode
guard let unit = input.audioUnit, AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
    FileHandle.standardError.write("rec: cannot select device\n".data(using: .utf8)!); exit(2)
}
let fmt = input.inputFormat(forBus: 0)
if fmt.sampleRate != rate {
    FileHandle.standardError.write("rec: device runs at \(Int(fmt.sampleRate)) Hz, not \(Int(rate)) Hz\n".data(using: .utf8)!); exit(2)
}
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                               AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 24,
                               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: a[4]), settings: settings,
                           commonFormat: .pcmFormatFloat32, interleaved: false)
let total = AVAudioFramePosition(secs * rate)
let done = DispatchSemaphore(value: 0)
var writeError: Error?
input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
    if file.length >= total || writeError != nil { return }
    do { try file.write(from: buf) } catch { writeError = error; done.signal(); return }
    if file.length >= total { done.signal() }
}
guard let outDev = outputDevice(a[1]) else {
    FileHandle.standardError.write("rec: output device not found (OUT_DEV)\n".data(using: .utf8)!); exit(2)
}
if a.count == 6, let want = UInt32(a[5]) { startSampling(outDev, rate: rate, want: want) }
try engine.start()
let timedOut = done.wait(timeout: .now() + secs + 10) == .timedOut
engine.stop()
input.removeTap(onBus: 0)
// exit() skips deinit, so close the file here or its WAV header keeps a data size of 0.
if #available(macOS 15.0, *) { file.close() }
if let e = writeError {
    FileHandle.standardError.write("rec: file write failed: \(e)\n".data(using: .utf8)!); exit(2)
}
if timedOut {
    FileHandle.standardError.write("rec: timed out with \(file.length) of \(total) frames (no input data?)\n".data(using: .utf8)!); exit(2)
}
print("rec: \(fmt.channelCount) ch, \(Int(rate)) Hz, \(file.length) frames")
// Exit 3 = the recording is fine but the output format check failed (the compare still runs).
// Exit 4 = the device offers no integer output format at all, so the check cannot apply.
if a.count == 6, let want = UInt32(a[5]) { finishFormatCheck(outDev, rate: rate, want: want) }
