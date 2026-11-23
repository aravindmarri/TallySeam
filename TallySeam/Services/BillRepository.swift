import Foundation
import SwiftData

/// How a bill payment is recorded. Either way exactly one expense transaction ends up linked.
enum BillPayment: Equatable, Sendable {
    /// Creates a new expense for the bill.
    case newTransaction(amountMinorUnits: Int64, date: Date, paymentMethodId: UUID?)
    /// Links an expense that was already recorded (for example from a receipt) instead of creating another one.
    case existingTransaction(id: UUID)
}

extension BillSchedule {
    /// Existing expenses that could be this bill's payment: same currency, not already linked to a bill,
    /// within `windowDays` of the due date. Exact amount matches come first, then the closest dates.
    static func paymentCandidates(_ records: [TransactionRecord], dueDate: Date, expectedAmount: Int64?, currencyCode: String,
                                  calendar: Calendar, windowDays: Int = 10) -> [TransactionRecord] {
        let due = calendar.startOfDay(for: dueDate)
        func distance(_ r: TransactionRecord) -> Int {
            abs(calendar.dateComponents([.day], from: due, to: calendar.startOfDay(for: r.transactionDate)).day ?? .max)
        }
        return records
            .filter { $0.transactionType == .expense && !$0.isRefund && $0.recurringBillId == nil
                && $0.currencyCode == currencyCode && distance($0) <= windowDays }
            .sorted { a, b in
                let am = a.amountMinorUnits == expectedAmount, bm = b.amountMinorUnits == expectedAmount
                if am != bm { return am }
                let da = distance(a), db = distance(b)
                if da != db { return da < db }
                return a.id.uuidString < b.id.uuidString
            }
    }
}

/// Recurring bills: create, edit, pause, delete, and record payments. Every change is saved immediately.
@MainActor
final class BillRepository {
    private let context: ModelContext
    private let calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    func fetch(id: UUID) throws -> RecurringBill? {
        var d = FetchDescriptor<RecurringBill>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    @discardableResult
    func save(_ draft: BillDraft) throws -> RecurringBill {
        if let first = draft.validationErrors.first { throw first }
        guard case .some(let amount) = draft.expectedAmount else { throw BillDraft.ValidationError.invalidAmount }
        let bill: RecurringBill
        if let id = draft.editingId {
            guard let existing = try fetch(id: id) else { throw RepositoryError.notFound }
            bill = existing
        } else {
            bill = RecurringBill(title: draft.trimmedTitle, expectedAmountMinorUnits: amount, currencyCode: draft.currencyCode,
                                 recurrenceRule: draft.rule, nextDueDate: draft.nextDueDate)
            context.insert(bill)
        }
        bill.title = draft.trimmedTitle
        bill.expectedAmountMinorUnits = amount
        bill.currencyCode = draft.currencyCode
        bill.categoryId = try expenseCategory(draft.categoryId)
        bill.paymentMethodId = draft.paymentMethodId
        bill.recurrenceRule = draft.rule
        bill.customIntervalDays = draft.rule == .custom ? draft.customIntervalDays : nil
        bill.nextDueDate = draft.nextDueDate
        bill.isActive = draft.isActive
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        bill.notes = notes.isEmpty ? nil : notes
        try context.save()
        return bill
    }

    func setActive(_ isActive: Bool, billId: UUID) throws {
        guard let bill = try fetch(id: billId) else { throw RepositoryError.notFound }
        bill.isActive = isActive
        try context.save()
    }

    /// Deletes the bill only. Payments already recorded stay as ordinary expenses with their history intact.
    func delete(id: UUID) throws {
        guard let bill = try fetch(id: id) else { throw RepositoryError.notFound }
        context.delete(bill)
        try SubscriptionRepository(context: context).targetDeleted(id)
        try context.save()
    }

    /// Records one payment and moves the bill to its next due date (one period after the current due date).
    @discardableResult
    func markPaid(billId: UUID, payment: BillPayment, now: Date = .now) throws -> TransactionRecord {
        guard let bill = try fetch(id: billId) else { throw RepositoryError.notFound }
        guard let next = BillSchedule.nextDueDate(after: bill.nextDueDate, rule: bill.recurrenceRule,
                                                  customIntervalDays: bill.customIntervalDays, calendar: calendar) else {
            throw RepositoryError.invalidBillSchedule
        }
        let record: TransactionRecord
        switch payment {
        case let .newTransaction(amount, date, paymentMethodId):
            guard amount > 0 else { throw TransactionDraft.ValidationError.zeroAmount }
            let r = TransactionRecord(transactionDate: date, createdAt: now, updatedAt: now, amountMinorUnits: amount,
                                      currencyCode: bill.currencyCode, title: bill.title, transactionType: .expense,
                                      categoryId: try expenseCategory(bill.categoryId), paymentMethodId: paymentMethodId,
                                      recurringBillId: bill.id)
            context.insert(MoneyTransaction(record: r))
            record = r
        case let .existingTransaction(id):
            var d = FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            guard let t = try context.fetch(d).first else { throw RepositoryError.notFound }
            var r = t.record
            guard r.transactionType == .expense, !r.isRefund else { throw RepositoryError.billPaymentMustBeExpense }
            guard r.recurringBillId == nil else { throw RepositoryError.transactionAlreadyLinkedToBill }
            guard r.currencyCode == bill.currencyCode else { throw RepositoryError.billCurrencyMismatch }
            r.recurringBillId = bill.id
            r.updatedAt = now
            t.apply(r)
            record = r
        }
        bill.nextDueDate = next
        try context.save()
        return record
    }

    /// Moves the bill to its next due date without recording a payment (for example a waived month).
    func skipPeriod(billId: UUID) throws {
        guard let bill = try fetch(id: billId) else { throw RepositoryError.notFound }
        guard let next = BillSchedule.nextDueDate(after: bill.nextDueDate, rule: bill.recurrenceRule,
                                                  customIntervalDays: bill.customIntervalDays, calendar: calendar) else {
            throw RepositoryError.invalidBillSchedule
        }
        bill.nextDueDate = next
        try context.save()
    }

    /// Recorded payments for a bill, newest first.
    func payments(billId: UUID) throws -> [TransactionRecord] {
        try context.fetch(FetchDescriptor<MoneyTransaction>())
            .filter { $0.recurringBillId == billId }
            .map(\.record)
            .sorted { $0.transactionDate > $1.transactionDate }
    }

    /// Keeps only an existing expense category; anything else becomes uncategorized.
    private func expenseCategory(_ id: UUID?) throws -> UUID? {
        guard let id else { return nil }
        var d = FetchDescriptor<SpendingCategory>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let c = try context.fetch(d).first, c.kind == .expense else { return nil }
        return id
    }
}

/// Monthly budgets: create, edit and delete. Budgets are limits, not financial records.
@MainActor
final class BudgetRepository {
    private let context: ModelContext
    private let calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    func all() throws -> [BudgetRecord] {
        try context.fetch(FetchDescriptor<Budget>()).map(\.record)
    }

