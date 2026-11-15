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

    /// Found by the TLC model checker with the step-1 fix modelled (FixedPushStep1). The lock is
    /// advisory: with cloud propagation delay, B cannot see A's lock yet and syncs while A's push
    /// is between its blob write and its manifest write. Neither push sees the other's change, and
    /// the later manifest write leaves A's edit with no conflict on either device.
    func testEditLostWhenTwoPushesPassTheLockTogether() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "edit on A", at: 10)

        var conflictsSeen = 0
        let folderA = AfterFirstBlobWriteFolder(cloud)
        folderA.afterFirstBlobWrite = {
            try? self.edit(self.storeB, take.id, "edit on B", at: 20)
            let lagged = LockNotYetVisibleFolder(self.cloud)
            let engineB = TestFixtures.engine(store: self.storeB, cloud: lagged, keys: self.k, deviceId: self.deviceB,
                                              now: { self.t0.addingTimeInterval(21) })
            let report = try? engineB.sync()
            XCTAssertEqual(report?.pushDeferred, false, "B's push must pass the lock for this race")
            conflictsSeen += report?.conflicts.count ?? 0
        }
        let engineAInPush = TestFixtures.engine(store: storeA, cloud: folderA, keys: k, deviceId: deviceA,
                                                now: { self.t0.addingTimeInterval(15) })
        conflictsSeen += try engineAInPush.sync().conflicts.count
        for at in stride(from: 40.0, through: 60.0, by: 10.0) {
            conflictsSeen += try engineB(at).sync().conflicts.count
            conflictsSeen += try engineA(at + 1).sync().conflicts.count
        }

        let survives = try storeA.take(id: take.id)?.primaryText == "edit on A"
            || storeB.take(id: take.id)?.primaryText == "edit on A"
            || cloudText(take.id) == "edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's edit was lost with no conflict shown on either device")
    }

    /// Found by the TLC model checker (with the step-1 and unverified fixes modelled). A pass that
    /// cannot read the Take's file yet (not downloaded: `skipped`) still moves the watermark past
    /// the other device's version without applying it. That version then looks already seen, so
    /// this device's next edit, made on the old version, is kept and uploaded over it.
    func testSkippedBlobDoesNotLetTheNextEditOverwriteAnUnseenVersion() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "edit on A", at: 10)
        try engineA(11).sync()

        // B's pass finds A's version declared but its file not downloaded yet.
        let notYet = BlobNotYetDownloadedFolder(cloud)
        let skipped = try TestFixtures.engine(store: storeB, cloud: notYet, keys: k, deviceId: deviceB,
                                              now: { self.t0.addingTimeInterval(20) }).sync()
        XCTAssertEqual(skipped.skipped, [take.id], "the setup: B skipped A's version")

        var conflictsSeen = 0
        try edit(storeB, take.id, "edit on B, made on base", at: 30)
        conflictsSeen += try engineB(31).sync().conflicts.count
        conflictsSeen += try engineA(40).sync().conflicts.count
        conflictsSeen += try engineB(41).sync().conflicts.count

        let survives = try storeA.take(id: take.id)?.primaryText == "edit on A"
            || storeB.take(id: take.id)?.primaryText == "edit on A"
            || cloudText(take.id) == "edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's edit was lost with no conflict shown on either device")
    }

    /// Found by reading a TLC convergence trace. No overlapping syncs: A edits offline, B syncs
    /// (nothing new), A comes back online and syncs, B edits and syncs. B's watermark is the time
    /// of B's last sync, but A's version carries the time A made the edit, which is earlier, so
    /// B reads it as unchanged since its last sync, keeps its own edit and uploads it over A's.
    func testOfflineEditUploadedAfterTheOtherDevicesSyncIsNeverLostSilently() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "offline edit on A", at: 10)   // A is offline
        var conflictsSeen = try engineB(20).sync().conflicts.count
        conflictsSeen += try engineA(30).sync().conflicts.count  // A back online
        XCTAssertEqual(try cloudText(take.id), "offline edit on A", "the setup: A's edit reached the folder")

        try edit(storeB, take.id, "edit on B", at: 40)
        conflictsSeen += try engineB(41).sync().conflicts.count
        conflictsSeen += try engineA(50).sync().conflicts.count
        conflictsSeen += try engineB(51).sync().conflicts.count

        let survives = try storeA.take(id: take.id)?.primaryText == "offline edit on A"
            || storeB.take(id: take.id)?.primaryText == "offline edit on A"
            || cloudText(take.id) == "offline edit on A"
            || conflictsSeen > 0
        XCTAssertTrue(survives, "A's offline edit was lost with no conflict shown on either device")
    }
}

/// The folder as a device sees it before a file has downloaded: every .clk read finds nothing.
private final class BlobNotYetDownloadedFolder: CloudFolder {
    private let base: CloudFolder
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { name.hasSuffix(".clk") ? nil : try base.read(name) }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
    func secureDelete(_ name: String) throws { try base.secureDelete(name) }
}

/// Runs `afterFirstBlobWrite` once, just after the first .clk write: inside a push, before its
/// manifest write.
private final class AfterFirstBlobWriteFolder: CloudFolder {
    private let base: CloudFolder
    var afterFirstBlobWrite: (() -> Void)?
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { try base.read(name) }
    func write(_ data: Data, to name: String) throws {
        try base.write(data, to: name)
        if name.hasSuffix(".clk"), let hook = afterFirstBlobWrite {
            afterFirstBlobWrite = nil
            hook()
        }
    }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
    func secureDelete(_ name: String) throws { try base.secureDelete(name) }
}

/// The folder as a device sees it before another device's lock file has reached it: the first
/// read of the lock finds nothing. Everything else, including its own lock read-back, is current.
private final class LockNotYetVisibleFolder: CloudFolder {
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
    func secureDelete(_ name: String) throws { try base.secureDelete(name) }
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
