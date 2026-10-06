//
//  CaptureInbox.swift
//  CatchlightCore
//
//  Sealing for captures that wait in the App Group (R7, owner 2026-10-06, option A).
//
//  The share extension and the Siri capture intents cannot save a Take: the master key is
//  `.userPresence`-gated and only exists in the foreground, unlocked app. So they QUEUE the
//  text (`CaptureRouting.enqueueShared`) and the app saves it on the next unlock. Up to
//  Core 1.1 that queue held the text as plain JSON in the App Group defaults, outside the
//  encrypted store, which is what "encrypted before it is written anywhere" rules out.
//
//  The fix is a public-key inbox. The app derives an X25519 key pair from the master key
//  and publishes only the PUBLIC half to the App Group. A writer seals each capture to it
//  with HPKE (RFC 9180, base mode): it needs nothing secret, so it works on a locked phone
//  and in the extension. Only the app, holding the master key, can derive the private half
//  and open what was queued. Nothing new is stored in the Keychain and the recovery phrase
//  is unchanged: the same phrase derives the same inbox on every device.
//
//      Master Key
//        └── HKDF info "catchlight-capture-inbox-v1" → X25519 private key (never stored)
//                                                      └── public key → App Group
//
//      sealed value = "sealed1:" + base64( encapsulated key (32) || AES-256-GCM ciphertext+tag )
//      HPKE suite   = DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM
//      HPKE info    = "catchlight-capture-inbox-hpke-v1"
//
//  This ADDS two labels to the contract; it changes none of the existing ones.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CaptureInbox {

    /// HPKE `info`, binding a sealed capture to this one use.
    public static let hpkeInfo = "catchlight-capture-inbox-hpke-v1"

    /// Marks a queue value as sealed. Anything without it is the plain JSON (or bare text)
    /// an older build queued, which is still read once so it isn't lost on update.
    static let sealedPrefix = "sealed1:"

    /// X25519 public keys and HPKE encapsulated keys are both 32 bytes.
    static let encapsulatedKeyByteCount = 32

    public enum InboxError: Error, Equatable {
        /// This OS has no HPKE (CryptoKit before macOS 14). Every iPhone build has it.
        case unavailable
        /// Not a sealed value, or one too short or badly encoded to be one.
        case malformed
    }

    static func isSealed(_ raw: String) -> Bool { raw.hasPrefix(sealedPrefix) }

    /// Seal `plaintext` to the inbox whose public key is `publicKey`. Needs no secret.
    public static func seal(_ plaintext: Data, to publicKey: Data) throws -> String {
        guard #available(macOS 14, iOS 17, *) else { throw InboxError.unavailable }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite,
                                     info: Data(hpkeInfo.utf8))
        let ciphertext = try sender.seal(plaintext)
        return sealedPrefix + (sender.encapsulatedKey + ciphertext).base64EncodedString()
    }

    /// Open a sealed value. Throws if it isn't one, or if it was sealed to another inbox
    /// (another account's key, or a value altered after sealing).
    public static func open(_ sealed: String,
                            with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard #available(macOS 14, iOS 17, *) else { throw InboxError.unavailable }
        guard isSealed(sealed),
              let bytes = Data(base64Encoded: String(sealed.dropFirst(sealedPrefix.count))),
              bytes.count > encapsulatedKeyByteCount else { throw InboxError.malformed }
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite,
                                           info: Data(hpkeInfo.utf8),
                                           encapsulatedKey: bytes.prefix(encapsulatedKeyByteCount))
        return try recipient.open(bytes.dropFirst(encapsulatedKeyByteCount))
    }

    @available(macOS 14, iOS 17, *)
    private static var ciphersuite: HPKE.Ciphersuite {
        HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
    }
}

extension KeyInfo {
    /// The capture inbox's X25519 private key (R7). Its own label, so it shares no key
    /// material with the database, manifest or handshake keys.
    public static let captureInbox = "catchlight-capture-inbox-v1"
}

extension KeyHierarchy {

    /// The capture inbox's private key. Derived from the master key on demand, never stored.
    public func captureInboxPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        let raw = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: Data(KeyInfo.captureInbox.utf8),
            outputByteCount: 32
        )
        // X25519 accepts any 32 bytes as a private key (it clamps them), so this cannot throw.
        return try! raw.withUnsafeBytes {
            try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data($0))
        }
    }

    /// The public half, which the app publishes to the App Group for writers to seal to.
    public func captureInboxPublicKey() -> Data {
        captureInboxPrivateKey().publicKey.rawRepresentation
    }
}
