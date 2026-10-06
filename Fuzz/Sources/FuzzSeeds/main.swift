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
    }
}
try FuzzSeeds.main()
