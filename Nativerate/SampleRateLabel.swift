//
//  SampleRateLabel.swift
//  Nativerate
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    @ObservedObject private var renderer = RendererOutput.shared

    private var text: String {
        guard let currentSampleRate = outputDevices.currentSampleRate else { return "Unknown" }
        // Exclusive Mode: the rate is the virtual device's, which has no source depth; the engine
        // knows the track's (Bit Depth Switching is hidden there, so it shows either way)
        if renderer.dacName != nil {
            return String(format: "%.1f kHz / ", currentSampleRate) + renderer.sourceText
        } else if outputDevices.enableBitDepthDetection {
            if let bitDepth = outputDevices.currentBitDepth {
                return String(format: "%.1f kHz / %d bit", currentSampleRate, bitDepth)
            } else {
                return String(format: "%.1f kHz / ? bit", currentSampleRate)
            }
        } else {
            return String(format: "%.1f kHz", currentSampleRate)
        }
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .accessibilityLabel("Sample rate: " + text.replacingOccurrences(of: " kHz", with: " kilohertz").replacingOccurrences(of: " / ", with: ", "))
    }
}
