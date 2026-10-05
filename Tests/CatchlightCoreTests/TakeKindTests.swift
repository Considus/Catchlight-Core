import XCTest
@testable import CatchlightCore

/// A Script's kind and page mode on the Take itself ([[D-265]], [[D-326]]). The first test is the
/// one that matters most: a Take's bytes are exactly what they were before these fields existed,
/// so nothing an older client or the phone writes or reads changes.
final class TakeKindTests: XCTestCase {

    private let id = UUID(uuidString: "6F1C2A9E-3B7D-4E2A-9C1F-0D8E7A6B5C4D")!
    private let created = Date(timeIntervalSince1970: 1_780_000_000.123)

    private func fixture(kind: String? = nil, pageMode: String? = nil) -> Take {
        Take(id: id, createdAt: created, modifiedAt: created.addingTimeInterval(60),
             blocks: [.text(TextBlock(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, text: "A line")),
                      .check(ChecklistItem(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, text: "An item", isComplete: true))],
             isNote: true, isImportant: true, manualOrder: 1.5, kind: kind, pageMode: pageMode)
    }

    /// Captured from `main` before this change (Core 1.0.2), by encoding the same fixture.
    private let golden = #"{"attachments":[],"blocks":[{"id":"11111111-2222-3333-4444-555555555555","kind":"text","text":"A line"},{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","isComplete":true,"kind":"check","text":"An item"}],"contentType":"blocks/v2","createdAt":"2026-05-28T20:26:40.123Z","id":"6F1C2A9E-3B7D-4E2A-9C1F-0D8E7A6B5C4D","isImportant":true,"isNote":true,"isObie":false,"isSeeded":false,"manualOrder":1.5,"modifiedAt":"2026-05-28T20:27:40.123Z","schemaVersion":3}"#

    func testATakeEncodesByteForByteAsBefore() throws {
        XCTAssertEqual(String(data: try PlatformJSON.encode(fixture()), encoding: .utf8), golden)
        // And a Take written before these fields existed decodes and re-encodes unchanged.
        let decoded = try PlatformJSON.decode(Take.self, from: Data(golden.utf8))
        XCTAssertNil(decoded.kind)
        XCTAssertNil(decoded.pageMode)
        XCTAssertFalse(decoded.isScript)
        XCTAssertEqual(String(data: try PlatformJSON.encode(decoded), encoding: .utf8), golden)
    }

    func testAScriptKeepsItsKindAndPageMode() throws {
        let script = fixture(kind: ManifestEntry.Kind.script, pageMode: Take.PageMode.a4)
        XCTAssertTrue(script.isScript)
        let json = String(data: try PlatformJSON.encode(script), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""kind":"script""#))
        XCTAssertTrue(json.contains(#""pageMode":"a4""#))
        let back = try PlatformJSON.decode(Take.self, from: Data(json.utf8))
        XCTAssertEqual(back, script)
        XCTAssertEqual(back.pageMode, Take.PageMode.a4)
    }

    /// One item, one encoding: "take" and "continuous" are the defaults and are never written.
    func testTheDefaultsAreNeverWritten() throws {
        let explicit = fixture(kind: ManifestEntry.Kind.take, pageMode: Take.PageMode.continuous)
        XCTAssertNil(explicit.kind)
        XCTAssertNil(explicit.pageMode)
        XCTAssertEqual(String(data: try PlatformJSON.encode(explicit), encoding: .utf8), golden)

        var script = fixture(kind: ManifestEntry.Kind.script, pageMode: Take.PageMode.usLetter)
        script.kind = ManifestEntry.Kind.take       // Script → Take ([[D-313]]): a change of kind only
        script.pageMode = Take.PageMode.continuous
        XCTAssertNil(script.kind)
        XCTAssertNil(script.pageMode)
        XCTAssertEqual(script.id, id, "same id, no copy")

        let decoded = try PlatformJSON.decode(Take.self, from: Data(golden.replacingOccurrences(
            of: #""schemaVersion":3"#, with: #""schemaVersion":3,"kind":"take","pageMode":"continuous""#).utf8))
        XCTAssertNil(decoded.kind)
        XCTAssertNil(decoded.pageMode)
    }

    /// A kind or page mode from a newer client is carried through untouched, not dropped or refused.
    func testAnUnknownKindOrPageModeSurvives() throws {
        let future = fixture(kind: "storyboard", pageMode: "a5")
        let back = try PlatformJSON.decode(Take.self, from: try PlatformJSON.encode(future))
        XCTAssertEqual(back.kind, "storyboard")
        XCTAssertEqual(back.pageMode, "a5")
        XCTAssertFalse(back.isScript)
    }

    /// The sealed payload round-trips too: what goes to the cloud is the same plaintext.
    func testASealedScriptOpensAsAScript() throws {
        let keys = KeyHierarchy(masterKeyBytes: Data(repeating: 7, count: 32))
        let crypto = TakeCrypto(keys: keys)
        let script = fixture(kind: ManifestEntry.Kind.script, pageMode: Take.PageMode.a4)
        let opened = try crypto.open(try crypto.seal(script), takeUUID: script.id)
        XCTAssertEqual(opened, script)
        XCTAssertTrue(opened.isScript)
    }
}
