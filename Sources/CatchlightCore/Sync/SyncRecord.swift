//
//  SyncRecord.swift
//  CatchlightCore
//
//  What one device keeps about one Take's sync, for itself (2026-11-17). Never uploaded, never
//  part of a Take or of the folder's files: each device's store keeps its own.
//
//  WHY. The engine used to judge "changed since the last sync" by comparing a version's edit
//  time with this device's last-sync time. An edit made offline earlier but uploaded later
//  carries an edit time older than the other device's last sync, so it looked unchanged and was
//  written over with no conflict shown (SyncPushBetweenHalvesTests, and the TLA+ model in
//  spec/). The record names instead the folder version this device last agreed with, so a
//  change on either side is a difference from that version, whenever it was made.
//
//  A version is named by its edit stamp: the manifest entry's `modified`, which is the Take's
//  `modifiedAt` as ISO-8601 with milliseconds. Not by the entry's HMAC: re-uploading the same
//  version (a first sync, a repair) seals it with a fresh nonce, so its HMAC changes while it
//  stays the same version.
//

import Foundation

public struct SyncRecord: Codable, Equatable, Sendable {
    /// The folder version this device last agreed with: applied here, found identical here, or
    /// its own upload once seen in a pulled manifest. Nil until then (an install from before
    /// records, or a Take not yet synced): the engine then takes the safe side.
    public var agreed: String?
    /// This device's own upload, not yet seen in a pulled manifest. Becomes `agreed` when it is.
    public var uploaded: String?
    /// The folder version last shown to the user against this device's copy (a conflict, or a
    /// copy that failed verification), and this device's stamp then (nil: not on this device).
    /// Settling it changes this device's copy (a choice is stamped as a fresh edit), and then
    /// `shown` becomes `agreed`.
    public var shown: String?
    public var shownLocal: String?
    /// This device's latest upload, kept after it is agreed (2.1.0). While this device's copy is
    /// still that upload, a folder version whose `builtOn` names a different upload of this
    /// device was written by a push that never had it (two pushes past the lock at once).
    /// Nil in a record from 2.0.0: nothing is checked until this device next uploads.
    public var published: String?

    public init(agreed: String? = nil, uploaded: String? = nil,
                shown: String? = nil, shownLocal: String? = nil, published: String? = nil) {
        self.agreed = agreed
        self.uploaded = uploaded
        self.shown = shown
        self.shownLocal = shownLocal
        self.published = published
    }
}
