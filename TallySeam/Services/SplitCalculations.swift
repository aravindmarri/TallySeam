import Foundation

struct SplitShare: Hashable, Sendable {
    var transactionId: UUID
    var personId: UUID
    var shareMinorUnits: Int64
}

struct SplitLedgerValue: Hashable, Sendable {
    var id: UUID
    var personId: UUID
    var kind: SplitLedgerKind
    var amountMinorUnits: Int64
    var currencyCode: String
    var linkedTransactionId: UUID?
}

enum SplitMath {
    /// Splits `total` equally between `count` people. Leftover cents go to the first people, so the
    /// shares always add up to the total exactly. Example: $10.00 by 3 → 3.34, 3.33, 3.33.
    static func equalShares(total: Int64, count: Int) -> [Int64] {
        guard count > 0, total >= 0 else { return [] }
        let n = Int64(count)
        let base = total / n, remainder = total % n
        return (0..<count).map { base + (Int64($0) < remainder ? 1 : 0) }
    }

    /// The user's own share: the amount minus everyone else's shares (never below zero).
    static func myShare(amount: Int64, others: [Int64]) -> Int64 {
        max(0, amount - others.reduce(0, +))
    }

    /// Records as they count for the user personally:
    /// - a split expense counts only the user's share;
    /// - a repayment received (an income transaction linked to "they paid me") is not income;
    /// - a payment the user made to settle what they owed (linked to "I paid them") stays spending.
    /// Records that end at zero are dropped. Transfers and other records are unchanged.
    static func personalRecords(_ records: [TransactionRecord], splits: [SplitShare], ledger: [SplitLedgerValue]) -> [TransactionRecord] {
        var othersShare: [UUID: Int64] = [:]
        for s in splits { othersShare[s.transactionId, default: 0] += s.shareMinorUnits }
        var repaid: [UUID: Int64] = [:]
        for e in ledger where e.kind == .theyPaidMe {
            if let t = e.linkedTransactionId { repaid[t, default: 0] += e.amountMinorUnits }
        }
        return records.compactMap { r in
            var r = r
            if r.transactionType == .expense, !r.isRefund, let others = othersShare[r.id] {
                r.amountMinorUnits = myShare(amount: r.amountMinorUnits, others: [others])
            }
            if r.transactionType == .income, !r.isRefund, let back = repaid[r.id] {
                r.amountMinorUnits = max(0, r.amountMinorUnits - back)
            }
            return r.amountMinorUnits == 0 && (othersShare[r.id] != nil || repaid[r.id] != nil) ? nil : r
        }
    }

    /// What each person owes the user in `currencyCode` (positive) or the user owes them (negative).
    /// Shares only count for expenses that still exist in that currency.
    static func balances(splits: [SplitShare], ledger: [SplitLedgerValue], transactions: [TransactionRecord],
                         currencyCode: String) -> [UUID: Int64] {
        let byId = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var b: [UUID: Int64] = [:]
        for s in splits {
            guard let t = byId[s.transactionId], t.currencyCode == currencyCode, t.transactionType == .expense else { continue }
            b[s.personId, default: 0] += s.shareMinorUnits
        }
        for e in ledger where e.currencyCode == currencyCode {
            switch e.kind {
            case .theyPaidMe, .iOwe: b[e.personId, default: 0] -= e.amountMinorUnits
            case .iPaidThem: b[e.personId, default: 0] += e.amountMinorUnits
            }
        }
        return b
    }
}

enum SplitError: Error, Equatable, LocalizedError {
    case invalidName, notAnExpense, sharesTooLarge, invalidAmount, linkAlreadyUsed
    var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name."
        case .notAnExpense: "Only expenses can be split."
        case .sharesTooLarge: "Other people's shares can't add up to more than the expense."
        case .invalidAmount: "Enter an amount above zero."
        case .linkAlreadyUsed: "That transaction is already linked to another payment."
        }
    }
}
