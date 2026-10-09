//
//  CaptureMutationGapTests.swift
//  CatchlightCoreTests
//
//  The 2026-10-09 mutation run over the code added since Core 1.2.1: the capture inbox (R7)
//  and the sealed share queue. Each test here kills a one-line change that survived the whole
//  suite. The comment on each names the file and the rule it guards.
//

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CatchlightCore

final class CaptureMutationGapTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var keys: KeyHierarchy!

    override func setUp() {
        super.setUp()
        suite = "CaptureMutationGapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        CaptureRouting.publishInboxKey(keys.captureInboxPublicKey(), defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var inbox: Curve25519.KeyAgreement.PrivateKey { keys.captureInboxPrivateKey() }

    private func texts() -> [String] {
        CaptureRouting.sharedQueue(opening: inbox, defaults: defaults).map(\.text)
    }

    /// `Z` sorts after every character a UUID string holds, so a share given the same time
    /// prefix as this key sorts BEFORE it. That makes a tie visible every run, where two real
    /// UUIDs would show it only half the time.
    private func plantKeyAfterAnyUUID(stamp: String, value: String = "planted") {
        defaults.set(value, forKey: "capture.shared.\(stamp).ZZZZ")
    }

    // MARK: - What counts as sealed

    /// CaptureInbox.swift — only a value that STARTS with exactly `sealed1:` is sealed. A
    /// share an older build queued in the clear is read as text, whatever words it holds. A
    /// looser test turns it into an unopenable entry, which the app reports lost and clears.
    func testUnsealedShareMentioningTheWordSealed_stillLandsAsText() {
        defaults.set("sealed the lease today", forKey: "capture.shared.000000000000001.\(UUID().uuidString)")
        defaults.set("label reads sealed1: do not open", forKey: "capture.shared.000000000000002.\(UUID().uuidString)")

        XCTAssertEqual(CaptureRouting.sharedQueue(opening: inbox, defaults: defaults).map(\.text),
                       ["sealed the lease today", "label reads sealed1: do not open"])
        XCTAssertTrue(CaptureRouting.unopenableSharedEntries(opening: inbox, defaults: defaults).isEmpty)
    }

    /// CaptureInbox.swift — `open` refuses anything that is not a `sealed1:` value, even when
    /// the bytes after the prefix would open. A later format gets its own prefix, and this
    /// build must not read it as version 1.
    func testOpen_aValueUnderAnotherPrefix_isMalformed() throws {
        let sealed = try CaptureInbox.seal(Data("v1 bytes".utf8), to: keys.captureInboxPublicKey())
        let otherPrefix = "sealed2:" + sealed.dropFirst("sealed1:".count)

        XCTAssertThrowsError(try CaptureInbox.open(otherPrefix, with: inbox)) {
            XCTAssertEqual($0 as? CaptureInbox.InboxError, .malformed)
        }
    }

    /// CaptureInbox.swift — a value that is badly encoded is malformed. Standard base64 with
    /// nothing else in it is the format, so a value with a stray character or a line break
    /// does not open, even when skipping the extra character would leave a good value.
    func testOpen_base64WithAStrayCharacter_isMalformed() throws {
        let sealed = try CaptureInbox.seal(Data("strict".utf8), to: keys.captureInboxPublicKey())
        let body = String(sealed.dropFirst("sealed1:".count))
        let head = String(body.prefix(20)), tail = String(body.dropFirst(20))
        let lineBreak: String = "sealed1:" + head + "\n" + tail
        let stray: String = "sealed1:" + head + "*" + tail

        for bad in [lineBreak, stray] {
            XCTAssertThrowsError(try CaptureInbox.open(bad, with: inbox)) {
                XCTAssertEqual($0 as? CaptureInbox.InboxError, .malformed)
            }
        }
        XCTAssertEqual(try CaptureInbox.open(sealed, with: inbox), Data("strict".utf8))
    }

    // MARK: - Opened, but not a capture

    /// CaptureRouting.swift — a sealed value that opens but is not a capture (no `text`) is
    /// unopenable, reported and cleared. It is never a Take: not a blank one, and not one
    /// holding the raw JSON.
    func testSealedValueWithoutText_isUnopenable_notATake() throws {
        let sealed = try CaptureInbox.seal(Data(#"{"isObie":true}"#.utf8), to: keys.captureInboxPublicKey())
        defaults.set(sealed, forKey: "capture.shared.000000000000001.\(UUID().uuidString)")

        XCTAssertEqual(CaptureRouting.sharedQueue(opening: inbox, defaults: defaults), [])
        XCTAssertEqual(CaptureRouting.unopenableSharedEntries(opening: inbox, defaults: defaults).count, 1)
    }

    /// CaptureRouting.swift — `SharedItem(text:isObie:)` keeps the flag it is given. The Siri
    /// "New Obie" capture sets it, and the queue carries it to the app. Comparing against
    /// another `SharedItem` built the same way cannot see the flag dropped, so this reads it.
    func testObieFlag_survivesTheQueue() {
        XCTAssertTrue(CaptureRouting.SharedItem(text: "x", isObie: true).isObie)
        XCTAssertTrue(CaptureRouting.enqueueShared(.init(text: "the one thing", isObie: true), defaults: defaults))

        let items = CaptureRouting.sharedQueue(opening: inbox, defaults: defaults)
        XCTAssertEqual(items.map(\.text), ["the one thing"])
        XCTAssertEqual(items.map(\.isObie), [true])
    }

    // MARK: - Queue order and the cap

    /// CaptureRouting.swift — the cap is 50, a product number, not just whatever the constant
    /// says: fifty shares made before the app is opened are all kept, and the fifty-first drops
    /// only the oldest. The existing cap test counts against `sharedQueueCap` itself, so any
    /// value passed it.
    func testCap_isFifty() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 1...50 {
            CaptureRouting.enqueueShared(.init(text: "share \(i)"), defaults: defaults,
                                         now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(texts(), (1...50).map { "share \($0)" })

        CaptureRouting.enqueueShared(.init(text: "share 51"), defaults: defaults, now: t0.addingTimeInterval(51))
        XCTAssertEqual(texts(), (2...51).map { "share \($0)" })
    }

    /// CaptureRouting.swift — the share just written is never trimmed by the cap, whatever its
    /// key sorts as. Fifty keys AT the cap are ignored for ordering, so the new share takes the
    /// clock's time and sorts first; the trim must skip it and drop a planted key instead.
    func testCap_neverTrimsTheShareJustWritten_evenWhenItSortsFirst() {
        for i in 0..<CaptureRouting.sharedQueueCap {
            defaults.set("planted \(i)", forKey: "capture.shared.999999999999999.\(UUID().uuidString)")
        }

        XCTAssertTrue(CaptureRouting.enqueueShared(.init(text: "just shared"), defaults: defaults,
                                                   now: Date(timeIntervalSince1970: 1_800_000_000)))

        let queued = texts()
        XCTAssertEqual(queued.count, CaptureRouting.sharedQueueCap)
        XCTAssertEqual(queued.first, "just shared")
    }

    /// CaptureRouting.swift — a share is stamped one PAST the newest queued time, never equal
    /// to it, so it sorts after that share whatever the two UUIDs are. Here the clock is behind.
    func testClockBehindTheNewestKey_newShareSortsAfterIt_whateverTheUUIDs() {
        plantKeyAfterAnyUUID(stamp: "001800000000000", value: "queued first")

        CaptureRouting.enqueueShared(.init(text: "queued second"), defaults: defaults,
                                     now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(texts(), ["queued first", "queued second"])
    }

    /// CaptureRouting.swift — one below the cap, the new share takes the cap itself, so it
    /// sorts after the key below it. FuzzRegressionTests checks the same rule with two random
    /// UUIDs, which a stamp one short of the cap passes half the time.
    func testKeyJustBelowTheCap_newShareTakesTheCap_whateverTheUUIDs() {
        plantKeyAfterAnyUUID(stamp: "999999999999998")

        XCTAssertTrue(CaptureRouting.enqueueShared(.init(text: "new"), defaults: defaults))

        XCTAssertEqual(texts(), ["planted", "new"])
    }

    /// CaptureRouting.swift — the stamp is capped at 15 digits even when the clock is past
    /// them. A longer stamp sorts by its first digit, so "10000000000000000" would land before
    /// a queued "999999999999998".
    func testClockPastFifteenDigits_stampIsCapped_andSortsLast() {
        plantKeyAfterAnyUUID(stamp: "999999999999998")

        XCTAssertTrue(CaptureRouting.enqueueShared(.init(text: "new"), defaults: defaults,
                                                   now: Date(timeIntervalSince1970: 10_000_000_000_000)))

        XCTAssertEqual(texts(), ["planted", "new"])
    }

    /// CaptureRouting.swift — only EXACTLY 15 digits is a time prefix. A 16-digit key with a
    /// leading zero has a value below the cap; read as a time, it pushes every later share onto
    /// the cap, where they tie and sort by UUID. Eight shares, so a pass by chance is 1 in 40,320.
    func testSixteenDigitKey_isIgnoredForOrdering() {
        defaults.set("planted", forKey: "capture.shared.0999999999999998.\(UUID().uuidString)")

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 1...8 {
            XCTAssertTrue(CaptureRouting.enqueueShared(.init(text: "share \(i)"), defaults: defaults,
                                                       now: t0.addingTimeInterval(Double(i))))
        }

        XCTAssertEqual(texts().filter { $0 != "planted" }, (1...8).map { "share \($0)" })
    }
}
