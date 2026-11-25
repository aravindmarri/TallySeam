import Foundation
import SwiftData

enum InvestmentError: Error, Equatable, LocalizedError {
    case missingTicker, invalidShares, invalidPrice
    var errorDescription: String? {
        switch self {
        case .missingTicker: "Enter a ticker symbol."
        case .invalidShares: "Enter a number of shares above zero, with up to six decimal places."
        case .invalidPrice: "Enter prices of zero or more."
        }
    }
}

/// Creates, edits and deletes investments and monthly snapshots. Everything stays on this iPhone.
@MainActor
final class InvestmentRepository {
    private let context: ModelContext
    private let logger: any AppLogger

    init(context: ModelContext, logger: any AppLogger = DiagnosticsService.shared) { self.context = context; self.logger = logger }

    static func cleanTicker(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().filter { !$0.isWhitespace }
    }

    @discardableResult
    func add(ticker: String, name: String, kind: InvestmentKind, shareMicros: Int64, purchasePriceMinorUnits: Int64,
             currentPriceMinorUnits: Int64, currencyCode: String, now: Date = .now) throws -> Investment {
        let t = try validate(ticker: ticker, shareMicros: shareMicros, prices: [purchasePriceMinorUnits, currentPriceMinorUnits])
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = Investment(ticker: t, name: n.isEmpty ? t : n, kind: kind, shareMicros: shareMicros,
                           purchasePriceMinorUnits: purchasePriceMinorUnits, currentPriceMinorUnits: currentPriceMinorUnits,
                           currencyCode: currencyCode, priceUpdatedAt: now, createdAt: now)
        context.insert(i)
        try logger.measure(.investmentSave) { try context.save() }
        return i
    }

    /// The price date moves only when the current price actually changes.
    func update(_ i: Investment, ticker: String, name: String, kind: InvestmentKind, shareMicros: Int64,
                purchasePriceMinorUnits: Int64, currentPriceMinorUnits: Int64, now: Date = .now) throws {
        let t = try validate(ticker: ticker, shareMicros: shareMicros, prices: [purchasePriceMinorUnits, currentPriceMinorUnits])
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if i.currentPriceMinorUnits != currentPriceMinorUnits { i.priceUpdatedAt = now }
        i.ticker = t; i.name = n.isEmpty ? t : n; i.kindRaw = kind.rawValue; i.shareMicros = shareMicros
        i.purchasePriceMinorUnits = purchasePriceMinorUnits; i.currentPriceMinorUnits = currentPriceMinorUnits
        try logger.measure(.investmentSave) { try context.save() }
    }

    func updatePrice(_ i: Investment, currentPriceMinorUnits: Int64, now: Date = .now) throws {
        guard currentPriceMinorUnits >= 0 else { throw InvestmentError.invalidPrice }
        i.currentPriceMinorUnits = currentPriceMinorUnits
        i.priceUpdatedAt = now
        try logger.measure(.investmentSave) { try context.save() }
    }

    func delete(_ i: Investment) throws {
        context.delete(i)
        try logger.measure(.investmentSave) { try context.save() }
    }

    /// Records the month's balances, replacing an earlier snapshot for the same month and currency.
    @discardableResult
    func recordSnapshot(month: Int, currencyCode: String, cash: Int64, bank: Int64, investments: Int64, creditCardDebt: Int64,
                        now: Date = .now) throws -> MonthlySnapshot {
        guard [cash, bank, investments, creditCardDebt].allSatisfy({ $0 >= 0 }) else { throw InvestmentError.invalidPrice }
        let existing = try context.fetch(FetchDescriptor<MonthlySnapshot>()).filter { $0.month == month && $0.currencyCode == currencyCode }
        let s: MonthlySnapshot
        if let first = existing.first {
            s = first
            existing.dropFirst().forEach { context.delete($0) }
            s.cashMinorUnits = cash; s.bankMinorUnits = bank; s.investmentsMinorUnits = investments
            s.creditCardDebtMinorUnits = creditCardDebt; s.recordedAt = now
        } else {
            s = MonthlySnapshot(month: month, currencyCode: currencyCode, cashMinorUnits: cash, bankMinorUnits: bank,
                                investmentsMinorUnits: investments, creditCardDebtMinorUnits: creditCardDebt, recordedAt: now)
            context.insert(s)
        }
        try logger.measure(.checkInSave) { try context.save() }
        return s
    }

    func deleteSnapshot(_ s: MonthlySnapshot) throws {
        context.delete(s)
        try context.save()
    }

    private func validate(ticker: String, shareMicros: Int64, prices: [Int64]) throws -> String {
        let t = Self.cleanTicker(ticker)
        guard !t.isEmpty, t.count <= 20 else { throw InvestmentError.missingTicker }
        guard shareMicros > 0 else { throw InvestmentError.invalidShares }
        guard prices.allSatisfy({ $0 >= 0 }) else { throw InvestmentError.invalidPrice }
        return t
    }
}

