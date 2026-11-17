import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

/// Two pushes overlapping inside one push: B cannot see A's lock (cloud propagation delay),
/// and B's whole sync lands after A's push read the manifest and before A writes it. A's
/// manifest write then replaces B's upload. Expected to pass: B edits again, so its next pull
/// finds both sides changed and shows the conflict. Without that second edit this is the lock
/// race the per-Take record does not close (spec/CatchlightSyncRecordsRaces.cfg).
final class SyncManifestOverwriteProbeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let storeA = InMemoryTakeStore(), storeB = InMemoryTakeStore()
    private let deviceA = UUID(), deviceB = UUID()

    private func engine(_ s: InMemoryTakeStore, _ c: CloudFolder, _ d: UUID, _ at: TimeInterval) -> SyncEngine {
        TestFixtures.engine(store: s, cloud: c, keys: k, deviceId: d, now: { self.t0.addingTimeInterval(at) })
    }
    private func cloudText(_ id: UUID) throws -> String? {
        guard let entry = try Manifest.readEncrypted(from: cloud, keys: k).takes.first(where: { $0.uuid == id }) else { return nil }
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

    func testOverlappingPushesNeverLoseAnEditSilently() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "base"
        take.modifiedAt = t0
        try storeA.upsert(take)
        try engine(storeA, cloud, deviceA, 1).sync()
        try engine(storeB, cloud, deviceB, 2).sync()
        try edit(storeA, take.id, "edit on A", at: 10)
        try edit(storeB, take.id, "edit on B", at: 20)

        var conflictsSeen = 0
        let blindB = LockBlindFolder(cloud)
        let viewA = NthReadFolder(cloud, name: Manifest.fileName, n: 2) {   // 1 = pull, 2 = push
            conflictsSeen += try self.engine(self.storeB, blindB, self.deviceB, 26).sync().conflicts.count
        }
        conflictsSeen += try engine(storeA, viewA, deviceA, 25).sync().conflicts.count
        XCTAssertTrue(viewA.fired)

        try edit(storeB, take.id, "second edit on B", at: 30)
        conflictsSeen += try engine(storeB, cloud, deviceB, 31).sync().conflicts.count
        conflictsSeen += try engine(storeA, cloud, deviceA, 40).sync().conflicts.count
        conflictsSeen += try engine(storeB, cloud, deviceB, 41).sync().conflicts.count

        let texts = [try storeA.take(id: take.id)?.primaryText, try storeB.take(id: take.id)?.primaryText, try cloudText(take.id)]
        XCTAssertTrue(texts.contains("edit on A") || conflictsSeen > 0, "A's edit lost with no conflict shown")
        XCTAssertTrue(texts.contains("second edit on B") || conflictsSeen > 0, "B's edit lost with no conflict shown")
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
