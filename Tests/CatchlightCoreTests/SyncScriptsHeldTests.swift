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

}
