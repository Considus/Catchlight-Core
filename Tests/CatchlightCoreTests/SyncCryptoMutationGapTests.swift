//
//  SyncCryptoMutationGapTests.swift
//  CatchlightCoreTests
//
//  Each test here kills a mutant that survived the whole suite in the 2026-10-05
//  mutation run over Sync/ and Crypto/: a one-line change the existing tests could not
//  tell from the real code. The comment on each names the file and the rule it guards.
//
//  Known-answer vectors are NOT captured from this implementation. They were computed
//  with an independent RFC 5869 HKDF-SHA-256 (Python hmac/hashlib) that first
//  reproduced every vector already pinned in EncryptionLayerTests (the master key and
//  the database, manifest-HMAC and per-item keys), so they check the spec, not the code.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncCryptoMutationGapTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static let abandonAbout = [
        "abandon", "abandon", "abandon", "abandon", "abandon", "abandon",
        "abandon", "abandon", "abandon", "abandon", "abandon", "about"
    ]
    /// Hex LETTERS on purpose: the existing per-item vectors use all-digit UUIDs, for which
    /// upper- and lowercase are the same bytes, so a case drift in the HKDF info went unseen.
    private static let letterUUID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!

    private func katKeys() -> KeyHierarchy {
        KeyHierarchy(masterKeyBytes: MasterKeyDerivation.deriveRaw(from: Self.abandonAbout))
    }
    private func randomKeys() -> KeyHierarchy { KeyHierarchy(masterKey: SymmetricKey(size: .bits256)) }
    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }
    private func engine(_ store: TakeStore, _ cloud: CloudFolder, _ keys: KeyHierarchy,
                        at: Date, device: UUID = UUID()) -> SyncEngine {
        TestFixtures.engine(store: store, cloud: cloud, keys: keys, deviceId: device, now: { at })
    }

    // MARK: - Key derivation contract (cross-platform: a drift makes every Take unreadable)

    /// TakeCrypto.swift — the per-item HKDF info is the UPPERCASE UUID string.
    func testItemKey_knownAnswer_forAUUIDWithHexLetters() {
        let mk = SymmetricKey(data: MasterKeyDerivation.deriveRaw(from: Self.abandonAbout))
        XCTAssertEqual(hex(itemKey(masterKey: mk, takeUUID: Self.letterUUID)),
                       "47288f9c61de0daf5511bc7afb7ca144f79571fd7861a4d4893f883411c21383")
    }

    /// KeyHierarchy.swift — the second copy of the derivation must agree with the
    /// first; its own comment says there is exactly one definition, and nothing checked it.
    func testKeyHierarchyItemKey_isTheSameDerivationAsTheFreeFunction() {
        let keys = katKeys()
        XCTAssertEqual(hex(keys.itemKey(takeUUID: Self.letterUUID)),
                       "47288f9c61de0daf5511bc7afb7ca144f79571fd7861a4d4893f883411c21383")
        XCTAssertEqual(hex(keys.itemKey(takeUUID: Self.letterUUID)),
                       hex(itemKey(masterKey: keys.masterKey, takeUUID: Self.letterUUID)))
    }

    /// KeyHierarchy.swift — the manifest body key had no known answer at all, so its
    /// length and info string could drift and every v3 manifest would stop opening.
    func testManifestEncryptionKey_knownAnswer() {
        XCTAssertEqual(hex(katKeys().manifestEncryptionKey()),
                       "e6e94c3643cef8ab77ac627ae815f032e76b3359123930615d17d6f83e1d4a74")
    }

    /// ManifestSigner.swift — the signer must key its HMAC with the manifest-HMAC
    /// key (not the database or encryption key) and emit lowercase hex. The HMAC key itself
    /// is pinned elsewhere; which key the SIGNER uses was not.
    func testSigner_hmacsWithTheManifestHMACKey_inLowercaseHex() {
        let signer = ManifestSigner(keys: katKeys())
        XCTAssertEqual(signer.blobHMACHex(Data("catchlight".utf8)),
                       "21fc1d7d95a2900bd2e23aa5055dc9ded99f409ab1bd3ba2f8fdf818a04886d1")
    }

    // MARK: - Legacy (v1/v2) manifests are still READ, so their signature must still bind

    /// A plaintext v2 manifest a tester's folder may still hold, carrying a tombstone for the
    /// local Take. Signed as given; `hmacOverride` replaces the signature after signing.
    private func plantLegacyManifest(deleting id: UUID, signedWith keys: KeyHierarchy,
                                     hmacOverride: String? = nil, in cloud: CloudFolder) throws {
        var manifest = Manifest(version: 2, updated: ISO8601.string(from: t0), takes: [],
                                tombstones: [ManifestTombstone(uuid: id,
                                    deletedAt: ISO8601.string(from: t0.addingTimeInterval(100)))])
        manifest = try ManifestSigner(keys: keys).sign(manifest)
        if let hmacOverride { manifest.manifestHmac = hmacOverride }
        try cloud.write(try manifest.serialise(), to: Manifest.fileName)
    }

    private func assertLegacyForgeryRejected(signedWith signingKeys: KeyHierarchy, keys: KeyHierarchy,
                                             hmacOverride: String?,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let cloud = InMemoryCloudFolder(), store = InMemoryTakeStore()
        var take = TestFixtures.richTake()
        take.modifiedAt = t0
        try store.upsert(take)
        try plantLegacyManifest(deleting: take.id, signedWith: signingKeys,
                                hmacOverride: hmacOverride, in: cloud)

        XCTAssertThrowsError(try engine(store, cloud, keys, at: t0.addingTimeInterval(200)).pullInbound(),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? SyncError, .manifestSignatureInvalid, file: file, line: line)
        }
        XCTAssertEqual(try store.take(id: take.id), take,
                       "a forged deletion must not remove the Take", file: file, line: line)
    }

    /// SyncEngine.swift and ManifestSigner.swift — a v2 manifest signed under another
    /// key is a forgery. Accepting it lets anyone with folder access delete every Take.
    func testLegacyManifest_signedUnderAnotherKey_isRejected_andNothingIsDeleted() throws {
        let keys = randomKeys()
        try assertLegacyForgeryRejected(signedWith: randomKeys(), keys: keys, hmacOverride: nil)
    }

    /// ManifestSigner.swift — a signature that is not hex at all must fail, not pass.
    func testLegacyManifest_withANonHexSignature_isRejected() throws {
        let keys = randomKeys()
        try assertLegacyForgeryRejected(signedWith: keys, keys: keys, hmacOverride: "z")
    }

    /// ManifestSigner.swift — the same for the v3 envelope.
    func testEnvelope_withANonHexSignature_doesNotVerify() throws {
        let keys = randomKeys()
        let signer = ManifestSigner(keys: keys)
        var envelope = try signer.sign(try Manifest(updated: "x", takes: [])
            .sealed(with: keys.manifestEncryptionKey()))
        envelope.manifestHmac = "z"
        XCTAssertFalse(try signer.verify(envelope))
    }

    // MARK: - Push must never delete or overwrite what it should keep

    /// SyncEngine.swift — edit-wins on push: a Take edited AFTER a remote deletion keeps
    /// its entry and blob, and the deletion is not written. Without the `continue` the edit
    /// is uploaded and then deleted fleet-wide in the same pass.
    func testPush_editAfterARemoteDeletion_keepsTheTakeInTheFolder() throws {
        // The store stamps a deletion with the real clock, so this test runs on it too.
        let base = Date()
        let keys = randomKeys(), cloud = InMemoryCloudFolder()
        var take = TestFixtures.richTake()
        take.modifiedAt = base.addingTimeInterval(-60)
        let deviceA = InMemoryTakeStore(), deviceB = InMemoryTakeStore()
        try deviceA.upsert(take)
        try engine(deviceA, cloud, keys, at: base.addingTimeInterval(-50)).pushOutbound()

        try engine(deviceB, cloud, keys, at: base.addingTimeInterval(-40)).pullInbound()
        try deviceB.delete(id: take.id)   // deletedAt = now, after every stamp above
        try engine(deviceB, cloud, keys, at: base.addingTimeInterval(10)).pushOutbound()
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.map(\.uuid), [take.id])

        var edited = take
        edited.primaryText = "edited after the deletion"
        edited.modifiedAt = base.addingTimeInterval(60)
        try deviceA.upsert(edited)
        try engine(deviceA, cloud, keys, at: base.addingTimeInterval(120)).pushOutbound()

        let manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        XCTAssertEqual(manifest.takes.map(\.uuid), [take.id], "the edit wins: its entry stays")
        XCTAssertEqual(manifest.tombstones, [], "the superseded deletion is not written")
        XCTAssertNotNil(try cloud.read("\(take.id.uuidString).clk"), "the edited blob is not deleted")
    }

    /// SyncEngine.swift — a repair re-checks that this device still holds the version the
    /// manifest names. If the manifest has moved on, re-uploading would put an OLDER version
    /// over another device's newer one.
    func testRepair_isSkippedWhenTheManifestNowNamesANewerVersion() throws {
        let keys = randomKeys(), cloud = InMemoryCloudFolder(), store = InMemoryTakeStore()
        var take = TestFixtures.richTake()
        take.modifiedAt = t0
        try store.upsert(take)
        try engine(store, cloud, keys, at: t0.addingTimeInterval(1)).pushOutbound()

        var manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        manifest.takes = manifest.takes.map {
            ManifestEntry(uuid: $0.uuid, modified: ISO8601.string(from: t0.addingTimeInterval(50)),
                          hmac: $0.hmac, kind: $0.kind)
        }
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)
        let newerElsewhere = Data("another device's newer copy".utf8)
        try cloud.write(newerElsewhere, to: "\(take.id.uuidString).clk")

        let report = try engine(store, cloud, keys, at: t0.addingTimeInterval(60))
            .pushOutbound(repairing: [take.id])

        XCTAssertEqual(report.repaired, [])
        XCTAssertEqual(report.uploaded, [])
        XCTAssertEqual(try cloud.read("\(take.id.uuidString).clk"), newerElsewhere)
    }

    /// SyncEngine.swift — a Script whose change cannot be dated against our last sync
    /// (never synced, or an unparseable stamp) must count as changed elsewhere, or push
    /// uploads the phone's Take over another device's Script. An entry stamped exactly at the
    /// last sync is not newer than it.
    func testChangedElsewhere_treatsUnknownAsChanged_andATieAsUnchanged() {
        let script = { (modified: String) in
            ManifestEntry(uuid: UUID(), modified: modified, hmac: "", kind: ManifestEntry.Kind.script)
        }
        let stamp = ISO8601.string(from: t0)
        XCTAssertTrue(SyncEngine.changedElsewhere(script(stamp), since: nil), "never synced")
        XCTAssertTrue(SyncEngine.changedElsewhere(script("not a date"), since: t0), "unparseable")
        XCTAssertFalse(SyncEngine.changedElsewhere(script(stamp), since: t0), "a tie is not newer")
        XCTAssertTrue(SyncEngine.changedElsewhere(script(ISO8601.string(from: t0.addingTimeInterval(1))),
                                                  since: t0))
    }

    /// SyncEngine.swift — the copy kept from a Take another device turned into a
    /// Script is an ordinary, user-made Take: never a seeded sample (which cleanup removes)
    /// and never the Obie unless the original was.
    func testForkedCopy_isNeitherSeededNorTheObie() throws {
        let keys = randomKeys(), cloud = InMemoryCloudFolder(), phone = InMemoryTakeStore()
        var take = TestFixtures.richTake()
        take.modifiedAt = t0
        take.isSeeded = false
        take.isObie = false
        try phone.upsert(take)
        try engine(phone, cloud, keys, at: t0.addingTimeInterval(1)).sync()

        var edited = take
        edited.primaryText = "phone edit"
        edited.modifiedAt = t0.addingTimeInterval(20)
        try phone.upsert(edited)
        var manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        manifest.takes = manifest.takes.map {
            ManifestEntry(uuid: $0.uuid, modified: ISO8601.string(from: t0.addingTimeInterval(25)),
                          hmac: $0.hmac, kind: ManifestEntry.Kind.script)
        }
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)

        let report = try engine(phone, cloud, keys, at: t0.addingTimeInterval(30)).sync()
        let copy = try XCTUnwrap(try phone.take(id: try XCTUnwrap(report.forkedFromScripts.first)))
        XCTAssertFalse(copy.isSeeded, "a seeded sample is cleaned up; the user's edit must not be")
        XCTAssertFalse(copy.isObie)
    }

    // MARK: - What sync() tells the app

    /// SyncEngine.swift — a push that fails must fail `sync()`. Swallowing it reports a
    /// sync that never reached the folder as done.
    func testSync_aPushFailureIsThrown_notReportedAsSuccess() throws {
        let keys = randomKeys(), store = InMemoryTakeStore()
        let cloud = FaultyCloudFolder(failManifestWrite: true)
        try store.upsert(TestFixtures.richTake())
        XCTAssertThrowsError(try engine(store, cloud, keys, at: t0).sync())
    }

    /// SyncEngine.swift — a push that ran is not reported as deferred.
    func testSync_aCompletedPushIsNotReportedAsDeferred() throws {
        let keys = randomKeys(), store = InMemoryTakeStore(), cloud = InMemoryCloudFolder()
        try store.upsert(TestFixtures.richTake())
        let report = try engine(store, cloud, keys, at: t0).sync()
        XCTAssertFalse(report.pushDeferred)
        XCTAssertEqual(report.uploaded.count, 1)
    }

    // MARK: - Account metadata is written once and never clobbered

    /// SyncEngine.swift — `accountCreatedAt` records when the account began. A second
    /// push, later, must leave it as the first push wrote it.
    func testAccountMetadata_isNotRewrittenByALaterPush() throws {
        let keys = randomKeys(), store = InMemoryTakeStore(), cloud = InMemoryCloudFolder()
        let device = UUID()
        try engine(store, cloud, keys, at: t0, device: device).pushOutbound()
        let first = try XCTUnwrap(try cloud.read(Self.metadata))
        try engine(store, cloud, keys, at: t0.addingTimeInterval(86_400), device: device).pushOutbound()
        XCTAssertEqual(try cloud.read(Self.metadata), first)
    }

    /// SyncEngine.swift — a read ERROR is not absence: the file must not be rewritten.
    func testAccountMetadata_aReadErrorIsNotTreatedAsAbsence() throws {
        let keys = randomKeys(), store = InMemoryTakeStore()
        let cloud = FaultyCloudFolder(failMetadataRead: true)
        try engine(store, cloud, keys, at: t0).pushOutbound()
        XCTAssertFalse(cloud.wrote.contains(Self.metadata))
    }

    private static let metadata = "catchlight-account-metadata.json"
}

/// An in-memory folder that fails one operation on request.
private final class FaultyCloudFolder: CloudFolder {
    struct Failure: Error {}
    private let inner = InMemoryCloudFolder()
    private let failManifestWrite: Bool
    private let failMetadataRead: Bool
    private(set) var wrote: [String] = []

    init(failManifestWrite: Bool = false, failMetadataRead: Bool = false) {
        self.failManifestWrite = failManifestWrite
        self.failMetadataRead = failMetadataRead
    }

    func listFiles() throws -> [String] { try inner.listFiles() }
    func read(_ name: String) throws -> Data? {
        if failMetadataRead, name == "catchlight-account-metadata.json" { throw Failure() }
        return try inner.read(name)
    }
    func write(_ data: Data, to name: String) throws { wrote.append(name); try inner.write(data, to: name) }
    func writeAtomically(_ data: Data, to name: String) throws {
        if failManifestWrite, name == Manifest.fileName { throw Failure() }
        wrote.append(name)
        try inner.writeAtomically(data, to: name)
    }
    func delete(_ name: String) throws { try inner.delete(name) }
    func secureDelete(_ name: String) throws { try inner.secureDelete(name) }
}
