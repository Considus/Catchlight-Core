//
//  SyncHeldTakeTests.swift
//  CatchlightCoreTests
//
//  A Take waiting for the user's conflict choice is HELD until it is resolved (owner
//  2026-10-07: "the file shouldn't update or edit until the conflict is resolved"). The app
//  keeps the conflict queue, across relaunches, and hands its ids to every sync. Held, a Take
//  is never uploaded, never overwritten by a newer remote version and never deleted by a remote
//  deletion; a newer remote version refreshes the conflict instead.
//
//  The gap this closes (Greptile on #17): once the first pass had held the Take, the watermark
//  moved past both versions, so an edit made before choosing read as an ordinary local change
//  and was uploaded over the other device's version.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncHeldTakeTests: XCTestCase {
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
    private func syncB(_ at: TimeInterval) throws -> SyncReport {
        try TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB,
                                now: { self.t0.addingTimeInterval(at) }).sync()
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

    /// One synced Take; A edits offline at t0+10, B edits at t0+20 and syncs; A's sync at t0+30
    /// finds the conflict and holds it. Returns the Take's id.
    private func conflictOnA() throws -> UUID {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try syncA(1)
        try syncB(2)
        try edit(storeA, take.id, "offline edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)
        try syncB(21)
        let first = try syncA(30)
        XCTAssertEqual(first.conflicts.map(\.local.id), [take.id])
        XCTAssertEqual(try cloudText(take.id), "edit on B")
        return take.id
    }

    /// The Greptile gap: an edit on A after the conflict, before the user chooses. Without the
    /// app's hold the next sync reads it as an ordinary local change and uploads it over B's.
    func testHeld_anEditBeforeChoosing_isNotUploaded() throws {
        let id = try conflictOnA()
        try edit(storeA, id, "second edit on A", at: 40)

        try syncA(50, holding: [id])

        XCTAssertEqual(try cloudText(id), "edit on B", "B's version stays in the cloud until the user chooses")
    }

    /// A newer remote version while held refreshes the conflict, and never overwrites A's.
    func testHeld_aNewerRemoteVersion_refreshesTheConflict_andIsNotApplied() throws {
        let id = try conflictOnA()
        try edit(storeB, id, "second edit on B", at: 40)
        try syncB(41)

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "offline edit on A")
        XCTAssertEqual(report.applied, [])
        XCTAssertEqual(report.conflicts.map(\.remote.primaryText), ["second edit on B"],
                       "the pair the user sees carries the newest remote version")
    }

    /// A remote deletion while held does not delete A's copy, and A does not re-upload it either.
    func testHeld_aRemoteDeletion_doesNotDeleteTheHeldTake() throws {
        let id = try conflictOnA()
        try storeB.delete(id: id)
        try TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB,
                                now: { Date() }).sync()

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "offline edit on A")
        XCTAssertEqual(report.deletedLocally, [])
        XCTAssertNil(try cloudText(id), "the held copy is not re-uploaded over the deletion")
    }

    /// Resolved (nothing held any more, the winner stamped as a fresh edit), the next sync
    /// uploads the user's choice.
    func testOnceResolved_theChoiceIsUploaded() throws {
        let id = try conflictOnA()
        try syncA(40, holding: [id])
        try edit(storeA, id, "kept: offline edit on A", at: 45)   // what ConflictQueue.resolve writes

        try syncA(50)

        XCTAssertEqual(try cloudText(id), "kept: offline edit on A")
    }

    /// The app's hold set and the pull's own conflicts are both held.
    func testSync_holdsTheAppsSetAndThePullsConflicts() throws {
        let id = try conflictOnA()
        var other = TestFixtures.richTake()
        other.primaryText = "unrelated"
        other.modifiedAt = t0.addingTimeInterval(45)
        try storeA.upsert(other)

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(report.uploaded, [other.id], "only the Take nobody is waiting on is uploaded")
        XCTAssertEqual(try cloudText(id), "edit on B")
    }
}
