import Foundation
import SwiftData

/// Someone the user splits costs with (a roommate, a friend). Only a name is kept.
@Model
final class SplitPerson {
    @Attribute(.unique) var id: UUID
    var name: String
    var isActive: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, isActive: Bool = true, createdAt: Date = .now) {
        self.id = id; self.name = name; self.isActive = isActive; self.createdAt = createdAt
    }
}

/// Another person's share of one of the user's expenses: they owe it to the user.
/// The user's own share is the expense amount minus everyone else's shares.
@Model
final class TransactionSplit {
    @Attribute(.unique) var id: UUID
    var transactionId: UUID
    var personId: UUID
    /// Non-negative minor units, in the transaction's currency.
    var shareMinorUnits: Int64
    var createdAt: Date

    init(id: UUID = UUID(), transactionId: UUID, personId: UUID, shareMinorUnits: Int64, createdAt: Date = .now) {
        self.id = id; self.transactionId = transactionId; self.personId = personId
        self.shareMinorUnits = shareMinorUnits; self.createdAt = createdAt
    }

    var value: SplitShare { SplitShare(transactionId: transactionId, personId: personId, shareMinorUnits: shareMinorUnits) }
}

enum SplitLedgerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// They paid the user back (e.g. a Zelle in).
    case theyPaidMe
    /// The user paid them (settling what the user owed).
    case iPaidThem
    /// They covered something for the user, so the user owes them.
    case iOwe

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .theyPaidMe: "They paid me"
        case .iPaidThem: "I paid them"
        case .iOwe: "I owe them"
        }
    }
}

/// A payment between the user and a person, or something the user owes them.
/// A payment can be linked to the transaction that moved the money, so a repayment received is
/// never counted as income.
@Model
final class SplitLedgerEntry {
    @Attribute(.unique) var id: UUID
    var personId: UUID
    var kindRaw: String
    var amountMinorUnits: Int64
    var currencyCode: String
    var date: Date
    var note: String?
    var linkedTransactionId: UUID?
    var createdAt: Date

    init(id: UUID = UUID(), personId: UUID, kind: SplitLedgerKind, amountMinorUnits: Int64, currencyCode: String, date: Date,
         note: String? = nil, linkedTransactionId: UUID? = nil, createdAt: Date = .now) {
        self.id = id; self.personId = personId; self.kindRaw = kind.rawValue; self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode; self.date = date; self.note = note; self.linkedTransactionId = linkedTransactionId
        self.createdAt = createdAt
    }

    var kind: SplitLedgerKind { SplitLedgerKind(rawValue: kindRaw) ?? .theyPaidMe }

    var value: SplitLedgerValue {
        SplitLedgerValue(id: id, personId: personId, kind: kind, amountMinorUnits: amountMinorUnits, currencyCode: currencyCode,
                         linkedTransactionId: linkedTransactionId)
    }
}
