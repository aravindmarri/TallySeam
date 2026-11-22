import Foundation
import SwiftData

/// Everything a backup contains. Settings and the app lock are device preferences and are not included.
struct BackupPayload: Codable, Equatable, Sendable {
    struct CategoryItem: Codable, Equatable, Sendable {
        var id: UUID; var name: String; var symbol: String; var colorIdentifier: String
        var kind: CategoryKind; var isSystemCategory: Bool; var displayOrder: Int
    }
    struct PaymentMethodItem: Codable, Equatable, Sendable {
        var id: UUID; var name: String; var type: String; var accountNickname: String?
        var lastFourDigits: String?; var isActive: Bool; var createdAt: Date; var underlyingPaymentMethodId: UUID?
    }
    struct ReceiptItem: Codable, Equatable, Sendable {
        var id: UUID; var importedAt: Date; var extractedText: String?; var extractedMerchant: String?
        var extractedDate: Date?; var extractedTotalMinorUnits: Int64?; var currencyCode: String?
        var reviewStatus: String; var imageFingerprint: String?
        /// JPEG data; nil if the image file was missing when the backup was made.
        var imageData: Data?
    }
    struct BillItem: Codable, Equatable, Sendable {
        var id: UUID; var title: String; var expectedAmountMinorUnits: Int64?; var currencyCode: String
        var categoryId: UUID?; var paymentMethodId: UUID?; var recurrence: String; var customIntervalDays: Int?
        var nextDueDate: Date; var isActive: Bool; var notes: String?
    }
    struct BudgetItem: Codable, Equatable, Sendable {
        var id: UUID; var categoryId: UUID?; var amountMinorUnits: Int64; var currencyCode: String
        var effectiveStartMonth: Date; var isActive: Bool
    }

    var schemaVersion = 1
    var exportedAt: Date
    var categories: [CategoryItem] = []
    var paymentMethods: [PaymentMethodItem] = []
    var transactions: [TransactionRecord] = []
    var receipts: [ReceiptItem] = []
    var bills: [BillItem] = []
    var budgets: [BudgetItem] = []
    /// Statement import data. Absent in backups made before statement import.
    var reconciliation: BackupReconciliationData?
    /// Investments and monthly snapshots. Absent in backups made before investments.
    var investments: BackupInvestmentData?
    /// People, split shares and settle-up entries. Absent in backups made before splits.
    var splits: BackupSplitData?

    /// Rejects data the app could never have produced. Nothing is imported if this fails.
    func validate() throws {
        let maxText = 10_000
        func ok(_ s: String?) -> Bool { (s?.count ?? 0) <= maxText }
        guard schemaVersion == 1,
              transactions.allSatisfy({ $0.amountMinorUnits >= 0 && !$0.currencyCode.isEmpty && ok($0.title) && ok($0.notes) && ok($0.merchant) }),
              bills.allSatisfy({ ($0.expectedAmountMinorUnits ?? 1) > 0 && RecurrenceRule(rawValue: $0.recurrence) != nil && ok($0.title) }),
              budgets.allSatisfy({ $0.amountMinorUnits > 0 }),
              categories.allSatisfy({ !$0.name.isEmpty && ok($0.name) }),
              paymentMethods.allSatisfy({ !$0.name.isEmpty && ok($0.name) }),
              Set(transactions.map(\.id)).count == transactions.count,
              Set(receipts.map(\.id)).count == receipts.count
        else { throw BackupError.invalidContents }
    }
}

/// What an import added and skipped.
struct ImportSummary: Equatable, Sendable {
    var transactionsAdded = 0
    var transactionsSkipped = 0
    var categoriesAdded = 0
    var paymentMethodsAdded = 0
    var receiptsAdded = 0
    var billsAdded = 0
    var budgetsAdded = 0
    /// Budgets imported as paused because an active budget for the same category and currency already exists.
    var budgetsPaused = 0
    var statementsAdded = 0
    /// Statements already on the device (same id or same file).
    var statementsSkipped = 0
}

/// Builds and restores backups, deletes all data, and cleans up unattached receipts.
///
/// Import only ever **adds**: items whose id already exists are skipped and nothing on the device
/// is changed or deleted. Categories are matched by id, then by name and kind, so a backup restores
/// correctly onto a fresh install whose default categories have different ids.
@MainActor
final class BackupService {
    private let context: ModelContext
    private let storage: ReceiptStorageService

    init(context: ModelContext, storage: ReceiptStorageService) {
        self.context = context
        self.storage = storage
    }

    // MARK: Export

