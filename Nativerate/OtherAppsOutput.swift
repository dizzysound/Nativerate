//
//  OtherAppsOutput.swift
//  Nativerate
//
//  Exclusive Mode, Music only (plug-in 1.1.4): where every other app's audio and the alert sounds play
//  while the engine holds the DAC for Music, and that device's volume. Menu: "Other apps and alerts";
//  the volume slider lives in a small window (a menu-style MenuBarExtra is a native NSMenu and draws no
//  sliders). The slider drives the device's own volume and mute; a device without a settable volume
//  gets a gain in the engine's other-apps player instead.
//

import AppKit
import CoreAudio
import SwiftUI

final class OtherAppsOutput: ObservableObject {
    static let shared = OtherAppsOutput()
    static let choiceKey = "OtherAppsDeviceUID"
    static let gainKey = "OtherAppsSoftwareGain"
    static let mute = "mute"

    /// nil: the built-in speakers (automatic); `mute`: other apps silent; else a device UID.
    @Published var choice: String? {
        didSet { UserDefaults.standard.set(choice, forKey: Self.choiceKey); refresh() }
    }
    /// The device the engine plays other apps on now (0: none; the engine isn't holding a DAC, or muted).
    @Published private(set) var active = AudioObjectID(0)
    @Published private(set) var devices: [(uid: String, name: String)] = []
    // the slider's device
    @Published private(set) var volume: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var hardwareVolume = false
    @Published private(set) var controlledName = ""

    private let lock = NSLock()
    private var gain: Float = 1 // under lock: the engine's player reads it

    private init() {
        choice = UserDefaults.standard.string(forKey: Self.choiceKey)
        gain = UserDefaults.standard.object(forKey: Self.gainKey) as? Float ?? 1
    }

    /// Engine thread: the player's software gain (1 unless the device has no volume of its own).
    var softwareGain: Float { lock.lock(); defer { lock.unlock() }; return gain }

    /// Where other apps should play, given the DAC: a device, or nil (muted) with the reason.
    static func resolve(dac: AudioObjectID) -> (device: AudioObjectID?, note: String) {
        let c = UserDefaults.standard.string(forKey: choiceKey)
        if c == mute { return (nil, "muted (chosen in Other apps and alerts)") }
        if let c, let d = CA.devices().first(where: { CA.string($0, kAudioDevicePropertyDeviceUID) == c && CA.hasOutput($0) }) {
            if d != dac { return (d, "chosen") }
            if let sp = VirtualDeviceEngine.builtInSpeakers(excluding: dac) { return (sp, "the chosen \(CA.string(d, kAudioObjectPropertyName)) is the DAC; built-in speakers instead") }
            return (nil, "muted (the chosen device is the DAC, and no built-in speakers besides it)")
        }
        if let sp = VirtualDeviceEngine.builtInSpeakers(excluding: dac) { return (sp, c == nil ? "built-in speakers (automatic)" : "the chosen device isn't present; built-in speakers instead") }
        return (nil, "muted (no built-in speakers besides the DAC)")
    }

    /// Any thread: the engine reports where other apps play.
    func setActive(_ d: AudioObjectID) {
        DispatchQueue.main.async { if self.active != d { self.active = d; self.refresh() } }
    }

    /// The device the slider controls: where other apps play now, else what the choice resolves to
    /// with no DAC held.
    private var controlled: AudioObjectID {
        if active != 0 { return active }
        return Self.resolve(dac: 0).device ?? 0
    }

    func refresh() {
        devices = CA.devices().filter { CA.hasOutput($0) && CA.string($0, kAudioDevicePropertyDeviceUID) != VirtualDeviceEngine.deviceUID && !VirtualDeviceEngine.isPrivateAggregate(CA.string($0, kAudioObjectPropertyName)) }
            .map { (CA.string($0, kAudioDevicePropertyDeviceUID), CA.string($0, kAudioObjectPropertyName)) }
        let d = controlled
        controlledName = d == 0 ? "" : CA.string(d, kAudioObjectPropertyName)
        let els = Self.elements(d, kAudioDevicePropertyVolumeScalar)
        hardwareVolume = !els.isEmpty
        if hardwareVolume, let v = Self.get(d, kAudioDevicePropertyVolumeScalar, els[0]) {
            volume = v
        } else {
            volume = softwareGain
        }
        let m = Self.elements(d, kAudioDevicePropertyMute)
        muted = m.first.flatMap { Self.get(d, kAudioDevicePropertyMute, $0) }.map { $0 != 0 } ?? false
    }

    /// The slider: the device's own volume (unmuting it when raised), else the player's gain.
    func setVolume(_ v: Float) {
        let d = controlled
        let els = Self.elements(d, kAudioDevicePropertyVolumeScalar)
        if els.isEmpty {
            lock.lock(); gain = v; lock.unlock()
            UserDefaults.standard.set(v, forKey: Self.gainKey)
        } else {
            lock.lock(); gain = 1; lock.unlock() // the device's own volume does it
            UserDefaults.standard.removeObject(forKey: Self.gainKey)
            for e in els { _ = Self.set(d, kAudioDevicePropertyVolumeScalar, e, v) }
            if v > 0, muted { setMuted(false) }
        }
        volume = v
    }

    func setMuted(_ on: Bool) {
        let d = controlled
        for e in Self.elements(d, kAudioDevicePropertyMute) { _ = Self.set(d, kAudioDevicePropertyMute, e, on ? 1 : 0) }
        refresh()
    }

    // MARK: device controls (output scope: the main element, else channels 1 and 2)

    private static func elements(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [UInt32] {
        guard d != 0 else { return [] }
        func settable(_ e: UInt32) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
            var s: DarwinBoolean = false
            return AudioObjectHasProperty(d, &a) && AudioObjectIsPropertySettable(d, &a, &s) == noErr && s.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    private static func get(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32) -> Float? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        if sel == kAudioDevicePropertyMute {
            var v = UInt32(0); var z = UInt32(4)
            return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr ? Float(v) : nil
        }
        var v = Float32(0); var z = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &z, &v) == noErr ? v : nil
    }

    private static func set(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector, _ e: UInt32, _ v: Float) -> OSStatus {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: e)
        if sel == kAudioDevicePropertyMute {
            var u = UInt32(v); return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &u)
        }
        var f = Float32(v); return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &f)
    }

    // MARK: window

    private var window: NSWindow?

    func showWindow() {
        refresh()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Other apps and alerts"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OtherAppsView(output: self))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OtherAppsView: View {
    @ObservedObject var output: OtherAppsOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("While Exclusive Mode holds the DAC, only Music plays there. Other apps and alert sounds play here:")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Device", selection: Binding(get: { output.choice ?? "" }, set: { output.choice = $0.isEmpty ? nil : $0 })) {
                Text("Built-in Speakers (automatic)").tag("")
                ForEach(output.devices, id: \.uid) { d in Text(d.name).tag(d.uid) }
                Divider()
                Text("Mute other apps").tag(OtherAppsOutput.mute)
            }
            if output.choice != OtherAppsOutput.mute, !output.controlledName.isEmpty {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: Binding(get: { Double(output.volume) }, set: { output.setVolume(Float($0)) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                }
                Toggle("Mute \(output.controlledName)", isOn: Binding(get: { output.muted }, set: { output.setMuted($0) }))
                    .disabled(!output.hardwareVolume)
                Text(output.hardwareVolume ? "\(output.controlledName)'s own volume." : "\(output.controlledName) has no volume control; this sets the other apps' level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { output.refresh() }
    }
}
