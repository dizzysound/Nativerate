//
//  MenuView.swift
//  Nativerate
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI
import CoreAudio
import SimplyCoreAudio

/// A menu-style MenuBarExtra is a native NSMenu: an Image(systemName: "checkmark") inside a Button's
/// label is not drawn there (on the Babyface bench, macOS 27, no option showed as selected). Toggles
/// get the menu's own check mark, so they carry no SF Symbol; submenus and actions do (Label), the
/// way System Settings' menus use them. Labels are sentence case (HIG); "Exclusive Mode" and "Music"
/// stay capitalised as the feature's and the app's names.
struct MenuView: View {
    
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    @EnvironmentObject private var bitPerfectCheck: BitPerfectCheck
    @ObservedObject private var virtualOutput = VirtualOutputPlugin.shared
    @ObservedObject private var musicSettings = MusicSettingsCheck.shared
    @ObservedObject private var dither = TPDFDither.shared
    @ObservedObject private var logExport = LogExport.shared
    @ObservedObject private var otherApps = OtherAppsOutput.shared
    @ObservedObject private var renderer = RendererOutput.shared
    
    /// Hover text for TPDF dither: what it does and what it means for the DAC in use (the title
    /// used to carry the DAC's depth, which read as the track's).
    private var ditherHelp: String {
        let what = "Adds triangular (±1 LSB) dither when the output has to be rounded to fit an integer DAC, which happens when inter-sample overshoot protection lowers the level or a track is deeper than the DAC. Without it, rounding leaves low-level distortion on quiet passages and fades; with it, a steady, very low noise floor. A track at or below the DAC's depth passes bit-exact either way."
        switch dither.dacBits {
        case nil: return what + "\n\nThe DAC's format isn't known yet."
        case let bits? where bits >= 32: return what + "\n\nNot needed here: this DAC takes 32-bit or float samples, so nothing is rounded."
        case let bits?: return what + "\n\nThis DAC takes \(bits)-bit samples."
        }
    }

    /// Hover text for inter-sample overshoot protection (after Benchmark Media's application note
    /// "Intersample Overs in CD Recordings").
    private let overshootHelp = "Lowers Exclusive Mode's output by 3.0 dB so that peaks between samples can't clip. A DAC rebuilds the waveform between the samples, and on loud masters that waveform can rise above 0 dBFS even when no sample does: up to +3.01 dB in theory, +0.8 to +1.5 dB on commercial CDs, often several times a second. Benchmark Media reports that every DAC and sample-rate-converter chip it tested clips these overs in its digital filter, producing bursts of distortion; its own DACs keep 3.5 dB of headroom above 0 dBFS for this. The cost: the output is 3 dB quieter and no longer bit-perfect."

    /// Hover text for Software Volume.
    private let softwareVolumeHelp = "For a DAC with no volume control of its own (the volume keys do nothing on it), the volume keys scale Exclusive Mode's output in software: 0 to -64 dB, 4 dB per key press. At 0 dB nothing is changed and the output stays bit-perfect; below it the samples are scaled (and dithered when the DAC is an integer one), so it isn't. Off by default. A DAC that has a volume control is unaffected: the keys drive it, and the audio stays at unity. Mute outputs silence on any DAC, with this on or off."

    private func checkSymbol(_ ok: Bool?) -> String {
        switch ok {
        case true?: return "checkmark.circle"
        case false?: return "exclamationmark.triangle"
        case nil: return "questionmark.circle"
        }
    }

    private func checkWord(_ ok: Bool?) -> String {
        switch ok {
        case true?: return "OK"
        case false?: return "Warning"
        case nil: return "Check manually"
        }
    }

