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

    func testAnAutoNamedPlace_roundTrips() throws {
        var auto = place(named: "12 Acacia Avenue")
        auto.locationNameIsAuto = true
        let data = try PlatformJSON.encode(auto)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""locationNameIsAuto":true"#))
        XCTAssertEqual(try PlatformJSON.decode(LocationTrigger.self, from: data), auto)
    }
}
