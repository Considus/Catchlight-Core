//
//  FuzzPhrase.swift — libFuzzer target: recovery phrase parsing.
//
//  The payload is what a user types or pastes into the recovery field. Core ships no
//  wordlist (the apps inject the official English list), so this uses the same synthetic
//  2048-word list as the unit tests ("w0" … "w2047"); fuzz.dict carries its words.
//  Mode (first byte, low bit): 0 splits on whitespace and newlines, as a paste is split;
//  1 treats the payload as 16 bytes of entropy and round-trips it through the mnemonic.
//

import Foundation
import CatchlightCore
import FuzzSupport

private let bip39 = BIP39(wordlist: try! BIP39Wordlist(words: (0..<2048).map { "w\($0)" }))

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzPhrase(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let (mode, payload) = split(fuzzData(start, count))
    if mode & 1 == 0 {
        let text = String(decoding: payload, as: UTF8.self)
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        _ = try? PhraseRecovery.recoverMasterKey(from: words, bip39: bip39)
        _ = try? bip39.validate(mnemonic: words)
    } else if let mnemonic = try? bip39.mnemonic(fromEntropy: payload) {
        _ = try? PhraseRecovery.recoverMasterKey(from: mnemonic, bip39: bip39)
    }
    return 0
}