    var body: some View {
        Group {
            // Status first: the music-settings warning, the rate and DAC, then whether the path is bit-perfect
            Section {
                if !musicSettings.problems.isEmpty {
                    Label("Music settings: " + musicSettings.problems.map(\.what).joined(separator: "; "), systemImage: "exclamationmark.triangle")
                }
                ContentView()
                bitPerfectMenu
            }

            Section("Output") {
                // Exclusive Mode needs the driver (the virtual output device); until it's installed the
                // toggle is unavailable and the install is offered right here (it turns Exclusive Mode on)
                Toggle("Exclusive Mode", isOn: $defaults.userPreferRendererEngine)
                    .disabled(virtualOutput.state == .notInstalled && !defaults.userPreferRendererEngine)
                if virtualOutput.state == .notInstalled {
                    Button {
                        MenuBarController.shared.changeVirtualDevice(install: true, enableAfter: true)
                    } label: {
                        Label(virtualOutput.busy ? "Installing Exclusive Mode driver…" : "Install Exclusive Mode driver…", systemImage: "arrow.down.circle")
                    }
                    .disabled(virtualOutput.busy)
                }

                outputDeviceMenu

                // Exclusive Mode sends only Music to the DAC; other apps and alert sounds play here
                if defaults.userPreferRendererEngine {
                    otherAppsMenu
                }
            }

            Section {
                settingsMenu
                aboutMenu
            }

            Section {
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit Nativerate")
                }
                .keyboardShortcut("q")
            }
        }
    }

    private var bitPerfectMenu: some View {
        Menu {
            ForEach(bitPerfectCheck.items) { item in
                Label(item.text, systemImage: checkSymbol(item.ok))
                    .accessibilityLabel("\(checkWord(item.ok)): \(item.text)")
            }
            Divider()
            Button {
                bitPerfectCheck.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Label(bitPerfectCheck.issueCount == 0 ? "Bit-perfect check" : "Bit-perfect check (\(bitPerfectCheck.issueCount) to review)",
                  systemImage: bitPerfectCheck.issueCount == 0 ? "checkmark.seal" : "exclamationmark.triangle")
        }
    }

    private var outputDeviceMenu: some View {
        Menu {
            Toggle("Default device", isOn: Binding(get: { outputDevices.selectedOutputDevice == nil }, set: { on in
                if on { outputDevices.selectedOutputDevice = nil; defaults.selectedDeviceUID = nil }
            }))
            Divider()
            ForEach(outputDevices.outputDevices, id: \.uid) { device in
                Toggle(device.name, isOn: Binding(get: { outputDevices.selectedOutputDevice?.uid == device.uid }, set: { on in
                    if on { outputDevices.selectedOutputDevice = device; defaults.selectedDeviceUID = device.uid }
                }))
            }
        } label: {
            Label("Output device", systemImage: "hifispeaker")
        }
    }

    private var otherAppsMenu: some View {
        Menu {
            Toggle("Built-in speakers (automatic)", isOn: Binding(get: { otherApps.choice == nil }, set: { if $0 { otherApps.choice = nil } }))
            ForEach(outputDevices.outputDevices, id: \.uid) { device in
                Toggle(device.name, isOn: Binding(get: { otherApps.choice == device.uid }, set: { if $0 { otherApps.choice = device.uid } }))
            }
            Divider()
            Toggle("Mute other apps", isOn: Binding(get: { otherApps.choice == OtherAppsOutput.mute }, set: { if $0 { otherApps.choice = OtherAppsOutput.mute } }))
            Divider()
            Button {
                otherApps.showWindow()
            } label: {
                Label("Volume…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label("Other apps and alerts", systemImage: "speaker.wave.2")
        }
    }

    // The optional settings. With Exclusive Mode on, Bit depth switching, Detect local files, Pause
    // while switching and Gap after switching do nothing (it always pauses and rewinds at a rate
    // change, for local files and streams, reads local files itself and takes the DAC's deepest
    // format), so they're hidden; they stay for the regular path. Exclusive Mode's own options show
    // only while it's on.
    private var settingsMenu: some View {
        Menu {
            Section("Menu bar") {
                Toggle("Show sample rate", isOn: Binding(get: { !defaults.userPreferIconStatusBarItem }, set: { defaults.userPreferIconStatusBarItem = !$0 }))
            }

            Section("Playback") {
                Toggle("Prefer closest sample rate multiple", isOn: $defaults.userPreferSampleRateMultiples)
                if !defaults.userPreferRendererEngine {
                    Toggle("Bit depth switching", isOn: $defaults.userPreferBitDepthDetection)
                    Toggle("Detect local files", isOn: $defaults.userPreferLocalFileDetection)
                    Toggle("Pause while switching (local files)", isOn: $defaults.userPreferPauseWhileSwitching)
                    Menu {
                        ForEach(SwitchGap.allCases, id: \.self) { gap in
                            Toggle(gap.rawValue, isOn: Binding(get: { defaults.switchGap == gap }, set: { if $0 { defaults.switchGap = gap } }))
                        }
                    } label: {
                        Text("Gap after switching")
                    }
                    .disabled(!defaults.userPreferPauseWhileSwitching)
                }
            }

            if defaults.userPreferRendererEngine {
                Section("Exclusive Mode") {
                    Toggle("Release DAC when Music is idle", isOn: $defaults.rendererReleaseWhenIdle)
                    Toggle("Software volume", isOn: $defaults.softwareVolume)
                        .help(softwareVolumeHelp)
                    Menu {
                        ForEach(SwitchGap.allCases, id: \.self) { m in
                            Toggle("\(m.rawValue) (\(String(format: "%.2f", m.margin)) s)", isOn: Binding(get: { defaults.switchMargin == m }, set: { if $0 { defaults.switchMargin = m } }))
                        }
                    } label: {
                        Text("Switch margin")
                    }
                    .help("How far the DAC plays behind Music, so a skip to a track at another sample rate is cut cleanly between the tracks (Music reports a skip about 0.3 s late). Longer is safer; play, pause and seek respond that much later. Takes effect at the next sample-rate change.")
                    Toggle("Inter-sample overshoot protection", isOn: $defaults.overshootProtection)
                        .help(overshootHelp)
                    // only a 16/24-bit integer DAC is requantized; a 32-bit or float one needs none
                    Toggle("TPDF dither", isOn: $defaults.tpdfDither)
                        .disabled((dither.dacBits ?? 32) >= 32)
                        .help(ditherHelp)
                }
            }

            Section("Advanced") {
                dacInfoMenu
                driverMenu
                scriptMenu
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private var dacInfoMenu: some View {
        Menu {
            let info = DACInfo.lines(for: renderer.dacID ?? (outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice)?.id)
            ForEach(info.indices, id: \.self) { Text(info[$0]) }
        } label: {
            Label("DAC info", systemImage: "waveform")
        }
    }

    private var driverMenu: some View {
        Menu {
            switch virtualOutput.state {
            case .notInstalled:
                Text("Not installed (Exclusive Mode needs it)")
                Button("Install…") { MenuBarController.shared.changeVirtualDevice(install: true) }
            case .installed(let version):
                Text("Installed (\(version))")
                Button("Reinstall…") { MenuBarController.shared.changeVirtualDevice(install: true) }
                Button("Remove…") { MenuBarController.shared.changeVirtualDevice(install: false) }
            case .outdated(let installed, let bundled):
                Text("Installed \(installed), this app has \(bundled)")
                Button("Update…") { MenuBarController.shared.changeVirtualDevice(install: true) }
                Button("Remove…") { MenuBarController.shared.changeVirtualDevice(install: false) }
            }
            if let error = virtualOutput.lastError {
                Label("Last attempt failed: \(error)", systemImage: "exclamationmark.triangle")
            }
        } label: {
            Label(virtualOutput.busy ? "Exclusive Mode driver (working…)" : "Exclusive Mode driver", systemImage: "puzzlepiece.extension")
        }
        .disabled(virtualOutput.busy)
    }

    private var scriptMenu: some View {
        Menu {
            Button("Choose script…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Choose a script to run when the sample rate changes."

                panel.begin { response in
                    guard response == .OK else { return }
                    let path = panel.url?.path
                    DispatchQueue.main.async { [weak defaults] in
                        defaults?.shellScriptPath = path
                    }
                }
            }

            Button("Clear selection") {
                defaults.shellScriptPath = nil
            }
            .disabled(defaults.shellScriptPath == nil)

            Text(defaults.shellScriptPath ?? "No script chosen")
        } label: {
            Label("Run script on rate change", systemImage: "terminal")
        }
    }

    private var aboutMenu: some View {
        Menu {
            Text("Version \(currentVersion) (build \(currentBuild))")
            if !currentCommit.isEmpty { Text("Commit \(currentCommit)") }
            Divider()
            Button {
                LogExport.shared.export()
            } label: {
                Label(logExport.busy ? "Exporting logs…" : "Export logs…", systemImage: "square.and.arrow.up")
            }
            .disabled(logExport.busy)
        } label: {
            Label("About Nativerate", systemImage: "info.circle")
        }
    }
}

/// Settings > Advanced > DAC info: what the selected device offers, read from its output streams' physical
/// formats when the menu is built.
enum DACInfo {
    static func lines(for device: AudioObjectID?) -> [String] {
        guard let d = device else { return ["No device"] }
        var lines = [CA.string(d, kAudioObjectPropertyName)]
        let nominal = CA.nominal(d)
        if nominal > 0 { lines.append("Current: \(khz(nominal))") }

        let formats = CA.streams(d, kAudioObjectPropertyScopeOutput).flatMap { CA.availablePhysicalFormats($0) }
            .filter { $0.mFormat.mFormatID == kAudioFormatLinearPCM }
        guard !formats.isEmpty else { return lines + ["No formats reported"] }

        // one line per bit depth (integer or float), with the rates that depth plays at
        let nominalRates = CA.nominalRates(d)
        var byDepth: [String: Set<Float64>] = [:]
        var order: [String] = []
        for r in formats {
            let f = r.mFormat
            let float = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let key = "\(f.mBitsPerChannel)-bit\(float ? " float" : "")"
            if byDepth[key] == nil { order.append(key) }
            // a ranged format (min < max) covers the device's listed rates inside that range
            let lo = r.mSampleRateRange.mMinimum, hi = r.mSampleRateRange.mMaximum
            let own = f.mSampleRate > 0 ? [f.mSampleRate] : []
            byDepth[key, default: []].formUnion(([lo, hi] + own).filter { $0 > 0 } + nominalRates.filter { $0 >= lo && $0 <= hi })
        }
        order.sort { (bits($0), $0) < (bits($1), $1) }
        lines.append("Bit depths: " + order.joined(separator: ", "))
        for key in order {
            lines.append("\(key): " + byDepth[key]!.sorted().map(khz).joined(separator: ", "))
        }
        if !nominalRates.isEmpty { lines.append("Sample rates: " + Set(nominalRates).sorted().map(khz).joined(separator: ", ")) }
        return lines
    }

    private static func bits(_ key: String) -> Int { Int(key.prefix { $0.isNumber }) ?? 0 }

    private static func khz(_ hz: Float64) -> String {
        let k = hz / 1000
        return (k == k.rounded() ? String(Int(k)) : String(format: "%g", k)) + " kHz"
    }
}
