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

    private func cloudTake(_ id: UUID) throws -> Take? {
        guard let bytes = try cloud.read("\(id.uuidString).clk") else { return nil }
        let ct = try XCTUnwrap(CloudBlob.parse(bytes).ciphertext)
        return try TakeCrypto(keys: k).open(ct, takeUUID: id)
    }

    private func edit(_ store: InMemoryTakeStore, _ id: UUID, _ text: String, at: TimeInterval) throws {
        var take = try XCTUnwrap(store.take(id: id))
        take.primaryText = text
        take.modifiedAt = t0.addingTimeInterval(at)
        try store.upsert(take)
    }

    /// One synced Take; A edits offline at t0+10, B edits at t0+20 and syncs; A's sync at t0+30
    /// finds the conflict and holds it. Returns the Take's id.
    private func conflictOnA(obie: Bool = false) throws -> UUID {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        take.isObie = obie
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

    // MARK: - Edge 1: another device's Obie arrives while this device's Obie is held

    /// B makes a new Take the Obie (demoting the held one on its side) and syncs. Applying that
    /// Take as it is would make the store demote and re-stamp A's held Obie. It lands without
    /// the flag instead, and A's push leaves the folder's copy alone, so the flag stays there.
    func testHeld_anIncomingObie_neverDemotesTheHeldObie() throws {
        let id = try conflictOnA(obie: true)
        var demoted = try XCTUnwrap(storeB.take(id: id))
        demoted.isObie = false
        demoted.modifiedAt = t0.addingTimeInterval(40)
        try storeB.upsert(demoted)
        var x = TestFixtures.richTake()
        x.primaryText = "the new Obie, made on B"
        x.modifiedAt = t0.addingTimeInterval(40)
        x.isObie = true
        try storeB.upsert(x)
        try syncB(41)

        let report = try syncA(50, holding: [id])

        let held = try XCTUnwrap(storeA.take(id: id))
        XCTAssertTrue(held.isObie, "the held Obie is not demoted")
        XCTAssertEqual(held.modifiedAt, t0.addingTimeInterval(10), "nor re-stamped")
        XCTAssertEqual(held.primaryText, "offline edit on A")
        XCTAssertEqual(try storeA.currentObie()?.id, id)
        let arrived = try XCTUnwrap(storeA.take(id: x.id), "the incoming Take's content still lands")
        XCTAssertEqual(arrived.primaryText, "the new Obie, made on B")
        XCTAssertFalse(arrived.isObie)
        XCTAssertTrue(report.applied.contains(x.id))
        XCTAssertFalse(report.uploaded.contains(x.id), "the copy without the flag is never sent")
        XCTAssertFalse(report.uploaded.contains(id))
        XCTAssertEqual(try cloudTake(x.id)?.isObie, true, "the folder keeps B's Obie")
    }

    /// Once the hold is lifted the flag lands, and A's copy of the other Take is not a conflict.
    func testHeld_anIncomingObie_landsOnceTheHoldIsLifted() throws {
        let id = try conflictOnA(obie: true)
        var demoted = try XCTUnwrap(storeB.take(id: id))
        demoted.isObie = false
        demoted.modifiedAt = t0.addingTimeInterval(40)
        try storeB.upsert(demoted)
        var x = TestFixtures.richTake()
        x.modifiedAt = t0.addingTimeInterval(40)
        x.isObie = true
        try storeB.upsert(x)
        try syncB(41)
        try syncA(50, holding: [id])
        try syncA(52, holding: [id])   // still held: still waiting, nothing reported
        // The user keeps B's version: what ConflictQueue.resolve writes.
        var kept = try XCTUnwrap(storeB.take(id: id))
        kept.modifiedAt = t0.addingTimeInterval(55)
        try storeA.upsert(kept)

        let report = try syncA(60)

        XCTAssertEqual(try storeA.currentObie()?.id, x.id)
        XCTAssertTrue(report.applied.contains(x.id))
        XCTAssertEqual(report.conflicts.count, 0, "a flag that waited is not a conflict")
    }

    // MARK: - Edge 2: a held Take with no entry in the folder

    /// A held Take the folder has no entry for is never uploaded.
    func testHeld_withNoEntryInTheFolder_isNotUploaded() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "never sent"
        take.modifiedAt = t0
        try storeA.upsert(take)

        let report = try syncA(10, holding: [take.id])

        XCTAssertEqual(report.uploaded, [])
        XCTAssertNil(try cloudText(take.id))
    }

    /// B deletes the held Take, so its entry goes; A edits it again after that deletion. Held,
    /// the edit does not win over the deletion yet: nothing is uploaded and the record stays.
    func testHeld_editedAfterARemoteDeletion_isNotUploaded_andTheDeletionRecordStays() throws {
        let id = try conflictOnA()
        try storeB.delete(id: id)
        try TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB,
                                now: { Date() }).sync()
        var take = try XCTUnwrap(storeA.take(id: id))
        take.primaryText = "edited after B deleted it"
        take.modifiedAt = Date().addingTimeInterval(60)
        try storeA.upsert(take)

        let report = try syncA(50, holding: [id])

        XCTAssertFalse(report.uploaded.contains(id))
        XCTAssertNil(try cloudText(id))
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: k).tombstones.map(\.uuid), [id],
                       "a device that has not seen the deletion yet must still find it")

        // Resolved, the edit wins over the deletion as usual.
        take.modifiedAt = Date().addingTimeInterval(120)
        try storeA.upsert(take)
        try syncA(60)
        XCTAssertEqual(try cloudText(id), "edited after B deleted it")
    }

    // MARK: - Edge 3: another device turns a held Take into a Script

    /// The shape a desktop conversion leaves: same id, entry marked Script, new stamp, and a
    /// file the phone must never read (garbage here, so reading it would show in the report).
    private func convertToScript(_ id: UUID, modified: TimeInterval) throws {
        var manifest = try Manifest.readEncrypted(from: cloud, keys: k)
        manifest.takes = manifest.takes.map { e in
            e.uuid == id ? ManifestEntry(uuid: e.uuid, modified: ISO8601.string(from: t0.addingTimeInterval(modified)),
                                         hmac: e.hmac, kind: ManifestEntry.Kind.script) : e
        }
        try Manifest.writeEncrypted(manifest, to: cloud, keys: k)
        try cloud.write(Data("the Mac's Script".utf8), to: "\(id.uuidString).clk")
    }

    private func scriptEntry(_ id: UUID) throws -> ManifestEntry? {
        try Manifest.readEncrypted(from: cloud, keys: k).takes.first { $0.uuid == id }
    }

    /// Unchanged here since the last sync, the Take would be let go. Held, it stays.
    func testHeld_turnedIntoAScriptElsewhere_isNotLetGo() throws {
        let id = try conflictOnA()
        try convertToScript(id, modified: 40)
        let entryBefore = try scriptEntry(id)

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "offline edit on A")
        XCTAssertEqual(report.deletedLocally, [])
        XCTAssertEqual(report.heldConverted, [id], "the app learns its pair's other side is now a Script")
        XCTAssertEqual(report.conflicts.count, 0, "the Script is never read, so there is no pair to show")
        XCTAssertEqual(report.quarantined, [])
        XCTAssertEqual(try scriptEntry(id), entryBefore)
        XCTAssertEqual(try cloud.read("\(id.uuidString).clk"), Data("the Mac's Script".utf8))
    }

    /// Edited here since the last sync and changed there too, the Take would be forked: a new
    /// Take made from it and the original let go. Held, neither happens.
    func testHeld_editedAndTurnedIntoAScriptElsewhere_isNotForked() throws {
        let id = try conflictOnA()
        try edit(storeA, id, "second edit on A", at: 40)
        try convertToScript(id, modified: 45)

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "second edit on A")
        XCTAssertEqual(report.forkedFromScripts, [])
        XCTAssertEqual(report.deletedLocally, [])
        XCTAssertEqual(try storeA.allTakes().count, 1, "no copy was made")
        XCTAssertEqual(report.heldConverted, [id])
        XCTAssertEqual(try cloud.read("\(id.uuidString).clk"), Data("the Mac's Script".utf8))
    }

    /// The Script has not changed since the last sync and the held Take has: push would send
    /// the edit into the Script. Held, the Script's file and entry stay exactly as they were.
    func testHeld_editedWhileItsEntryIsAnUnchangedScript_isNotSentIntoTheScript() throws {
        let id = try conflictOnA()
        try convertToScript(id, modified: 25)
        let entryBefore = try scriptEntry(id)
        try edit(storeA, id, "second edit on A", at: 40)

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(try scriptEntry(id), entryBefore)
        XCTAssertEqual(try cloud.read("\(id.uuidString).clk"), Data("the Mac's Script".utf8))
        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "second edit on A")
    }

    // MARK: - Review of #29

    /// Review of #29: this device's Obie O meets its conflict in the SAME pass that brings
    /// another device's Obie X, and X sorts first in the folder's index. O isn't in the app's hold
    /// set yet, so only the pull itself can know it must not be demoted. It must look at O first.
    func testObieConflictFoundInTheSamePassAsAnIncomingObie_isNotDemoted() throws {
        var o = TestFixtures.richTake(id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!)   // sorts last in the index
        o.primaryText = "base"
        o.modifiedAt = t0
        o.isObie = true
        try storeA.upsert(o)
        try syncA(1)
        try syncB(2)
        try edit(storeA, o.id, "offline edit on A", at: 10)
        var x = TestFixtures.richTake(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)   // sorts first
        x.primaryText = "the new Obie, made on B"
        x.modifiedAt = t0.addingTimeInterval(20)
        x.isObie = true
        try storeB.upsert(x)   // B's store demotes and re-stamps O
        try syncB(21)

        let report = try syncA(30)

        let mine = try XCTUnwrap(storeA.take(id: o.id))
        XCTAssertTrue(mine.isObie, "A's Obie is not demoted while its conflict waits")
        XCTAssertEqual(mine.modifiedAt, t0.addingTimeInterval(10), "nor re-stamped")
        XCTAssertEqual(mine.primaryText, "offline edit on A")
        XCTAssertEqual(report.conflicts.map(\.local.id), [o.id])
        XCTAssertEqual(try storeA.take(id: x.id)?.isObie, false, "X lands without the flag")
    }

    /// Review of #29: a held Take's deletion record outlives the retention window while held,
    /// or the folder would keep neither its entry nor its record.
    func testHeld_aDeletionRecordPastRetention_staysWhileHeld() throws {
        let id = try conflictOnA()
        try storeB.delete(id: id)
        try TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB, now: { Date() }).sync()
        let long = Date().addingTimeInterval(Manifest.tombstoneRetention + 86_400)

        try TestFixtures.engine(store: storeA, cloud: cloud, keys: k, deviceId: deviceA, now: { long })
            .sync(holding: [id])

        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: k).tombstones.map(\.uuid), [id])
        XCTAssertNotNil(try storeA.take(id: id))
    }

}
