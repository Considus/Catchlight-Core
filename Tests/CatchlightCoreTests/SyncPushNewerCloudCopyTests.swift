//
//  SyncPushNewerCloudCopyTests.swift
//  CatchlightCoreTests
//
//  R4 follow-up (2026-10-05): A edits a Take offline while B edits the same Take and syncs
//  first. A's pull reports the conflict for the user to resolve, and A's push must leave the
//  cloud copy alone until the user picks a version, whichever edit is the later one. Before
//  the fix the push uploaded A's edit over B's in the same sync.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncPushNewerCloudCopyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    @discardableResult
    private func syncA(_ at: TimeInterval) throws -> SyncReport {
        try TestFixtures.engine(store: storeA, cloud: cloud, keys: k, deviceId: deviceA,
                                now: { self.t0.addingTimeInterval(at) }).sync()
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

    /// Both devices hold one synced Take; A edits it offline at `offlineAt`, B edits it at
    /// t0+20 and syncs at t0+21. Returns the Take's id.
    private func diverge(offlineAt: TimeInterval) throws -> UUID {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try syncA(1)
        try syncB(2)

        var offline = take
        offline.primaryText = "offline edit on A"
        offline.modifiedAt = t0.addingTimeInterval(offlineAt)
        try storeA.upsert(offline)

        var newer = try XCTUnwrap(storeB.take(id: take.id))
        newer.primaryText = "edit on B"
        newer.modifiedAt = t0.addingTimeInterval(20)
        try storeB.upsert(newer)
        try syncB(21)
        return take.id
    }

    private func assertHeldForTheUser(_ id: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let first = try syncA(30)
        XCTAssertEqual(first.conflicts.map(\.local.id), [id], "the conflict must reach the user", file: file, line: line)
        XCTAssertEqual(try cloudText(id), "edit on B",
                       "A's push replaced B's version before the user chose", file: file, line: line)

        // B is left alone, and A keeps asking until the user chooses.
        let b = try syncB(40)
        XCTAssertTrue(b.conflicts.isEmpty, file: file, line: line)
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "edit on B", file: file, line: line)
        let again = try syncA(50)
        XCTAssertEqual(again.conflicts.map(\.local.id), [id], file: file, line: line)
        XCTAssertEqual(try cloudText(id), "edit on B", file: file, line: line)
        XCTAssertEqual(try storeA.take(id: id)?.primaryText, "offline edit on A", file: file, line: line)
    }

    /// A's offline edit is the OLDER one.
    func testOfflineEditOlderThanCloudCopy_isHeldUntilTheUserChooses() throws {
        let id = try diverge(offlineAt: 10)
        try assertHeldForTheUser(id)
    }

    /// A's offline edit is the NEWER one: still the user's choice, not the later date's.
    func testOfflineEditNewerThanCloudCopy_isHeldUntilTheUserChooses() throws {
        let id = try diverge(offlineAt: 25)
        try assertHeldForTheUser(id)
    }

    /// The user keeps A's version. `ConflictQueue.resolve` stamps the winner as a fresh edit,
    /// and the next sync uploads it and settles both devices.
    func testResolvingTheConflict_uploadsTheChosenVersion() throws {
        let id = try diverge(offlineAt: 10)
        try assertHeldForTheUser(id)

        var winner = try XCTUnwrap(storeA.take(id: id))
        winner.modifiedAt = t0.addingTimeInterval(55)
        try storeA.upsert(winner)

        let resolved = try syncA(60)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(try cloudText(id), "offline edit on A")
        let b = try syncB(70)
        XCTAssertTrue(b.conflicts.isEmpty)
        XCTAssertEqual(try storeB.take(id: id)?.primaryText, "offline edit on A")
    }

}
