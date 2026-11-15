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

    /// The other device's version is in the manifest but its file can't be read yet (provider
    /// lag), and that device's clock runs ahead. Push must not upload over a version it cannot
    /// see, and must keep this edit counted as unsynced: if the watermark moved past it, the next
    /// pull would read the other version as the only change and write it over this edit.
    func testEditIsKeptWhenTheOtherDevicesVersionCannotBeReadYet() throws {
        let folder = HidingFolder(cloud)
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 30)
        try engineB(31).sync()

        folder.hideBlobs = true
        let engineAHidden = TestFixtures.engine(store: storeA, cloud: folder, keys: k, deviceId: deviceA,
                                                now: { self.t0.addingTimeInterval(27) })
        var conflictsSeen = try engineAHidden.sync().conflicts.count
        XCTAssertEqual(try cloudText(take.id), "edit on B",
                       "A uploaded over B's version without being able to read it")

        folder.hideBlobs = false
        conflictsSeen += try engineA(40).sync().conflicts.count
        XCTAssertEqual(try storeA.take(id: take.id)?.primaryText == "edit on A" || conflictsSeen > 0, true,
                       "A's edit was replaced by B's with no conflict shown")
        XCTAssertGreaterThan(conflictsSeen, 0, "both devices changed the Take, so A must see a conflict")
    }

    /// The other side of the rule: an edit made between the pull and the push of one sync, on
    /// top of the version that pull has just brought in, is this device building on what it has
    /// seen. It uploads with no conflict, as it did before push learned to check the folder.
    func testEditOnTopOfAVersionThisSyncPulledUploadsWithoutConflict() throws {
        let folder = SecondManifestReadFolder(cloud)
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engineA(1).sync()
        try engineB(2).sync()

        try edit(storeA, take.id, "edit on A", at: 10)
        try engineA(11).sync()

        // B's sync pulls A's edit; the user edits it before B's push reads the folder.
        folder.beforeSecondManifestRead = { try? self.edit(self.storeB, take.id, "B builds on A's edit", at: 15) }
        let engineBWithEdit = TestFixtures.engine(store: storeB, cloud: folder, keys: k, deviceId: deviceB,
                                                  now: { self.t0.addingTimeInterval(20) })
        let report = try engineBWithEdit.sync()
        XCTAssertEqual(report.conflicts.count, 0, "B had seen A's version, so there is nothing to choose between")
        XCTAssertEqual(try cloudText(take.id), "B builds on A's edit")
    }
}

/// Runs `beforeSecondManifestRead` once, just before the second manifest read: in `sync()`,
/// between the pull and the push.
private final class SecondManifestReadFolder: CloudFolder {
    private let base: CloudFolder
    private var manifestReads = 0
    var beforeSecondManifestRead: (() -> Void)?
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if name == Manifest.fileName {
            manifestReads += 1
            if manifestReads == 2 { beforeSecondManifestRead?() }
        }
        return try base.read(name)
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
    func secureDelete(_ name: String) throws { try base.secureDelete(name) }
}

/// Hides every .clk from reads while `hideBlobs` is set: a file the manifest names that the
/// provider has not delivered yet. Writes go through.
private final class HidingFolder: CloudFolder {
    private let base: CloudFolder
    var hideBlobs = false
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        if hideBlobs, name.hasSuffix(".clk") { return nil }
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
