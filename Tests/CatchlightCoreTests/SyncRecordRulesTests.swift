//
//  SyncRecordRulesTests.swift
//  CatchlightCoreTests
//
//  The per-Take sync record's rules (SyncRecord.swift), one test each, so removing any one of
//  them fails here. The losses they close are in SyncPushBetweenHalvesTests; the first sync
//  after updating is in SyncUpgradeToRecordsTests.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncRecordRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    private func engine(_ store: InMemoryTakeStore, _ device: UUID, _ folder: CloudFolder? = nil,
                        at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: store, cloud: folder ?? cloud, keys: k, deviceId: device,
                            now: { self.t0.addingTimeInterval(at) })
    }

    @discardableResult
    private func syncA(_ at: TimeInterval) throws -> SyncReport { try engine(storeA, deviceA, at: at).sync() }
    @discardableResult
    private func syncB(_ at: TimeInterval) throws -> SyncReport { try engine(storeB, deviceB, at: at).sync() }

    private func cloudText(_ id: UUID) throws -> String? {
        guard let entry = try Manifest.readEncrypted(from: cloud, keys: k).takes.first(where: { $0.uuid == id }) else {
            return nil
        }
        let bytes = try XCTUnwrap(cloud.read("\(entry.uuid.uuidString).clk"))
        let ct = try XCTUnwrap(CloudBlob.parse(bytes).ciphertext)
        return try TakeCrypto(keys: k).open(ct, takeUUID: entry.uuid).primaryText
    }

    private func edit(_ store: InMemoryTakeStore, _ id: UUID, _ text: String, at: TimeInterval) throws {
        var take = try XCTUnwrap(store.take(id: id))
        take.primaryText = text
        take.modifiedAt = t0.addingTimeInterval(at)
        try store.upsert(take)
    }

    private func synced() throws -> UUID {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try syncA(1)
        try syncB(2)
        try syncA(3)
        return take.id
    }

    /// The everyday flow: A edits and syncs, B takes it, edits on top and syncs, A syncs. A has
    /// not seen its own upload in a pull yet, but B could only write over it by having it, so A
    /// takes B's version quietly: no conflict for building on each other's edits.
    func testAnEditBuiltOnThisDevicesUpload_isTakenWithoutAConflict() throws {
        let id = try synced()
        try edit(storeA, id, "edit on A", at: 10)
        try syncA(11)
        try syncB(20)
        try edit(storeB, id, "B builds on A's edit", at: 21)
        try syncB(22)

        let report = try syncA(30)

        XCTAssertTrue(report.conflicts.isEmpty, "nothing to choose: B's edit is built on A's")
        XCTAssertEqual(report.applied, [id])
        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "B builds on A's edit")
    }

    /// A device with no record yet (just updated) and an edit waiting finds, mid-pull, that
    /// another device has pushed: the file no longer matches the entry it read. Its push must
    /// not upload over that version it has not had, and must keep its edit counted as unsynced,
    /// so the next pull shows the two as a conflict.
    func testNoRecordYet_aVersionPushedMidPull_isNotUploadedOver() throws {
        let id = try synced()
        storeB.removeAllSyncRecords()                       // B has just updated
        try edit(storeB, id, "edit on B", at: 20)
        try edit(storeA, id, "edit on A", at: 10)

        let midPull = BeforeFirstBlobReadFolder(cloud) { try self.syncA(15) }
        var conflictsSeen = try engine(storeB, deviceB, midPull, at: 25).sync().conflicts.count
        XCTAssertTrue(midPull.fired)
        XCTAssertEqual(try cloudText(id), "edit on A", "B uploaded over A's edit, which it never had")

        let next = try syncB(30)
        conflictsSeen += next.conflicts.count
        XCTAssertEqual(next.conflicts.map(\.remote.primaryText), ["edit on A"])
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B")
        XCTAssertGreaterThan(conflictsSeen, 0)
    }

    /// With no record yet, the pull judges this device's side by the last-sync time. A push that
    /// leaves an edit for the next pull must keep the watermark below it, or that pull reads the
    /// edit as old and writes the other device's version over it.
    func testNoRecordYet_anEditLeftForTheNextPull_staysCountedAsUnsynced() throws {
        let id = try synced()
        storeB.removeAllSyncRecords()                       // B has just updated
        try edit(storeB, id, "edit on B", at: 10)
        try edit(storeA, id, "edit on A", at: 30)
        try syncA(31)

        let lagging = BlobsHiddenFolder(cloud)
        _ = try engine(storeB, deviceB, lagging, at: 40).sync()   // can't read A's file yet
        XCTAssertEqual(try cloudText(id), "edit on A")
        XCTAssertLessThan(try XCTUnwrap(storeB.lastSyncDate()), t0.addingTimeInterval(10),
                          "the watermark stays below the edit left for the next pull")

        let next = try syncB(50)
        XCTAssertEqual(next.conflicts.map(\.remote.primaryText), ["edit on A"])
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B")
    }

    /// A cloud copy failing verification, where the manifest names a version this device has
    /// not had and this device's own edit is newer: push won't upload over that version, so
    /// the user is shown the copy instead of nothing happening.
    func testUnverifiedCopy_ofAVersionNotHad_isShownEvenWhenTheLocalEditIsNewer() throws {
        let id = try synced()
        let staleBytes = try XCTUnwrap(cloud.read("\(id.uuidString).clk"))
        try edit(storeA, id, "edit on A", at: 10)
        try syncA(11)
        try cloud.write(staleBytes, to: "\(id.uuidString).clk")   // the provider kept the old file
        try edit(storeB, id, "edit on B", at: 20)

        let report = try syncB(30)

        XCTAssertEqual(report.unverified.map(\.id), [id], "the user decides")
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B")
    }

    /// A deleted Take's file goes only after the manifest stops naming it. The other way round,
    /// a push stopped between the two left an entry whose file was gone, which no device could
    /// read again and none would upload over.
    func testADeletedTakesFile_isRemovedOnlyAfterTheManifestDropsIt() throws {
        let id = try synced()
        try storeA.delete(id: id)
        let order = OrderRecordingFolder(cloud)

        _ = try engine(storeA, deviceA, order, at: 20).sync()

        let manifestWrite = try XCTUnwrap(order.events.lastIndex(of: "write \(Manifest.fileName)"))
        let blobDelete = try XCTUnwrap(order.events.firstIndex(of: "delete \(id.uuidString).clk"))
        XCTAssertLessThan(manifestWrite, blobDelete)
        XCTAssertNil(try cloud.read("\(id.uuidString).clk"))
    }

    /// A deletion older than another device's edit it has not seen never removes that edit
    /// (the edit-versus-deletion rule: the later one wins). Here A's edit lands between B's pull
    /// and push, so only B's push sees it, and B then brings the Take back as the
    /// couldn't-verify queue's "keep the cloud copy" does: had the deletion gone out, A would take
    /// B's version as built on its own upload, and its edit would be lost unseen.
    func testADeletion_neverRemovesANewerEditThisDeviceHasNotSeen() throws {
        let id = try synced()
        try storeB.delete(id: id)                                   // at "now", before A's edit
        let deletedAt = try XCTUnwrap(storeB.tombstones().first?.deletedAt)
        var conflictsSeen = 0
        let betweenHalves = BeforeFirstReadFolder(cloud, name: SyncLock.fileName) {
            var take = try XCTUnwrap(self.storeA.take(id: id))
            take.primaryText = "edit on A"
            take.modifiedAt = deletedAt.addingTimeInterval(10)      // after B's deletion
            try self.storeA.upsert(take)
            conflictsSeen += try self.engine(self.storeA, self.deviceA, at: 30).sync().conflicts.count
        }
        conflictsSeen += try engine(storeB, deviceB, betweenHalves, at: 31).sync().conflicts.count
        XCTAssertTrue(betweenHalves.fired)

        var kept = TestFixtures.richTake()
        kept = Take(id: id, createdAt: kept.createdAt, modifiedAt: deletedAt.addingTimeInterval(20),
                    blocks: [.textLine("kept on B")])
        try storeB.upsert(kept)
        conflictsSeen += try syncB(40).conflicts.count
        conflictsSeen += try syncA(50).conflicts.count

        let survives = try storeA.take(id: id)?.primaryText == "edit on A"
            || storeB.take(id: id)?.primaryText == "edit on A"
            || cloudText(id) == "edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's edit, newer than B's deletion, was lost with nothing shown")
    }

    /// Two pushes past the advisory lock at once (cloud delay): B's whole sync lands inside A's
    /// push, so the folder ends up naming A's upload over B's file. B shows the pair as a copy
    /// it couldn't verify. Once A repairs the file, B's own upload has been replaced, but not by
    /// a device that had it: while that pair is still unsettled, B must not take A's version
    /// quietly over its own edit.
    func testAnUnsettledPair_isNotTakenQuietlyAsBuiltOnThisDevicesUpload() throws {
        let id = try synced()
        try edit(storeA, id, "edit on A", at: 10)
        var shown = 0
        let folderA = AfterFirstBlobWriteFolder(cloud) {
            try self.edit(self.storeB, id, "edit on B", at: 20)
            let report = try self.engine(self.storeB, self.deviceB, LockHiddenOnceFolder(self.cloud), at: 21).sync()
            XCTAssertFalse(report.pushDeferred, "the setup: B's push passes the lock")
            shown += report.conflicts.count + report.unverified.count
        }
        shown += try engine(storeA, deviceA, folderA, at: 15).sync().conflicts.count
        XCTAssertTrue(folderA.fired)

        for at in stride(from: 40.0, through: 60.0, by: 10.0) {
            let b = try syncB(at)
            shown += b.conflicts.count + b.unverified.count
            shown += try syncA(at + 1).conflicts.count
        }

        XCTAssertTrue(try storeB.take(id: id)?.primaryText == "edit on B" || shown > 0,
                      "B's edit was replaced by A's with nothing shown")
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B", "B keeps its edit while unsettled")
    }

    /// A Take restored while a push runs, after the push read its deletion: the restore wins
    /// (it is newer), step 4 uploads it, and the file removal that follows the manifest write
    /// must leave that fresh file alone.
    func testATakeRestoredDuringThePush_keepsItsFreshlyUploadedFile() throws {
        let id = try synced()
        let original = try XCTUnwrap(storeA.take(id: id))
        try storeA.delete(id: id)
        let deletedAt = try XCTUnwrap(storeA.tombstones().first?.deletedAt)
        var restored = original
        restored.primaryText = "restored"
        restored.modifiedAt = deletedAt.addingTimeInterval(1)   // after the deletion
        let racing = RestoreAfterTombstonesReadStore(wrapping: storeA, restore: restored)

        _ = try TestFixtures.engine(store: racing, cloud: cloud, keys: k, deviceId: deviceA,
                                    now: { deletedAt.addingTimeInterval(2) }).pushOutbound()

        XCTAssertTrue(racing.restored)
        XCTAssertEqual(try cloudText(id), "restored", "the manifest names a file that is gone")
    }

    /// A device with no record yet holds a newer edit, and the folder's copy fails verification
    /// against a version the manifest names. Push won't upload over a version this device can't
    /// show it has had, so the pull must show the copy: otherwise the edit sits unsent and
    /// nothing tells the user.
    func testNoRecordYet_anUnverifiedCopyWithANewerLocalEdit_isShown() throws {
        let id = try synced()
        let staleBytes = try XCTUnwrap(cloud.read("\(id.uuidString).clk"))
        try edit(storeA, id, "edit on A", at: 10)
        try syncA(11)
        try cloud.write(staleBytes, to: "\(id.uuidString).clk")   // the provider kept the old file
        storeB.removeAllSyncRecords()                               // B has just updated
        try edit(storeB, id, "edit on B", at: 20)

        let report = try syncB(30)

        XCTAssertEqual(report.unverified.map(\.id), [id])
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B")
    }

    /// Once this device's deletion is in the folder, the deleted Take's record goes too: rows
    /// for deleted Takes would otherwise pile up in the store for good.
    func testARecord_isClearedOnceThisDevicesDeletionReachesTheFolder() throws {
        let id = try synced()
        XCTAssertNotNil(try storeA.syncRecord(id: id))
        try storeA.delete(id: id)
        try syncA(10)                                      // the deletion goes out
        try syncA(20)                                      // and is seen in a pull

        XCTAssertTrue(try storeA.tombstones().isEmpty)
        XCTAssertNil(try storeA.syncRecord(id: id))
    }
}

