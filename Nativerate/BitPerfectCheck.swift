//
//  BitPerfectCheck.swift
//  Nativerate
//
//  Settings that change what reaches the output device from Music (its own processing, plus
//  alert sounds mixed into the same device), shown in the menu.
//  Music's preferences are read from its defaults domain (no Apple event). The volume needs one
//  Apple event per refresh: at launch, on Refresh, when the output or alert device changes, and on
//  Music player notifications (play, pause, track changes), at most once every 3 s.
//

import AppKit
import Combine
import CoreAudio
import Foundation
import SimplyCoreAudio

final class BitPerfectCheck: ObservableObject {

    struct Item: Identifiable {
        let id: String
        let ok: Bool? // nil: couldn't be read
        let text: String
    }

    @Published private(set) var items = [Item]()

    var issueCount: Int {
        items.filter { $0.ok == false }.count
    }

    private let outputDevice: () -> AudioObjectID?
    private let queue = DispatchQueue(label: "bitPerfectCheckQueue", qos: .utility)
    private var observer: NSObjectProtocol?
    private var deviceObservers = [NSObjectProtocol]()
    private var othersRouteSink: AnyCancellable?
    private var offGridSink: AnyCancellable?
    private var nearGridSink: AnyCancellable?
    private var dacSink: AnyCancellable?
    private var softwareVolumeSink: AnyCancellable?
    private var lastRefresh = Date.distantPast // main thread only

