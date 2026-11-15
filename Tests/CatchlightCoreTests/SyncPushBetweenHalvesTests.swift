//
//  SyncPushBetweenHalvesTests.swift
//  CatchlightCoreTests
//
//  Found while writing the TLA+ model of sync (spec/CatchlightSync.tla). `sync()` runs the
//  pull and then the push, but another device can push in between: the pull reads every blob
//  in the folder first, so the window is as long as the pull. Push step 1 uploads every Take
//  changed since the last sync without comparing it with the folder's entry, so this device's
//  edit replaces the other device's newer one, which its own pull never saw.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncPushBetweenHalvesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    private func engineA(_ at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: storeA, cloud: cloud, keys: k, deviceId: deviceA,
                            now: { self.t0.addingTimeInterval(at) })
    }

    private func engineB(_ at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: storeB, cloud: cloud, keys: k, deviceId: deviceB,
                            now: { self.t0.addingTimeInterval(at) })
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

    /// A's offline edit must survive somewhere the user can see it: on a device, in the folder,
    /// or as a conflict. Here it ends up in none of them, and neither device reports anything.
    func testEditPushedBetweenTheOtherDevicesPullAndPushIsNeverLostSilently() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "offline edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        // A's sync, split where B's sync lands: the pull still sees "base" in the folder.
        var conflictsSeen = try engineA(25).pullInbound().conflicts.count
        conflictsSeen += try engineB(26).sync().conflicts.count
        conflictsSeen += try engineA(27).pushOutbound().conflicts.count
        XCTAssertEqual(try cloudText(take.id), "edit on B",
                       "A's push replaced B's newer edit, which A's pull never saw")

        // B keeps writing on top of its own version, as a user would.
        try edit(storeB, take.id, "second edit on B", at: 30)
        conflictsSeen += try engineB(31).sync().conflicts.count
        conflictsSeen += try engineA(40).sync().conflicts.count

        let survives = try storeA.take(id: take.id)?.primaryText == "offline edit on A"
            || storeB.take(id: take.id)?.primaryText == "offline edit on A"
            || cloudText(take.id) == "offline edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's offline edit was lost with no conflict shown on either device")
    }
}
