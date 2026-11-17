//
//  SyncUpgradeToRecordsTests.swift
//  CatchlightCoreTests
//
//  A device updating from a build without per-Take sync records (SyncRecord.swift) starts with
//  none: its first sync must not lose an edit, on either device, whatever was waiting when it
//  updated. `removeAllSyncRecords()` leaves a store as such a build left it.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncUpgradeToRecordsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    @discardableResult
    private func syncA(_ at: TimeInterval, holding: Set<UUID> = []) throws -> SyncReport {
        try TestFixtures.engine(store: storeA, cloud: cloud, keys: k, deviceId: deviceA,
                                now: { self.t0.addingTimeInterval(at) }).sync(holding: holding)
    }

    @discardableResult
    private func syncB(_ at: TimeInterval, holding: Set<UUID> = []) throws -> SyncReport {
        try TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB,
                                now: { self.t0.addingTimeInterval(at) }).sync(holding: holding)
    }

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

    /// One Take, synced on both devices by a build without records.
    private func syncedWithoutRecords() throws -> UUID {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try syncA(1)
        try syncB(2)
        storeA.removeAllSyncRecords()
        storeB.removeAllSyncRecords()
        return take.id
    }

    /// The loss the records fix, with B updating in the middle of it: A's offline edit reaches
    /// the folder after B's last sync, so it carries an older stamp than that sync, and B
    /// updates with an edit of its own waiting. B's first sync with records must not keep its
    /// edit and upload it over A's: it has no record to prove A's version is one it has had.
    func testFirstSyncAfterUpdating_withAnEditWaiting_neverUploadsOverAnOfflineEdit() throws {
        let id = try syncedWithoutRecords()
        try syncA(5)                                        // A updated first, nothing waiting
        try edit(storeA, id, "offline edit on A", at: 10)   // A is offline
        try syncB(20)                                       // B syncs: nothing new
        storeB.removeAllSyncRecords()                       // B is still on the old build
        try syncA(30)                                       // A back online
        XCTAssertEqual(try cloudText(id), "offline edit on A", "the setup: A's edit reached the folder")
        try edit(storeB, id, "edit on B", at: 40)
        storeB.removeAllSyncRecords()                       // B updates now, edit waiting

        let first = try syncB(41)

        XCTAssertEqual(first.conflicts.map(\.remote.primaryText), ["offline edit on A"],
                       "B's first sync shows the two versions instead of choosing")
        XCTAssertEqual(try cloudText(id), "offline edit on A", "A's edit is still in the folder")
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B", "B's edit is still on B")
    }

    /// The same with A updating too, before it uploads its offline edit.
    func testBothDevicesUpdating_offlineEditThenEditOnTheOther_isNeverLostSilently() throws {
        let id = try syncedWithoutRecords()
        try edit(storeA, id, "offline edit on A", at: 10)
        var conflictsSeen = try syncB(20).conflicts.count
        storeB.removeAllSyncRecords()
        conflictsSeen += try syncA(30).conflicts.count
        try edit(storeB, id, "edit on B", at: 40)
        conflictsSeen += try syncB(41).conflicts.count
        conflictsSeen += try syncA(50).conflicts.count
        conflictsSeen += try syncB(51).conflicts.count

        let survives = try storeA.take(id: id)?.primaryText == "offline edit on A"
            || storeB.take(id: id)?.primaryText == "offline edit on A"
            || cloudText(id) == "offline edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's offline edit was lost with no conflict shown on either device")
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B", "B's edit is never lost either")
    }

    /// An edit waiting on the updated device, with nothing new in the folder: it is kept, and
    /// reaches the folder. With no record to show the folder's version is one this device has
    /// had, the first sync may ask once (the safe side); keeping this device's version then
    /// uploads it, and the other device takes it quietly.
    func testFirstSyncAfterUpdating_withAnEditWaitingAndNothingNew_keepsAndUploadsTheEdit() throws {
        let id = try syncedWithoutRecords()
        try edit(storeB, id, "edit on B", at: 10)

        let first = try syncB(20)
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B", "never written over")
        if !first.conflicts.isEmpty {
            XCTAssertEqual(first.conflicts.map(\.remote.primaryText), ["base"])
            XCTAssertEqual(try cloudText(id), "base", "nothing uploaded while the user chooses")
            try edit(storeB, id, "edit on B", at: 25)   // keeping B's: stamped as a fresh edit
            XCTAssertTrue(try syncB(30, holding: []).conflicts.isEmpty)
        }
        XCTAssertEqual(try cloudText(id), "edit on B")
        let a = try syncA(40)
        XCTAssertTrue(a.conflicts.isEmpty)
        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "edit on B")
    }

    /// The common case is quiet: no edit waiting, another device edited. Applied, no conflict,
    /// and from then on the record is in place.
    func testFirstSyncAfterUpdating_withNoEditWaiting_appliesTheOtherDevicesEditQuietly() throws {
        let id = try syncedWithoutRecords()
        try syncA(5)                                        // A updated first, nothing waiting
        try edit(storeA, id, "edit on A", at: 10)
        try syncA(11)

        let first = try syncB(20)

        XCTAssertTrue(first.conflicts.isEmpty)
        XCTAssertEqual(first.applied, [id])
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on A")
        XCTAssertEqual(try storeB.syncRecord(id: id)?.agreed, ISO8601.string(from: t0.addingTimeInterval(10)),
                       "the first sync leaves a record of the version both now hold")
    }
}