    /// New budgets start in the month containing `now`; editing keeps the original start month.
    @discardableResult
    func save(_ draft: BudgetDraft, now: Date = .now) throws -> BudgetRecord {
        guard let amount = draft.amountMinorUnits else { throw BudgetDraft.ValidationError.invalidAmount }
        if let cid = draft.categoryId {
            var d = FetchDescriptor<SpendingCategory>(predicate: #Predicate { $0.id == cid })
            d.fetchLimit = 1
            guard let c = try context.fetch(d).first, c.kind == .expense else { throw BudgetDraft.ValidationError.notExpenseCategory }
        }
        let budgets = try context.fetch(FetchDescriptor<Budget>())
        if draft.isActive, budgets.contains(where: { $0.id != draft.editingId && $0.isActive && $0.categoryId == draft.categoryId
            && $0.currencyCode == draft.currencyCode }) {
            throw BudgetDraft.ValidationError.duplicate
        }
        let budget: Budget
        if let id = draft.editingId {
            guard let existing = budgets.first(where: { $0.id == id }) else { throw RepositoryError.notFound }
            budget = existing
        } else {
            budget = Budget(categoryId: draft.categoryId, amountMinorUnits: amount, currencyCode: draft.currencyCode,
                            effectiveStartMonth: calendar.monthRange(containing: now).start)
            context.insert(budget)
        }
        budget.categoryId = draft.categoryId
        budget.amountMinorUnits = amount
        budget.currencyCode = draft.currencyCode
        budget.isActive = draft.isActive
        try context.save()
        return budget.record
    }

    func delete(id: UUID) throws {
        guard let b = try context.fetch(FetchDescriptor<Budget>()).first(where: { $0.id == id }) else { throw RepositoryError.notFound }
        context.delete(b)
        try context.save()
    }
}
