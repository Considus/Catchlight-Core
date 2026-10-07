//
//  FuzzRegressionTests.swift
//  CatchlightCoreTests
//
//  Crashes found by the libFuzzer targets under Fuzz/ (2026-10-05), each minimised and
//  pinned here at a public seam. Every input below is untrusted: a file the user imports,
//  a file anyone with write access to the cloud folder can plant, or a handshake response
//  that has not been authenticated yet. The expected behaviour is the one each API already
//  documents for bad input (nil, a thrown error, or fail-safe), never a trap.
//
//  ROOT CAUSE (one bug, several doors): on Linux (and Windows, which shares
//  swift-corelibs-foundation) `DateFormatter.date(from:)` hits a `fatalError("Incorrect
//  range …")` instead of returning nil when ICU's parse stops inside a grapheme cluster —
//  a digit followed by a combining mark, e.g. "2\u{301}". `ISO8601.date(from:)` hands it
//  any string, so every caller below traps. Emoji and a decomposed "é" return nil safely.
//  Apple's Foundation returns nil for the same input (checked on macOS 2026-10-05), so
//  these six tests pass there with or without the fix; they guard Linux and Windows.
//  The exceptions are the duplicate-tombstone and capture-queue tests, separate bugs in Core
//  itself that trap on every platform.
//
//  A trap kills the test process, so run these one at a time to see each fail:
//      swift test --filter FuzzRegressionTests/<name>
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class FuzzRegressionTests: XCTestCase {

    /// A digit followed by U+0301 COMBINING ACUTE ACCENT: the shortest trigger.
    private let digitThenCombiningMark = "2\u{301}"
    /// A well-formed wire timestamp with a combining mark appended: what a single stray
    /// keystroke or a mangled copy-paste produces.
    private let timestampThenCombiningMark = "2026-05-01T09:00:00.000Z\u{301}"

    private let keys = KeyHierarchy(masterKeyBytes: Data((1...32).map { UInt8($0) }))

    // MARK: - The seam itself

    func testISO8601_digitFollowedByCombiningMark_returnsNil() {
        XCTAssertNil(ISO8601.date(from: digitThenCombiningMark))
        XCTAssertNil(ISO8601.date(from: timestampThenCombiningMark))
    }

    // MARK: - Markdown import (a file the user opens)

    /// fuzz-import: the `<!-- catchlight:data` block's dates go through
    /// `TakeTransfer.decoder()`. A bad block must fall back to heading parsing, as the
    /// importer documents ("nil if absent/invalid"), and still import the visible Take.
    func testImport_dataBlockDateWithCombiningMark_fallsBackToHeadings() {
        let file = """
        ---
        exported: x
        ---
        ## a
        b
        <!-- catchlight:data
        [{"createdAt":"\(digitThenCombiningMark)"}]
        -->

        """
        let takes = TakeImporter.parseDocument(file, fileDate: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(takes.count, 1)
        XCTAssertEqual(takes.first?.primaryText, "b")
    }

    // MARK: - Sync manifest (fuzz-manifest, minimised crash input)

    /// The minimised fuzz-manifest input: a v2 manifest whose tombstone `deletedAt` is
    /// "26" + U+033E. Pull already treats an unparseable `deletedAt` as `.distantPast`
    /// (SyncEngine step 2), so it must complete.
    func testPull_manifestTombstoneDateWithCombiningMark_completes() throws {
        let json = #"""
        {"manifestHmac":"","schemaVersion":1,"takes":[],"tombstones":[{"deletedAt":"26\#u{33E}","uuid":"99999999-8888-4777-8666-555555555555"}],"updated":"2026-10-05T12:00:00.000Z","version":2}
        """#
        let signed = try ManifestSigner(keys: keys).sign(try Manifest.parse(Data(json.utf8)))
        let cloud = InMemoryCloudFolder()
        try cloud.write(try signed.serialise(), to: Manifest.fileName)

        let engine = TestFixtures.engine(store: InMemoryTakeStore(), cloud: cloud, keys: keys)
        XCTAssertNoThrow(try engine.pullInbound())
    }

    // MARK: - Cloud blob (fuzz-blob, minimised crash input)

    /// The minimised fuzz-blob input: a Take payload whose `createdAt` is "2" + U+0365,
    /// sealed under its item key so it decrypts. `PlatformJSON`'s date strategy documents
    /// a thrown `DecodingError` for a non-ISO date, which `TakeCrypto.open` passes up.
    func testOpen_takeCreatedAtWithCombiningMark_throws() throws {
        let id = UUID(uuidString: "5E62D354-549D-486B-96F1-B28C80691111")!
        let json = #"{"createdAt":"2\#u{365}","id":"5E62D354-549D-486B-96F1-B28C80691111"}"#
        let sealed = try encryptTake(Data(json.utf8), masterKey: keys.masterKey, takeUUID: id)
        XCTAssertThrowsError(try TakeCrypto(keys: keys).open(sealed, takeUUID: id)) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }

    // MARK: - Duplicate tombstones (a second, unrelated bug; every platform)

    /// A signed manifest listing the same tombstone id twice, pulled by a device that has a
    /// pending local deletion. Pull's step 2b builds `Dictionary(uniqueKeysWithValues:)`
    /// over the manifest's tombstones, which traps on a duplicate key in the Swift standard
    /// library itself, so this fails on Apple platforms too. Push already tolerates the same
    /// manifest (it merges by id, last one wins), so pull must as well.
    func testPull_duplicateTombstoneIds_withPendingLocalDeletion_completes() throws {
        let store = InMemoryTakeStore()
        let local = TestFixtures.richTake()
        try store.upsert(local)
        try store.delete(id: local.id)   // leaves a pending local tombstone

        let dup = ManifestTombstone(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                                    deletedAt: "2026-07-01T00:00:00.000Z")
        let manifest = Manifest(updated: "2026-07-01T00:00:00.000Z", takes: [], tombstones: [dup, dup])
        let cloud = InMemoryCloudFolder()
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)

        let engine = TestFixtures.engine(store: store, cloud: cloud, keys: keys)
        XCTAssertNoThrow(try engine.pullInbound())
    }

    // MARK: - Lock file (anyone with write access to the folder, no key needed)

    /// `SyncLock.isStale` documents "Returns `true` for malformed timestamps so a corrupt
    /// lock never wedges sync forever". A planted lock with a malformed `acquiredAt` must
    /// therefore be overwritten and the push proceed.
    func testPush_lockFileTimestampWithCombiningMark_isTreatedAsStale() throws {
        let cloud = InMemoryCloudFolder()
        let planted = SyncLock(deviceId: UUID(), acquiredAt: timestampThenCombiningMark)
        try cloud.write(try PlatformJSON.encode(planted), to: SyncLock.fileName)

        let engine = TestFixtures.engine(store: InMemoryTakeStore(), cloud: cloud, keys: keys)
        XCTAssertNoThrow(try engine.pushOutbound())
    }

    // MARK: - Device handshake (checked before anything is authenticated)

    /// `unwrapMasterKey` validates expiry FIRST, before the response is authenticated, so a
    /// malformed expiry must be rejected as expired rather than trap.
    func testHandshake_expiryWithCombiningMark_isRejectedAsExpired() throws {
        let issued = Date()
        let (request, priv) = DeviceHandshake.makeRequest(deviceIdentifier: "iPad", now: issued)
        let genuine = try DeviceHandshake.makeResponse(to: request, masterKey: SymmetricKey(size: .bits256), now: issued)
        let response = HandshakeResponse(requestId: genuine.requestId,
                                         originalDevicePublicKey: genuine.originalDevicePublicKey,
                                         wrappedMasterKey: genuine.wrappedMasterKey,
                                         oneTimeValue: genuine.oneTimeValue,
                                         expiry: genuine.expiry + "\u{301}")
        XCTAssertThrowsError(try DeviceHandshake.unwrapMasterKey(response: response, ephemeralPrivate: priv, now: issued)) { error in
            XCTAssertEqual(error as? SyncError, .handshakeExpired)
        }
    }

    // MARK: - Capture queue (App Group defaults, 2026-10-06; a third bug, every platform)

    /// fuzz-capture-inbox: one queued key whose time prefix is `Int64.max`. `enqueueShared`
    /// stamps a share one past the newest queued time, so `Int64.max + 1` trapped in the share
    /// extension and in Siri capture, on every share until the key was gone. A key outside
    /// the writer's own 15-digit format must be ignored for ordering, and the share queued.
    func testEnqueueShared_keyWithInt64MaxTimePrefix_queuesTheShare() throws {
        let suite = "FuzzRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        CaptureRouting.publishInboxKey(keys.captureInboxPublicKey(), defaults: defaults)
        defaults.set("", forKey: "capture.shared.9223372036854775807")

        XCTAssertTrue(CaptureRouting.enqueueShared(CaptureRouting.SharedItem(text: "after a planted key"),
                                                   defaults: defaults))
        let texts = CaptureRouting.sharedQueue(opening: keys.captureInboxPrivateKey(), defaults: defaults).map(\.text)
        XCTAssertEqual(texts, ["after a planted key", ""])
    }

    /// Review of the fix above: a stamp capped at 15 digits could TIE a planted key at the top of
    /// the range, leaving the order to the UUIDs. One below the cap, the new share takes the cap
    /// itself and still sorts after it.
    func testEnqueueShared_keyJustBelowTheCap_newShareStillSortsAfterIt() throws {
        let suite = "FuzzRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        CaptureRouting.publishInboxKey(keys.captureInboxPublicKey(), defaults: defaults)
        defaults.set("planted", forKey: "capture.shared.999999999999998.\(UUID().uuidString)")

        XCTAssertTrue(CaptureRouting.enqueueShared(CaptureRouting.SharedItem(text: "new"), defaults: defaults))
        let texts = CaptureRouting.sharedQueue(opening: keys.captureInboxPrivateKey(), defaults: defaults).map(\.text)
        XCTAssertEqual(texts, ["planted", "new"])
    }

    /// A planted key AT the cap: every later stamp was capped onto it, so every real share tied
    /// with every other and the queue sorted them by UUID, scrambling the drain order and the cap
    /// trim. The key at the cap is now ignored, and real shares keep their order (five of them,
    /// so a pass by chance is 1 in 120). The planted key itself is unordered.
    func testEnqueueShared_keyAtTheCap_realSharesKeepTheirOrder() throws {
        let suite = "FuzzRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        CaptureRouting.publishInboxKey(keys.captureInboxPublicKey(), defaults: defaults)
        defaults.set("planted", forKey: "capture.shared.999999999999999.\(UUID().uuidString)")

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 1...5 {
            XCTAssertTrue(CaptureRouting.enqueueShared(CaptureRouting.SharedItem(text: "share \(i)"), defaults: defaults,
                                                       now: t0.addingTimeInterval(Double(i))))
        }
        let texts = CaptureRouting.sharedQueue(opening: keys.captureInboxPrivateKey(), defaults: defaults).map(\.text)
        XCTAssertEqual(texts.filter { $0 != "planted" }, (1...5).map { "share \($0)" })
    }
}
