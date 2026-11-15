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

        // A's sync, split where B's sync lands: the pull still sees "base" in the folder. The
        // push is handed the pull's report, as `sync()` hands it over.
        let pulled = try engineA(25).pullInbound()
        var conflictsSeen = pulled.conflicts.count
        conflictsSeen += try engineB(26).sync().conflicts.count
        conflictsSeen += try engineA(27).pushOutbound(afterPull: pulled).conflicts.count
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
    /// The same race through `sync()` itself: B's whole sync runs at the moment A's push starts
    /// (when it reads the lock), after A's pull has read the folder.
    func testSyncNeverUploadsOverAVersionPushedBetweenItsPullAndPush() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "offline edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        var conflictsSeen = 0
        let viewA = InterleavingCloudFolder(cloud)
        viewA.beforeFirstRead(of: SyncLock.fileName) {
            conflictsSeen += try self.engineB(26).sync().conflicts.count
        }
        let syncA = TestFixtures.engine(store: storeA, cloud: viewA, keys: k, deviceId: deviceA,
                                        now: { self.t0.addingTimeInterval(25) })
        conflictsSeen += try syncA.sync().conflicts.count
        XCTAssertTrue(viewA.fired, "B's sync ran between A's pull and push")
        XCTAssertEqual(try cloudText(take.id), "edit on B",
                       "A's push replaced B's newer edit, which A's pull never saw")

        try edit(storeB, take.id, "second edit on B", at: 30)
        conflictsSeen += try engineB(31).sync().conflicts.count
        let next = try engineA(40).sync()
        conflictsSeen += next.conflicts.count
        XCTAssertEqual(next.conflicts.map(\.local.primaryText), ["offline edit on A"],
                       "A's next sync shows its edit against B's as a conflict")
        XCTAssertEqual(next.conflicts.map(\.remote.primaryText), ["second edit on B"])
        XCTAssertEqual(try storeA.take(id: take.id)?.primaryText, "offline edit on A",
                       "A's edit stays on A while the user chooses")
        XCTAssertGreaterThan(conflictsSeen, 0)
    }

    /// Only an edit of A's own is kept back. When A holds just the version its pull found and B
    /// pushes a newer one between the halves, there is nothing to keep: A's push leaves B's
    /// version in the folder, and A's next sync takes it with no conflict.
    func testAPulledVersionIsNotHeldAgainstANewerOnePushedBetweenTheHalves() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeB, take.id, "first edit on B", at: 10)
        try engineB(11).sync()

        let viewA = InterleavingCloudFolder(cloud)
        viewA.beforeFirstRead(of: SyncLock.fileName) {
            try self.edit(self.storeB, take.id, "second edit on B", at: 30)
            _ = try self.engineB(31).sync()
        }
        let first = try TestFixtures.engine(store: storeA, cloud: viewA, keys: k, deviceId: deviceA,
                                            now: { self.t0.addingTimeInterval(25) }).sync()
        XCTAssertTrue(viewA.fired)
        XCTAssertEqual(first.applied, [take.id], "A's pull took B's first edit")
        XCTAssertEqual(try cloudText(take.id), "second edit on B")

        let next = try engineA(40).sync()
        XCTAssertTrue(next.conflicts.isEmpty, "nothing of A's own was waiting")
        XCTAssertEqual(try storeA.take(id: take.id)?.primaryText, "second edit on B")
    }

    /// An edit made on this device between its own pull and push is uploaded as before: the
    /// folder did not change between the halves, so there is nothing of another device's to keep.
    func testAnEditMadeBetweenThisDevicesOwnPullAndPushIsStillUploaded() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()

        let viewA = InterleavingCloudFolder(cloud)
        viewA.beforeFirstRead(of: SyncLock.fileName) {
            try self.edit(self.storeA, take.id, "edited during the sync", at: 24)
        }
        _ = try TestFixtures.engine(store: storeA, cloud: viewA, keys: k, deviceId: deviceA,
                                    now: { self.t0.addingTimeInterval(25) }).sync()
        XCTAssertTrue(viewA.fired)
        XCTAssertEqual(try cloudText(take.id), "edited during the sync")
    }

    /// Found by the TLC model checker (spec/CatchlightSync.cfg). B's pull reads the manifest,
    /// A pushes, then B's pull reads the blob: the bytes no longer match the entry B read, B holds
    /// a newer local edit than that entry, so it reports nothing, and B's push uploads its edit
    /// over A's. A's next pull then takes B's version. One edit on each device is enough.
    func testEditPushedWhileTheOtherDeviceIsMidPullIsNeverLostSilently() throws {
        let folder = MidPullFolder(cloud)
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        var conflictsSeen = 0
        // A's sync started at t0+15, before B's edit, and its push lands inside B's pull.
        folder.beforeFirstBlobRead = {
            conflictsSeen += (try? self.engineA(15).sync().conflicts.count) ?? 0
        }
        let engineBMidPull = TestFixtures.engine(store: storeB, cloud: folder, keys: k, deviceId: deviceB,
                                                 now: { self.t0.addingTimeInterval(26) })
        conflictsSeen += try engineBMidPull.sync().conflicts.count
        conflictsSeen += try engineA(40).sync().conflicts.count
        conflictsSeen += try engineB(41).sync().conflicts.count

        let survives = try storeA.take(id: take.id)?.primaryText == "edit on A"
            || storeB.take(id: take.id)?.primaryText == "edit on A"
            || cloudText(take.id) == "edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's edit was lost with no conflict shown on either device")
    }
}

/// A view of a cloud folder that runs a closure once, just before the first read of one file:
/// how a test lands another device's sync at an exact point inside this device's sync.
private final class InterleavingCloudFolder: CloudFolder {
    private let base: CloudFolder
    private var trigger: (name: String, action: () throws -> Void)?
    private(set) var fired = false

    init(_ base: CloudFolder) { self.base = base }

    func beforeFirstRead(of name: String, _ action: @escaping () throws -> Void) {
        trigger = (name, action)
    }

    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if let t = trigger, t.name == name {
            trigger = nil
            fired = true
            try t.action()
        }
        return try base.read(name)
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

/// Runs `beforeFirstBlobRead` once, just before the first .clk read: another device's sync
/// landing between this device's manifest read and its blob read.
private final class MidPullFolder: CloudFolder {
    private let base: CloudFolder
    var beforeFirstBlobRead: (() -> Void)?
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if name.hasSuffix(".clk"), let hook = beforeFirstBlobRead {
            beforeFirstBlobRead = nil
            hook()
        }
        return try base.read(name)
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
    func secureDelete(_ name: String) throws { try base.secureDelete(name) }
}
