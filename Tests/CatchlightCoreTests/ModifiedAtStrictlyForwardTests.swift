//
//  ModifiedAtStrictlyForwardTests.swift
//  CatchlightCoreTests
//
//  Sync uploads a Take when its modifiedAt is later than the last sync and later than the
//  cloud copy's. A save stamped with the same millisecond as the version already pushed
//  (a coarse clock: Windows CI read the same millisecond twice 1 ms apart) or an earlier
//  one (the clock set back) passed neither test and stayed on the device for good.
//  `Take.markModified(at:)` stamps strictly forward instead (2026-10-11).
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class ModifiedAtStrictlyForwardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20.000Z

    // MARK: - The stamp

    func testMarkModified_takesTheClock_whenItHasMovedOn() {
        var take = Take(modifiedAt: t0, blocks: [.textLine("x")])
        take.markModified(at: t0.addingTimeInterval(30))
        XCTAssertEqual(ISO8601.string(from: take.modifiedAt), "2023-11-14T22:13:50.000Z")
    }

    func testMarkModified_movesForward_whenTheClockReadsTheSameMillisecond() {
        var take = Take(modifiedAt: t0, blocks: [.textLine("x")])
        take.markModified(at: t0)
        XCTAssertEqual(ISO8601.string(from: take.modifiedAt), "2023-11-14T22:13:20.001Z")
    }

    func testMarkModified_movesForward_whenTheClockHasGoneBack() {
        var take = Take(modifiedAt: t0, blocks: [.textLine("x")])
        take.markModified(at: t0.addingTimeInterval(-3600))
        XCTAssertEqual(ISO8601.string(from: take.modifiedAt), "2023-11-14T22:13:20.001Z")
    }

    // MARK: - What it protects: the edit reaches the cloud

    private let k = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
    private let cloud = InMemoryCloudFolder()
    private let store = InMemoryTakeStore()

    private func sync(_ at: TimeInterval) throws {
        try TestFixtures.engine(store: store, cloud: cloud, keys: k, deviceId: UUID(),
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

    func testAnEditInTheSameMillisecondAsThePushedVersion_reachesTheCloud() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "first"
        take.modifiedAt = t0.addingTimeInterval(5)
        try store.upsert(take)
        try sync(5)
        XCTAssertEqual(try cloudText(take.id), "first")

        take.primaryText = "second"
        take.markModified(at: t0.addingTimeInterval(5))      // the clock hasn't moved
        try store.upsert(take)
        try sync(60)

        XCTAssertEqual(try cloudText(take.id), "second")
    }

    func testAnEditAfterTheClockWentBack_reachesTheCloud() throws {
        var take = TestFixtures.richTake()
        take.primaryText = "first"
        take.modifiedAt = t0.addingTimeInterval(5)
        try store.upsert(take)
        try sync(5)

        take.primaryText = "second"
        take.markModified(at: t0.addingTimeInterval(-600))   // clock set back ten minutes
        try store.upsert(take)
        try sync(60)

        XCTAssertEqual(try cloudText(take.id), "second")
    }
}
