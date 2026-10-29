//
//  BitPerfectCheck.swift
//  Nativerate
//
//  Settings that change what reaches the output device from Music (its own processing, plus
//  alert sounds mixed into the same device), shown in the Bit-perfect check window.
//  Nothing runs in the background: the check runs when the window opens and on its Refresh button.
//  Music's preferences are read from its defaults domain (no Apple event); the volume and the
//  track's source need one Apple event each.
//

import AppKit
import Combine
import CoreAudio
import Foundation
import SimplyCoreAudio
import SwiftUI

final class BitPerfectCheck: ObservableObject {

    struct Item: Identifiable {
        let id: String
        let ok: Bool? // nil: couldn't be read
        let text: String
    }

    @Published private(set) var items = [Item]()
    /// True from a refresh until its result arrives; the window hides the previous results meanwhile.
    @Published private(set) var checking = false
    private var generation = 0

    private let outputDevice: () -> AudioObjectID?
    private let queue = DispatchQueue(label: "bitPerfectCheckQueue", qos: .utility)
    private var window: NSWindow?

    init(outputDevice: @escaping () -> AudioObjectID?) {
        self.outputDevice = outputDevice
    }

    func showWindow() {
        refresh()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: BitPerfectCheckView(check: self)))
            w.title = "Bit-perfect check"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        generation += 1
        let thisRun = generation
        checking = true
        let device = outputDevice()
        let others = RendererOutput.shared.othersRoute
        let offGrid = RendererOutput.shared.offGrid
        let nearGrid = RendererOutput.shared.nearGrid
        let softwareVolume = RendererOutput.shared.softwareVolume
        let soundCheck = RendererOutput.shared.soundCheck
        queue.async { [weak self] in
            var items = Self.check(outputDevice: device, soundCheck: soundCheck)
            if let softwareVolume { items.append(Item(id: "softwareVolume", ok: false, text: softwareVolume)) }
            if let others { items.append(Item(id: "otherApps", ok: others.ok, text: others.text)) }
            if offGrid {
                let cause = soundCheck?.changesSamples == true ? "the Music scaling above" : "Music volume, Sound Check, EQ or rate conversion"
                items.append(Item(id: "offGrid", ok: false, text: "Samples aren't bit-exact before the DAC (they fit no 16- or 24-bit grid): \(cause)"))
            }
            if nearGrid != 0 { items.append(Item(id: "nearGrid", ok: false, text: "\(nearGrid) bit, but not bit-exact: macOS rounds Music's samples by a fraction of a \(nearGrid)-bit step (seen on macOS 26; inaudible, not a level change)")) }
            print("[BitPerfectCheck] " + items.map { "\($0.ok.map { $0 ? "ok" : "REVIEW" } ?? "?"): \($0.text)" }.joined(separator: " | "))
            DispatchQueue.main.async {
                guard let self, self.generation == thisRun else { return }
                self.items = items
                self.checking = false
            }
        }
    }

    private static let musicDomain = "com.apple.Music" as CFString

    private static func musicPreference(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, musicDomain)
    }

    // Preference keys and values observed on macOS 26.6.2 by toggling each setting in Music.
    private static func check(outputDevice: AudioObjectID?, soundCheck: SoundCheckLine?) -> [Item] {
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
        if let soundCheck {
            // Music can scale a track by a Sound Check gain while its Sound Check setting is off (pastor Mac,
            // macOS 27.2: setting unchecked, preference false, gSoundCheckEnabled 1, scalar 0.355), so the log
            // line says what the samples got, and the setting says whether the user can do anything about it.
            let scalar = String(format: "%.3f", soundCheck.scalar)
            let settingOn = ((musicPreference("optimizeSongVolume") as? Int) ?? 0) != 0
            let text: String
            if soundCheck.changesSamples {
                text = settingOn ? "Sound Check on: Music scales this track's samples by \(scalar) (changes levels)"
                    : "Music scales this track's samples by \(scalar) (changes levels) although Sound Check is off in Music's settings; Nativerate can't switch this off"
            } else {
                text = soundCheck.on ? "Sound Check on, but it leaves this track's level alone (scalar \(scalar))" : "Sound Check off"
            }
            items.append(Item(id: "soundCheck", ok: !soundCheck.changesSamples, text: text))
        } else {
            // 0 when off; absent when on
            let soundCheckOff = (musicPreference("optimizeSongVolume") as? Int) == 0
            items.append(Item(id: "soundCheck", ok: soundCheckOff, text: soundCheckOff ? "Sound Check off" : "Sound Check may be on (changes levels)"))
        }
        // Only an Apple Music subscription stream has an Atmos mix to play instead of the stereo track.
        if currentTrackIsSubscriptionStream() {
            // 30 when Off; absent when Automatic
            let atmosOff = (musicPreference("preferredDolbyAtmosPlaySetting") as? Int) == 30
            items.append(Item(id: "atmos", ok: atmosOff, text: atmosOff ? "Dolby Atmos off" : "Dolby Atmos not Off (can play the Atmos mix instead of lossless stereo)"))
        }
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

    /// False when Music isn't running, has no current track, or can't be asked.
    private static func currentTrackIsSubscriptionStream() -> Bool {
        guard isMusicRunning else { return false }
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            set t to current track
            set c to ""
            try
                set c to cloud status of t as string
            end try
            set f to "0"
            try
                if class of t is file track and location of t is not missing value then set f to "1"
            end try
            return c & "|" & f
        end tell
        """
        guard let output = runScript(script), !output.isEmpty else { return false }
        let parts = output.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return SourceInference.isSubscriptionStream(cloud: String(parts[0]), localFile: parts[1] == "1")
    }

    private static var isMusicRunning: Bool {
        // "tell application" would launch Music if it isn't running
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private static func runScript(_ source: String) -> String? {
        switch OsascriptRunner.run(source, timeout: 10) {
        case .output(let output):
            return output
        case .failed(let message):
            print("[BitPerfectCheck] AppleScript - \(message)")
        case .timedOut:
            print("[BitPerfectCheck] AppleScript - timed out")
        }
        return nil
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

struct BitPerfectCheckView: View {
    @ObservedObject var check: BitPerfectCheck

    private func symbol(_ ok: Bool?) -> String {
        switch ok {
        case true?: return "checkmark.circle"
        case false?: return "exclamationmark.triangle"
        case nil: return "questionmark.circle"
        }
    }

    private func word(_ ok: Bool?) -> String {
        switch ok {
        case true?: return "OK"
        case false?: return "Warning"
        case nil: return "Check manually"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if check.checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                }
                .accessibilityElement(children: .combine)
            } else {
                ForEach(check.items) { item in
                    Label(item.text, systemImage: symbol(item.ok))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(word(item.ok)): \(item.text)")
                }
            }
            Divider()
            Button {
                check.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(check.checking)
        }
        .padding(16)
        .frame(width: 480, alignment: .leading)
    }
}
