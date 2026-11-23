import Foundation
import SwiftData

/// A kind of subscription (Gym & Fitness, Streaming, Car…), a sub-group of the Subscriptions category.
@Model
final class SubscriptionType {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var displayOrder: Int
    var createdAt: Date

    init(id: UUID = UUID(), name: String, symbol: String, displayOrder: Int, createdAt: Date = .now) {
        self.id = id; self.name = name; self.symbol = symbol; self.displayOrder = displayOrder; self.createdAt = createdAt
    }
}

/// Which subscription type a transaction or recurring bill belongs to. `targetId` is the
/// transaction's or bill's id; at most one link per target.
@Model
final class SubscriptionLink {
    @Attribute(.unique) var id: UUID
    var targetId: UUID
    var typeId: UUID
    var createdAt: Date

    init(id: UUID = UUID(), targetId: UUID, typeId: UUID, createdAt: Date = .now) {
        self.id = id; self.targetId = targetId; self.typeId = typeId; self.createdAt = createdAt
    }
}

enum DefaultSubscriptionTypes {
    static let all: [(name: String, symbol: String)] = [
        ("Gym & Fitness", "figure.run"),
        ("Streaming", "play.tv.fill"),
        ("Car", "car.fill"),
        ("Phone & Internet", "wifi"),
        ("Software & Apps", "app.badge.fill"),
        ("News & Memberships", "person.text.rectangle.fill"),
    ]

    static func makeAll() -> [SubscriptionType] {
        all.enumerated().map { SubscriptionType(name: $1.name, symbol: $1.symbol, displayOrder: $0) }
    }
}
