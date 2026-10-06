//
//  SyncMutationGapTests.swift
//  CatchlightCoreTests
//
//  The rest of the 2026-10-05 mutation run over Sync/ (the first 22 are in
//  SyncCryptoMutationGapTests): each test here kills a one-line change that survived the
//  whole suite. The comment on each names the file and the rule it guards.
//
//  The store stamps a deletion with the real clock, so every test that deletes runs its
//  engines on a timeline built around the real clock too. Another device's deletion that
//  must be OLDER than an edit is planted in the folder instead, as that device's push
//  would leave it.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncMutationGapTests: XCTestCase {

    private let day: TimeInterval = 24 * 3600

    private func makeKeys() -> KeyHierarchy { KeyHierarchy(masterKey: SymmetricKey(size: .bits256)) }

    private func engine(_ store: TakeStore, _ cloud: CloudFolder, _ keys: KeyHierarchy,
                        at: Date, device: UUID = UUID()) -> SyncEngine {
        TestFixtures.engine(store: store, cloud: cloud, keys: keys, deviceId: device, now: { at })
    }

    private func take(text: String, modified: Date) -> Take {
        var take = TestFixtures.richTake()
        take.primaryText = text
        take.modifiedAt = modified
        take.isObie = false
        return take
    }

    private func blob(_ id: UUID) -> String { "\(id.uuidString).clk" }

    /// What another device's push leaves after it deleted `id` at `deletedAt`: no entry, no
    /// blob, one deletion record.
    private func plantDeletion(of id: UUID, at deletedAt: Date,
                               in cloud: CloudFolder, keys: KeyHierarchy) throws {
        var manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        manifest.takes.removeAll { $0.uuid == id }
        manifest.tombstones = [ManifestTombstone(uuid: id, deletedAt: ISO8601.string(from: deletedAt))]
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)
        try cloud.delete(blob(id))
    }

    // MARK: - Deletions survive a device that was away

    /// Manifest.swift — deletion records are kept for 180 days. A device away for two
    /// months, while the rest of the fleet kept syncing, must still find the record and
    /// delete its copy. A 30-day window prunes the record first, and the returning device can
    /// no longer tell the deleted Take from one it never uploaded.
    func testDeletionRecord_reachesADeviceThatWasAwayForTwoMonths() throws {
        let base = Date()
        let keys = makeKeys(), cloud = InMemoryCloudFolder()
        let away = InMemoryTakeStore(), deleter = InMemoryTakeStore()
        let original = take(text: "deleted elsewhere", modified: base.addingTimeInterval(-3600))
        try away.upsert(original)
        try engine(away, cloud, keys, at: base.addingTimeInterval(-3000)).sync()
        try engine(deleter, cloud, keys, at: base.addingTimeInterval(-2000)).sync()

        try deleter.delete(id: original.id)
        try engine(deleter, cloud, keys, at: base.addingTimeInterval(60)).sync()
        // The rest of the fleet keeps syncing while the other device is away.
        try engine(deleter, cloud, keys, at: base.addingTimeInterval(45 * day)).sync()

        let report = try engine(away, cloud, keys, at: base.addingTimeInterval(60 * day)).sync()

        XCTAssertNil(try away.take(id: original.id), "the deletion reaches the returning device")
        XCTAssertEqual(report.deletedLocally, [original.id])
        XCTAssertEqual(report.heldBack, [])
        let manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        XCTAssertEqual(manifest.takes, [])
        XCTAssertEqual(manifest.tombstones.map(\.uuid), [original.id])
    }

    /// SyncEngine.swift — a deletion record is kept until the retention window has passed and
    /// pruned once it has, so the manifest does not grow by one record per deletion forever.
    func testDeletionRecord_isKeptWithinRetention_andPrunedAfterIt() throws {
        let base = Date()
        let keys = makeKeys(), cloud = InMemoryCloudFolder(), store = InMemoryTakeStore()
        let doomed = take(text: "deleted", modified: base.addingTimeInterval(-3600))
        try store.upsert(doomed)
        try engine(store, cloud, keys, at: base.addingTimeInterval(-3000)).pushOutbound()
        try store.delete(id: doomed.id)

        try engine(store, cloud, keys, at: base.addingTimeInterval(60)).pushOutbound()
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.map(\.uuid), [doomed.id])
        try engine(store, cloud, keys, at: base.addingTimeInterval(179 * day)).pushOutbound()
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.map(\.uuid), [doomed.id],
                       "inside the window the record stays")

        try engine(store, cloud, keys, at: base.addingTimeInterval(181 * day)).pushOutbound()
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones, [],
                       "past the window the record is pruned")
    }

    // MARK: - The newest deletion is the one the folder keeps

    /// Two devices hold a Take. Another device deleted it first (`firstDeletion`); the
    /// `editor` then edited it offline; the `deleter` deleted it last. Returns the edited Take.
    private func deletedEditedDeleted(keys: KeyHierarchy, cloud: CloudFolder, base: Date,
                                      editor: InMemoryTakeStore, deleter: InMemoryTakeStore) throws -> Take {
        let original = take(text: "original", modified: base.addingTimeInterval(-3 * 3600))
        try deleter.upsert(original)
        try engine(deleter, cloud, keys, at: base.addingTimeInterval(-170 * 60)).sync()
        try engine(editor, cloud, keys, at: base.addingTimeInterval(-160 * 60)).sync()

        try plantDeletion(of: original.id, at: base.addingTimeInterval(-2 * 3600), in: cloud, keys: keys)
        var edited = original
        edited.primaryText = "edited between the two deletions"
        edited.modifiedAt = base.addingTimeInterval(-3600)
        try editor.upsert(edited)
        try deleter.delete(id: original.id)   // stamped now, after the edit
        return edited
    }

    /// SyncEngine.swift — push merging this device's deletion with one already in the folder
    /// keeps the NEWER stamp. Keeping the older one lets an edit made between the two
    /// deletions win against a deletion that came after it.
    func testPush_mergingTwoDeletions_keepsTheNewerStamp() throws {
        let base = Date()
        let keys = makeKeys(), cloud = InMemoryCloudFolder()
        let editor = InMemoryTakeStore(), deleter = InMemoryTakeStore()
        let edited = try deletedEditedDeleted(keys: keys, cloud: cloud, base: base,
                                              editor: editor, deleter: deleter)
        let lastDeletion = try XCTUnwrap(try deleter.tombstones().first).deletedAt

        try engine(deleter, cloud, keys, at: base.addingTimeInterval(60)).pushOutbound()
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones,
                       [ManifestTombstone(uuid: edited.id, deletedAt: ISO8601.string(from: lastDeletion))])

        try engine(editor, cloud, keys, at: base.addingTimeInterval(120)).sync()
        XCTAssertNil(try editor.take(id: edited.id), "the later deletion wins over the edit")
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).takes, [])
    }

    /// SyncEngine.swift — pull purges a pending deletion only when the folder's record is at
    /// least as new. An OLDER record there is not this deletion: purging on it means push
    /// never sends the newer stamp, and the edit made between the two survives.
    func testPull_anOlderRecordInTheFolder_doesNotPurgeANewerLocalDeletion() throws {
        let base = Date()
        let keys = makeKeys(), cloud = InMemoryCloudFolder()
        let editor = InMemoryTakeStore(), deleter = InMemoryTakeStore()
        let edited = try deletedEditedDeleted(keys: keys, cloud: cloud, base: base,
                                              editor: editor, deleter: deleter)

        try engine(deleter, cloud, keys, at: base.addingTimeInterval(60)).pullInbound()
        XCTAssertEqual(try deleter.tombstones().map(\.id), [edited.id], "still to be sent")

        try engine(deleter, cloud, keys, at: base.addingTimeInterval(90)).pushOutbound()
        try engine(editor, cloud, keys, at: base.addingTimeInterval(120)).sync()
        XCTAssertNil(try editor.take(id: edited.id), "the later deletion wins over the edit")
    }

    // MARK: - A local deletion always removes its file

    /// SyncEngine.swift — a deletion made here deletes the Take's file whether or not the
    /// manifest still lists it. A concurrent device's manifest write can drop the entry and
    /// leave the file; skipping the delete then leaves the Take's ciphertext in the folder
    /// for good, since nothing else ever removes a file with no entry.
    func testPush_aLocalDeletion_removesTheFile_evenWithNoManifestEntry() throws {
        let base = Date()
        let keys = makeKeys(), cloud = InMemoryCloudFolder(), store = InMemoryTakeStore()
        let doomed = take(text: "deleted", modified: base.addingTimeInterval(-3600))
        try store.upsert(doomed)
        try engine(store, cloud, keys, at: base.addingTimeInterval(-3000)).pushOutbound()
        // Another device's manifest, written past the advisory lock, never saw the entry.
        var manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        manifest.takes = []
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)
        XCTAssertNotNil(try cloud.read(blob(doomed.id)))

        try store.delete(id: doomed.id)
        try engine(store, cloud, keys, at: base.addingTimeInterval(60)).pushOutbound()

        XCTAssertNil(try cloud.read(blob(doomed.id)))
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.map(\.uuid), [doomed.id])
    }

    // MARK: - A Take that became a Script elsewhere (D-315)

    private func remarkAsScript(_ id: UUID, modified: Date, in cloud: CloudFolder, keys: KeyHierarchy) throws {
        var manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        manifest.takes = manifest.takes.map { e in
            guard e.uuid == id else { return e }
            return ManifestEntry(uuid: e.uuid, modified: ISO8601.string(from: modified),
                                 hmac: e.hmac, kind: ManifestEntry.Kind.script)
        }
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)
    }

    /// SyncEngine.swift — the fork lets the original go only if it has not changed since
    /// the version copied. A second edit landing during the fork must stop the release:
    /// releasing regardless removes the Take holding that edit, and the copy has only the first.
    func testFork_aSecondEditDuringTheFork_isNotLost() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let keys = makeKeys(), cloud = InMemoryCloudFolder(), inner = InMemoryTakeStore()
        let original = take(text: "original", modified: t0)
        try inner.upsert(original)
        try engine(inner, cloud, keys, at: t0.addingTimeInterval(1)).sync()
        var first = original
        first.primaryText = "first edit"
        first.modifiedAt = t0.addingTimeInterval(20)
        try inner.upsert(first)
        try remarkAsScript(original.id, modified: t0.addingTimeInterval(25), in: cloud, keys: keys)

        var second = original
        second.primaryText = "second edit"
        second.modifiedAt = t0.addingTimeInterval(27)
        let phone = EditDuringReleaseStore(wrapping: inner, edit: second)
        let report = try engine(phone, cloud, keys, at: t0.addingTimeInterval(30)).pushOutbound()

        XCTAssertTrue(phone.editFired)
        XCTAssertEqual(try inner.allTakes().map(\.primaryText), ["second edit"],
                       "the second edit is kept, and the copy of the first is withdrawn")
        let copy = try XCTUnwrap(report.forkedFromScripts.first)
        XCTAssertEqual(report.forkedFromScripts.count, 1)
        XCTAssertEqual(try inner.take(id: copy)?.primaryText, "second edit")
    }

    /// SyncEngine.swift — push step 4 forks only an edit made since the last sync. A Take
    /// not touched since then is an old version the Script has superseded; forking it makes
    /// a duplicate Take of content the user never changed.
    func testPushStep4_anUneditedTakeThatBecameAScript_isNotForked() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let keys = makeKeys(), cloud = InMemoryCloudFolder(), phone = InMemoryTakeStore()
        let original = take(text: "unchanged", modified: t0)
        try phone.upsert(original)
        try engine(phone, cloud, keys, at: t0.addingTimeInterval(1)).sync()
        try remarkAsScript(original.id, modified: t0.addingTimeInterval(25), in: cloud, keys: keys)
        let scriptEntries = try Manifest.readEncrypted(from: cloud, keys: keys).takes

        let report = try engine(phone, cloud, keys, at: t0.addingTimeInterval(30)).pushOutbound()

        XCTAssertEqual(report.forkedFromScripts, [])
        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).takes, scriptEntries)
        XCTAssertEqual(try phone.allTakes().map(\.id), [original.id])
    }
}

