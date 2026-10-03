//
//  TestSupport.swift
//  CatchlightCoreTests
//
//  Test-only doubles. NONE of these are production code.
//

import Foundation
import CryptoKit
import CatchlightCoreTestSupport
@testable import CatchlightCore

extension TestFixtures {
    /// Build a SyncEngine with test defaults. `deviceId` is REQUIRED by the
    /// production initialiser (2026-06-10 remediation) — a fresh UUID default is
    /// fine for single-engine tests; multi-device tests pass explicit ids.
    static func engine(
        store: TakeStore,
        cloud: CloudFolder?,
        keys: KeyHierarchy,
        deviceId: UUID = UUID(),
        now: @escaping () -> Date = Date.init
    ) -> SyncEngine {
        SyncEngine(store: store, cloud: cloud, keys: keys, deviceId: deviceId, now: now)
    }

    /// A deterministic synthetic 2048-word "wordlist" to exercise the BIP-39
    /// ALGORITHM (entropy ⇄ checksum ⇄ indices). NOT the official English wordlist;
    /// it only needs 2048 unique tokens.
    static func syntheticWordlist() -> BIP39Wordlist {
        let words = (0..<2048).map { "w\($0)" }
        return try! BIP39Wordlist(words: words)
    }
}

// MARK: - Manifest helpers for the v3 encrypted format (owner 2026-08-11, D-196)
//
// The manifest on disk is now an encrypted `ManifestEnvelope`, so a test can no longer
// `Manifest.parse` what the engine wrote. These two are the test-side mirror of
// `SyncEngine.readVerifiedManifest` / `writeManifest`, kept here so the ~10 sync tests that
// poke at the folder share one definition instead of each growing its own seal/open dance.

extension Manifest {
    /// Read + decrypt the manifest a `SyncEngine` wrote into a fake cloud folder.
    static func readEncrypted(from cloud: CloudFolder, keys: KeyHierarchy) throws -> Manifest {
        let data = try cloud.read(Manifest.fileName)!
        let envelope = try ManifestEnvelope.parse(data)
        return try Manifest.opening(envelope, with: keys.manifestEncryptionKey())
    }

    /// Seal + sign + write a manifest as the engine would, for tests that plant one.
    static func writeEncrypted(_ manifest: Manifest, to cloud: CloudFolder, keys: KeyHierarchy) throws {
        let signer = ManifestSigner(keys: keys)
        let envelope = try signer.sign(try manifest.sealed(with: keys.manifestEncryptionKey()))
        try cloud.write(try envelope.serialise(), to: Manifest.fileName)
    }
}