    init(outputDevice: @escaping () -> AudioObjectID?) {
        self.outputDevice = outputDevice
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            // Music posts several of these per play, pause or track change; one refresh is enough.
            guard let self, Date().timeIntervalSince(lastRefresh) > 3 else { return }
            refresh()
        }
        // The alert-sounds item compares two devices; keep it current when either changes.
        // (SimplyCoreAudio posts these; a change of the menu's Selected Device calls refreshAfterDeviceChange.)
        for name in [Notification.Name.defaultOutputDeviceChanged, .defaultSystemOutputDeviceChanged] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshAfterDeviceChange()
            })
        }
        // Exclusive Mode's other-apps route (speakers, muted, or mixed into Music with an old plug-in)
        othersRouteSink = RendererOutput.shared.$othersRoute.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshAfterDeviceChange()
        }
        offGridSink = RendererOutput.shared.$offGrid.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshAfterDeviceChange()
        }
        // the DAC Exclusive Mode holds (the default output is then the virtual device)
        dacSink = RendererOutput.shared.$dacID.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshAfterDeviceChange()
        }
        nearGridSink = RendererOutput.shared.$nearGrid.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshAfterDeviceChange()
        }
        softwareVolumeSink = RendererOutput.shared.$softwareVolume.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshAfterDeviceChange()
        }
        refresh()
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Defers to the next main-queue turn, so observers that update the device (OutputDevices) run first.
    func refreshAfterDeviceChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        lastRefresh = Date()
        let device = outputDevice()
        let others = RendererOutput.shared.othersRoute
        let offGrid = RendererOutput.shared.offGrid
        let nearGrid = RendererOutput.shared.nearGrid
        let softwareVolume = RendererOutput.shared.softwareVolume
        queue.async { [weak self] in
            var items = Self.check(outputDevice: device)
            if let softwareVolume { items.append(Item(id: "softwareVolume", ok: false, text: softwareVolume)) }
            if let others { items.append(Item(id: "otherApps", ok: others.ok, text: others.text)) }
            if offGrid { items.append(Item(id: "offGrid", ok: false, text: "Samples aren't bit-exact before the DAC (they fit no 16- or 24-bit grid): Music volume, Sound Check, EQ or rate conversion")) }
            if nearGrid != 0 { items.append(Item(id: "nearGrid", ok: false, text: "\(nearGrid) bit, but not bit-exact: macOS rounds Music's samples by a fraction of a \(nearGrid)-bit step (seen on macOS 26; inaudible, not a level change)")) }
            print("[BitPerfectCheck] " + items.map { "\($0.ok.map { $0 ? "ok" : "REVIEW" } ?? "?"): \($0.text)" }.joined(separator: " | "))
            DispatchQueue.main.async {
                self?.items = items
            }
        }
    }

    private static let musicDomain = "com.apple.Music" as CFString

    private static func musicPreference(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, musicDomain)
    }

    // Preference keys and values observed on macOS 26.6.2 by toggling each setting in Music.
    private static func check(outputDevice: AudioObjectID?) -> [Item] {
        var items = [Item]()

        if !isMusicRunning {
            items.append(Item(id: "volume", ok: nil, text: "Music volume: Music isn't running"))
        } else if let output = runScript("tell application \"Music\" to return sound volume as string"),
                  let volume = Int(output) {
            items.append(Item(id: "volume", ok: volume == 100,
                              text: volume == 100 ? "Music volume 100%" : "Music volume \(volume)% (scales the samples)"))
        } else {
            // e.g. Automation permission denied (-1743) or Music not responding
            items.append(Item(id: "volume", ok: nil,
                              text: "Music volume couldn't be read (allow control of Music in Privacy & Security › Automation)"))
        }

        // Read fresh values; Music may have changed them since the last read.
        CFPreferencesAppSynchronize(musicDomain)
        // present and 1 when on, absent when off
        let enhancer = (musicPreference("soundEnhancerEnabled") as? Bool) ?? false
        items.append(Item(id: "enhancer", ok: !enhancer, text: enhancer ? "Sound Enhancer on" : "Sound Enhancer off"))
        // 0 when off; absent when on
        let soundCheckOff = (musicPreference("optimizeSongVolume") as? Int) == 0
        items.append(Item(id: "soundCheck", ok: soundCheckOff, text: soundCheckOff ? "Sound Check off" : "Sound Check may be on (changes levels)"))
        // 30 when Off; absent when Automatic
        let atmosOff = (musicPreference("preferredDolbyAtmosPlaySetting") as? Int) == 30
        items.append(Item(id: "atmos", ok: atmosOff, text: atmosOff ? "Dolby Atmos off" : "Dolby Atmos not Off (can play the Atmos mix instead of lossless stereo)"))
        // Neither leaves a trace in Music's preferences, and AppleScript's "EQ enabled" reads false while it's on.
        items.append(Item(id: "manual", ok: nil, text: "Check in Music: Equalizer and Crossfade off"))
        if UserDefaults.standard.bool(forKey: "PreferRendererEngine"), UserDefaults.standard.bool(forKey: Defaults.kOvershootProtection) {
            items.append(Item(id: "overshoot", ok: false, text: "Inter-sample overshoot protection on (output -3.0 dB, not bit-perfect)"))
        }

        if let dac = RendererOutput.shared.dacID ?? outputDevice, isFloatOnly(dac) {
            // Music always sends 32-bit float, so float output needs no conversion.
            items.append(Item(id: "floatOnly", ok: true, text: "DAC takes 32-bit float only: 16- and 24-bit samples pass unchanged"))
        }

        if let outputDevice, let alertDevice = systemOutputDevice() {
            let separate = alertDevice != outputDevice
            items.append(Item(id: "alerts", ok: separate,
                              text: separate ? "Alert sounds play on another device" : "Alert sounds mix into this device"))
        }
        return items
    }

    private static var isMusicRunning: Bool {
        // "tell application" would launch Music if it isn't running
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error {
            print("[BitPerfectCheck] AppleScript - \(error)")
            return nil
        }
        return output
    }

    /// The device offers PCM formats, all of them float (no integer format to play).
    /// Skips the virtual device and aggregates: both list float only, whatever the DAC behind them takes.
    private static func isFloatOnly(_ device: AudioObjectID) -> Bool {
        guard CA.string(device, kAudioDevicePropertyDeviceUID) != VirtualDeviceEngine.deviceUID,
              CA.transport(device) != kAudioDeviceTransportTypeAggregate else { return false }
        let formats = CA.streams(device, kAudioObjectPropertyScopeOutput).flatMap { CA.availablePhysicalFormats($0) }
            .map(\.mFormat).filter { $0.mFormatID == kAudioFormatLinearPCM }
        return !formats.isEmpty && formats.allSatisfy { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 }
    }

    /// The device macOS plays alert and system sounds on ("Play sound effects through").
    private static func systemOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }
}