/// Commits a second user edit at the start of the first `release` of that Take, i.e. while
/// a fork is in progress. Everything else forwards to the wrapped store.
private final class EditDuringReleaseStore: TakeStore {
    private let wrapped: InMemoryTakeStore
    private let edit: Take
    private(set) var editFired = false

    init(wrapping wrapped: InMemoryTakeStore, edit: Take) {
        self.wrapped = wrapped
        self.edit = edit
    }

    func release(id: UUID, ifNotModifiedAfter cutoff: Date) throws -> Bool {
        if id == edit.id, !editFired {
            editFired = true
            try wrapped.upsert(edit)   // the user's edit lands here
        }
        return try wrapped.release(id: id, ifNotModifiedAfter: cutoff)
    }

    func upsert(_ take: Take) throws { try wrapped.upsert(take) }
    func delete(id: UUID) throws { try wrapped.delete(id: id) }
    func take(id: UUID) throws -> Take? { try wrapped.take(id: id) }
    func allTakes() throws -> [Take] { try wrapped.allTakes() }
    func takesModified(since date: Date?) throws -> [Take] { try wrapped.takesModified(since: date) }
    func search(_ query: String) throws -> [Take] { try wrapped.search(query) }
    func upsert(_ sequence: CatchlightSequence) throws { try wrapped.upsert(sequence) }
    func sequence(id: UUID) throws -> CatchlightSequence? { try wrapped.sequence(id: id) }
    func allSequences() throws -> [CatchlightSequence] { try wrapped.allSequences() }
    func deleteSequence(id: UUID) throws { try wrapped.deleteSequence(id: id) }
    func currentObie() throws -> Take? { try wrapped.currentObie() }
    func setObie(id: UUID, replaceExisting: Bool) throws { try wrapped.setObie(id: id, replaceExisting: replaceExisting) }
    func lastSyncDate() -> Date? { wrapped.lastSyncDate() }
    func setLastSyncDate(_ date: Date) { wrapped.setLastSyncDate(date) }
    func tombstones() throws -> [Tombstone] { try wrapped.tombstones() }
    func purgeTombstones(ids: [UUID]) throws { try wrapped.purgeTombstones(ids: ids) }
    func applyRemote(_ take: Take) throws -> Bool { try wrapped.applyRemote(take) }
}
