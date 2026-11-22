import Foundation
import SwiftData

/// People, split shares and settle-up entries. Everything stays on this iPhone.
@MainActor
final class SplitRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    // MARK: People

    @discardableResult
    func addPerson(name: String) throws -> SplitPerson {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 60 else { throw SplitError.invalidName }
        if let existing = try context.fetch(FetchDescriptor<SplitPerson>()).first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            existing.isActive = true
            try context.save()
            return existing
        }
        let p = SplitPerson(name: n)
        context.insert(p)
        try context.save()
        return p
    }

    func renamePerson(_ p: SplitPerson, to name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 60 else { throw SplitError.invalidName }
        p.name = n
        try context.save()
    }

    /// Hides a person from pickers. Their shares and payments are kept so balances stay correct.
    func archivePerson(_ p: SplitPerson) throws {
        p.isActive = false
        try context.save()
    }

    // MARK: Splits

    func shares(for transactionId: UUID) throws -> [TransactionSplit] {
        try context.fetch(FetchDescriptor<TransactionSplit>()).filter { $0.transactionId == transactionId }
    }

    /// Replaces the split on an expense with these shares for other people. An empty list removes the split.
    func setSplit(transaction: TransactionRecord, shares: [UUID: Int64]) throws {
        guard transaction.transactionType == .expense, !transaction.isRefund else { throw SplitError.notAnExpense }
        let positive = shares.filter { $0.value > 0 }
        guard positive.values.allSatisfy({ $0 > 0 }), positive.values.reduce(0, +) <= transaction.amountMinorUnits else {
            throw SplitError.sharesTooLarge
        }
        try self.shares(for: transaction.id).forEach { context.delete($0) }
        for (person, share) in positive.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            context.insert(TransactionSplit(transactionId: transaction.id, personId: person, shareMinorUnits: share))
        }
        try context.save()
    }

    func removeSplit(transactionId: UUID) throws {
        try shares(for: transactionId).forEach { context.delete($0) }
        try context.save()
    }

    // MARK: Settle up

    @discardableResult
    func record(kind: SplitLedgerKind, personId: UUID, amountMinorUnits: Int64, currencyCode: String, date: Date,
                note: String?, linkedTransactionId: UUID?) throws -> SplitLedgerEntry {
        guard amountMinorUnits > 0 else { throw SplitError.invalidAmount }
        if let link = linkedTransactionId,
           try context.fetch(FetchDescriptor<SplitLedgerEntry>()).contains(where: { $0.linkedTransactionId == link }) {
            throw SplitError.linkAlreadyUsed
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = SplitLedgerEntry(personId: personId, kind: kind, amountMinorUnits: amountMinorUnits, currencyCode: currencyCode,
                                 date: date, note: (trimmed?.isEmpty ?? true) ? nil : trimmed, linkedTransactionId: linkedTransactionId)
        context.insert(e)
        try context.save()
        return e
    }

    func deleteEntry(_ e: SplitLedgerEntry) throws {
        context.delete(e)
        try context.save()
    }

    /// Called when a transaction is deleted: its split shares go, and payments linked to it are
    /// kept but unlinked (the money still moved between the two people).
    func transactionDeleted(_ id: UUID) throws {
        try shares(for: id).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<SplitLedgerEntry>()).filter { $0.linkedTransactionId == id }.forEach { $0.linkedTransactionId = nil }
    }
}

/// People, splits and settle-up entries in a backup. Restoring adds only what this iPhone doesn't have.
struct BackupSplitData: Codable, Equatable, Sendable {
    struct PersonItem: Codable, Equatable, Sendable { var id: UUID; var name: String; var isActive: Bool; var createdAt: Date }
    struct ShareItem: Codable, Equatable, Sendable { var id: UUID; var transactionId: UUID; var personId: UUID; var shareMinorUnits: Int64; var createdAt: Date }
    struct EntryItem: Codable, Equatable, Sendable {
        var id: UUID; var personId: UUID; var kind: String; var amountMinorUnits: Int64; var currencyCode: String; var date: Date
        var note: String?; var linkedTransactionId: UUID?; var createdAt: Date
    }
    var people: [PersonItem] = []
    var shares: [ShareItem] = []
    var entries: [EntryItem] = []

    var isEmpty: Bool { people.isEmpty && shares.isEmpty && entries.isEmpty }

    @MainActor
    static func make(from context: ModelContext) throws -> BackupSplitData {
        var d = BackupSplitData()
        d.people = try context.fetch(FetchDescriptor<SplitPerson>()).map { .init(id: $0.id, name: $0.name, isActive: $0.isActive, createdAt: $0.createdAt) }
            .sorted { $0.createdAt < $1.createdAt }
        d.shares = try context.fetch(FetchDescriptor<TransactionSplit>()).map {
            .init(id: $0.id, transactionId: $0.transactionId, personId: $0.personId, shareMinorUnits: $0.shareMinorUnits, createdAt: $0.createdAt)
        }.sorted { $0.createdAt < $1.createdAt }
        d.entries = try context.fetch(FetchDescriptor<SplitLedgerEntry>()).map {
            .init(id: $0.id, personId: $0.personId, kind: $0.kindRaw, amountMinorUnits: $0.amountMinorUnits, currencyCode: $0.currencyCode,
                  date: $0.date, note: $0.note, linkedTransactionId: $0.linkedTransactionId, createdAt: $0.createdAt)
        }.sorted { $0.createdAt < $1.createdAt }
        return d
    }

    func validate() throws {
        let personIds = Set(people.map(\.id))
        guard people.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 60 }),
              shares.allSatisfy({ $0.shareMinorUnits > 0 && personIds.contains($0.personId) }),
              entries.allSatisfy({ $0.amountMinorUnits > 0 && !$0.currencyCode.isEmpty && personIds.contains($0.personId)
                                    && SplitLedgerKind(rawValue: $0.kind) != nil && ($0.note?.count ?? 0) <= 10_000 }),
              personIds.count == people.count,
              Set(shares.map(\.id)).count == shares.count,
              Set(entries.map(\.id)).count == entries.count
        else { throw BackupError.invalidContents }
    }

    @MainActor
    func restore(into context: ModelContext) throws {
        let havePeople = Set(try context.fetch(FetchDescriptor<SplitPerson>()).map(\.id))
        for p in people where !havePeople.contains(p.id) {
            context.insert(SplitPerson(id: p.id, name: p.name, isActive: p.isActive, createdAt: p.createdAt))
        }
        let haveShares = Set(try context.fetch(FetchDescriptor<TransactionSplit>()).map(\.id))
        for s in shares where !haveShares.contains(s.id) {
            context.insert(TransactionSplit(id: s.id, transactionId: s.transactionId, personId: s.personId,
                                            shareMinorUnits: s.shareMinorUnits, createdAt: s.createdAt))
        }
        let haveEntries = Set(try context.fetch(FetchDescriptor<SplitLedgerEntry>()).map(\.id))
        for e in entries where !haveEntries.contains(e.id) {
            context.insert(SplitLedgerEntry(id: e.id, personId: e.personId, kind: SplitLedgerKind(rawValue: e.kind) ?? .theyPaidMe,
                                            amountMinorUnits: e.amountMinorUnits, currencyCode: e.currencyCode, date: e.date,
                                            note: e.note, linkedTransactionId: e.linkedTransactionId, createdAt: e.createdAt))
        }
    }
}
