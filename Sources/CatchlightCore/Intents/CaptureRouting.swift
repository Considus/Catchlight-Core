//
//  CaptureRouting.swift
//  CatchlightCore — App Intents / Widgets (2026-06-23)
//
//  The capture-mode-agnostic routing contract shared by the app target, the
//  WidgetKit extension, the New Take App Intent, the Control, and the App
//  Shortcut. One enum + one URL scheme + one App-Group hand-off, so every
//  "open Catchlight and start capturing" surface funnels through the SAME
//  drain in the app (`CatchlightApp.drainPendingCapture`).
//
//  WHY this lives in Core: it is pure Foundation (no UIKit / WidgetKit), and
//  BOTH the app and the extension link CatchlightCore, so the contract can't
//  drift between processes. The widget writes a `pendingMode`, opens the app,
//  and the app reads the SAME key back out of the shared App Group.
//
//  CAPTURE-MODE-AGNOSTIC BY DESIGN (owner 2026-06-23): `text` ships now; `audio`
//  is reserved so the audio-recording widget/intent is a drop-in later (it adds
//  a case, not a new pipe). Routing never hard-codes "text".
//
//  PRIVACY: nothing here touches the encrypted store. The hand-off carries only a
//  capture MODE and, for the share sheet and Siri, the text the user themselves just
//  shared or dictated — never existing content — and that text is queued SEALED to
//  the capture inbox's public key (R7, `CaptureInbox`), never in the clear.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CaptureRouting {

    // MARK: - Capture mode

    /// What a capture surface asks the app to open into. Agnostic so new capture
    /// kinds slot in without new plumbing. `text` is live; `audio` is reserved
    /// for the audio-Take recording flow (the widget/intent exist before the
    /// recording engine does, and simply no-op until it ships).
    public enum Mode: String, Sendable, CaseIterable {
        case text
        /// Create a new Take pre-flagged as the Obie (the store's single-Obie
        /// upsert demotes the previous Obie on save). "Obie this in Catchlight".
        case obie
        case audio
    }

    // MARK: - Deep-link URL scheme (widgets use `widgetURL`)

    /// Custom URL scheme registered in the app's Info.plist (`CFBundleURLTypes`).
    /// Launcher widgets deep-link through this; the Control and Shortcuts/Siri use
    /// the App Intent directly. Both ultimately write the same pending hand-off.
    public static let urlScheme = "catchlight"

    /// Host segment identifying a "new capture" deep link: `catchlight://new?mode=text`.
    public static let captureHost = "new"

    private static let modeQueryItem = "mode"

    /// Build the deep-link a launcher widget hands to `widgetURL` / `Link`.
    public static func captureURL(_ mode: Mode) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = captureHost
        components.queryItems = [URLQueryItem(name: modeQueryItem, value: mode.rawValue)]
        // Force-unwrap is safe: every component above is a valid literal.
        return components.url!
    }

    /// Parse an incoming `onOpenURL` URL into a capture mode, or nil if it isn't
    /// one of ours. An unknown/missing `mode` defaults to `.text` (the only mode
    /// a current build can act on) so a malformed launch still captures.
    public static func mode(from url: URL) -> Mode? {
        guard url.scheme == urlScheme, url.host == captureHost else { return nil }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == modeQueryItem })?.value
        return raw.flatMap(Mode.init(rawValue:)) ?? .text
    }

    // MARK: - Cross-process hand-off (App Group)

    /// Shared suite both processes read/write. Matches the app group in
    /// `Catchlight.entitlements`.
    public static let appGroupSuite = "group.com.considus.catchlight"

    private static let pendingModeKey = "capture.pendingMode"
    private static let pendingTextKey = "capture.pendingText"

    /// A queued capture the app hasn't consumed yet. Written by an intent/widget,
    /// drained by the app once it is foregrounded AND unlocked.
    public struct Pending: Sendable, Equatable {
        public let mode: Mode
        /// Prose to pre-fill the new Take with (Siri/Shortcuts "Add a Take '…'").
        /// nil for a pure launcher (open to a blank editor).
        public let text: String?
        public init(mode: Mode, text: String? = nil) {
            self.mode = mode
            self.text = text
        }
    }

    /// Record a capture request for the app to pick up on next activation.
    /// No-op if the App Group is unavailable (the app simply opens normally).
    public static func setPending(_ pending: Pending,
                                  defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        guard let defaults else { return }
        defaults.set(pending.mode.rawValue, forKey: pendingModeKey)
        if let text = pending.text, !text.isEmpty {
            defaults.set(text, forKey: pendingTextKey)
        } else {
            defaults.removeObject(forKey: pendingTextKey)
        }
    }

    /// Read the queued capture without consuming it.
    public static func pending(defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) -> Pending? {
        guard let defaults,
              let raw = defaults.string(forKey: pendingModeKey),
              let mode = Mode(rawValue: raw) else { return nil }
        return Pending(mode: mode, text: defaults.string(forKey: pendingTextKey))
    }

    /// Clear the queued capture once the app has acted on it (or chose not to).
    public static func clearPending(defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        defaults?.removeObject(forKey: pendingModeKey)
        defaults?.removeObject(forKey: pendingTextKey)
    }

    // MARK: - Shared-item queue (Share Extension, 2026-08-11)

    /// Where builds before the per-key queue kept every share, as one string array. Still
    /// read and drained so shares queued by an older build land; nothing writes it any more.
    private static let legacySharedQueueKey = "capture.sharedQueue"

    /// Each share lives under its OWN key, `capture.shared.<ms since 1970>.<uuid>`. The share
    /// extension and the app are different processes writing the same App Group defaults, and
    /// a single array read, changed and written back by both lost whichever write came first
    /// (a share made while the app was draining vanished unread). Writing one key per share
    /// leaves nothing to read back: an enqueue only adds its key, and a drain removes only
    /// the keys it read. The zero-padded time prefix makes key order queue order.
    private static let sharedKeyPrefix = "capture.shared."

    /// The capture inbox's PUBLIC key (`CaptureInbox`), published by the app at each unlock.
    /// Not secret: it only lets a writer seal, never open.
    private static let inboxPublicKeyKey = "capture.inboxPublicKey"

    /// How many shared items the queue holds before it starts dropping the OLDEST.
    ///
    /// The queue only drains when the app is opened AND unlocked, so an unbounded one would
    /// grow without limit on a device where Catchlight isn't opened for a week. 50 is far
    /// beyond any realistic share-then-open gap while still bounding the App Group defaults —
    /// and dropping the oldest, not the newest, keeps the share the user just made.
    public static let sharedQueueCap = 50

    /// One queued share: the content, plus how the user shaped it on the share sheet
    /// (owner 2026-08-11 — the sheet gained Obie / Important / Task toggles, so the shaping has
    /// to survive the hand-off, not just the text).
    ///
    /// Encoded as JSON, then sealed. Decoding an UNSEALED value falls back to treating a bare
    /// string as plain text, so an item queued by an older build still lands rather than being
    /// dropped as unparseable.
    public struct SharedItem: Codable, Equatable, Sendable {
        public var text: String
        /// Capture it as the Obie. Set by the Siri "New Obie" capture, NOT by the share sheet —
        /// the sheet briefly carried Obie / Important / Task pills and the owner cut them as
        /// off-brand (2026-08-11). Those two flags went with them rather than lingering as dead
        /// fields; decoding ignores unknown keys, so anything already queued still reads.
        public var isObie: Bool

        public init(text: String, isObie: Bool = false) {
            self.text = text
            self.isObie = isObie
        }
    }

    /// A queued item together with where it is stored, so a drain can remove exactly the
    /// items it read (`clearShared(_:)`). `storageKey` is nil for an item in the legacy array,
    /// which is found again by its stored text (`legacyRaw`) rather than by its position.
    public struct SharedEntry: Equatable, Sendable {
        public let item: SharedItem
        let storageKey: String?
        var legacyRaw: String? = nil
    }

    /// A queued value that is sealed but would not open: sealed to an inbox this account no
    /// longer holds (the account was erased or replaced since), or damaged. Its content is
    /// gone for good, so the app tells the user and clears it (`clearShared(_:)`).
    public struct UnopenableEntry: Equatable, Sendable {
        let storageKey: String
    }

    // MARK: Inbox key

    /// Publish the inbox's public key so writers can seal to it. The app calls this at each
    /// unlock, so the key always belongs to the account that will open what is queued.
    public static func publishInboxKey(_ publicKey: Data,
                                       defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        defaults?.set(publicKey.base64EncodedString(), forKey: inboxPublicKeyKey)
    }

    /// Withdraw the inbox key (Erase everything, Second device). Captures made before the next
    /// account is set up are then refused, not sealed to a key nobody will hold.
    public static func clearInboxKey(defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        defaults?.removeObject(forKey: inboxPublicKeyKey)
    }

    static func inboxPublicKey(defaults: UserDefaults) -> Data? {
        defaults.string(forKey: inboxPublicKeyKey).flatMap { Data(base64Encoded: $0) }
    }

    // MARK: Writing

    /// Append a shared item for the app to turn into a Take on next open. Returns false when
    /// nothing was queued: empty text, no App Group, or no inbox key yet (Catchlight hasn't been
    /// set up, or the account was just erased). The caller tells the user to open Catchlight.
    ///
    /// A QUEUE, deliberately, where the widget hand-off above is a single slot. A launcher
    /// widget is idempotent — tapping it twice should not make two blank Takes, so last-wins is
    /// correct there. Sharing is the opposite: each share is a distinct piece of content the
    /// user expects to keep, and share-three-articles-then-open-the-app is ordinary behaviour.
    /// Reusing `setPending` would have silently kept only the last one.
    ///
    /// Runs in the SHARE EXTENSION's process, or in a Siri intent on a locked phone, so it never
    /// touches the encrypted store: the master key is `.userPresence`-gated and only
    /// materialises in the foreground app, which is why the writer queues rather than saves.
    /// What it queues is SEALED to the inbox's public key (R7, `CaptureInbox`), so the text is
    /// never written in the clear; only the app, unlocked, can open it.
    @discardableResult
    public static func enqueueShared(_ item: SharedItem,
                                     defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite),
                                     now: Date = Date()) -> Bool {
        var item = item
        item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let defaults, !item.text.isEmpty,
              let publicKey = inboxPublicKey(defaults: defaults),
              let encoded = try? PlatformJSON.encode(item),
              let sealed = try? CaptureInbox.seal(encoded, to: publicKey) else { return false }
        // Never earlier than a key already queued, so a share always sorts after the ones
        // before it even when the device clock has moved back (a manual change or an NTP
        // correction). The count-based clear and the cap both rely on that order. Reading the
        // existing keys here writes nothing back, so it adds no race.
        let newest = queuedKeys(defaults: defaults).compactMap(millis(fromKey:)).max()
        let clock = max(0, Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))
        let stamp = String(max(clock, (newest ?? -1) + 1))
        let key = sharedKeyPrefix + String(repeating: "0", count: max(0, 15 - stamp.count)) + stamp
            + "." + UUID().uuidString
        defaults.set(sealed, forKey: key)

        // Over the cap: drop the oldest. Removing a key another process already removed is
        // harmless, so this needs no coordination either. Only per-key entries count and are
        // trimmed: trimming the legacy array would make this process a writer of it again,
        // racing the app's drain, and an older build already capped that array itself.
        // The share just written is never trimmed, whatever its key sorts as.
        let keyed = queuedKeys(defaults: defaults)
        if keyed.count > sharedQueueCap {
            let older = keyed.filter { $0 != key }
            for old in older.prefix(keyed.count - sharedQueueCap) { defaults.removeObject(forKey: old) }
        }
        return true
    }

    /// Convenience for a plain text/link share with no shaping.
    @discardableResult
    public static func enqueueShared(_ text: String,
                                     defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) -> Bool {
        enqueueShared(SharedItem(text: text), defaults: defaults)
    }

    // MARK: Reading

    /// Read the queued items, oldest first, WITHOUT consuming them. The app drops them with
    /// `clearShared(_:)` only once the Takes are safely written, so a crash or a failed save
    /// between the two does not lose the user's content.
    ///
    /// Sealed items open with `inbox`, the private key only the unlocked app can derive
    /// (`KeyHierarchy.captureInboxPrivateKey()`). Without it, or when one won't open, a sealed
    /// item is left out, never handed back as text: `unopenableSharedEntries` lists those.
    /// Unsealed items, which only an older build wrote, read as before.
    public static func sharedQueueEntries(opening inbox: Curve25519.KeyAgreement.PrivateKey? = nil,
                                          defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) -> [SharedEntry] {
        guard let defaults else { return [] }
        let legacy = (defaults.stringArray(forKey: legacySharedQueueKey) ?? [])
            .map { SharedEntry(item: decodeUnsealed($0), storageKey: nil, legacyRaw: $0) }
        let keyed = keyedValues(defaults: defaults).compactMap { key, raw -> SharedEntry? in
            guard CaptureInbox.isSealed(raw) else { return SharedEntry(item: decodeUnsealed(raw), storageKey: key) }
            guard let inbox, let item = open(raw, with: inbox) else { return nil }
            return SharedEntry(item: item, storageKey: key)
        }
        return legacy + keyed
    }

    /// The queued items alone, oldest first. Sealed items open with `inbox`, as above.
    public static func sharedQueue(opening inbox: Curve25519.KeyAgreement.PrivateKey? = nil,
                                   defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) -> [SharedItem] {
        sharedQueueEntries(opening: inbox, defaults: defaults).map(\.item)
    }

    /// Sealed items `inbox` cannot open. Nothing can open them, so the app reports how many
    /// were lost and clears them.
    public static func unopenableSharedEntries(opening inbox: Curve25519.KeyAgreement.PrivateKey,
                                               defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) -> [UnopenableEntry] {
        guard let defaults else { return [] }
        return keyedValues(defaults: defaults)
            .filter { CaptureInbox.isSealed($0.1) && open($0.1, with: inbox) == nil }
            .map { UnopenableEntry(storageKey: $0.0) }
    }

    // MARK: Clearing

    /// Drop exactly these entries, which the app has now committed. A share that arrived
    /// after they were read has its own key and is left alone.
    public static func clearShared(_ entries: [SharedEntry],
                                   defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        guard let defaults else { return }
        for key in entries.compactMap(\.storageKey) { defaults.removeObject(forKey: key) }
        let legacyDone = entries.compactMap(\.legacyRaw)
        guard !legacyDone.isEmpty else { return }
        // Remove each committed item by its text, not by position, so a share the app failed
        // to save stays queued even when a later one was saved. Only an older build ever wrote
        // this array. Its share extension could still append during the update itself, and that
        // append can be lost here; iOS stops an app's extensions when it updates the app, so
        // the window is the update, not normal use.
        var legacy = defaults.stringArray(forKey: legacySharedQueueKey) ?? []
        for raw in legacyDone {
            if let i = legacy.firstIndex(of: raw) { legacy.remove(at: i) }
        }
        if legacy.isEmpty {
            defaults.removeObject(forKey: legacySharedQueueKey)
        } else {
            defaults.set(legacy, forKey: legacySharedQueueKey)
        }
    }

    /// Drop sealed entries that will never open.
    public static func clearShared(_ entries: [UnopenableEntry],
                                   defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        for entry in entries { defaults?.removeObject(forKey: entry.storageKey) }
    }

    /// Drop the first `consumed` items in queue order. Kept for callers that predate
    /// `clearShared(_:)`. A share that arrives mid-drain sorts after the ones read (enqueue
    /// never writes a key earlier than one already queued), so it is left alone. Two cases
    /// remain that only `clearShared(_:)` closes: the cap trimming the queue between the read
    /// and this call, and two extension processes enqueueing in the same instant as the read.
    /// Order counts every queued value, sealed or not, so a caller that read without the inbox
    /// key would count fewer items than this removes: use `clearShared(_:)` with sealed queues.
    public static func clearSharedQueue(consumed: Int,
                                        defaults: UserDefaults? = UserDefaults(suiteName: appGroupSuite)) {
        guard consumed > 0, let defaults else { return }
        let legacy = (defaults.stringArray(forKey: legacySharedQueueKey) ?? [])
            .map { SharedEntry(item: decodeUnsealed($0), storageKey: nil, legacyRaw: $0) }
        let keyed = queuedKeys(defaults: defaults)
            .map { SharedEntry(item: SharedItem(text: ""), storageKey: $0) }
        clearShared(Array((legacy + keyed).prefix(consumed)), defaults: defaults)
    }

    // MARK: Helpers

    /// Every per-key value, oldest first.
    private static func keyedValues(defaults: UserDefaults) -> [(String, String)] {
        defaults.dictionaryRepresentation()
            .compactMap { key, value -> (String, String)? in
                guard key.hasPrefix(sharedKeyPrefix), let raw = value as? String else { return nil }
                return (key, raw)
            }
            .sorted { $0.0 < $1.0 }
    }

    private static func queuedKeys(defaults: UserDefaults) -> [String] {
        keyedValues(defaults: defaults).map(\.0)
    }

    /// The time prefix of a per-key share, or nil for any other key.
    private static func millis(fromKey key: String) -> Int64? {
        let rest = key.dropFirst(sharedKeyPrefix.count)
        return Int64(rest.prefix { $0 != "." })
    }

    private static func open(_ sealed: String, with inbox: Curve25519.KeyAgreement.PrivateKey) -> SharedItem? {
        guard let json = try? CaptureInbox.open(sealed, with: inbox) else { return nil }
        return try? PlatformJSON.decode(SharedItem.self, from: json)
    }

    /// Tolerant on purpose: anything that isn't our JSON is treated as plain text, so a
    /// share queued by an older build lands as a Take instead of being silently dropped.
    /// Never called on a sealed value, which would otherwise land as a Take of base64.
    private static func decodeUnsealed(_ raw: String) -> SharedItem {
        (try? PlatformJSON.decode(SharedItem.self, from: Data(raw.utf8))) ?? SharedItem(text: raw)
    }
}
