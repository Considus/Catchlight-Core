import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

/// The two lock-race paths left after `builtOn` (spec/CatchlightSyncRecordsRaces.cfg): two pushes
/// pass the advisory lock at once, and
///   • one writes its older edit back over the other's newer deletion, after that device has seen
///     the deletion listed and stopped keeping it, so the Take comes back there;
///   • the Take's one file is written by one push and its entry by the other, so the folder lists
///     a version whose file holds another, and the device that can't read it writes over it.
final class SyncRaceFileAndDeletionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    private func engine(_ s: InMemoryTakeStore, _ c: CloudFolder, _ d: UUID, _ at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: s, cloud: c, keys: k, deviceId: d, now: { self.t0.addingTimeInterval(at) })
    }
    private func manifest() throws -> Manifest { try Manifest.readEncrypted(from: cloud, keys: k) }
    private func cloudText(_ id: UUID) throws -> String? {
        guard try manifest().takes.contains(where: { $0.uuid == id }),
              let bytes = try cloud.read("\(id.uuidString).clk"),
              let ct = try CloudBlob.parse(bytes).ciphertext else { return nil }
        return try? TakeCrypto(keys: k).open(ct, takeUUID: id).primaryText
    }
    private func edit(_ store: InMemoryTakeStore, _ id: UUID, _ text: String, at: TimeInterval) throws {
        var take = try XCTUnwrap(store.take(id: id))
        take.primaryText = text
        take.modifiedAt = t0.addingTimeInterval(at)
        try store.upsert(take)
    }
    private func syncedTake() throws -> Take {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engine(storeA, cloud, deviceA, 1).sync()
        try engine(storeB, cloud, deviceB, 2).sync()
        return take
    }

    // MARK: - A deletion written over by a racing push

    /// A edits, B deletes later. A's push reads the manifest before B's deletion lands, B syncs
    /// twice (the second sees its deletion listed), then A's push writes its edit back with no
    /// deletion record. The deletion is newer, so B must not take the Take back.
    func testDeletionWrittenOverByARacingOlderEdit_doesNotComeBack() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 10)
        try storeB.delete(id: take.id)   // InMemoryTakeStore stamps the deletion with the wall clock
        let deletedAt = try XCTUnwrap(storeB.tombstones().first?.deletedAt)
        XCTAssertGreaterThan(deletedAt, t0.addingTimeInterval(10), "the deletion must be newer than A's edit")

        let blindB = LockBlindFolder(cloud)
        let viewA = NthReadFolder(cloud, name: Manifest.fileName, n: 2) {   // 1 = pull, 2 = push
            try self.engine(self.storeB, blindB, self.deviceB, 21).sync()
            try self.engine(self.storeB, blindB, self.deviceB, 22).sync()   // sees its deletion listed
        }
        try engine(storeA, viewA, deviceA, 15).sync()
        XCTAssertTrue(viewA.fired)
        XCTAssertNotNil(try manifest().takes.first(where: { $0.uuid == take.id }), "the race did not happen")

        try engine(storeB, cloud, deviceB, 30).sync()
        XCTAssertNil(try storeB.take(id: take.id), "B's newer deletion was undone by an older edit")
        try engine(storeA, cloud, deviceA, 40).sync()
        XCTAssertNil(try storeA.take(id: take.id), "the newer deletion never reached A")
        XCTAssertNil(try manifest().takes.first(where: { $0.uuid == take.id }))
    }

    /// A deletion is kept after the folder confirms it, but its file is deleted once: later pushes
    /// don't ask the folder to delete a file that is already gone.
    func testKeptDeletion_deletesItsFileOnce() throws {
        let take = try syncedTake()
        try storeB.delete(id: take.id)
        let counting = CountingFolder(cloud)
        try engine(storeB, counting, deviceB, 10).sync()
        XCTAssertEqual(counting.blobDeletes, 1)
        try engine(storeB, counting, deviceB, 11).sync()   // sees it listed; keeps the deletion
        try engine(storeB, counting, deviceB, 12).sync()
        XCTAssertEqual(counting.blobDeletes, 1, "the gone file was deleted again")
        XCTAssertEqual(try storeB.tombstones().map(\.id), [take.id])
    }

    /// A deletion the folder never confirmed is kept past retention, as before: it alone stops
    /// the pull bringing the Take back from a folder that still lists it. Only confirmed
    /// deletions go once past retention.
    func testUnconfirmedDeletion_isKeptPastRetention() throws {
        let take = try syncedTake()
        try storeB.delete(id: take.id)
        let deletedAt = try XCTUnwrap(storeB.tombstones().first?.deletedAt)
        let pastRetention = deletedAt.timeIntervalSince(t0) + Manifest.tombstoneRetention + 3600
        try engine(storeB, cloud, deviceB, pastRetention).pullInbound()   // the folder still lists it
        XCTAssertEqual(try storeB.tombstones().map(\.id), [take.id], "an unconfirmed deletion was dropped")
        XCTAssertNil(try storeB.take(id: take.id))
    }

    // MARK: - The Take's file and its entry written by different pushes

    /// A's push writes its file, then B's whole sync runs before A writes the manifest: B finds a
    /// file newer than the entry and repairs it with the version the entry names. A's entry then
    /// names a file holding B's copy. B can't read A's version and shows it as couldn't-verify;
    /// the user edits on. B must not count A's version as had and write over it: A repairs its
    /// file on its next sync, and B then shows the conflict.
    func testVersionWhoseFileWasRepairedOver_isNeverWrittenOver() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 10)
        let blindB = LockBlindFolder(cloud)
        let viewA = BeforeManifestWriteFolder(cloud) { try self.engine(self.storeB, blindB, self.deviceB, 12).sync() }
        try engine(storeA, viewA, deviceA, 11).sync()
        XCTAssertTrue(viewA.fired)

        let shown = try engine(storeB, cloud, deviceB, 20).sync()
        XCTAssertEqual(shown.unverified.map(\.id), [take.id], "the race did not leave the file and entry apart")
        try edit(storeB, take.id, "edit on B", at: 25)
        let next = try engine(storeB, cloud, deviceB, 26).sync()
        XCTAssertEqual(next.unverified.count, 0, "asked again about a version the user already acted on")
        var conflictsSeen = next.conflicts.count
        XCTAssertNotEqual(try cloudText(take.id), "edit on B", "B wrote over a version it never read")

        try engine(storeA, cloud, deviceA, 30).sync()                                   // repairs its file
        conflictsSeen += try engine(storeB, cloud, deviceB, 31).sync().conflicts.count
        let texts = [try storeA.take(id: take.id)?.primaryText, try storeB.take(id: take.id)?.primaryText,
                     try cloudText(take.id)]
        XCTAssertTrue(texts.contains("edit on A"), "A's edit is gone: \(texts)")
        XCTAssertGreaterThan(conflictsSeen, 0, "B's edit and A's version were never shown together")
    }

    /// The other order: B's push writes its file, A's whole sync writes A's file and entry, then
    /// B's manifest write lands. The folder lists B's version and holds A's file. A can't read
    /// B's version, so shows it as couldn't-verify; the user edits on. A must not then count B's
    /// version as one it has had and write over it: it waits until B repairs the file, then
    /// shows the conflict.
    func testVersionOnlyShownAsCouldntVerify_isNeverWrittenOver() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        let blindA = LockBlindFolder(cloud)
        let viewB = BeforeManifestWriteFolder(cloud) {
            try self.engine(self.storeA, blindA, self.deviceA, 21).sync()
        }
        try engine(storeB, viewB, deviceB, 20.5).sync()
        XCTAssertTrue(viewB.fired)
        XCTAssertEqual(try manifest().takes.first(where: { $0.uuid == take.id })?.modified,
                       ISO8601.string(from: t0.addingTimeInterval(20)), "the folder should list B's version")

        let shown = try engine(storeA, cloud, deviceA, 30).sync()
        XCTAssertEqual(shown.unverified.map(\.id), [take.id], "A should be unable to read B's version")
        try edit(storeA, take.id, "edit on A, carried on", at: 31)
        let next = try engine(storeA, cloud, deviceA, 32).sync()
        XCTAssertEqual(next.unverified.count, 0, "asked again about a version the user already acted on")
        var conflictsSeen = next.conflicts.count
        XCTAssertNotEqual(try cloudText(take.id), "edit on A, carried on", "A wrote over a version it never read")

        conflictsSeen += try engine(storeB, cloud, deviceB, 40).sync().conflicts.count   // repairs its file
        conflictsSeen += try engine(storeA, cloud, deviceA, 41).sync().conflicts.count
        let texts = [try storeA.take(id: take.id)?.primaryText, try storeB.take(id: take.id)?.primaryText,
                     try cloudText(take.id)]
        XCTAssertTrue(texts.contains("edit on B"), "B's edit is gone: \(texts)")
        XCTAssertGreaterThan(conflictsSeen, 0, "A's later edit and B's version were never shown together")
    }

    /// The same folder, seen by a third device that never had the Take: it can read only the file,
    /// an older version than the entry names. Its user keeps that copy (a fresh stamp, as the
    /// app's "Keep" does). The version the folder lists was never read here, so this device must
    /// not upload over it.
    func testVersionOnlyShownAsCouldntVerify_onADeviceWithoutTheTake_isNeverWrittenOver() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)
        let blindA = LockBlindFolder(cloud)
        let viewB = BeforeManifestWriteFolder(cloud) { try self.engine(self.storeA, blindA, self.deviceA, 21).sync() }
        try engine(storeB, viewB, deviceB, 20.5).sync()
        let listed = try XCTUnwrap(manifest().takes.first(where: { $0.uuid == take.id })?.modified)

        let storeC = InMemoryTakeStore(), deviceC = UUID()
        let shown = try engine(storeC, cloud, deviceC, 30).sync()
        let copy = try XCTUnwrap(shown.unverified.first?.cloud)
        try engine(storeC, cloud, deviceC, 31).sync()   // nothing chosen yet
        var kept = copy
        kept.modifiedAt = t0.addingTimeInterval(32)
        try storeC.upsert(kept)
        try engine(storeC, cloud, deviceC, 33).sync()
        XCTAssertEqual(try manifest().takes.first(where: { $0.uuid == take.id })?.modified, listed,
                       "a device that never read the listed version uploaded over it")
    }
}

