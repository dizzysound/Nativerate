//
//  SourceInference.swift
//  Nativerate
//

import Foundation

enum SourceInference {
    /// A track whose samples fit neither the 16- nor the 24-bit grid, and whose source no decoder line of its
    /// own told: lossy only on a positive sign. The decoder Music reused for it (the newest line) was lossy
    /// (coffee: "Get Behind the Mule" on Another Day's AAC decoder), or the track started on a lossy decoder.
    /// No line at all (the first track after launch: Music set its decoder up before Nativerate listened) says
    /// nothing, and guessing lossy there labeled lossless ALAC lossy (coffee, 2026-10-24, 24-bit "Hip").
    ///
    /// A stream that started lossy and then got its lossless decoder (`upgradedToLossless`) is a different
    /// case: the lossless decoder plays, and off the grids can be Music's volume or Sound Check (pastor Mac,
    /// 2026-10-29: "Love In The Past Tense", 24 bit at 96k, AAC at the start, labeled lossy; its plain 24-bit
    /// tracks are off both grids too). The start then counts only when nothing readable in Music changes samples.
    static func offGridIsLossy(trackStartedLossy: Bool, upgradedToLossless: Bool = false, sourceKnown: Bool, newestDecoderLossy: Bool, musicLeavesSamplesAlone: () -> Bool) -> Bool {
        if trackStartedLossy { return !upgradedToLossless || musicLeavesSamplesAlone() }
        return !sourceKnown && newestDecoderLossy && musicLeavesSamplesAlone()
    }
}

/// Music's "Sound Check on, flags 0x0, err 0, scalar 0.434" line (com.apple.coreaudio, MEMixerChannel): the gain
/// Music applies to a track's samples. On macOS 27 the switch is not in Music's preferences (pastor Mac,
/// 2026-10-29: `optimizeSongVolume` false while the log says on, scalars 0.434 to 0.866), so the log is the
/// only place to read it.
struct SoundCheckLine: Equatable {
    let on: Bool
    let scalar: Double

    /// Music logs the scalar with three decimals; 1.000 leaves the samples alone.
    var changesSamples: Bool { abs(scalar - 1) > 0.0005 }

    static func parse(_ line: String) -> SoundCheckLine? {
        let on: Bool
        if line.contains("Sound Check on,") { on = true } else if line.contains("Sound Check off,") { on = false } else { return nil }
        guard let r = line.range(of: "scalar ") else { return nil }
        let digits = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        guard let scalar = Double(digits) else { return nil }
        return SoundCheckLine(on: on, scalar: scalar)
    }
}

/// The Sound Check lines Music logged since the engine started. Music sets the next track's mixer up while the
/// current one plays, so the newest line may belong to the next track: the samples count as changed when the
/// newest line or any line in the last `window` seconds says so (the safe side: it keeps a lossless track from
/// being labeled lossy for samples Music scaled).
struct SoundCheckHistory {
    private var entries: [(at: Date, line: SoundCheckLine)] = []

    var latest: SoundCheckLine? { entries.last?.line }

    mutating func record(_ line: SoundCheckLine, at: Date) {
        entries.append((at, line))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    mutating func clear() { entries = [] }

    /// nil: no line seen, so nothing is known.
    func changesSamples(now: Date, window: TimeInterval = 60) -> Bool? {
        guard let last = entries.last else { return nil }
        return last.line.changesSamples || entries.contains { now.timeIntervalSince($0.at) <= window && $0.line.changesSamples }
    }
}
