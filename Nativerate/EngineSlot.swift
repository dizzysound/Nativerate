//
//  EngineSlot.swift
//  Nativerate
//

import Foundation

/// Who may run the virtual-device engine's single loop. A stop() that times out (the loop can sit in
/// CoreAudio for minutes under a saturated CPU) leaves the old thread alive, so the slot stays taken
/// until that thread's end is seen: a start() meanwhile must not run a second loop beside it.
struct EngineSlot {
    enum Start: Equatable {
        case begin     // the slot was free and is now taken: run a loop
        case running   // a loop is already running: nothing to do
        case deferred  // a loop is still ending after a stop: it starts when that one ends
    }

    private(set) var occupied = false
    private(set) var stopping = false
    private(set) var abandoned = false // stop() gave up waiting; the thread is still alive
    private(set) var startPending = false

    mutating func requestStart() -> Start {
        if !occupied { occupied = true; stopping = false; abandoned = false; return .begin }
        if stopping { startPending = true; return .deferred }
        return .running
    }

    /// True when stop() should wait for the thread. A thread already given up on is not waited for again,
    /// and a stop cancels a deferred start (the listener turned Exclusive Mode off meanwhile).
    mutating func requestStop() -> Bool {
        startPending = false
        guard occupied else { return false }
        stopping = true
        return !abandoned
    }

    mutating func stopTimedOut() { abandoned = true }

    /// The thread's end was seen. True when a start was deferred behind it: start again now.
    mutating func ended() -> Bool {
        let again = startPending
        occupied = false; stopping = false; abandoned = false; startPending = false
        return again
    }
}
