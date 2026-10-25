//
//  StallPolicy.swift
//  Nativerate
//

import Foundation

/// What Exclusive Mode does when the DAC stalls instead of settling after a rate switch (a Neumann MT 48
/// went into a restart loop for 45-55 s after 44.1 -> 88.2/96 kHz switches: the DAC ran at ~36% of real
/// time, the ring filled and dropped 18 s of audio, and the clock lock then held the full ring for good).
enum StallPolicy {
    /// Music stays paused this much longer after the first wait times out, before playing into the DAC anyway.
    static let dacSettleExtraWait: TimeInterval = 90

    /// Waits `first` seconds for the DAC; if it isn't ready, says so and waits `extra` more with Music still paused.
    /// Turning Exclusive Mode off (`cancelled`) ends the wait at once and skips the extra one.
    static func settle(first: TimeInterval, extra: TimeInterval = dacSettleExtraWait, cancelled: () -> Bool = { false }, attempt: (TimeInterval) -> Bool, stillWaiting: () -> Void) -> Bool {
        if attempt(first) { return true }
        if cancelled() { return false }
        stillWaiting()
        return attempt(extra)
    }

    /// Music's state while a switch holds it paused: the wait is up to 102 s now, so the listener can press
    /// play and pause meanwhile. A play is paused again (it would play into the stalled DAC and move the
    /// position the rewind is measured from); a pause after a play means the listener wants it paused.
    /// Each pause of ours (the switch's own, and every re-pause) is expected to echo back as one Paused
    /// notice within the echo window; a Paused notice beyond those is the listener's, however soon it comes.
    struct ListenerWatch {
        static let echoWindow: TimeInterval = 1.5 // our own pause echoes back as a Paused notice this late
        private var played = false
        private var pausedAfter = false
        private var echoes = 1 // the switch's own pause, issued just before the wait
        private let startedAt: Date
        private var echoUntil: Date
        private var repauseAt = Date.distantPast
        private var seenNotice = Date.distantPast

        init(startedAt: Date) {
            self.startedAt = startedAt
            echoUntil = startedAt.addingTimeInterval(Self.echoWindow)
        }

        /// True when Music must be paused again now.
        mutating func observe(playing: Bool, lastNoticeAt: Date, now: Date) -> Bool {
            if now > echoUntil { echoes = 0 }
            // a notice from before the switch is not news (the Playing that brought us here)
            guard lastNoticeAt > startedAt else { return false }
            if lastNoticeAt != seenNotice {
                seenNotice = lastNoticeAt
                if playing {
                    played = true
                    pausedAfter = false
                } else if echoes > 0 {
                    echoes -= 1
                } else if played {
                    pausedAfter = true
                }
            }
            guard playing, now >= repauseAt else { return false }
            echoes += 1
            echoUntil = now.addingTimeInterval(Self.echoWindow)
            repauseAt = echoUntil
            return true
        }

        var listenerPaused: Bool { played && pausedAfter }
    }

    /// The clock lock holds the ring's fill for good, so a ring that filled up while the DAC stalled is cut
    /// back to the target first. Not while a track boundary is pending: the marker is a ring position.
    static func shouldTrimBeforeLock(fill: Int, target: Int, boundaryPending: Bool) -> Bool {
        !boundaryPending && target > 0 && fill > 2 * target
    }
}
