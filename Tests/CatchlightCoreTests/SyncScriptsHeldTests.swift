//
//  SyncScriptsHeldTests.swift
//  CatchlightCoreTests
//
//  A device made with `holdsScripts` (the desktop, later the iPad) syncs Scripts as it syncs
//  Takes, while the phone keeps skipping them (D-315, D-325). Approved 2026-10-05 in
//  Script_Sync_Proposal_v1.0.md. Two "Macs" and a "phone" share one in-memory folder.
//

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import CatchlightCoreTestSupport
@testable import CatchlightCore

final class SyncScriptsHeldTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private var keys: KeyHierarchy!
    private var cloud: InMemoryCloudFolder!

    override func setUp() {
        keys = KeyHierarchy(masterKey: SymmetricKey(size: .bits256))
        cloud = InMemoryCloudFolder()
    }

    private struct Device {
        let store = InMemoryTakeStore()
        let id = UUID()
        let holdsScripts: Bool
    }

    @discardableResult
    private func sync(_ d: Device, at: Date) throws -> SyncReport {
        try TestFixtures.engine(store: d.store, cloud: cloud, keys: keys, deviceId: d.id,
                                now: { at }, holdsScripts: d.holdsScripts).sync()
    }

    private func script(_ text: String, at: Date, pageMode: String? = Take.PageMode.a4) -> Take {
        Take(createdAt: at, modifiedAt: at, blocks: [.text(TextBlock(text: text))],
             kind: ManifestEntry.Kind.script, pageMode: pageMode)
    }

    private func entry(_ id: UUID) throws -> ManifestEntry? {
        try Manifest.readEncrypted(from: cloud, keys: keys).takes.first { $0.uuid == id }
    }

    func testAScriptCrossesBetweenTwoMacsAndThePhoneNeverHoldsIt() throws {
        let macA = Device(holdsScripts: true), macB = Device(holdsScripts: true), phone = Device(holdsScripts: false)
        let s = script("# Winter series", at: t0)
        try macA.store.upsert(s)

        XCTAssertEqual(try sync(macA, at: t0.addingTimeInterval(1)).uploaded, [s.id])
        XCTAssertEqual(try entry(s.id)?.kind, ManifestEntry.Kind.script)

        XCTAssertEqual(try sync(macB, at: t0.addingTimeInterval(2)).applied, [s.id])
        let onB = try XCTUnwrap(try macB.store.take(id: s.id))
        XCTAssertTrue(onB.isScript)
        XCTAssertEqual(onB.pageMode, Take.PageMode.a4)
        XCTAssertEqual(onB.plainText, "# Winter series")

        try sync(phone, at: t0.addingTimeInterval(3))
        XCTAssertNil(try phone.store.take(id: s.id), "the phone never fetches a Script")
        XCTAssertEqual(try entry(s.id)?.kind, ManifestEntry.Kind.script, "and its push leaves the entry alone")
    }

    func testTakeToScriptAndBackIsAKindChangeOnTheSameId() throws {
        let mac = Device(holdsScripts: true), phone = Device(holdsScripts: false)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Captured on the phone"))])
        try phone.store.upsert(take)
        try sync(phone, at: t0.addingTimeInterval(1))
        try sync(mac, at: t0.addingTimeInterval(2))

        // The Mac turns it into a Script: same id, kind changes, nothing deleted.
        take = try XCTUnwrap(try mac.store.take(id: take.id))
        take.kind = ManifestEntry.Kind.script
        take.pageMode = Take.PageMode.usLetter
        take.modifiedAt = t0.addingTimeInterval(10)
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(11))
        XCTAssertEqual(try entry(take.id)?.kind, ManifestEntry.Kind.script)
        XCTAssertTrue(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.isEmpty, "no deletion record")

        // The phone lets its copy go, without a tombstone (D-315).
        let report = try sync(phone, at: t0.addingTimeInterval(12))
        XCTAssertEqual(report.deletedLocally, [take.id])
        XCTAssertNil(try phone.store.take(id: take.id))

        // And back to a Take on the Mac: the phone gets it again.
        take = try XCTUnwrap(try mac.store.take(id: take.id))
        take.kind = nil
        take.modifiedAt = t0.addingTimeInterval(20)
        try mac.store.upsert(take)
        XCTAssertNil(try mac.store.take(id: take.id)?.pageMode, "a Take carries no page mode")
        try sync(mac, at: t0.addingTimeInterval(21))
        XCTAssertNil(try entry(take.id)?.kind)
        try sync(phone, at: t0.addingTimeInterval(22))
        XCTAssertEqual(try phone.store.take(id: take.id)?.plainText, "Captured on the phone")
    }

    func testDeletingAScriptOnOneMacDeletesItOnTheOther() throws {
        let macA = Device(holdsScripts: true), macB = Device(holdsScripts: true), phone = Device(holdsScripts: false)
        let s = script("Exhibition proposal", at: t0)
        try macA.store.upsert(s)
        try sync(macA, at: t0.addingTimeInterval(1))
        try sync(macB, at: t0.addingTimeInterval(2))
        try sync(phone, at: t0.addingTimeInterval(3))

        try macA.store.delete(id: s.id)
        try sync(macA, at: t0.addingTimeInterval(10))
        XCTAssertNil(try entry(s.id))
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.map(\.uuid), [s.id])
        XCTAssertNil(try cloud.read("\(s.id.uuidString).clk"))

        try sync(macB, at: t0.addingTimeInterval(11))
        XCTAssertNil(try macB.store.take(id: s.id))
        try sync(phone, at: t0.addingTimeInterval(12))   // nothing to do, nothing breaks
        XCTAssertNil(try phone.store.take(id: s.id))
    }

    func testAScriptChangedOnTwoMacsIsAConflictAndTheCloudKeepsTheOther() throws {
        let macA = Device(holdsScripts: true), macB = Device(holdsScripts: true)
        var s = script("Draft", at: t0)
        try macA.store.upsert(s)
        try sync(macA, at: t0.addingTimeInterval(1))
        try sync(macB, at: t0.addingTimeInterval(2))

        s.blocks = [.text(TextBlock(text: "Draft, edited on A"))]
        s.modifiedAt = t0.addingTimeInterval(10)
        try macA.store.upsert(s)
        var onB = try XCTUnwrap(try macB.store.take(id: s.id))
        onB.blocks = [.text(TextBlock(text: "Draft, edited on B"))]
        onB.modifiedAt = t0.addingTimeInterval(11)
        try macB.store.upsert(onB)

        try sync(macA, at: t0.addingTimeInterval(12))
        let report = try sync(macB, at: t0.addingTimeInterval(13))
        XCTAssertEqual(report.conflicts.map(\.local.id), [s.id])
        XCTAssertTrue(report.conflicts.first?.remote.isScript ?? false)
        // #17's hold applies to Scripts too: B's version did not replace A's in the cloud.
        let fresh = Device(holdsScripts: true)
        try sync(fresh, at: t0.addingTimeInterval(15))
        XCTAssertEqual(try fresh.store.take(id: s.id)?.plainText, "Draft, edited on A")
    }

    func testAKindFromANewerClientIsStillLeftAlone() throws {
        let mac = Device(holdsScripts: true)
        let future = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "storyboard"))], kind: "storyboard")
        let elsewhere = Device(holdsScripts: true)
        try elsewhere.store.upsert(future)
        try sync(elsewhere, at: t0.addingTimeInterval(1))
        XCTAssertEqual(try entry(future.id)?.kind, "storyboard")

        try sync(mac, at: t0.addingTimeInterval(2))
        XCTAssertNil(try mac.store.take(id: future.id), "an unknown kind is never fetched")
        XCTAssertEqual(try entry(future.id)?.kind, "storyboard", "and carried forward untouched")
    }

    func testThePhonesEngineIsUnchangedByDefault() {
        let engine = TestFixtures.engine(store: InMemoryTakeStore(), cloud: cloud, keys: keys)
        XCTAssertFalse(engine.holdsScripts)
        XCTAssertFalse(engine.holds(ManifestEntry(uuid: UUID(), modified: "", hmac: "", kind: ManifestEntry.Kind.script)))
        XCTAssertTrue(engine.holds(ManifestEntry(uuid: UUID(), modified: "", hmac: "")))
    }

    /// Local review: an item whose entry has a kind this device can't hold keeps that kind, even
    /// when this device holds an edit to it. Uploading must never turn a newer client's item back
    /// into a Take.
    func testALocalEditNeverOverwritesAKindThisDeviceCannotHold() throws {
        let mac = Device(holdsScripts: true)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Plain"))])
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(1))

        // The entry now names a kind this Mac doesn't know, stamped no later than the Mac's last
        // sync (clock skew, say), so the pull keeps the Mac's later edit rather than forking it.
        var manifest = try Manifest.readEncrypted(from: cloud, keys: keys)
        manifest.takes = manifest.takes.map { e in
            e.uuid == take.id ? ManifestEntry(uuid: e.uuid, modified: e.modified, hmac: e.hmac, kind: "storyboard") : e
        }
        try Manifest.writeEncrypted(manifest, to: cloud, keys: keys)

        take.blocks = [.text(TextBlock(text: "Plain, edited on the Mac"))]
        take.modifiedAt = t0.addingTimeInterval(5)
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(6))
        XCTAssertEqual(try entry(take.id)?.kind, "storyboard", "the newer client's kind stands, as on the phone")
    }

    /// A device that doesn't hold Scripts never uploads one it finds in its own store (the Mac,
    /// with Scripts in its library and the switch off). Uploading it would write a Take entry,
    /// and the phone would show the Script as a Take.
    func testADeviceThatDoesNotHoldScriptsNeverUploadsItsOwn() throws {
        let mac = Device(holdsScripts: false), phone = Device(holdsScripts: false)
        let s = script("Mac only", at: t0)
        try mac.store.upsert(s)

        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(1)).uploaded, [], "first pass: every local item is new")
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(2)).uploaded, [], "later pass: the self-heal step")
        XCTAssertNil(try entry(s.id))
        XCTAssertNil(try cloud.read("\(s.id.uuidString).clk"))
        try sync(phone, at: t0.addingTimeInterval(3))
        XCTAssertNil(try phone.store.take(id: s.id))
        XCTAssertTrue(try XCTUnwrap(try mac.store.take(id: s.id)).isScript, "and the Mac keeps it")
    }

    /// A Take made a Script on such a device stays a Take in the folder, as it was: the change of
    /// kind can't be sent, and sending the Script's text as the Take's would show it on the phone.
    func testATakeMadeAScriptWhereScriptsAreNotHeldStaysAsItWasInTheFolder() throws {
        let mac = Device(holdsScripts: false), phone = Device(holdsScripts: false)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Captured"))])
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(1))
        try sync(phone, at: t0.addingTimeInterval(2))

        take.kind = ManifestEntry.Kind.script
        take.blocks = [.text(TextBlock(text: "# Captured, expanded into a Script"))]
        take.modifiedAt = t0.addingTimeInterval(10)
        try mac.store.upsert(take)
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(11)).uploaded, [])
        XCTAssertNil(try entry(take.id)?.kind)
        let fresh = Device(holdsScripts: false)
        try sync(fresh, at: t0.addingTimeInterval(12))
        XCTAssertEqual(try fresh.store.take(id: take.id)?.plainText, "Captured")
        // The Take and the Script now differ for good; with no change to the Take, no conflict.
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(13)).conflicts.count, 0)
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(14)).conflicts.count, 0)
    }

    /// Local review: the phone still shows the Take a non-holding device made a Script. Deleting
    /// it there deletes the Take only; the Script stays (D-325).
    func testDeletingTheOldTakeElsewhereKeepsAScriptWhereScriptsAreNotHeld() throws {
        let mac = Device(holdsScripts: false), phone = Device(holdsScripts: false)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Captured"))])
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(1))
        try sync(phone, at: t0.addingTimeInterval(2))
        take.kind = ManifestEntry.Kind.script
        take.modifiedAt = t0.addingTimeInterval(10)
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(11))

        try phone.store.delete(id: take.id)
        try sync(phone, at: t0.addingTimeInterval(20))
        XCTAssertTrue(try XCTUnwrap(try sync(mac, at: t0.addingTimeInterval(21))).deletedLocally.isEmpty)
        XCTAssertTrue(try XCTUnwrap(try mac.store.take(id: take.id)).isScript)
    }

    /// Local review: an edit to the old Take from elsewhere never replaces the Script it became
    /// on a non-holding device. Both changed, so it is a conflict for the user to settle.
    func testAnEditToTheOldTakeElsewhereIsAConflictWithTheScript() throws {
        let mac = Device(holdsScripts: false), phone = Device(holdsScripts: false)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Captured"))])
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(1))
        try sync(phone, at: t0.addingTimeInterval(2))
        take.kind = ManifestEntry.Kind.script
        take.blocks = [.text(TextBlock(text: "# Captured, as a Script"))]
        take.modifiedAt = t0.addingTimeInterval(10)
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(11))   // the Script is now older than the last sync

        var onPhone = try XCTUnwrap(try phone.store.take(id: take.id))
        onPhone.blocks = [.text(TextBlock(text: "Captured, edited on the phone"))]
        onPhone.modifiedAt = t0.addingTimeInterval(20)
        try phone.store.upsert(onPhone)
        try sync(phone, at: t0.addingTimeInterval(21))

        let report = try sync(mac, at: t0.addingTimeInterval(22))
        XCTAssertEqual(report.conflicts.map(\.local.id), [take.id])
        XCTAssertEqual(report.conflicts.first?.remote.plainText, "Captured, edited on the phone")
        let kept = try XCTUnwrap(try mac.store.take(id: take.id))
        XCTAssertTrue(kept.isScript)
        XCTAssertEqual(kept.plainText, "# Captured, as a Script")
    }

    /// Greptile on #22: the Take deleted elsewhere, then made a Script here before this device
    /// pulled. The Script stays, and the deletion record must stay in the folder too, or a device
    /// still holding the old Take would upload it again.
    func testADeletionRecordStaysWhenTheTakeBecameAScriptHere() throws {
        let mac = Device(holdsScripts: false), phone = Device(holdsScripts: false), stale = Device(holdsScripts: false)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Captured"))])
        try phone.store.upsert(take)
        try sync(phone, at: t0.addingTimeInterval(1))
        try sync(mac, at: t0.addingTimeInterval(2))
        try sync(stale, at: t0.addingTimeInterval(3))

        try phone.store.delete(id: take.id)
        try sync(phone, at: t0.addingTimeInterval(10))
        take.kind = ManifestEntry.Kind.script
        take.modifiedAt = Date().addingTimeInterval(60)   // after the deletion, which the store stamps with the clock
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(12))

        XCTAssertTrue(try XCTUnwrap(try mac.store.take(id: take.id)).isScript)
        XCTAssertEqual(try Manifest.readEncrypted(from: cloud, keys: keys).tombstones.map(\.uuid), [take.id])
        try sync(stale, at: t0.addingTimeInterval(13))
        XCTAssertNil(try stale.store.take(id: take.id))
        XCTAssertNil(try entry(take.id))
    }

    /// Greptile on #22: keeping the Script must settle the conflict, though the Script is never
    /// uploaded. The Take and the Script differ for good, so only a change to the Take since the
    /// last sync is reported, and only by the pass that finds it.
    func testKeepingTheScriptSettlesTheConflict() throws {
        let mac = Device(holdsScripts: false), phone = Device(holdsScripts: false)
        var take = Take(createdAt: t0, modifiedAt: t0, blocks: [.text(TextBlock(text: "Captured"))])
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(1))
        try sync(phone, at: t0.addingTimeInterval(2))
        take.kind = ManifestEntry.Kind.script
        take.modifiedAt = t0.addingTimeInterval(10)
        try mac.store.upsert(take)
        try sync(mac, at: t0.addingTimeInterval(11))
        var onPhone = try XCTUnwrap(try phone.store.take(id: take.id))
        onPhone.blocks = [.text(TextBlock(text: "Edited on the phone"))]
        onPhone.modifiedAt = t0.addingTimeInterval(20)
        try phone.store.upsert(onPhone)
        try sync(phone, at: t0.addingTimeInterval(21))
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(22)).conflicts.count, 1)
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(23)).conflicts.count, 0, "reported once, chosen or not")

        // The user keeps the Script: stamped as a fresh edit, as the apps resolve a conflict.
        take = try XCTUnwrap(try mac.store.take(id: take.id))
        take.modifiedAt = t0.addingTimeInterval(30)
        try mac.store.upsert(take)
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(31)).conflicts.count, 0)
        XCTAssertEqual(try sync(mac, at: t0.addingTimeInterval(32)).conflicts.count, 0)
        XCTAssertTrue(try XCTUnwrap(try mac.store.take(id: take.id)).isScript)
        XCTAssertEqual(try phone.store.take(id: take.id)?.plainText, "Edited on the phone", "the phone keeps its Take")
    }

}
