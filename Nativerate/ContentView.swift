//
//  ContentView.swift
//  Nativerate
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI
import OSLog
import SimplyCoreAudio

struct ContentView: View {
    @EnvironmentObject var outputDevices: OutputDevices
    @ObservedObject private var renderer = RendererOutput.shared
    
    var body: some View {
        VStack {
            if outputDevices.currentSampleRate != nil {
                SampleRateLabel()
                    .font(.title2.weight(.semibold))
            }
            // the engine's DAC while it holds one (the default output is then its virtual device)
            if let name = renderer.dacName ?? (outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice)?.name {
                Label(name, systemImage: "hifispeaker")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