/// Investments and snapshots in a backup. Restoring adds only records this iPhone doesn't have.
struct BackupInvestmentData: Codable, Equatable, Sendable {
    struct InvestmentItem: Codable, Equatable, Sendable {
        var id: UUID; var ticker: String; var name: String; var kind: String; var shareMicros: Int64
        var purchasePriceMinorUnits: Int64; var currentPriceMinorUnits: Int64; var currencyCode: String
        var priceUpdatedAt: Date; var createdAt: Date; var notes: String?
    }
    struct SnapshotItem: Codable, Equatable, Sendable {
        var id: UUID; var month: Int; var currencyCode: String; var cashMinorUnits: Int64; var bankMinorUnits: Int64
        var investmentsMinorUnits: Int64; var creditCardDebtMinorUnits: Int64; var recordedAt: Date; var notes: String?
    }
    var investments: [InvestmentItem] = []
    var snapshots: [SnapshotItem] = []

    var isEmpty: Bool { investments.isEmpty && snapshots.isEmpty }

    @MainActor
    static func make(from context: ModelContext) throws -> BackupInvestmentData {
        var d = BackupInvestmentData()
        d.investments = try context.fetch(FetchDescriptor<Investment>()).map {
            .init(id: $0.id, ticker: $0.ticker, name: $0.name, kind: $0.kindRaw, shareMicros: $0.shareMicros,
                  purchasePriceMinorUnits: $0.purchasePriceMinorUnits, currentPriceMinorUnits: $0.currentPriceMinorUnits,
                  currencyCode: $0.currencyCode, priceUpdatedAt: $0.priceUpdatedAt, createdAt: $0.createdAt, notes: $0.notes)
        }.sorted { $0.createdAt < $1.createdAt }
        d.snapshots = try context.fetch(FetchDescriptor<MonthlySnapshot>()).map {
            .init(id: $0.id, month: $0.month, currencyCode: $0.currencyCode, cashMinorUnits: $0.cashMinorUnits,
                  bankMinorUnits: $0.bankMinorUnits, investmentsMinorUnits: $0.investmentsMinorUnits,
                  creditCardDebtMinorUnits: $0.creditCardDebtMinorUnits, recordedAt: $0.recordedAt, notes: $0.notes)
        }.sorted { $0.month < $1.month }
        return d
    }

    func validate() throws {
        guard investments.allSatisfy({ !$0.ticker.isEmpty && $0.ticker.count <= 20 && $0.name.count <= 10_000 && $0.shareMicros > 0
                                        && $0.purchasePriceMinorUnits >= 0 && $0.currentPriceMinorUnits >= 0 && !$0.currencyCode.isEmpty }),
              snapshots.allSatisfy({ (190001...999912).contains($0.month) && (1...12).contains($0.month % 100) && !$0.currencyCode.isEmpty
                                      && [$0.cashMinorUnits, $0.bankMinorUnits, $0.investmentsMinorUnits, $0.creditCardDebtMinorUnits].allSatisfy { $0 >= 0 } }),
              Set(investments.map(\.id)).count == investments.count,
              Set(snapshots.map(\.id)).count == snapshots.count
        else { throw BackupError.invalidContents }
    }

    /// Adds missing records. A snapshot is skipped when this iPhone already has one for that month and currency.
    @MainActor
    func restore(into context: ModelContext) throws {
        let haveInvestments = Set(try context.fetch(FetchDescriptor<Investment>()).map(\.id))
        for i in investments where !haveInvestments.contains(i.id) {
            context.insert(Investment(id: i.id, ticker: i.ticker, name: i.name, kind: InvestmentKind(rawValue: i.kind) ?? .stock,
                                      shareMicros: i.shareMicros, purchasePriceMinorUnits: i.purchasePriceMinorUnits,
                                      currentPriceMinorUnits: i.currentPriceMinorUnits, currencyCode: i.currencyCode,
                                      priceUpdatedAt: i.priceUpdatedAt, createdAt: i.createdAt, notes: i.notes))
        }
        let existing = try context.fetch(FetchDescriptor<MonthlySnapshot>())
        var taken = Set(existing.map { "\($0.month)-\($0.currencyCode)" })
        let haveSnapshots = Set(existing.map(\.id))
        for s in snapshots where !haveSnapshots.contains(s.id) && !taken.contains("\(s.month)-\(s.currencyCode)") {
            taken.insert("\(s.month)-\(s.currencyCode)")
            context.insert(MonthlySnapshot(id: s.id, month: s.month, currencyCode: s.currencyCode, cashMinorUnits: s.cashMinorUnits,
                                           bankMinorUnits: s.bankMinorUnits, investmentsMinorUnits: s.investmentsMinorUnits,
                                           creditCardDebtMinorUnits: s.creditCardDebtMinorUnits, recordedAt: s.recordedAt, notes: s.notes))
        }
    }
}