/// Restores a Take once, between the push reading its tombstones and reading the Takes:
/// the user restoring it while the push runs.
private final class RestoreAfterTombstonesReadStore: TakeStore {
    private let wrapped: InMemoryTakeStore
    private let restore: Take
    private var tombstonesRead = false
    private(set) var restored = false
    init(wrapping wrapped: InMemoryTakeStore, restore: Take) { self.wrapped = wrapped; self.restore = restore }

    func tombstones() throws -> [Tombstone] {
        let out = try wrapped.tombstones()
        tombstonesRead = true
        return out
    }
    func allTakes() throws -> [Take] {
        if tombstonesRead, !restored { restored = true; try wrapped.upsert(restore) }
        return try wrapped.allTakes()
    }
    func upsert(_ take: Take) throws { try wrapped.upsert(take) }
    func delete(id: UUID) throws { try wrapped.delete(id: id) }
    func take(id: UUID) throws -> Take? { try wrapped.take(id: id) }
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
    func syncRecord(id: UUID) throws -> SyncRecord? { try wrapped.syncRecord(id: id) }
    func setSyncRecord(_ record: SyncRecord?, id: UUID) throws { try wrapped.setSyncRecord(record, id: id) }
    func purgeTombstones(ids: [UUID]) throws { try wrapped.purgeTombstones(ids: ids) }
    func applyRemote(_ take: Take) throws -> Bool { try wrapped.applyRemote(take) }
    func release(id: UUID, ifNotModifiedAfter cutoff: Date) throws -> Bool {
        try wrapped.release(id: id, ifNotModifiedAfter: cutoff)
    }
}

