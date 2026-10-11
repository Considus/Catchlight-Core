//
//  LocationTrigger.swift
//  CatchlightCore
//
//  Location-based reminder (geofence) payload (Phase 5 brief §4.4).
//
//  WIRED UP since 2026-06-23 (D-081, PR #76): a Take's `locationReminder` drives a
//  `UNLocationNotificationTrigger` geofence (see `ReminderScheduler.scheduleLocationReminder`).
//  The model type predated the feature (it has always shipped so the v1.1 wiring needed no
//  breaking migration), so additive fields use `decodeIfPresent` to keep older payloads
//  decoding.
//

import Foundation

public struct LocationTrigger: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    /// Geofence radius in metres.
    public var radiusMetres: Double

    /// `true` = fire on arrival; `false` = fire on departure.
    public var triggerOnArrival: Bool

    /// User-provided label, e.g. "Home". Optional.
    public var locationName: String?

    /// Whether this "where" ALSO fires a local notification (owner 2026-06-27; mirrors
    /// `TimeReminder.alarmEnabled`, model C). `true` = geofence notification; `false` = a
    /// silent place tag (the Take carries the location and shows it on the card, but no
    /// geofence is registered and nothing nags on arrival/departure). Defaults true, and
    /// payloads written before this field decode as true, so existing location reminders
    /// keep firing — no behaviour change on migration.
    public var alarmEnabled: Bool

    /// The user marked this place reminder DONE (2026-07-01, place/time parity —
    /// mirrors `TimeReminder.isDone`). Done disables the geofence (the scheduler
    /// skips a done "where") and drives the grey done card treatment via
    /// `Take.isMarkedDone`. Additive: `decodeIfPresent` defaults false so older
    /// payloads keep decoding with no behaviour change.
    public var isDone: Bool

    /// The app filled `locationName` in itself (owner 2026-10-11): the "Current location"
    /// placeholder, a reverse-geocoded address or a search result's title, not a name the
    /// user typed. An editor reopened later lets the next place picked replace such a name
    /// and keeps one the user chose. Additive and written only when true, so a place
    /// reminder without it keeps its bytes, and older payloads decode as user-chosen. An
    /// older client re-saving the Take drops it, which also reads as user-chosen: the safe
    /// side, since a typed name is never replaced. A client sets it only when it fills the
    /// name in, and clears it whenever the user types one.
    public var locationNameIsAuto: Bool

    public init(
        latitude: Double,
        longitude: Double,
        radiusMetres: Double,
        triggerOnArrival: Bool,
        locationName: String? = nil,
        alarmEnabled: Bool = true,
        isDone: Bool = false,
        locationNameIsAuto: Bool = false
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMetres = radiusMetres
        self.triggerOnArrival = triggerOnArrival
        self.locationName = locationName
        self.alarmEnabled = alarmEnabled
        self.isDone = isDone
        self.locationNameIsAuto = locationNameIsAuto
    }

    // Explicit Codable so the additive `alarmEnabled` / `isDone` can carry decoding
    // defaults for older payloads (synthesised decoding would reject a payload
    // missing the keys).
    enum CodingKeys: String, CodingKey {
        case latitude, longitude, radiusMetres, triggerOnArrival, locationName, alarmEnabled, isDone
        case locationNameIsAuto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
        self.radiusMetres = try c.decode(Double.self, forKey: .radiusMetres)
        self.triggerOnArrival = try c.decode(Bool.self, forKey: .triggerOnArrival)
        self.locationName = try c.decodeIfPresent(String.self, forKey: .locationName)
        self.alarmEnabled = try c.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? true
        self.isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        self.locationNameIsAuto = try c.decodeIfPresent(Bool.self, forKey: .locationNameIsAuto) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(radiusMetres, forKey: .radiusMetres)
        try c.encode(triggerOnArrival, forKey: .triggerOnArrival)
        try c.encodeIfPresent(locationName, forKey: .locationName)
        try c.encode(alarmEnabled, forKey: .alarmEnabled)
        try c.encode(isDone, forKey: .isDone)
        // Written only when true, so a place reminder without it keeps its bytes.
        if locationNameIsAuto { try c.encode(true, forKey: .locationNameIsAuto) }
    }
}
