//
//  FuzzCaptureInbox.swift — libFuzzer target: the capture inbox and the shared queue (R7).
//
//  The App Group defaults are written by the share extension, the Siri intents and older
//  builds, and read back by the app; nothing in them is authenticated except what opens.
//  Mode (first byte):
//    bit 0 = 0  `CaptureInbox.open` with the fixed inbox key. The payload is the value as
//               UTF-8 text (bit 1 prepends "sealed1:"), or with bit 2 set, raw bytes sent as
//               "sealed1:" + base64(payload), which reaches HPKE itself.
//    bit 0 = 1  A throwaway defaults suite seeded with `FuzzDefaultsRecord`s, then read with
//               and without the key (`sharedQueueEntries`, `unopenableSharedEntries`), then
//               drained with `clearShared`. Bit 1 also enqueues a share over the same keys,
//               the writer's read of the queue (`enqueueShared`).
//
//  `FUZZ_CAPTURE_MODE=open` or `=defaults` pins bit 0, to give each half a run of its own.
//
//  Besides traps, it checks what the API documents, and traps itself when that breaks:
//  every string under `capture.shared.` reads as an entry or as unopenable; a drain of both
//  leaves nothing readable; an enqueued share opens, sorts after every key in the writer's
//  format, and keeps the cap.
//

import Foundation
import CatchlightCore
import FuzzSupport

private let suiteName = "fuzz.capture-inbox"
private let defaults = UserDefaults(suiteName: suiteName)!

private let pinnedMode: UInt8? = {
    switch ProcessInfo.processInfo.environment["FUZZ_CAPTURE_MODE"] {
    case "open": return 0
    case "defaults": return 1
    default: return nil
    }
}()

private func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if !ok { fatalError("invariant: \(what())") }
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzCaptureInbox(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    var (mode, payload) = split(fuzzData(start, count))
    if let pinnedMode { mode = mode & ~1 | pinnedMode }
    if mode & 1 == 0 {
        let value: String
        if mode & 4 != 0 {
            value = "sealed1:" + payload.base64EncodedString()
        } else {
            value = (mode & 2 != 0 ? "sealed1:" : "") + String(decoding: payload, as: UTF8.self)
        }
        _ = try? CaptureInbox.open(value, with: Fuzz.inboxKey)
        return 0
    }

    defaults.removePersistentDomain(forName: suiteName)
    for record in FuzzDefaultsRecord.parse(payload) {
        defaults.set(record.plistValue, forKey: record.defaultsKey)
    }
    let keyedStrings = defaults.dictionaryRepresentation().filter {
        $0.key.hasPrefix(FuzzDefaultsRecord.sharedPrefix) && $0.value is String
    }
    let legacyCount = defaults.stringArray(forKey: FuzzDefaultsRecord.legacyKey)?.count ?? 0
    let unsealed = keyedStrings.values.filter { !($0 as! String).hasPrefix("sealed1:") }.count

    let blind = CaptureRouting.sharedQueueEntries(opening: nil, defaults: defaults)
    let entries = CaptureRouting.sharedQueueEntries(opening: Fuzz.inboxKey, defaults: defaults)
    let lost = CaptureRouting.unopenableSharedEntries(opening: Fuzz.inboxKey, defaults: defaults)
    check(blind.count == legacyCount + unsealed, "without the key: \(blind.count) read, \(legacyCount) legacy + \(unsealed) unsealed")
    check(entries.count + lost.count == legacyCount + keyedStrings.count,
          "with the key: \(entries.count) read + \(lost.count) unopenable, \(legacyCount) legacy + \(keyedStrings.count) keyed")

    if mode & 2 != 0 {
        let wrote = CaptureRouting.enqueueShared(CaptureRouting.SharedItem(text: "fuzz-new-share"),
                                                 defaults: defaults, now: Fuzz.now)
        let keyedAfter = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix(FuzzDefaultsRecord.sharedPrefix) && $0.value is String
        }
        let published = defaults.string(forKey: FuzzDefaultsRecord.inboxPublicKeyKey).flatMap { Data(base64Encoded: $0) }
        if wrote && published == Fuzz.inboxPublicKey {
            // "a share always sorts after the ones before it": the ones in the writer's own
            // format, 15 zero-padded digits. Keys sort as strings, so nothing can promise to
            // sort after a key no writer makes (`capture.shared.zzz`, or 16 digits).
            let timed = keyedAfter.keys.filter {
                let digits = $0.dropFirst(FuzzDefaultsRecord.sharedPrefix.count).prefix { $0 != "." }
                return digits.count == 15 && digits.allSatisfy { $0.isASCII && $0.isWholeNumber }
            }.sorted()
            let mine = keyedAfter.first { key, value in
                (try? CaptureInbox.open(value as! String, with: Fuzz.inboxKey)).map {
                    String(decoding: $0, as: UTF8.self).contains("fuzz-new-share")
                } ?? false
            }?.key
            check(mine != nil, "the new share does not open")
            check(timed.contains(mine!), "the new share's key \(mine!) is outside the writer's format")
            check(mine == timed.last, "the new share \(mine ?? "-") sorts before \(timed.last ?? "-")")
            check(keyedAfter.count <= CaptureRouting.sharedQueueCap, "\(keyedAfter.count) keyed after the cap")
        }
    }

    let now = CaptureRouting.sharedQueueEntries(opening: Fuzz.inboxKey, defaults: defaults)
    CaptureRouting.clearShared(now, defaults: defaults)
    CaptureRouting.clearShared(CaptureRouting.unopenableSharedEntries(opening: Fuzz.inboxKey, defaults: defaults),
                               defaults: defaults)
    let left = CaptureRouting.sharedQueueEntries(opening: Fuzz.inboxKey, defaults: defaults).count
        + CaptureRouting.unopenableSharedEntries(opening: Fuzz.inboxKey, defaults: defaults).count
    check(left == 0, "\(left) left after draining")
    return 0
}
