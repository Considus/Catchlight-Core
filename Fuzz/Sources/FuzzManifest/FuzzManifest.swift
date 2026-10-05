//
//  FuzzManifest.swift — libFuzzer target: sync manifest decoding and verification.
//
//  Mode (first byte, low two bits):
//    0  the payload IS `catchlight-manifest.json` as found in the cloud folder — anyone
//       with write access to the folder controls it, without the key. Runs the public
//       decoders directly, then a full pull + push (`readVerifiedManifest`).
//    1  the payload is a v3 manifest BODY, sealed and signed with the fixed key — what a
//       device holding the key (an older or buggy build) writes. Reaches the decrypted
//       `Manifest` decoder and every pull/push branch past verification.
//    2  the payload is a v1/v2 plaintext manifest; if it decodes it is re-signed with the
//       fixed key, so the legacy path runs past verification.
//  Bit 2 picks whether the local store has a last-sync date.
//

import Foundation
import CatchlightCore
import FuzzSupport

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzManifest(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let (mode, payload) = split(fuzzData(start, count))
    let withLastSync = mode & 0b100 != 0
    let cloud = InMemoryCloudFolder()

    switch mode & 0b11 {
    case 0:
        _ = ManifestEnvelope.peekVersion(payload)
        if let envelope = try? ManifestEnvelope.parse(payload) {
            _ = try? Fuzz.signer.verify(envelope)
            _ = try? Manifest.opening(envelope, with: Fuzz.manifestKey)
        }
        if let manifest = try? Manifest.parse(payload) {
            _ = try? Fuzz.signer.verify(manifest)
        }
        try? cloud.write(payload, to: Manifest.fileName)
    case 1:
        guard let bytes = try? Fuzz.signedEnvelope(body: payload) else { return 0 }
        try? cloud.write(bytes, to: Manifest.fileName)
    default:
        guard let manifest = try? Manifest.parse(payload),
              let signed = try? Fuzz.signer.sign(manifest),
              let bytes = try? signed.serialise() else { return 0 }
        try? cloud.write(bytes, to: Manifest.fileName)
    }
    Fuzz.syncBothWays(cloud: cloud, withLastSync: withLastSync)
    return 0
}
