//
//  FuzzSupport.swift
//  The fixed key, store and folder every fuzz target builds against. NOT production code.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCore

public enum Fuzz {
    /// A fixed test master key, so a crash input reproduces byte for byte.
    public static let keys = KeyHierarchy(masterKeyBytes: Data((1...32).map { UInt8($0) }))
    public static let signer = ManifestSigner(keys: keys)
    public static let manifestKey = keys.manifestEncryptionKey()
    public static let takeId = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    public static let localId = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    public static let deletedId = UUID(uuidString: "99999999-8888-4777-8666-555555555555")!
    public static let now = ISO8601.date(from: "2026-10-05T12:00:00.000Z")!
    public static let deviceId = UUID(uuidString: "DEADBEEF-0000-4000-8000-000000000001")!

    /// A store holding one live Take and one pending tombstone, so pull reaches the
    /// tombstone-reconciliation and conflict branches rather than only the empty case.
    public static func store(withLastSync: Bool) -> InMemoryTakeStore {
        let store = InMemoryTakeStore()
        let t0 = ISO8601.date(from: "2026-05-01T09:00:00.000Z")!
        try? store.upsert(Take(id: localId, createdAt: t0, modifiedAt: t0,
                               blocks: [.textLine("local"), .checkItem("item", isComplete: false)],
                               isNote: true))
        try? store.upsert(Take(id: deletedId, createdAt: t0, modifiedAt: t0,
                               blocks: [.textLine("gone")], isNote: true))
        try? store.delete(id: deletedId)
        if withLastSync { store.setLastSyncDate(ISO8601.date(from: "2026-06-01T00:00:00.000Z")!) }
        return store
    }

    public static func engine(store: TakeStore, cloud: CloudFolder) -> SyncEngine {
        SyncEngine(store: store, cloud: cloud, keys: keys, deviceId: deviceId, now: { now })
    }

    /// Seal `body` as a v3 manifest envelope with the fixed key and sign it: the bytes a
    /// device holding the key would write.
    public static func signedEnvelope(body: Data) throws -> Data {
        let sealed = try CryptoService.encrypt(body, key: manifestKey)
        let envelope = try signer.sign(ManifestEnvelope(encryptedBody: sealed.base64EncodedString()))
        return try envelope.serialise()
    }

    /// Pull, then push, against `cloud`. Every error is an expected outcome for bad input;
    /// only a trap, a sanitizer report or a hang is a finding.
    public static func syncBothWays(cloud: InMemoryCloudFolder, withLastSync: Bool) {
        let store = store(withLastSync: withLastSync)
        let engine = engine(store: store, cloud: cloud)
        _ = try? engine.pullInbound()
        _ = try? engine.pushOutbound()
    }
}

/// The first input byte picks a mode; the rest is the payload.
public func split(_ data: Data) -> (mode: UInt8, payload: Data) {
    guard let first = data.first else { return (0, Data()) }
    return (first, Data(data.dropFirst()))
}

/// Wrap the libFuzzer callback's raw buffer.
public func fuzzData(_ start: UnsafeRawPointer, _ count: Int) -> Data {
    Data(bytes: start, count: count)
}
