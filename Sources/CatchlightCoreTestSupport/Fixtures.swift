//
//  Fixtures.swift
//  CatchlightCoreTestSupport
//
//  Test-only helpers shared by Core's own suite and every app's. NONE of these
//  are production code, and no app target may link this product.
//

import Foundation
import CatchlightCore

extension Take {
    /// Test sugar for the sync, store and conflict suites, which only need to
    /// give a Take some body text and read it back. They don't care about the
    /// block structure. The production `primaryText` bridge was retired when the
    /// block editor landed (D-035 / Phase 2); this mirrors its old semantics
    /// (first prose block, inserted at the front if none) so those tests stay
    /// about sync, not content shape.
    public var primaryText: String {
        get {
            for block in blocks {
                if case .text(let textBlock) = block { return textBlock.text }
            }
            return ""
        }
        set {
            if let index = blocks.firstIndex(where: { if case .text = $0 { return true } else { return false } }) {
                if case .text(var textBlock) = blocks[index] {
                    textBlock.text = newValue
                    blocks[index] = .text(textBlock)
                }
            } else {
                blocks.insert(.text(TextBlock(text: newValue)), at: 0)
            }
        }
    }
}

public enum TestFixtures {
    /// A representative Take exercising every populated v1.0 field. Interleaved
    /// block content: a prose line plus two check items (so it is a Task — D-034 —
    /// but incomplete, one item unticked).
    public static func richTake(id: UUID = UUID()) -> Take {
        Take(
            id: id,
            createdAt: ISO8601.date(from: "2026-05-01T09:00:00.000Z")!,
            modifiedAt: ISO8601.date(from: "2026-05-02T10:30:00.000Z")!,
            blocks: [
                .textLine("Buy film for the weekend shoot / café at 3"),
                .checkItem("Kodak Portra 400", isComplete: false),
                .checkItem("Lens cloth", isComplete: true)
            ],
            contentType: "blocks/v2",
            isNote: true,
            isObie: false,
            timeReminder: TimeReminder(
                scheduledDate: ISO8601.date(from: "2026-05-03T15:00:00.000Z")!,
                isDelivered: false,
                notificationIdentifier: id.uuidString
            ),
            locationReminder: nil,
            attachments: [],
            isSeeded: false
        )
    }
}
