// Records all inputs of a CoreAudio device to a 24-bit WAV, without dropped or repeated blocks.
// (sox's coreaudio input repeats 4096-frame blocks and drops others at high rates.)
// Build: swiftc -O rec.swift -o recorder
// Usage: ./recorder "<device name substring>" <rate> <seconds> <out.wav> [<expected output bits>]
// With the last argument it also reads the device's OUTPUT physical stream format at the end of the
// recording (while Nativerate has just finished playing), prints it, and exits 3 if it is not
// <rate> Hz and <bits>-bit. Exit 2 = setup error.
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

func outputPhysicalFormat(_ dev: AudioDeviceID) -> AudioStreamBasicDescription? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                          mScope: kAudioObjectPropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr,
          let first = streams.first else { return nil }
    var asbd = AudioStreamBasicDescription()
    var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    addr.mSelector = kAudioStreamPropertyPhysicalFormat
    addr.mScope = kAudioObjectPropertyScopeGlobal
    return AudioObjectGetPropertyData(first, &addr, 0, nil, &s, &asbd) == noErr ? asbd : nil
}

let a = CommandLine.arguments
guard a.count == 5 || a.count == 6, let rate = Double(a[2]), let secs = Double(a[3]) else {
    FileHandle.standardError.write("usage: rec <device> <rate> <seconds> <out.wav> [expected output bits]\n".data(using: .utf8)!); exit(2)
}
guard var dev = deviceID(matching: a[1]) else {
    FileHandle.standardError.write("rec: input device not found: \(a[1])\n".data(using: .utf8)!); exit(2)
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
input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
    if file.length >= total { return }
    try? file.write(from: buf)
    if file.length >= total { done.signal() }
}
try engine.start()
done.wait()
engine.stop()
print("rec: \(fmt.channelCount) ch, \(Int(rate)) Hz, \(file.length) frames")
if a.count == 6, let want = UInt32(a[5]) {
    guard let out = outputPhysicalFormat(dev) else {
        FileHandle.standardError.write("rec: cannot read the output physical format\n".data(using: .utf8)!); exit(2)
    }
    print("rec: output physical format \(Int(out.mSampleRate)) Hz, \(out.mBitsPerChannel)-bit, "
          + "\(out.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer"), \(out.mChannelsPerFrame) ch")
    if Int(out.mSampleRate) != Int(rate) || out.mBitsPerChannel != want || out.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
        print("rec: FAIL output format is not \(Int(rate)) Hz \(want)-bit integer")
        exit(3)
    }
}
