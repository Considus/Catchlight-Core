//
//  main.swift (fuzz-seeds) — writes each fuzz target's starting corpus from Core's own fixtures
//  (`TestFixtures.richTake`, `SeedTakes`, a real engine push). Run without the fuzzer
//  sanitizer:  swift run fuzz-seeds <out-dir>
//

import Foundation
import CatchlightCore
import CatchlightCoreTestSupport
import FuzzSupport

struct FuzzSeeds {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "corpus-seeds")
        func write(_ target: String, _ name: String, mode: UInt8?, _ data: Data) throws {
            let dir = out.appendingPathComponent(target)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var bytes = Data()
            if let mode { bytes.append(mode) }
            bytes.append(data)
            try bytes.write(to: dir.appendingPathComponent(name))
        }

        let utc = TimeZone(identifier: "UTC")!
        let exportedAt = ISO8601.date(from: "2026-10-01T08:00:00.000Z")!
        let rich = TestFixtures.richTake(id: Fuzz.takeId)
        var obie = rich; obie.isObie = true; obie.isImportant = true; obie.manualOrder = 2.5
        let seeds = SeedTakes.make(now: exportedAt)
        let all = [rich] + seeds

        // Import: real exports (with the data block), one Take and many.
        try write("import", "export-rich.md", mode: nil, Data(TakeExporter.export([rich], exportedAt: exportedAt, timeZone: utc).utf8))
        try write("import", "export-obie.md", mode: nil, Data(TakeExporter.export([obie], exportedAt: exportedAt, timeZone: utc).utf8))
        try write("import", "export-all.md", mode: nil, Data(TakeExporter.export(all, exportedAt: exportedAt, timeZone: utc).utf8))

        // A real engine push: the manifest and blob exactly as written to the folder.
        let cloud = InMemoryCloudFolder()
        let store = InMemoryTakeStore()
        for take in [rich] + seeds.prefix(3) { try store.upsert(take) }
        let deleted = Take(id: Fuzz.deletedId, createdAt: exportedAt, modifiedAt: exportedAt,
                           blocks: [.textLine("gone")], isNote: true)
        try store.upsert(deleted); try store.delete(id: Fuzz.deletedId)
        try Fuzz.engine(store: store, cloud: cloud).pushOutbound()
        let manifestFile = try cloud.read(Manifest.fileName)!
        let manifest = try Manifest.opening(try ManifestEnvelope.parse(manifestFile), with: Fuzz.manifestKey)
        var legacy = manifest; legacy.version = 2
        let legacySigned = try Fuzz.signer.sign(legacy)
        for withLastSync: UInt8 in [0, 4] {
            try write("manifest", "folder-v3-\(withLastSync)", mode: 0 | withLastSync, manifestFile)
            try write("manifest", "folder-v2-\(withLastSync)", mode: 0 | withLastSync, try legacySigned.serialise())
            try write("manifest", "body-v3-\(withLastSync)", mode: 1 | withLastSync, try manifest.serialise())
            try write("manifest", "plain-v2-\(withLastSync)", mode: 2 | withLastSync, try legacy.serialise())
        }

        let blobFile = try cloud.read(CloudBlob.fileName(for: Fuzz.takeId))!
        for (i, take) in ([rich, obie] + seeds).enumerated() {
            try write("blob", "take-json-\(i)", mode: 1, try PlatformJSON.encode(take))
            try write("blob", "take-json-local-\(i)", mode: 1 | 4 | 8, try PlatformJSON.encode(take))
        }
        try write("blob", "clk-folder", mode: 0, blobFile)
        try write("blob", "clk-listed", mode: 2, blobFile)
        try write("blob", "clk-listed-local", mode: 2 | 4 | 8, blobFile)

        // Phrase: valid mnemonics from fixed entropies, and the entropies themselves.
        let bip39 = BIP39(wordlist: try BIP39Wordlist(words: (0..<2048).map { "w\($0)" }))
        for (i, fill) in [UInt8(0x00), 0x7f, 0xff, 0x5a].enumerated() {
            let entropy = Data(repeating: fill, count: 16)
            let words = try bip39.mnemonic(fromEntropy: entropy)
            try write("phrase", "mnemonic-\(i)", mode: 0, Data(words.joined(separator: " ").utf8))
            try write("phrase", "mnemonic-lines-\(i)", mode: 0, Data(("  " + words.joined(separator: "\n") + "\n").utf8))
            try write("phrase", "entropy-\(i)", mode: 1, entropy)
        }

        // Capture inbox (R7): values sealed to the fixed inbox and the plain JSON an older
        // build queued, alone (modes 0, 2, 4) and as App Group defaults (modes 1, 3).
        let shares = [CaptureRouting.SharedItem(text: "https://example.com/a shared link"),
                      CaptureRouting.SharedItem(text: "Obie this", isObie: true),
                      CaptureRouting.SharedItem(text: "naïve 🎉\nline two")]
        let plain = try shares.map { try PlatformJSON.encode($0) }
        let sealed = try plain.map { try CaptureInbox.seal($0, to: Fuzz.inboxPublicKey) }
        for (i, value) in sealed.enumerated() {
            try write("capture-inbox", "sealed-\(i)", mode: 0, Data(value.utf8))
            try write("capture-inbox", "sealed-body-\(i)", mode: 2, Data(value.dropFirst("sealed1:".count).utf8))
            try write("capture-inbox", "sealed-bytes-\(i)", mode: 4,
                      Data(base64Encoded: String(value.dropFirst("sealed1:".count)))!)
            try write("capture-inbox", "plain-json-\(i)", mode: 0, plain[i])
        }

        typealias R = FuzzDefaultsRecord
        let publish = R(.inboxKey, .string, Data(Fuzz.inboxPublicKey.base64EncodedString().utf8))
        let uuid = ".0A1B2C3D-0000-4000-8000-000000000001"
        func stamped(_ ms: String, _ value: FuzzDefaultsValue, _ bytes: Data) -> R {
            R(.shared, value, key: ms + uuid, bytes)
        }
        func queue(_ name: String, _ records: [R]) throws {
            let body = records.reduce(into: Data()) { $0.append($1.serialised) }
            try write("capture-inbox", "defaults-\(name)", mode: 1, body)
            try write("capture-inbox", "defaults-\(name)-enqueue", mode: 3, body)
        }
        try queue("sealed", [publish] + plain.enumerated().map {
            stamped("00000175952000\($0.offset)", .sealed, $0.element)
        })
        try queue("sealed-verbatim", [publish] + sealed.enumerated().map {
            stamped("00000175952000\($0.offset)", .string, Data($0.element.utf8))
        })
        try queue("plain-json", [publish] + plain.enumerated().map {
            stamped("00000175952000\($0.offset)", .string, $0.element)
        })
        try queue("legacy", [publish,
                             R(.legacy, .stringArray, plain[0] + Data([0]) + Data("bare text".utf8) + Data([0]) + plain[0]),
                             stamped("000001759520000", .sealed, plain[1])])
        // Odd time prefixes: none, negative, signed, Int64's minimum, 18 digits, past Int64,
        // not ASCII, not decimal, padded. None of them traps or breaks queue order on its own:
        // a seed that crashes would stop the run before it starts.
        let odd = ["", "-1", "+5", "-9223372036854775808", "922337203685477580", "99999999999999999999",
                   "١٢٣", "0x10", " 12", "12 "]
        try queue("odd-prefixes", [publish] + odd.map { stamped($0, .sealed, plain[0]) }
                  + [R(.shared, .string, key: "no-dot-at-all", Data("x".utf8)),
                     R(.shared, .string, key: "...", Data("x".utf8))])
        try queue("non-string", [publish,
                                 stamped("000001759520001", .data, Data(sealed[0].utf8)),
                                 stamped("000001759520002", .int, Data([1, 2, 3])),
                                 stamped("000001759520003", .double, Data([0, 0, 0, 0, 0, 0, 0xf0, 0x3f])),
                                 stamped("000001759520004", .bool, Data([1])),
                                 stamped("000001759520005", .stringArray, Data(sealed[0].utf8)),
                                 stamped("000001759520006", .mixedArray, plain[0] + Data([0, 7, 0]) + plain[1]),
                                 stamped("000001759520007", .dictionary, Data("text".utf8)),
                                 R(.legacy, .mixedArray, plain[0] + Data([0, 1, 0]) + plain[1]),
                                 R(.legacy, .string, plain[0]),
                                 R(.inboxKey, .data, Fuzz.inboxPublicKey)])
        try queue("wrong-inbox", [R(.inboxKey, .string, Data(Data(repeating: 9, count: 32).base64EncodedString().utf8)),
                                  stamped("000001759520000", .sealed, plain[0])])
        try queue("over-cap", [publish] + (0..<52).map {
            stamped(String(format: "%015d", 1_759_520_000_000 + $0), .sealed, plain[$0 % 3])
        })
    }
}
try FuzzSeeds.main()
