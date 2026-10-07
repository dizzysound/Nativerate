//
//  NativerateApp.swift
//  Nativerate
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI

@main
struct NativerateApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State private var controller = MenuBarController.shared
    @ObservedObject private var defaults = Defaults.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller.outputDevices)
                .environmentObject(controller.bitPerfectCheck)
                .environmentObject(defaults)
        } label: {
            if defaults.userPreferIconStatusBarItem {
                // filled speaker while Exclusive Mode is switched on
                Image(systemName: defaults.userPreferRendererEngine ? "hifispeaker.fill" : "hifispeaker")
                    .padding(.horizontal, 8)
                    .accessibilityLabel(defaults.userPreferRendererEngine ? "Nativerate, Exclusive Mode on" : "Nativerate")
            }
            else {
                SampleRateLabel()
                    .environmentObject(controller.outputDevices)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
