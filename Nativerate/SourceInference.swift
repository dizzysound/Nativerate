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
    static func offGridIsLossy(trackStartedLossy: Bool, sourceKnown: Bool, newestDecoderLossy: Bool, musicLeavesSamplesAlone: () -> Bool) -> Bool {
        trackStartedLossy || (!sourceKnown && newestDecoderLossy && musicLeavesSamplesAlone())
    }
}
