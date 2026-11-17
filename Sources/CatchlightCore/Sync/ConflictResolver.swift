//
//  ConflictResolver.swift
//  CatchlightCore
//
//  Conflict DETECTION for the sync engine (Phase 5 brief §7.6). Resolution UI is
//  Phase 6 — this layer only decides what happened and never silently discards a
//  user's edit.
//
//  Catchlight v1.0 has no vector clocks. What counts as "changed" is decided by the
//  caller: the sync engine compares each side with the version this device last agreed
//  with (its per-Take `SyncRecord`, 2026-11-17); `decide(local:remote:lastSync:)` keeps
//  the older comparison of edit times with the last-sync time. The rule, given a local
//  and a remote version of the same Take:
//
//    • only the remote changed since last sync   → take remote
//    • only the local changed since last sync    → keep local (it will be pushed)
//    • BOTH changed and they differ              → CONFLICT (surface both to user)
//    • neither changed / identical               → no change
//
//  Because both versions decrypt with the same per-item key (same UUID → same HKDF
//  derivation) and every encryption uses a fresh random nonce, there is never a
//  nonce-collision risk when both versions are present (Encryption Architecture §11.2).
//

import Foundation

public enum SyncDecision: Equatable, Sendable {
    case noChange
    case takeRemote(Take)
    case keepLocal(Take)
    case conflict(local: Take, remote: Take)
}

public enum ConflictResolver {
    public static func decide(local: Take?, remote: Take, lastSync: Date?) -> SyncDecision {
        let watermark = lastSync ?? .distantPast
        return decide(local: local, remote: remote,
                      localChanged: (local?.modifiedAt ?? .distantPast) > watermark,
                      remoteChanged: remote.modifiedAt > watermark)
    }

    /// The same rule, given what changed on each side since this device last agreed with the
    /// folder. The sync engine works this out from the device's `SyncRecord` (2026-11-15);
    /// comparing edit times with the last-sync time lost an edit made offline and uploaded
    /// after the other device's last sync.
    public static func decide(local: Take?, remote: Take,
                              localChanged: Bool, remoteChanged: Bool) -> SyncDecision {
        guard let local else {
            // Not present locally → a new Take created on another device.
            return .takeRemote(remote)
        }
        if local == remote { return .noChange }

        switch (localChanged, remoteChanged) {
        case (false, true):  return .takeRemote(remote)
        case (true, false):  return .keepLocal(local)
        case (true, true):   return .conflict(local: local, remote: remote)
        case (false, false):
            // Neither side recorded a change since last sync yet they differ —
            // the bookkeeping is confused (clock skew, watermark drift). The
            // previous fall-back silently overwrote by most-recent-write, which
            // violated this file's "never silently discards a user's edit"
            // contract. Surface it as a conflict instead (2026-06-10); the
            // existing resolution UI handles it at zero extra cost.
            return .conflict(local: local, remote: remote)
        }
    }
}