    func makePayload(now: Date = .now) throws -> BackupPayload {
        var p = BackupPayload(exportedAt: now)
        p.categories = try context.fetch(FetchDescriptor<SpendingCategory>(sortBy: [SortDescriptor(\.displayOrder)])).map {
            .init(id: $0.id, name: $0.name, symbol: $0.symbol, colorIdentifier: $0.colorIdentifier, kind: $0.kind,
                  isSystemCategory: $0.isSystemCategory, displayOrder: $0.displayOrder)
        }
        p.paymentMethods = try context.fetch(FetchDescriptor<PaymentMethod>()).map {
            .init(id: $0.id, name: $0.name, type: $0.typeRaw, accountNickname: $0.accountNickname, lastFourDigits: $0.lastFourDigits,
                  isActive: $0.isActive, createdAt: $0.createdAt, underlyingPaymentMethodId: $0.underlyingPaymentMethodId)
        }
        p.transactions = try context.fetch(FetchDescriptor<MoneyTransaction>()).map(\.record).sorted { $0.transactionDate < $1.transactionDate }
        p.receipts = try context.fetch(FetchDescriptor<Receipt>()).map {
            .init(id: $0.id, importedAt: $0.importedAt, extractedText: $0.extractedText, extractedMerchant: $0.extractedMerchant,
                  extractedDate: $0.extractedDate, extractedTotalMinorUnits: $0.extractedTotalMinorUnits, currencyCode: $0.currencyCode,
                  reviewStatus: $0.reviewStatusRaw, imageFingerprint: $0.imageFingerprint,
                  imageData: storage.loadData(relativePath: $0.imageRelativePath))
        }
        p.bills = try context.fetch(FetchDescriptor<RecurringBill>()).map {
            .init(id: $0.id, title: $0.title, expectedAmountMinorUnits: $0.expectedAmountMinorUnits, currencyCode: $0.currencyCode,
                  categoryId: $0.categoryId, paymentMethodId: $0.paymentMethodId, recurrence: $0.recurrenceRaw,
                  customIntervalDays: $0.customIntervalDays, nextDueDate: $0.nextDueDate, isActive: $0.isActive, notes: $0.notes)
        }
        p.budgets = try context.fetch(FetchDescriptor<Budget>()).map {
            .init(id: $0.id, categoryId: $0.categoryId, amountMinorUnits: $0.amountMinorUnits, currencyCode: $0.currencyCode,
                  effectiveStartMonth: $0.effectiveStartMonth, isActive: $0.isActive)
        }
        let reconciliation = try BackupReconciliationData.make(from: context)
        p.reconciliation = reconciliation.isEmpty ? nil : reconciliation
        let investments = try BackupInvestmentData.make(from: context)
        p.investments = investments.isEmpty ? nil : investments
        let splits = try BackupSplitData.make(from: context)
        p.splits = splits.isEmpty ? nil : splits
        return p
    }

