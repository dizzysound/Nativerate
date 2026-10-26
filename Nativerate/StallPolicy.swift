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
    /// Music's Paused notices come in twos and threes and late, so none is read here. Only a Playing is
    /// news (the engine never plays Music during a switch), and what the listener did is read from Music's
    /// state instead: each pause the engine sends is one script that reads the state and pauses in one
    /// step (`pauseSent`), so the state it reports cannot change between the read and the pause. State
    /// "playing": the listener wants it playing and the pause held it. Not playing, after a Playing
    /// notice: the listener paused it again (or it was never played; see the residual windows below).
    ///
    /// Residual windows: a Playing delivered later than the end of the pause command that already covered
    /// it counts as a new play (Music then stays paused); a listener Pause on a Music we already paused
    /// posts nothing and cannot be seen.
    struct ListenerWatch {
        static let repauseInterval: TimeInterval = 1.5 // a failed re-pause is asked again after this
        static let pollInterval: TimeInterval = 1.5 // Music is looked at this often even without a Playing notice
        private var commandEnd = Date.distantPast // a Playing from before this was covered by the last pause command
        private var playPending = false
        private var commanded = false // a pause script has run
        private var callerPaused = false // a caller of the switch paused Music before it started
        private var nextRepause = Date.distantPast
        private var nextPoll = Date.distantPast
        private(set) var listenerPaused = false

        /// `notices`: every Music notice since the last call. True when the engine must run its pause
        /// script now (a Playing arrived, or it is time to look), then report it with `pauseSent`.
        /// `final`: the last look before Music is played again: always asks, so a play whose Playing notice
        /// was missed (the engine waits without looking) is found from the state.
        mutating func observe(notices: [(playing: Bool, at: Date)], now: Date, final: Bool = false) -> Bool {
            for n in notices where n.playing && n.at > commandEnd { playPending = true }
            let due = final || (playPending ? now >= nextRepause : now >= nextPoll)
            if due {
                nextRepause = now.addingTimeInterval(Self.repauseInterval)
                nextPoll = now.addingTimeInterval(Self.pollInterval)
            }
            return due
        }

        /// The result of the pause script: `prior` is Music's state when it ran (nil: the script failed),
        /// `to` when it returned. `byCaller`: a caller of the switch had paused Music already, so a paused
        /// state at the first command is not the listener's.
        mutating func pauseSent(prior: String?, to: Date, byCaller: Bool = false) {
            if byCaller { callerPaused = true } // kept if this script failed: a later first look must not blame the listener
            guard let prior else { return } // no news: a pending Playing stays pending
            commandEnd = to
            if Self.wasPlaying(prior) {
                listenerPaused = false
            } else if playPending || !commanded && !callerPaused {
                listenerPaused = true
            }
            playPending = false
            commanded = true
        }

        /// Music's states while it is not playing; anything else (fast forwarding, rewinding) is playing.
        static func wasPlaying(_ state: String) -> Bool { state != "paused" && state != "stopped" }
    }

    /// The clock lock holds the ring's fill for good, so a ring that filled up while the DAC stalled is cut
    /// back to the target first. Not while a track boundary is pending: the marker is a ring position.
    static func shouldTrimBeforeLock(fill: Int, target: Int, boundaryPending: Bool) -> Bool {
        !boundaryPending && target > 0 && fill > 2 * target
    }
}
