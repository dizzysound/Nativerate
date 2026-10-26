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
    ///
    /// Only a Playing is certainly the listener's. A Paused is ours when it is the echo of a pause the engine
    /// sent that changed Music's state (`ownPause`), and the listener's otherwise. At most one echo is due:
    /// a later pause that took effect means the earlier one did not. An echo cannot arrive before its
    /// command went out, and Music posts its notices in order, so a Playing that arrives after the command
    /// returned finds the echo already delivered; if it is still due, none was posted and it is dropped.
    /// A listener's pause needs a Playing before it, so a dropped or stale echo never swallows one.
    struct ListenerWatch {
        static let repauseInterval: TimeInterval = 1.5 // a re-pause that has not taken effect is asked again after this
        private static let deliverySlack: TimeInterval = 0.25 // a Playing this soon after a command may still have been posted before it ran
        private var played = false
        private var pausedAfter = false
        private var lastPlaying = false // the last notice since the switch began
        private var echo: (from: Date, to: Date)? // the command whose Paused notice is still due
        private var pausedAtStart: Bool // the listener had already paused before the switch began
        private let startedAt: Date
        private var repauseAt = Date.distantPast

        /// `pausedAtStart`: Music was already paused by the listener when the switch began; a later play
        /// replaces that.
        init(startedAt: Date, pausedAtStart: Bool = false) {
            self.startedAt = startedAt
            self.pausedAtStart = pausedAtStart
        }

        /// A pause the engine sent, from `from` to `to`. `tookEffect`: Music was playing and is paused now;
        /// only then is an echo due (a pause of an already paused Music may post none).
        mutating func ownPause(from: Date, to: Date, tookEffect: Bool) {
            if tookEffect { echo = (from, to) }
        }

        /// `notices`: every Music notice since the last call, in order (a play and a pause can arrive together).
        /// True when Music is playing and must be paused again now; report that pause with `ownPause`.
        mutating func observe(notices: [(playing: Bool, at: Date)], now: Date) -> Bool {
            for n in notices {
                // a notice from before the switch is not news (the Playing that brought us here)
                guard n.at > startedAt else { continue }
                defer { lastPlaying = n.playing }
                if n.playing {
                    if let e = echo, n.at > e.to.addingTimeInterval(Self.deliverySlack) { echo = nil }
                    played = true
                    pausedAtStart = false
                    pausedAfter = false
                } else if let e = echo, n.at >= e.from {
                    echo = nil
                } else if played {
                    pausedAfter = true
                }
            }
            guard lastPlaying, now >= repauseAt else { return false }
            repauseAt = now.addingTimeInterval(Self.repauseInterval)
            return true
        }

        var listenerPaused: Bool { pausedAtStart || (played && pausedAfter) }
    }

    /// The clock lock holds the ring's fill for good, so a ring that filled up while the DAC stalled is cut
    /// back to the target first. Not while a track boundary is pending: the marker is a ring position.
    static func shouldTrimBeforeLock(fill: Int, target: Int, boundaryPending: Bool) -> Bool {
        !boundaryPending && target > 0 && fill > 2 * target
    }
}
