//
//  LocationNameIsAutoTests.swift
//  CatchlightCoreTests
//
//  `LocationTrigger.locationNameIsAuto` records that the app filled the place's name in
//  itself (the "Current location" placeholder, a reverse-geocoded address, a search
//  result's title), so an editor reopened later can let the next place picked replace it,
//  while a name the user typed stays (owner 2026-10-11). Additive and written only when
//  true, so a place reminder without it keeps exactly the bytes it had before the field
//  existed, and an older payload decodes as a name the user chose.
//

import XCTest
@testable import CatchlightCore

final class LocationNameIsAutoTests: XCTestCase {

    /// The exact bytes a place reminder encoded to before `locationNameIsAuto` existed.
    private let golden = #"{"alarmEnabled":true,"isDone":false,"latitude":51.5,"locationName":"Office","longitude":-0.1,"radiusMetres":150,"triggerOnArrival":true}"#

    private func place(named name: String = "Office") -> LocationTrigger {
        LocationTrigger(latitude: 51.5, longitude: -0.1, radiusMetres: 150,
                        triggerOnArrival: true, locationName: name)
    }

    func testAUserNamedPlace_keepsItsBytes() throws {
        XCTAssertEqual(String(data: try PlatformJSON.encode(place()), encoding: .utf8), golden,
                       "a place reminder that isn't auto-named must encode exactly as before")
    }

    func testAPayloadWithoutTheField_decodesAsUserChosen_andReencodesUnchanged() throws {
        let decoded = try PlatformJSON.decode(LocationTrigger.self, from: Data(golden.utf8))
        XCTAssertFalse(decoded.locationNameIsAuto)
        XCTAssertEqual(String(data: try PlatformJSON.encode(decoded), encoding: .utf8), golden)
    }

    /// A whole Take carrying a place reminder, which is what is written to disk and synced:
    /// its bytes are unchanged too while the name is the user's.
    func testATakeWithAPlaceReminder_keepsItsBytes() throws {
        let take = Take(id: UUID(uuidString: "6F1C2A9E-3B7D-4E2A-9C1F-0D8E7A6B5C4D")!,
                        createdAt: Date(timeIntervalSince1970: 1_780_000_000.123),
                        modifiedAt: Date(timeIntervalSince1970: 1_780_000_060.123),
                        blocks: [.text(TextBlock(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, text: "Post the parcel"))],
                        locationReminder: place())
        let takeGolden = #"{"attachments":[],"blocks":[{"id":"11111111-2222-3333-4444-555555555555","kind":"text","text":"Post the parcel"}],"contentType":"blocks/v2","createdAt":"2026-05-28T20:26:40.123Z","id":"6F1C2A9E-3B7D-4E2A-9C1F-0D8E7A6B5C4D","isImportant":false,"isNote":true,"isObie":false,"isSeeded":false,"locationReminder":"# + golden + #","modifiedAt":"2026-05-28T20:27:40.123Z","schemaVersion":3}"#
        XCTAssertEqual(String(data: try PlatformJSON.encode(take), encoding: .utf8), takeGolden)
    }

    func testAnAutoNamedPlace_roundTrips() throws {
        var auto = place(named: "12 Acacia Avenue")
        auto.locationNameIsAuto = true
        let data = try PlatformJSON.encode(auto)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""locationNameIsAuto":true"#))
        XCTAssertEqual(try PlatformJSON.decode(LocationTrigger.self, from: data), auto)
    }
}
