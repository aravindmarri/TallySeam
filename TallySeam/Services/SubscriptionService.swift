import Foundation
import SwiftData

enum SubscriptionMath {
    /// Is this the Subscriptions category? Matched by its icon so renaming it keeps working.
    static func isSubscriptionCategory(name: String, symbol: String, kind: CategoryKind) -> Bool {
        kind == .expense && (symbol == "repeat.circle.fill" || MerchantName.normalize(name) == "subscriptions")
    }

    /// Keywords in a merchant or bill name that suggest a subscription type (by default type name).
    static let keywords: [(type: String, words: [String])] = [
        ("Gym & Fitness", ["planet fitness", "la fitness", "anytime fitness", "gold s gym", "24 hour fitness", "crunch", "equinox",
                           "orangetheory", "ymca", "gym", "fitness", "yoga", "peloton", "badminton"]),
        ("Streaming", ["netflix", "spotify", "hulu", "disney", "hbo", "max com", "youtube premium", "youtube tv", "paramount",
                       "peacock", "apple tv", "apple music", "prime video", "crunchyroll", "audible", "sling"]),
        ("Car", ["progressive", "geico", "state farm", "allstate", "car wash", "auto pay", "toyota financial", "honda financial",
                 "ally auto", "tesla", "sirius", "carwash", "parking", "spothero", "toll"]),
        ("Phone & Internet", ["verizon", "t mobile", "tmobile", "at t", "mint mobile", "visible", "xfinity", "comcast", "spectrum",
                              "cox", "google fi", "cricket"]),
        ("Software & Apps", ["openai", "chatgpt", "icloud", "apple com bill", "google storage", "google one", "microsoft", "adobe",
                             "dropbox", "github", "notion", "claude", "anthropic", "canva", "1password"]),
        ("News & Memberships", ["walmart", "costco", "sam s club", "amazon prime", "prime membership", "nytimes", "new york times",
                                "wsj", "medium", "patreon", "linkedin", "membership"]),
    ]

    /// The default type a name suggests, or nil. Whole-word match on the normalized name.
    static func suggestedTypeName(for text: String) -> String? {
        let n = " " + MerchantName.normalize(text.replacingOccurrences(of: "*", with: " ").replacingOccurrences(of: "'", with: " ")) + " "
        for entry in keywords where entry.words.contains(where: { n.contains(" \($0) ") }) { return entry.type }
        return nil
    }

    /// A bill's cost per month in minor units, rounded half away from zero. Nil when the amount varies.
    static func monthlyAmount(expected: Int64?, rule: RecurrenceRule, customDays: Int?) -> Int64? {
        guard let expected else { return nil }
        let perMonth: Decimal
        switch rule {
        case .monthly: return expected
        case .yearly: perMonth = Decimal(expected) / 12
        case .weekly: perMonth = Decimal(expected) * 52 / 12
        case .custom:
            guard let d = customDays, d > 0 else { return nil }
            perMonth = Decimal(expected) * 365 / Decimal(d) / 12
        }
        var v = perMonth, r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        return NSDecimalNumber(decimal: r).int64Value
    }
}

enum SubscriptionError: Error, Equatable, LocalizedError {
    case invalidName
    var errorDescription: String? { "Enter a name." }
}

