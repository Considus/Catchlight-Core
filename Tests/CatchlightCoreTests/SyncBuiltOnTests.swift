import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

/// The lock race the per-Take record alone could not close (spec/CatchlightSyncRecordsRaces.cfg):
/// two pushes pass the advisory lock at once, and the later manifest write replaces the other
/// device's upload with a version that never had it. Each manifest entry now says which upload
/// of each device it was built on (`ManifestEntry.builtOn`), so the device whose upload was left
/// out sees that on its next pull and shows a conflict instead of taking the other version.
final class SyncBuiltOnTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    private func engine(_ s: InMemoryTakeStore, _ c: CloudFolder, _ d: UUID, _ at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: s, cloud: c, keys: k, deviceId: d, now: { self.t0.addingTimeInterval(at) })
    }
    private func entry(_ id: UUID) throws -> ManifestEntry? {
        try Manifest.readEncrypted(from: cloud, keys: k).takes.first(where: { $0.uuid == id })
    }
    private func cloudText(_ id: UUID) throws -> String? {
        guard let entry = try entry(id) else { return nil }
        let bytes = try XCTUnwrap(cloud.read("\(entry.uuid.uuidString).clk"))
        guard let ct = try CloudBlob.parse(bytes).ciphertext else { return nil }
        return try? TakeCrypto(keys: k).open(ct, takeUUID: entry.uuid).primaryText
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

    /// A's push reads the manifest, then B's whole sync uploads B's edit, then A's push writes
    /// its own edit over it. B does nothing more: its next pull must not take A's version
    /// silently, because A's was never built on B's.
    func testUploadReplacedByAPushThatNeverHadIt_isShownAsAConflict() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        var conflictsSeen = 0
        let blindB = LockBlindFolder(cloud)
        let viewA = NthReadFolder(cloud, name: Manifest.fileName, n: 2) {   // 1 = pull, 2 = push
            conflictsSeen += try self.engine(self.storeB, blindB, self.deviceB, 26).sync().conflicts.count
        }
        conflictsSeen += try engine(storeA, viewA, deviceA, 25).sync().conflicts.count
        XCTAssertTrue(viewA.fired)
        XCTAssertEqual(try cloudText(take.id), "edit on A", "the race did not happen: A's write should replace B's upload")

        let pulled = try engine(storeB, cloud, deviceB, 31).sync()
        XCTAssertEqual(pulled.conflicts.count, 1, "B's upload was written over by a version without it, and B took it with no conflict")
        XCTAssertEqual(pulled.conflicts.first?.local.primaryText, "edit on B")
        XCTAssertEqual(pulled.conflicts.first?.remote.primaryText, "edit on A")
        XCTAssertEqual(conflictsSeen, 0)
    }

    /// The same race after B's pull has already seen its upload in the folder: B agreed with its
    /// own version, then A's write replaced it.
    func testUploadSeenThenReplacedByAPushThatNeverHadIt_isShownAsAConflict() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        let blindB = LockBlindFolder(cloud)
        let viewA = NthReadFolder(cloud, name: Manifest.fileName, n: 2) {
            try self.engine(self.storeB, blindB, self.deviceB, 26).sync()
            try self.engine(self.storeB, blindB, self.deviceB, 27).sync()   // sees its upload listed
        }
        try engine(storeA, viewA, deviceA, 25).sync()
        XCTAssertTrue(viewA.fired)
        XCTAssertEqual(try storeB.syncRecord(id: take.id)?.agreed, ISO8601.string(from: t0.addingTimeInterval(20)))

        let pulled = try engine(storeB, cloud, deviceB, 31).sync()
        XCTAssertEqual(pulled.conflicts.count, 1, "B agreed with its own upload, A wrote over it unseen, and B took A's with no conflict")
    }

    /// The everyday chain: B uploads, A pulls it and edits twice, syncing each time. B was away
    /// for both: A's latest was built on A's own, which was built on B's, so B takes it quietly.
    func testUploadBuiltOnTwiceElsewhere_isTakenWithNoConflict() throws {
        let take = try syncedTake()
        try edit(storeB, take.id, "edit on B", at: 10)
        try engine(storeB, cloud, deviceB, 11).sync()
        try engine(storeA, cloud, deviceA, 12).sync()
        XCTAssertEqual(try storeA.take(id: take.id)?.primaryText, "edit on B")
        try edit(storeA, take.id, "first on A", at: 13)
        try engine(storeA, cloud, deviceA, 14).sync()
        try edit(storeA, take.id, "second on A", at: 15)
        try engine(storeA, cloud, deviceA, 16).sync()

        let pulled = try engine(storeB, cloud, deviceB, 20).sync()
        XCTAssertEqual(pulled.conflicts.count, 0)
        XCTAssertEqual(try storeB.take(id: take.id)?.primaryText, "second on A")
    }

    /// Each upload names, per device, the upload it was built on: its own new version, and what
    /// the entry it replaced already named.
    func testUploadRecordsWhatItWasBuiltOn() throws {
        let take = try syncedTake()
        let base = ISO8601.string(from: t0)
        XCTAssertEqual(try entry(take.id)?.builtOn?[deviceA.uuidString], base)
        try edit(storeB, take.id, "edit on B", at: 10)
        try engine(storeB, cloud, deviceB, 11).sync()
        let built = try XCTUnwrap(entry(take.id)?.builtOn)
        XCTAssertEqual(built[deviceA.uuidString], base, "carried from the entry it replaced")
        XCTAssertEqual(built[deviceB.uuidString], ISO8601.string(from: t0.addingTimeInterval(10)))
        XCTAssertEqual(try storeB.syncRecord(id: take.id)?.published, ISO8601.string(from: t0.addingTimeInterval(10)))
    }

    /// An entry written by a build without the field names nothing, so it counts as one that
    /// never had this device's upload: shown as a conflict, never taken unseen. Here an older
    /// build on A did build on B's upload, so this is the extra conflict a mixed fleet costs.
    func testEntryWithoutBuiltOn_overThisDevicesUpload_isShownAsAConflict() throws {
        let take = try syncedTake()
        try edit(storeB, take.id, "edit on B", at: 10)
        try engine(storeB, cloud, deviceB, 11).sync()
        try engine(storeA, cloud, deviceA, 12).sync()
        try edit(storeA, take.id, "edit on A", at: 13)
        try engine(storeA, cloud, deviceA, 14).sync()
        // Strip the field, as an older build's write would.
        try stripBuiltOn()
        XCTAssertNil(try entry(take.id)?.builtOn)

        let pulled = try engine(storeB, cloud, deviceB, 20).sync()
        XCTAssertEqual(pulled.conflicts.count, 1)
        XCTAssertEqual(try storeB.take(id: take.id)?.primaryText, "edit on B")
    }

    /// A Take this device has not uploaded since updating has no `published`, so an entry without
    /// the field changes nothing: the version is taken as before.
    func testEntryWithoutBuiltOn_withNoUploadHere_isTakenAsBefore() throws {
        let take = try syncedTake()
        try edit(storeA, take.id, "edit on A", at: 13)
        try engine(storeA, cloud, deviceA, 14).sync()
        try stripBuiltOn()
        try storeB.setSyncRecord(SyncRecord(agreed: ISO8601.string(from: t0)), id: take.id)   // as 2.0.0 left it

        let pulled = try engine(storeB, cloud, deviceB, 20).sync()
        XCTAssertEqual(pulled.conflicts.count, 0)
        XCTAssertEqual(try storeB.take(id: take.id)?.primaryText, "edit on A")
    }

    /// The field is written only when set, so an entry without it encodes exactly as before, and
    /// one with it reads back the same.
    func testBuiltOn_isWrittenOnlyWhenSet_andReadsBack() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let plain = ManifestEntry(uuid: id, modified: "2026-11-17T00:00:00.000Z", hmac: "ab")
        XCTAssertEqual(String(data: try PlatformJSON.encode(plain), encoding: .utf8),
                       #"{"hmac":"ab","modified":"2026-11-17T00:00:00.000Z","uuid":"00000000-0000-0000-0000-000000000001"}"#)
        XCTAssertNil(ManifestEntry(uuid: id, modified: "m", hmac: "ab", builtOn: [:]).builtOn)
        let built = ManifestEntry(uuid: id, modified: "m", hmac: "ab", builtOn: ["D": "m"])
        XCTAssertEqual(try PlatformJSON.decode(ManifestEntry.self, from: try PlatformJSON.encode(built)), built)
    }

    private func stripBuiltOn() throws {
        var manifest = try Manifest.readEncrypted(from: cloud, keys: k)
        manifest.takes = manifest.takes.map { ManifestEntry(uuid: $0.uuid, modified: $0.modified, hmac: $0.hmac, kind: $0.kind) }
        try Manifest.writeEncrypted(manifest, to: cloud, keys: k)
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
        return data   // the push goes on with what it read BEFORE B's sync
    }
    func write(_ data: Data, to name: String) throws { try base.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws { try base.writeAtomically(data, to: name) }
    func delete(_ name: String) throws { try base.delete(name) }
}
