//
//  CaptureSharedQueueTests.swift
//  CatchlightCoreTests — the shared-item queue the share extension and the app both write
//  (WorkPlan R6, 2026-10-05).
//

import Foundation
import XCTest
@testable import CatchlightCore

/// Stands in for the OTHER process: the first time this process writes or removes a key, a
/// second `UserDefaults` on the same suite enqueues a share before the write lands. That is
/// the interleaving a share made while the app is draining produces.
private final class InterleavingDefaults: UserDefaults {
    var interleave: (() -> Void)?

    private func fireOnce() {
        let work = interleave
        interleave = nil
        work?()
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        fireOnce()
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        fireOnce()
        super.removeObject(forKey: defaultName)
    }
}

final class CaptureSharedQueueTests: XCTestCase {
    private var suite: String!
    private var defaults: InterleavingDefaults!
    private var other: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "CaptureSharedQueueTests.\(UUID().uuidString)"
        defaults = InterleavingDefaults(suiteName: suite)
        other = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEnqueue_thenRead_keepsOrder() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        CaptureRouting.enqueueShared(.init(text: "first"), defaults: defaults, now: t0)
        CaptureRouting.enqueueShared(.init(text: "second", isObie: true), defaults: defaults,
                                     now: t0.addingTimeInterval(1))
        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults),
                       [.init(text: "first"), .init(text: "second", isObie: true)])
    }

    func testEnqueue_blankText_isIgnored() {
        CaptureRouting.enqueueShared("  \n ", defaults: defaults)
        XCTAssertTrue(CaptureRouting.sharedQueue(defaults: defaults).isEmpty)
    }

    /// The R6 loss: the app clears what it drained while the extension enqueues a new share.
    func testShareArrivingWhileTheAppClears_isNotLost() {
        CaptureRouting.enqueueShared(.init(text: "drained"), defaults: defaults)
        let drained = CaptureRouting.sharedQueueEntries(defaults: defaults)
        defaults.interleave = { CaptureRouting.enqueueShared(.init(text: "arrived mid-drain"), defaults: self.other) }

        CaptureRouting.clearShared(drained, defaults: defaults)

        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults).map(\.text), ["arrived mid-drain"])
    }

    /// The same loss through the count-based clear the app calls today.
    func testShareArrivingWhileTheAppClearsByCount_isNotLost() {
        CaptureRouting.enqueueShared(.init(text: "drained"), defaults: defaults)
        let count = CaptureRouting.sharedQueue(defaults: defaults).count
        defaults.interleave = { CaptureRouting.enqueueShared(.init(text: "arrived mid-drain"), defaults: self.other) }

        CaptureRouting.clearSharedQueue(consumed: count, defaults: defaults)

        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults).map(\.text), ["arrived mid-drain"])
    }

    /// Two shares written at the same moment from two processes both survive.
    func testTwoConcurrentEnqueues_bothKept() {
        defaults.interleave = { CaptureRouting.enqueueShared(.init(text: "from the other process"), defaults: self.other) }
        CaptureRouting.enqueueShared(.init(text: "from this process"), defaults: defaults)
        XCTAssertEqual(Set(CaptureRouting.sharedQueue(defaults: defaults).map(\.text)),
                       ["from the other process", "from this process"])
    }

    func testCap_dropsTheOldest() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0...CaptureRouting.sharedQueueCap {
            CaptureRouting.enqueueShared(.init(text: "share \(i)"), defaults: defaults,
                                         now: t0.addingTimeInterval(Double(i)))
        }
        let texts = CaptureRouting.sharedQueue(defaults: defaults).map(\.text)
        XCTAssertEqual(texts.count, CaptureRouting.sharedQueueCap)
        XCTAssertEqual(texts.first, "share 1")
        XCTAssertEqual(texts.last, "share \(CaptureRouting.sharedQueueCap)")
    }

    /// Shares an older build queued in the single array still drain, first, and clear.
    func testLegacyArray_isReadFirstAndCleared() throws {
        let encoded = String(decoding: try PlatformJSON.encode(CaptureRouting.SharedItem(text: "old json", isObie: true)),
                             as: UTF8.self)
        other.set([encoded, "old bare string"], forKey: "capture.sharedQueue")
        CaptureRouting.enqueueShared(.init(text: "new"), defaults: defaults)

        let entries = CaptureRouting.sharedQueueEntries(defaults: defaults)
        XCTAssertEqual(entries.map(\.item), [.init(text: "old json", isObie: true),
                                             .init(text: "old bare string"), .init(text: "new")])

        CaptureRouting.clearShared(Array(entries.prefix(2)), defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "capture.sharedQueue"))
        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults).map(\.text), ["new"])
    }

    /// The cap trim runs in the share extension, so it must never rewrite the legacy array
    /// the app may be draining at the same moment.
    func testCap_neverTrimsTheLegacyArray() {
        let legacy = (0..<CaptureRouting.sharedQueueCap).map { "old \($0)" }
        other.set(legacy, forKey: "capture.sharedQueue")
        CaptureRouting.enqueueShared(.init(text: "new"), defaults: defaults)
        XCTAssertEqual(other.stringArray(forKey: "capture.sharedQueue"), legacy)
        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults).last?.text, "new")
    }

    func testClearShared_leavesItemsItDidNotRead() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        CaptureRouting.enqueueShared(.init(text: "a"), defaults: defaults, now: t0)
        let read = CaptureRouting.sharedQueueEntries(defaults: defaults)
        CaptureRouting.enqueueShared(.init(text: "b"), defaults: defaults, now: t0.addingTimeInterval(1))
        CaptureRouting.clearShared(read, defaults: defaults)
        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults).map(\.text), ["b"])
    }
}