/// Subscription types and the links that put transactions and bills in them.
@MainActor
final class SubscriptionRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    /// Adds the default types when there are none.
    func seedDefaultsIfNeeded() throws {
        guard try context.fetchCount(FetchDescriptor<SubscriptionType>()) == 0 else { return }
        DefaultSubscriptionTypes.makeAll().forEach { context.insert($0) }
        try context.save()
    }

    @discardableResult
    func addType(name: String, symbol: String = "repeat.circle.fill") throws -> SubscriptionType {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40 else { throw SubscriptionError.invalidName }
        let all = try context.fetch(FetchDescriptor<SubscriptionType>())
        if let same = all.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return same }
        let t = SubscriptionType(name: n, symbol: symbol, displayOrder: (all.map(\.displayOrder).max() ?? -1) + 1)
        context.insert(t)
        try context.save()
        return t
    }

    func renameType(_ t: SubscriptionType, to name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 40 else { throw SubscriptionError.invalidName }
        t.name = n
        try context.save()
    }

    /// Deletes a type. Transactions and bills in it simply lose the sub-group; nothing else changes.
    func deleteType(_ t: SubscriptionType) throws {
        let id = t.id
        try context.fetch(FetchDescriptor<SubscriptionLink>()).filter { $0.typeId == id }.forEach { context.delete($0) }
        context.delete(t)
        try context.save()
    }

    func typeId(for targetId: UUID) throws -> UUID? {
        try context.fetch(FetchDescriptor<SubscriptionLink>()).first { $0.targetId == targetId }?.typeId
    }

    /// Puts a transaction or bill in a type, or clears it with nil.
    func setType(_ typeId: UUID?, for targetId: UUID) throws {
        try context.fetch(FetchDescriptor<SubscriptionLink>()).filter { $0.targetId == targetId }.forEach { context.delete($0) }
        if let typeId { context.insert(SubscriptionLink(targetId: targetId, typeId: typeId)) }
        try context.save()
    }

    /// Called when a transaction or bill is deleted.
    func targetDeleted(_ id: UUID) throws {
        try context.fetch(FetchDescriptor<SubscriptionLink>()).filter { $0.targetId == id }.forEach { context.delete($0) }
    }
}

/// Subscription types and links in a backup. Restoring adds only what this iPhone doesn't have;
/// a type with the same name as one already here is merged into it.
struct BackupSubscriptionData: Codable, Equatable, Sendable {
    struct TypeItem: Codable, Equatable, Sendable { var id: UUID; var name: String; var symbol: String; var displayOrder: Int; var createdAt: Date }
    struct LinkItem: Codable, Equatable, Sendable { var id: UUID; var targetId: UUID; var typeId: UUID; var createdAt: Date }
    var types: [TypeItem] = []
    var links: [LinkItem] = []

    var isEmpty: Bool { links.isEmpty && types.isEmpty }

    @MainActor
    static func make(from context: ModelContext) throws -> BackupSubscriptionData {
        var d = BackupSubscriptionData()
        d.types = try context.fetch(FetchDescriptor<SubscriptionType>())
            .map { .init(id: $0.id, name: $0.name, symbol: $0.symbol, displayOrder: $0.displayOrder, createdAt: $0.createdAt) }
            .sorted { $0.displayOrder < $1.displayOrder }
        d.links = try context.fetch(FetchDescriptor<SubscriptionLink>())
            .map { .init(id: $0.id, targetId: $0.targetId, typeId: $0.typeId, createdAt: $0.createdAt) }
            .sorted { $0.createdAt < $1.createdAt }
        return d
    }

    func validate() throws {
        let ids = Set(types.map(\.id))
        guard types.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 40 && $0.symbol.count <= 100 }),
              links.allSatisfy({ ids.contains($0.typeId) }),
              ids.count == types.count, Set(links.map(\.id)).count == links.count
        else { throw BackupError.invalidContents }
    }

    @MainActor
    func restore(into context: ModelContext) throws {
        var existing = try context.fetch(FetchDescriptor<SubscriptionType>())
        var map: [UUID: UUID] = [:]
        for t in types {
            if let same = existing.first(where: { $0.id == t.id || $0.name.caseInsensitiveCompare(t.name) == .orderedSame }) {
                map[t.id] = same.id
            } else {
                let new = SubscriptionType(id: t.id, name: t.name, symbol: t.symbol, displayOrder: t.displayOrder, createdAt: t.createdAt)
                context.insert(new)
                existing.append(new)
                map[t.id] = t.id
            }
        }
        let links = try context.fetch(FetchDescriptor<SubscriptionLink>())
        var linkedTargets = Set(links.map(\.targetId))
        let haveIds = Set(links.map(\.id))
        for l in self.links where !haveIds.contains(l.id) && !linkedTargets.contains(l.targetId) {
            guard let type = map[l.typeId] else { continue }
            context.insert(SubscriptionLink(id: l.id, targetId: l.targetId, typeId: type, createdAt: l.createdAt))
            linkedTargets.insert(l.targetId)
        }
    }
}
