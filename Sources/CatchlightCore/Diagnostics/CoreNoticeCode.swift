//
//  CoreNoticeCode.swift
//  CatchlightCore
//
//  Reference codes for the diagnostics lines Catchlight-Core writes itself. They share
//  one numbering with the apps' own notices: an app owns 100–949, Core owns 950–999, and
//  a number means the same line on every platform. The app supplies the platform part
//  (`CCIOS`, `CCMOS`) through `DiagnosticsLog.platformCode`, so a line reads
//  `[CCIOS-952] Launch — …`. With no platform code set, lines are written uncoded.
//
//  A number is never reused or renumbered once released. Each case carries its English
//  summary as a trailing comment on one line; the apps' support-table generator reads it.
//

import Foundation

public enum CoreNoticeCode: Int, CaseIterable, Sendable {
    case previousRunEndedUnexpectedly = 951 // Previous run ended without a clean shutdown, with build, OS and device.
    case launch = 952                       // App launched, with build, OS and device.
    case cleanExit = 953                    // Backgrounded (clean exit).
    case syncPullFailed = 954               // Sync pull failed, with the system error.
    case syncPullOK = 955                   // Sync pull completed.
    case syncRepairedCloudCopy = 956        // Sync re-uploaded a cloud copy that failed verification.
    case syncPushOK = 957                   // Sync push completed.
    case syncPushDeferred = 958             // Sync push deferred: another device holds the lock.
    case syncPushFailed = 959               // Sync push failed, with the system error.
}
