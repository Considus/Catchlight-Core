//
//  FuzzBlob.swift — libFuzzer target: cloud blob envelope and Take decryption.
//
//  Mode (first byte, low two bits):
//    0  the payload is a `.clk` file as found in the folder (no key): `CloudBlob.parse`,
//       Base64, `CryptoService.decrypt` and `TakeCrypto.open` with the fixed key.
//    1  the payload is a Take's JSON PLAINTEXT, sealed under its per-item key, wrapped in
//       a v2 blob and listed in a signed manifest — what a device holding the key writes.
//       Reaches `TakeCrypto.open`'s Take decoder and the pull merge.
//    2  the payload is the raw `.clk` file, listed in a signed manifest with its correct
//       HMAC, so the engine's own blob parsing runs past the HMAC check.
//  Bit 2 picks whether the local store has a last-sync date; bit 3 whether the listed
//  id is one the store already holds (conflict path) or a new one.
//

import Foundation
import CatchlightCore
import FuzzSupport

private let crypto = TakeCrypto(keys: Fuzz.keys)

private func plant(blob: Data, id: UUID, in cloud: InMemoryCloudFolder) {
    let entry = ManifestEntry(uuid: id, modified: "2026-07-01T00:00:00.000Z",
                              hmac: Fuzz.signer.blobHMACHex(blob))
    let manifest = Manifest(updated: "2026-07-01T00:00:00.000Z", takes: [entry])
    guard let body = try? manifest.serialise(),
          let envelope = try? Fuzz.signedEnvelope(body: body) else { return }
    try? cloud.write(envelope, to: Manifest.fileName)
    try? cloud.write(blob, to: CloudBlob.fileName(for: id))
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzBlob(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let (mode, payload) = split(fuzzData(start, count))
    let withLastSync = mode & 0b100 != 0
    let id = mode & 0b1000 != 0 ? Fuzz.localId : Fuzz.takeId

    switch mode & 0b11 {
    case 0:
        if let blob = try? CloudBlob.parse(payload), let ciphertext = blob.ciphertext {
            _ = try? CryptoService.decrypt(ciphertext, key: Fuzz.manifestKey)
            _ = try? crypto.open(ciphertext, takeUUID: id)
        }
        _ = try? crypto.open(payload, takeUUID: id)
        return 0
    case 1:
        guard let sealed = try? encryptTake(payload, masterKey: Fuzz.keys.masterKey, takeUUID: id) else { return 0 }
        _ = try? crypto.open(sealed, takeUUID: id)
        let blob = CloudBlob(encryptedPayload: sealed.base64EncodedString())
        guard let bytes = try? blob.serialise() else { return 0 }
        let cloud = InMemoryCloudFolder()
        plant(blob: bytes, id: id, in: cloud)
        Fuzz.syncBothWays(cloud: cloud, withLastSync: withLastSync)
    default:
        let cloud = InMemoryCloudFolder()
        plant(blob: payload, id: id, in: cloud)
        Fuzz.syncBothWays(cloud: cloud, withLastSync: withLastSync)
    }
    return 0
}