private final class LockBlindFolder: CloudFolder {
    let base: CloudFolder
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles().filter { $0 != SyncLock.fileName } }
    func read(_ name: String) throws -> Data? { name == SyncLock.fileName ? lock : try base.read(name) }
    private var lock: Data?
    func write(_ data: Data, to name: String) throws { if name == SyncLock.fileName { lock = data } else { try base.write(data, to: name) } }
    func writeAtomically(_ data: Data, to name: String) throws { try write(data, to: name) }
    func delete(_ name: String) throws { if name == SyncLock.fileName { lock = nil } else { try base.delete(name) } }
}

private final class NthReadFolder: CloudFolder {
    let base: CloudFolder; let name: String; var n: Int; let action: () throws -> Void
    private(set) var fired = false
    init(_ base: CloudFolder, name: String, n: Int, _ action: @escaping () throws -> Void) {
        self.base = base; self.name = name; self.n = n; self.action = action
    }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? {
        let data = try base.read(name)
        if name == self.name { n -= 1; if n == 0 { fired = true; try action() } }
        return data   // the push goes on with what it read BEFORE the other device's sync
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}

private final class CountingFolder: CloudFolder {
    let base: CloudFolder
    private(set) var blobDeletes = 0
    init(_ base: CloudFolder) { self.base = base }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { try base.read(name) }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws {
        if name.hasSuffix(".clk") { blobDeletes += 1 }
        try base.delete(name)
    }
}

/// Runs the other device's sync once, just before this push writes the manifest: after this push
/// has written the Take's file.
private final class BeforeManifestWriteFolder: CloudFolder {
    let base: CloudFolder; let action: () throws -> Void
    private(set) var fired = false
    init(_ base: CloudFolder, _ action: @escaping () throws -> Void) { self.base = base; self.action = action }
    func listFiles() throws -> [String] { try base.listFiles() }
    func read(_ name: String) throws -> Data? { try base.read(name) }
    func write(_ data: Data, to name: String) throws { try before(name); try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try before(name); try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
    private func before(_ name: String) throws {
        if name == Manifest.fileName, !fired { fired = true; try action() }
    }
}
