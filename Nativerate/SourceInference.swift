//
//  SourceInference.swift
//  Nativerate
//

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
