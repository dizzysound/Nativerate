//
//  Defaults.swift
//  Nativerate
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

class Defaults: ObservableObject {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.dizzysound.Nativerate-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.dizzysound.Nativerate-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.dizzysound.Nativerate-Key-BitDepthDetection"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kUserPreferLocalFileDetection = "PreferLocalFileDetection"
    private let kUserPreferPauseWhileSwitching = "PreferPauseWhileSwitching"
    private let kSwitchGap = "SwitchGap"
    private let kUserPreferRendererEngine = "PreferRendererEngine"
    static let kRendererReleaseWhenIdle = "RendererReleaseWhenIdle"
    static let kOvershootProtection = "OvershootProtection"
    static let kTPDFDither = "TPDFDither"
    static let kSoftwareVolume = "SoftwareVolume"
    static let kInteger16 = "RendererInteger16"
    static let kSwitchMargin = "RendererSwitchMargin"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferSampleRateMultiples : false,
            kUserPreferLocalFileDetection : false,
            kUserPreferPauseWhileSwitching : false,
            kUserPreferRendererEngine : false,
            Self.kRendererReleaseWhenIdle : true,
            Self.kOvershootProtection : false,
            Self.kTPDFDither : false,
            Self.kSoftwareVolume : false,
            Self.kInteger16 : false
        ])
        
        self.shellScriptPath = UserDefaults.standard.string(forKey: kShellScriptPath)
        self.userPreferIconStatusBarItem = UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
        self.userPreferSampleRateMultiples = UserDefaults.standard.bool(forKey: kUserPreferSampleRateMultiples)
        self.userPreferLocalFileDetection = UserDefaults.standard.bool(forKey: kUserPreferLocalFileDetection)
        self.userPreferPauseWhileSwitching = UserDefaults.standard.bool(forKey: kUserPreferPauseWhileSwitching)
        self.switchGap = SwitchGap(rawValue: UserDefaults.standard.string(forKey: kSwitchGap) ?? "") ?? .normal
        self.switchMargin = SwitchGap(rawValue: UserDefaults.standard.string(forKey: Self.kSwitchMargin) ?? "") ?? .normal
        self.userPreferRendererEngine = UserDefaults.standard.bool(forKey: kUserPreferRendererEngine)
        self.rendererReleaseWhenIdle = UserDefaults.standard.bool(forKey: Self.kRendererReleaseWhenIdle)
        self.overshootProtection = UserDefaults.standard.bool(forKey: Self.kOvershootProtection)
        self.tpdfDither = UserDefaults.standard.bool(forKey: Self.kTPDFDither)
        self.softwareVolume = UserDefaults.standard.bool(forKey: Self.kSoftwareVolume)
        self.integer16 = UserDefaults.standard.bool(forKey: Self.kInteger16)
        OvershootProtection.shared.set(self.overshootProtection)
        TPDFDither.shared.set(self.tpdfDither)
        SoftwareVolume.shared.set(self.softwareVolume)
    }

    /// Exclusive Mode, Advanced: Inter-sample Overshoot Protection (a fixed -3.0 dB on the output).
    @Published var overshootProtection: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: Self.kOvershootProtection)
            OvershootProtection.shared.set(newValue)
        }
    }

    /// Exclusive Mode, Advanced: TPDF dither when B requantizes to an integer DAC under 32 bits.
    @Published var tpdfDither: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: Self.kTPDFDither)
            TPDFDither.shared.set(newValue)
        }
    }

    /// Exclusive Mode, Advanced: the volume keys scale the output when the DAC has no volume control of its own.
    @Published var softwareVolume: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: Self.kSoftwareVolume)
            SoftwareVolume.shared.set(newValue)
        }
    }

    /// Exclusive Mode, Advanced: a 16-bit track plays in the DAC's 16-bit non-mixable format when it
    /// has one (the engine reads the key at each track's switch decision).
    @Published var integer16: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: Self.kInteger16)
        }
    }

    /// Exclusive Mode: give the DAC and the default output back while Music is idle (engine reads
    /// the UserDefaults key; the delay is RendererIdleSeconds, default 60).
    @Published var rendererReleaseWhenIdle: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: Self.kRendererReleaseWhenIdle)
        }
    }

    /// RendererEngine owns rate switching and plays Music's audio through a process tap.
    @Published var userPreferRendererEngine: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferRendererEngine)
        }
    }

    /// Exclusive Mode: how far the DAC trails Music (SwitchGap.margin), so a late-reported skip is still
    /// cut at the gap between the tracks. The engine reads the key at its next rate change or start.
    @Published var switchMargin: SwitchGap {
        willSet {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.kSwitchMargin)
        }
    }

    @Published var switchGap: SwitchGap {
        willSet {
            UserDefaults.standard.set(newValue.rawValue, forKey: kSwitchGap)
        }
    }
    
    @Published var userPreferPauseWhileSwitching: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferPauseWhileSwitching)
        }
    }
    
    @Published var userPreferLocalFileDetection: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferLocalFileDetection)
        }
    }
    
    @Published var userPreferSampleRateMultiples: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferSampleRateMultiples)
        }
    }
    
    @Published var userPreferIconStatusBarItem: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferIconStatusBarItem)
        }
    }
    
    var selectedDeviceUID: String? {
        get {
            return UserDefaults.standard.string(forKey: kSelectedDeviceUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kSelectedDeviceUID)
        }
    }
    
    @Published var shellScriptPath: String? {
        willSet {
            UserDefaults.standard.setValue(newValue, forKey: kShellScriptPath)
        }
    }
    
    @Published var userPreferBitDepthDetection: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDetection)
        }
    }


    @MainActor func setPreferBitDepthDetection(newValue: Bool) {
        self.userPreferBitDepthDetection = newValue
    }
    
    @MainActor func setShellScriptPath(newValue: String?) {
        self.shellScriptPath = newValue
    }
    
    @MainActor func setPreferSampleRateMultiple(newValue: Bool) {
        self.userPreferSampleRateMultiples = newValue
    }

    var statusBarItemTitle: String {
        let title = self.userPreferIconStatusBarItem ? "Show Sample Rate" : "Show Icon"
        return title
    }
}
