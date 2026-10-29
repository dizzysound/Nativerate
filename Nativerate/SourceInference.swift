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

    /// Whether the current track is an Apple Music subscription stream, the only kind the Dolby Atmos setting
    /// can change. Music marks one with cloud status "subscription" (also when it is downloaded). A track with
    /// no file on disk and no cloud status at all is a stream whose library info Music leaves empty (pastor,
    /// 2026-10-18). Local files and matched, uploaded or purchased tracks are not.
    static func isSubscriptionStream(cloud: String, localFile: Bool) -> Bool {
        switch cloud.lowercased() {
        case "subscription": return true
        case "", "missing value": return !localFile
        default: return false
        }
    }
}

/// Music's "Sound Check on, flags 0x0, err 0, scalar 0.434" line (com.apple.coreaudio, MEMixerChannel): the gain
/// Music applies to a track's samples. The log shows what Music actually applied, which can differ from
/// `optimizeSongVolume` until Music restarts after the preference changes.
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

/// The Sound Check lines Music logged since the engine started, tied to the playing track. Music sets the next
/// track's mixer up while the current one plays, so the newest line may belong to the next track. A track's
/// lines are the newest one logged before it started and after the previous track's setup window (its setup,
/// pre-rolled or not; an older line is the previous track's, which a track with no line of its own must not
/// inherit) and any within `grace` seconds after it started (a setup that came after Playing); later lines are
/// the next track's. A scaled line inside the previous track's grace is ambiguous (its late setup, or this
/// track's pre-roll after a fast skip): it counts for this track only when the previous track already had a line
/// before it started (found the same way counts), so the previous track's late setup was not its only line. Scaled wins among a track's
/// lines (it keeps a lossless track from being labeled lossy for samples Music scaled). Without a track start,
/// or a line for the track, nothing is known.
struct SoundCheckHistory {
    private var entries: [(at: Date, line: SoundCheckLine)] = []
    private var trackStart: Date?
    private var previousTrackStart: Date?
    private var previousHadLineBeforeStart = false
    private var trackHadLineBeforeStart = false

    mutating func record(_ line: SoundCheckLine, at: Date) {
        entries.append((at, line))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    mutating func trackStarted(at: Date, grace: TimeInterval = 5) {
        previousTrackStart = trackStart
        previousHadLineBeforeStart = trackHadLineBeforeStart
        trackStart = at
        trackHadLineBeforeStart = preStartLine(at, grace: grace) != nil
    }

    mutating func clear() {
        entries = []; trackStart = nil; previousTrackStart = nil
        previousHadLineBeforeStart = false; trackHadLineBeforeStart = false
    }

    private func lineBeforeStart(_ start: Date, after previous: Date?, grace: TimeInterval) -> SoundCheckLine? {
        let floor = previous.map { $0.addingTimeInterval(grace) }
        return entries.last(where: { $0.at <= start && (floor == nil || $0.at > floor!) })?.line
    }

    /// The line logged before `start` that is the track's own, including a scaled one the previous track's grace
    /// window makes ambiguous. A track found that way still counts as having had a line before its start, so a
    /// run of fast skips keeps the scaled signal.
    private func preStartLine(_ start: Date, grace: TimeInterval) -> SoundCheckLine? {
        if let before = lineBeforeStart(start, after: previousTrackStart, grace: grace) { return before }
        guard let prev = previousTrackStart, previousHadLineBeforeStart else { return nil }
        return entries.last(where: { $0.at > prev && $0.at <= start && $0.line.changesSamples })?.line
    }

    /// The line that stands for the playing track; nil when none is known.
    func forTrack(grace: TimeInterval = 5) -> SoundCheckLine? {
        guard let start = trackStart else { return nil }
        var lines: [SoundCheckLine] = []
        if let before = preStartLine(start, grace: grace) { lines.append(before) }
        lines += entries.filter { $0.at > start && $0.at.timeIntervalSince(start) <= grace }.map { $0.line }
        return lines.first { $0.changesSamples } ?? lines.last
    }

    /// nil: no line for the playing track, so nothing is known.
    func changesSamples(grace: TimeInterval = 5) -> Bool? { forTrack(grace: grace)?.changesSamples }
}
