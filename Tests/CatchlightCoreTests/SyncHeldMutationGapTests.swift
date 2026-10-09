//
//  SyncHeldMutationGapTests.swift
//  CatchlightCoreTests
//
//  The 2026-10-09 mutation run over the hold added since Core 1.2.1 (the `heldIDs` checks in
//  pullInbound, pushOutbound and sync): each test here kills a one-line change that survived
//  the whole suite. The comment on each names the file and the rule it guards.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncHeldMutationGapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    private func engineA(_ at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: storeA, cloud: cloud, keys: k, deviceId: deviceA,
                            now: { self.t0.addingTimeInterval(at) })
    }

    @discardableResult
    private func syncA(_ at: TimeInterval, holding: Set<UUID> = []) throws -> SyncReport {
        try engineA(at).sync(holding: holding)
    }

    @discardableResult
    private func syncB(_ at: TimeInterval) throws -> SyncReport {
        try TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB,
                                now: { self.t0.addingTimeInterval(at) }).sync()
    }

    private func edit(_ store: InMemoryTakeStore, _ id: UUID, _ text: String, at: TimeInterval) throws {
        var take = try XCTUnwrap(store.take(id: id))
        take.primaryText = text
        take.modifiedAt = t0.addingTimeInterval(at)
        try store.upsert(take)
    }

    /// One synced Take; A edits offline at t0+10, B edits at t0+20 and syncs; A's sync at t0+30
    /// finds the conflict, and A's last sync is t0+30. Returns the Take's id.
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
        XCTAssertEqual(try syncA(30).conflicts.map(\.local.id), [take.id])
        return take.id
    }

    // MARK: - Which remote versions refresh a held conflict

    /// SyncEngine.swift (pullInbound) — a held conflict is reported again only for a remote
    /// version newer than the last sync. The version the user is already choosing against is
    /// not raised a second time on every pass.
    func testHeld_anUnchangedRemoteVersion_isNotReportedAgain() throws {
        let id = try conflictOnA()

        let report = try syncA(40, holding: [id])

        XCTAssertEqual(report.conflicts.map(\.local.id), [])
    }

    /// SyncEngine.swift (pullInbound) — "newer" is newer than the LAST SYNC, not newer than
    /// the held copy. An edit on A after the conflict does not hide B's later version from
    /// the pair the user is choosing between.
    func testHeld_aNewerRemoteVersion_isReported_evenWhenTheHeldCopyIsNewerStill() throws {
        let id = try conflictOnA()
        try edit(storeB, id, "second edit on B", at: 40)
        try syncB(41)
        try edit(storeA, id, "second edit on A", at: 45)

        let report = try syncA(50, holding: [id])

        XCTAssertEqual(report.conflicts.map(\.remote.primaryText), ["second edit on B"])
        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "second edit on A")
    }

    /// SyncEngine.swift (pullInbound) — a remote version stamped exactly AT the last sync is
    /// not newer than it, as everywhere else in the engine (`ConflictResolver` reads a change
    /// as `modifiedAt > lastSync`). The hold uses the same boundary.
    func testHeld_aRemoteVersionStampedAtTheLastSync_isNotNewer() throws {
        let id = try conflictOnA()
        try edit(storeB, id, "edit on B at the moment of A's sync", at: 30)
        try syncB(31)

        let report = try syncA(40, holding: [id])

        XCTAssertEqual(report.conflicts.map(\.local.id), [])
    }

    /// SyncEngine.swift (pullInbound) — with no last sync recorded, every remote version is
    /// newer, so a held Take whose remote copy differs is reported. Nothing is skipped for want
    /// of a watermark.
    func testHeld_withNoLastSync_aDifferingRemoteVersionIsReported() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "on B"
        take.modifiedAt = t0
        try storeB.upsert(take)
        try syncB(1)
        take.primaryText = "on A, never synced"
        take.modifiedAt = t0.addingTimeInterval(5)
        try storeA.upsert(take)
        XCTAssertNil(storeA.lastSyncDate())

        let report = try engineA(10).pullInbound(holding: [take.id])

        XCTAssertEqual(report.conflicts.map(\.remote.primaryText), ["on B"])
        XCTAssertEqual(try storeA.take(id: take.id)?.primaryText, "on A, never synced")
    }

    /// SyncEngine.swift (pullInbound) — a held Take is never reported as conflicting with an
    /// identical copy of itself. The folder can hold this device's own version stamped after
    /// its last sync: the watermark is taken before the push reads the changed Takes, so an
    /// edit made during the push is uploaded and still reads as newer than the last sync.
    func testHeld_aRemoteCopyIdenticalToTheHeldOne_isNotAConflict() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try syncA(1)
        try edit(storeA, take.id, "edited during the push", at: 40)
        try syncA(35)   // the push uploads the t0+40 edit; the watermark is t0+35

        let report = try syncA(50, holding: [take.id])

        XCTAssertEqual(report.conflicts.map(\.local.id), [])
    }
}
