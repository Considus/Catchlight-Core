//
//  CaptureInboxTests.swift
//  CatchlightCoreTests — captures queued by the share extension and Siri are sealed (R7).
//
//  The inbox public key's known answer was NOT captured from this implementation. It comes
//  from a plain-Python RFC 5869 HKDF and RFC 7748 X25519 that first reproduced the RFC 7748
//  test vector and the master-key vector pinned in EncryptionLayerTests.
//

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CatchlightCore

final class CaptureInboxTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var keys: KeyHierarchy!

    override func setUp() {
        super.setUp()
        suite = "CaptureInboxTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        CaptureRouting.publishInboxKey(keys.captureInboxPublicKey(), defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func storedValues() -> [String] {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("capture.shared.") }
            .compactMap { $0.value as? String }
    }

    // MARK: - Contract

    func testInboxPublicKey_knownAnswer() {
        let words = ["abandon", "abandon", "abandon", "abandon", "abandon", "abandon",
                     "abandon", "abandon", "abandon", "abandon", "abandon", "about"]
        let keys = KeyHierarchy(masterKeyBytes: MasterKeyDerivation.deriveRaw(from: words))
        XCTAssertEqual(keys.captureInboxPublicKey().map { String(format: "%02x", $0) }.joined(),
                       "c6d34261ef27f241361f06ba834a9e3577165a4485eadab37502328a3c422d7b")
    }

    func testInboxKey_isDerived_soTheSamePhraseOpensItOnAnyDevice() {
        let again = KeyHierarchy(masterKey: keys.masterKey)
        XCTAssertEqual(again.captureInboxPublicKey(), keys.captureInboxPublicKey())
    }

    // MARK: - Nothing is written in the clear

    func testEnqueue_storesNoPlaintext_andTheAppOpensIt() {
        XCTAssertTrue(CaptureRouting.enqueueShared(.init(text: "pick up the prescription", isObie: true),
                                                   defaults: defaults))

        let stored = storedValues()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].hasPrefix("sealed1:"))
        XCTAssertFalse(stored[0].contains("prescription"))
        XCTAssertFalse(stored[0].contains("isObie"))

        XCTAssertEqual(CaptureRouting.sharedQueue(opening: keys.captureInboxPrivateKey(), defaults: defaults),
                       [.init(text: "pick up the prescription", isObie: true)])
    }

    func testWithoutAnInboxKey_nothingIsQueued() {
        CaptureRouting.clearInboxKey(defaults: defaults)
        XCTAssertFalse(CaptureRouting.enqueueShared(.init(text: "before setup"), defaults: defaults))
        XCTAssertTrue(storedValues().isEmpty)
    }

    /// A reader without the key must never hand a sealed value back as a Take of base64.
    func testReadingWithoutTheKey_leavesSealedItemsOut() {
        CaptureRouting.enqueueShared(.init(text: "secret"), defaults: defaults)
        XCTAssertEqual(CaptureRouting.sharedQueue(defaults: defaults), [])
    }

    // MARK: - Another account, damage, and older builds

    func testSealedToAnotherAccount_isReportedUnopenable_andClears() {
        CaptureRouting.enqueueShared(.init(text: "made before the erase"), defaults: defaults)
        let newAccount = KeyHierarchy(masterKey: SymmetricKey(size: .bits256)).captureInboxPrivateKey()
        CaptureRouting.publishInboxKey(newAccount.publicKey.rawRepresentation, defaults: defaults)
        CaptureRouting.enqueueShared(.init(text: "made after"), defaults: defaults)

        XCTAssertEqual(CaptureRouting.sharedQueue(opening: newAccount, defaults: defaults).map(\.text),
                       ["made after"])
        let lost = CaptureRouting.unopenableSharedEntries(opening: newAccount, defaults: defaults)
        XCTAssertEqual(lost.count, 1)

        CaptureRouting.clearShared(lost, defaults: defaults)
        XCTAssertEqual(storedValues().count, 1)
        XCTAssertEqual(CaptureRouting.sharedQueue(opening: newAccount, defaults: defaults).map(\.text),
                       ["made after"])
    }

    func testAlteredSealedValue_doesNotOpen() throws {
        let sealed = try CaptureInbox.seal(Data("original".utf8), to: keys.captureInboxPublicKey())
        var bytes = try XCTUnwrap(Data(base64Encoded: String(sealed.dropFirst("sealed1:".count))))
        bytes[bytes.count - 1] ^= 0x01
        let altered = "sealed1:" + bytes.base64EncodedString()
        XCTAssertThrowsError(try CaptureInbox.open(altered, with: keys.captureInboxPrivateKey()))
    }

    func testMalformedSealedValue_throwsMalformed() {
        for bad in ["sealed1:", "sealed1:not base64!", "sealed1:" + Data(count: 32).base64EncodedString(), "plain"] {
            XCTAssertThrowsError(try CaptureInbox.open(bad, with: keys.captureInboxPrivateKey())) {
                XCTAssertEqual($0 as? CaptureInbox.InboxError, .malformed, bad)
            }
        }
    }

    /// A share queued in the clear by Core 1.1 (per-key JSON) or earlier (bare text) still
    /// lands once after the update, beside sealed ones, in queue order.
    func testUnsealedValuesFromAnOlderBuild_stillDrain() throws {
        let olderJSON = String(decoding: try PlatformJSON.encode(CaptureRouting.SharedItem(text: "queued by 1.1")),
                               as: UTF8.self)
        defaults.set(olderJSON, forKey: "capture.shared.000000000000001.\(UUID().uuidString)")
        CaptureRouting.enqueueShared(.init(text: "queued now"), defaults: defaults)

        let entries = CaptureRouting.sharedQueueEntries(opening: keys.captureInboxPrivateKey(), defaults: defaults)
        XCTAssertEqual(entries.map(\.item.text), ["queued by 1.1", "queued now"])
        CaptureRouting.clearShared(entries, defaults: defaults)
        XCTAssertTrue(storedValues().isEmpty)
    }
}
