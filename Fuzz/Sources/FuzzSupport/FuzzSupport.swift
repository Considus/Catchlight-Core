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
    /// The capture inbox of the fixed key (R7): what `fuzz-capture-inbox` opens with.
    public static let inboxKey = keys.captureInboxPrivateKey()
    public static let inboxPublicKey = keys.captureInboxPublicKey()

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

/// `fuzz-capture-inbox`'s App Group input: a run of records, each one defaults entry.
///
///     record = tag (1) | key length (1) | key | value length (2, little-endian) | value
///
/// `tag % 4` picks where the key goes: under `capture.shared.` (the key bytes follow the
/// prefix, so the fuzzer picks the time prefix), the legacy `capture.sharedQueue` array, the
/// published inbox key `capture.inboxPublicKey` (both ignore the key bytes), or a raw key.
/// `(tag >> 2) % 9` picks the value's type: see `FuzzDefaultsValue`. A short final record
/// takes whatever bytes are left.
public enum FuzzDefaultsSlot: UInt8, CaseIterable { case shared, legacy, inboxKey, raw }

public enum FuzzDefaultsValue: UInt8, CaseIterable {
    /// The bytes as UTF-8 text (invalid sequences replaced).
    case string
    /// The bytes sealed to the fixed inbox with `CaptureInbox.seal`: a value that opens, with
    /// fuzzer-chosen plaintext, so the JSON decode after HPKE is reached.
    case sealed
    case data, int, double, bool
    /// Strings split on 0x00.
    case stringArray
    /// Elements split on 0x00, alternately a String, an Int and a Data.
    case mixedArray
    /// `["text": <bytes as text>, "isObie": true]`, a dictionary where a string belongs.
    case dictionary
}

public struct FuzzDefaultsRecord {
    public var slot: FuzzDefaultsSlot
    public var value: FuzzDefaultsValue
    public var key: Data
    public var bytes: Data
    public init(_ slot: FuzzDefaultsSlot, _ value: FuzzDefaultsValue, key: String = "", _ bytes: Data) {
        self.slot = slot; self.value = value; self.key = Data(key.utf8); self.bytes = bytes
    }

    public static let sharedPrefix = "capture.shared."
    public static let legacyKey = "capture.sharedQueue"
    public static let inboxPublicKeyKey = "capture.inboxPublicKey"

    /// Parse every record in `data`. Never fails: running out of bytes ends the run.
    public static func parse(_ data: Data) -> [FuzzDefaultsRecord] {
        let b = [UInt8](data)
        var i = 0, out: [FuzzDefaultsRecord] = []
        while i + 2 <= b.count {
            let tag = b[i], klen = Int(b[i + 1]); i += 2
            let key = Data(b[i..<min(b.count, i + klen)]); i = min(b.count, i + klen)
            var vlen = 0
            if i + 2 <= b.count { vlen = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 } else { i = b.count }
            let bytes = Data(b[i..<min(b.count, i + vlen)]); i = min(b.count, i + vlen)
            var r = FuzzDefaultsRecord(FuzzDefaultsSlot(rawValue: tag % 4)!,
                                       FuzzDefaultsValue(rawValue: (tag >> 2) % 9)!, bytes)
            r.key = key
            out.append(r)
        }
        return out
    }

    public var serialised: Data {
        var d = Data([slot.rawValue | value.rawValue << 2, UInt8(key.count)])
        d.append(key)
        d.append(contentsOf: [UInt8(bytes.count & 0xff), UInt8(bytes.count >> 8)])
        d.append(bytes)
        return d
    }

    public var defaultsKey: String {
        switch slot {
        case .shared: return Self.sharedPrefix + String(decoding: key, as: UTF8.self)
        case .legacy: return Self.legacyKey
        case .inboxKey: return Self.inboxPublicKeyKey
        case .raw: return String(decoding: key, as: UTF8.self)
        }
    }

    /// The property-list value this record writes.
    public var plistValue: Any {
        let text = String(decoding: bytes, as: UTF8.self)
        let parts = bytes.split(separator: 0, omittingEmptySubsequences: false)
        switch value {
        case .string: return text
        case .sealed: return (try? CaptureInbox.seal(bytes, to: Fuzz.inboxPublicKey)) ?? text
        case .data: return bytes
        case .int: return bytes.prefix(8).reversed().reduce(Int(0)) { $0 << 8 | Int($1) }
        case .double:
            var raw: UInt64 = 0
            for byte in bytes.prefix(8).reversed() { raw = raw << 8 | UInt64(byte) }
            let d = Double(bitPattern: raw)
            return d.isNaN ? 0.0 : d   // a plist cannot hold NaN on every platform
        case .bool: return (bytes.first ?? 0) & 1 == 1
        case .stringArray: return parts.map { String(decoding: $0, as: UTF8.self) }
        case .mixedArray:
            return parts.enumerated().map { i, part -> Any in
                switch i % 3 {
                case 0: return String(decoding: part, as: UTF8.self)
                case 1: return part.count
                default: return Data(part)
                }
            }
        case .dictionary: return ["text": text, "isObie": true] as [String: Any]
        }
    }
}
