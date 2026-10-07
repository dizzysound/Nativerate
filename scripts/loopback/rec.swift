// Records all inputs of a CoreAudio device to a 24-bit WAV, without dropped or repeated blocks.
// (sox's coreaudio input repeats 4096-frame blocks and drops others at high rates.)
// Build: swiftc -O rec.swift -o recorder
// Usage: ./recorder "<device name substring>" <rate> <seconds> <out.wav> [<expected output bits>]
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

/// True if any output stream of the device offers a non-mixable integer physical format.
func hasIntegerFormat(_ dev: AudioDeviceID) -> Bool {
    for st in outputStreams(dev) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(st, &addr, 0, nil, &size) == noErr, size > 0 else { continue }
        var fmts = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                  count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(st, &addr, 0, nil, &size, &fmts) == noErr else { continue }
        if fmts.contains(where: { $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0 && $0.mFormat.mBitsPerChannel >= 16 }) { return true }
    }
    return false
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
if a.count >= 4, a[3] == "--wait-rate", let r = Double(a[2]), let d = deviceID(matching: a[1]) {
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
// Nativerate sets the integer format while it plays and puts the old one back afterwards, so the
// output streams are sampled every 0.2 s during the recording, not once at the end.
let lock = NSLock()
var seen: [String] = []        // distinct "stream N: ..." descriptions, in order of first sight
var matched = false
var sampling = true
if a.count == 6, let want = UInt32(a[5]) {
    DispatchQueue.global().async {
        while true {
            lock.lock(); let go = sampling; lock.unlock()
            if !go { break }
            for st in outputStreams(dev) {
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
try engine.start()
let timedOut = done.wait(timeout: .now() + secs + 10) == .timedOut
engine.stop()
lock.lock(); sampling = false; lock.unlock()
if let e = writeError {
    FileHandle.standardError.write("rec: file write failed: \(e)\n".data(using: .utf8)!); exit(2)
}
if timedOut {
    FileHandle.standardError.write("rec: timed out with \(file.length) of \(total) frames (no input data?)\n".data(using: .utf8)!); exit(2)
}
print("rec: \(fmt.channelCount) ch, \(Int(rate)) Hz, \(file.length) frames")
// Exit 3 = the recording is fine but the output format check failed (the compare still runs).
// Exit 4 = the device offers no integer output format at all, so the check cannot apply.
if a.count == 6, let want = UInt32(a[5]) {
    lock.lock(); let list = seen; let ok = matched; lock.unlock()
    for d in list { print("rec: output physical format seen: \(d)") }
    if ok { print("rec: output format OK: \(Int(rate)) Hz \(want)-bit integer seen while recording") }
    else if !hasIntegerFormat(dev) {
        print("rec: SKIP integer format assert: this device offers no integer output format (float-only)")
        exit(4)
    } else {
        print("rec: FAIL output format was never \(Int(rate)) Hz \(want)-bit integer (Integer Mode on and Exclusive Mode on?)")
        exit(3)
    }
}