    nonisolated static func encode(_ payload: BackupPayload) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(payload)
    }

    nonisolated static func decode(_ data: Data) throws -> BackupPayload {
        do { return try JSONDecoder().decode(BackupPayload.self, from: data) } catch { throw BackupError.invalidContents }
    }

    // MARK: Import

    @discardableResult
    func restore(_ payload: BackupPayload) throws -> ImportSummary {
        try payload.validate()
        var summary = ImportSummary()
        var writtenImages: [String] = []
        do {
            let categoryMap = try restoreCategories(payload.categories, summary: &summary)
            func mapCategory(_ id: UUID?) -> UUID? { id.flatMap { categoryMap[$0] } }

            let existingMethods = Set(try context.fetch(FetchDescriptor<PaymentMethod>()).map(\.id))
            for m in payload.paymentMethods where !existingMethods.contains(m.id) {
                context.insert(PaymentMethod(id: m.id, name: m.name, type: PaymentMethodType(rawValue: m.type) ?? .other,
                                             accountNickname: m.accountNickname, lastFourDigits: m.lastFourDigits, isActive: m.isActive,
                                             createdAt: m.createdAt, underlyingPaymentMethodId: m.underlyingPaymentMethodId))
                summary.paymentMethodsAdded += 1
            }

            let existingReceipts = Set(try context.fetch(FetchDescriptor<Receipt>()).map(\.id))
            for r in payload.receipts where !existingReceipts.contains(r.id) {
                let path = ReceiptStorageService.relativePath(for: r.id)
                if let data = r.imageData {
                    try storage.save(jpegData: data, id: r.id)
                    writtenImages.append(path)
                }
                let receipt = Receipt(id: r.id, imageRelativePath: path, importedAt: r.importedAt, imageFingerprint: r.imageFingerprint)
                receipt.extractedText = r.extractedText; receipt.extractedMerchant = r.extractedMerchant
                receipt.extractedDate = r.extractedDate; receipt.extractedTotalMinorUnits = r.extractedTotalMinorUnits
                receipt.currencyCode = r.currencyCode; receipt.reviewStatusRaw = r.reviewStatus
                context.insert(receipt)
                summary.receiptsAdded += 1
            }

            let existingTransactions = Set(try context.fetch(FetchDescriptor<MoneyTransaction>()).map(\.id))
            for t in payload.transactions {
                guard !existingTransactions.contains(t.id) else { summary.transactionsSkipped += 1; continue }
                var r = t
                r.categoryId = mapCategory(t.categoryId)
                context.insert(MoneyTransaction(record: r))
                summary.transactionsAdded += 1
            }

            let existingBills = Set(try context.fetch(FetchDescriptor<RecurringBill>()).map(\.id))
            for b in payload.bills where !existingBills.contains(b.id) {
                let bill = RecurringBill(id: b.id, title: b.title, expectedAmountMinorUnits: b.expectedAmountMinorUnits,
                                         currencyCode: b.currencyCode, recurrenceRule: RecurrenceRule(rawValue: b.recurrence) ?? .monthly,
                                         nextDueDate: b.nextDueDate, isActive: b.isActive)
                bill.categoryId = mapCategory(b.categoryId); bill.paymentMethodId = b.paymentMethodId
                bill.customIntervalDays = b.customIntervalDays; bill.notes = b.notes
                context.insert(bill)
                summary.billsAdded += 1
            }

            var budgets = try context.fetch(FetchDescriptor<Budget>())
            for b in payload.budgets where !budgets.contains(where: { $0.id == b.id }) {
                let category = mapCategory(b.categoryId)
                if b.categoryId != nil && category == nil { continue }   // category no longer exists
                let clash = budgets.contains { $0.isActive && $0.categoryId == category && $0.currencyCode == b.currencyCode }
                let budget = Budget(id: b.id, categoryId: category, amountMinorUnits: b.amountMinorUnits, currencyCode: b.currencyCode,
                                    effectiveStartMonth: b.effectiveStartMonth, isActive: b.isActive && !clash)
                if b.isActive && clash { summary.budgetsPaused += 1 }
                context.insert(budget)
                budgets.append(budget)
                summary.budgetsAdded += 1
            }
            if let reconciliation = payload.reconciliation {
                let r = try reconciliation.restore(into: context, knownTransactionIds: existingTransactions.union(payload.transactions.map(\.id)))
                summary.statementsAdded = r.statementsAdded
                summary.statementsSkipped = r.statementsSkipped
            }
            if let investments = payload.investments {
                try investments.validate()
                try investments.restore(into: context)
            }
            if let splits = payload.splits {
                try splits.validate()
                try splits.restore(into: context)
            }
            try context.save()
        } catch {
            context.rollback()
            for path in writtenImages { try? storage.delete(relativePath: path) }
            throw error
        }
        return summary
    }

    /// Returns a map from backup category id to the id to use on this device.
    private func restoreCategories(_ items: [BackupPayload.CategoryItem], summary: inout ImportSummary) throws -> [UUID: UUID] {
        let existing = try context.fetch(FetchDescriptor<SpendingCategory>())
        var map: [UUID: UUID] = [:]
        var nextOrder = (existing.map(\.displayOrder).max() ?? -1) + 1
        for c in items {
            if existing.contains(where: { $0.id == c.id }) {
                map[c.id] = c.id
            } else if let match = existing.first(where: { $0.kind == c.kind && $0.name.caseInsensitiveCompare(c.name) == .orderedSame }) {
                map[c.id] = match.id
            } else {
                context.insert(SpendingCategory(id: c.id, name: c.name, symbol: c.symbol, colorIdentifier: c.colorIdentifier,
                                                kind: c.kind, isSystemCategory: false, displayOrder: nextOrder))
                nextOrder += 1
                map[c.id] = c.id
                summary.categoriesAdded += 1
            }
        }
        return map
    }

    // MARK: Delete all data

    /// Permanently deletes every transaction, receipt (records and image files), bill, budget, payment method
    /// and custom category, then restores the default categories. The user must confirm first.
    /// Settings are reset to defaults.
    func deleteAllData() throws {
        try context.fetch(FetchDescriptor<MoneyTransaction>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<Receipt>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<RecurringBill>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<Budget>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<PaymentMethod>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<SpendingCategory>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<AppSettings>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<ReconciliationMatch>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<StatementTransaction>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<ImportedStatement>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<ImportSession>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<FinancialAccount>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<MerchantAlias>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<Investment>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<MonthlySnapshot>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<SplitLedgerEntry>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<TransactionSplit>()).forEach { context.delete($0) }
        try context.fetch(FetchDescriptor<SplitPerson>()).forEach { context.delete($0) }
        try context.save()
        try storage.removeOrphans(referenced: [])
        DefaultCategories.makeAll().forEach { context.insert($0) }
        context.insert(AppSettings())
        try context.save()
    }

    // MARK: Unattached receipts

    /// Receipts that no transaction points to (for example after their transaction was deleted).
    func unattachedReceipts() throws -> [Receipt] {
        let used = Set(try context.fetch(FetchDescriptor<MoneyTransaction>()).compactMap(\.receiptId))
        return try context.fetch(FetchDescriptor<Receipt>()).filter { !used.contains($0.id) }
    }

    /// Deletes unattached receipt records and their images. The user must confirm first.
    @discardableResult
    func deleteUnattachedReceipts() throws -> Int {
        let receipts = try unattachedReceipts()
        let paths = receipts.map(\.imageRelativePath)
        receipts.forEach { context.delete($0) }
        try context.save()
        for p in paths { try? storage.delete(relativePath: p) }
        return receipts.count
    }
}