/// Runs `action` once, just before the first read of `name`.
private final class BeforeFirstReadFolder: CloudFolder {
    private let base: CloudFolder
    private let name: String
    private var action: (() throws -> Void)?
    private(set) var fired = false
    init(_ base: CloudFolder, name: String, _ action: @escaping () throws -> Void) {
        self.base = base; self.name = name; self.action = action
    }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if name == self.name, let a = action { action = nil; fired = true; try a() }
        return try base.read(name)
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

/// Runs `action` once, just after the first .clk write: inside a push, before its manifest write.
private final class AfterFirstBlobWriteFolder: CloudFolder {
    private let base: CloudFolder
    private var action: (() throws -> Void)?
    private(set) var fired = false
    init(_ base: CloudFolder, _ action: @escaping () throws -> Void) { self.base = base; self.action = action }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { try base.read(name) }
    func write(_ data: Data, to name: String) throws {
        try base.write(data, to: name)
        if name.hasSuffix(".clk"), let a = action { action = nil; fired = true; try a() }
    }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

/// The first read of the lock finds nothing: another device's lock not delivered yet.
private final class LockHiddenOnceFolder: CloudFolder {
    private let base: CloudFolder
    private var hidden = true
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if name == SyncLock.fileName, hidden { hidden = false; return nil }
        return try base.read(name)
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

/// Runs `action` once, just before the first .clk read: inside a pull.
private final class BeforeFirstBlobReadFolder: CloudFolder {
    private let base: CloudFolder
    private var action: (() throws -> Void)?
    private(set) var fired = false
    init(_ base: CloudFolder, _ action: @escaping () throws -> Void) { self.base = base; self.action = action }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if name.hasSuffix(".clk"), let a = action { action = nil; fired = true; try a() }
        return try base.read(name)
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

/// Every .clk read finds nothing: files the manifest names that have not downloaded yet.
private final class BlobsHiddenFolder: CloudFolder {
    private let base: CloudFolder
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { name.hasSuffix(".clk") ? nil : try base.read(name) }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

/// Records the order of writes and deletes.
private final class OrderRecordingFolder: CloudFolder {
    private let base: CloudFolder
    private(set) var events: [String] = []
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { try base.read(name) }
    func write(_ data: Data, to name: String) throws { events.append("write \(name)"); try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws {
        events.append("write \(name)"); try base.writeAtomically(data, to: name)
    }
    func delete(_ name: String) throws { events.append("delete \(name)"); try base.delete(name) }
}
