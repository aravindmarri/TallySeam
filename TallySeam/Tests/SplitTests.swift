import Foundation
import SwiftData
import Testing
@testable import TallySeam

@Suite struct SplitMathTests {
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    func expense(_ amount: Int64, id: UUID = UUID(), currency: String = "USD") -> TransactionRecord {
        TransactionRecord(id: id, transactionDate: day, amountMinorUnits: amount, currencyCode: currency, title: "Groceries", transactionType: .expense)
    }

    @Test func equalSharesAlwaysAddUp() {
        #expect(SplitMath.equalShares(total: 9_000, count: 3) == [3_000, 3_000, 3_000])
        #expect(SplitMath.equalShares(total: 1_000, count: 3) == [334, 333, 333])
        #expect(SplitMath.equalShares(total: 1, count: 2) == [1, 0])
        #expect(SplitMath.equalShares(total: 500, count: 0).isEmpty)
        for total in [Int64(1), 99, 1_001, 123_457] {
            for n in 1...7 { #expect(SplitMath.equalShares(total: total, count: n).reduce(0, +) == total) }
        }
    }

    @Test func myShareIsWhatOthersDontOwe() {
        #expect(SplitMath.myShare(amount: 9_000, others: [3_000, 3_000]) == 3_000)
        #expect(SplitMath.myShare(amount: 9_000, others: [9_500]) == 0)
    }

    @Test func reportsCountOnlyMyShareAndRepaymentsAreNotIncome() {
        let groceries = expense(9_000)
        let zelle = TransactionRecord(transactionDate: day, amountMinorUnits: 6_000, title: "Zelle From Roommate", transactionType: .income)
        let salary = TransactionRecord(transactionDate: day, amountMinorUnits: 500_000, title: "Salary", transactionType: .income)
        let a = UUID(), b = UUID()
        let splits = [SplitShare(transactionId: groceries.id, personId: a, shareMinorUnits: 3_000),
                      SplitShare(transactionId: groceries.id, personId: b, shareMinorUnits: 3_000)]
        let ledger = [SplitLedgerValue(id: UUID(), personId: a, kind: .theyPaidMe, amountMinorUnits: 6_000, currencyCode: "USD",
                                       linkedTransactionId: zelle.id)]
        let personal = SplitMath.personalRecords([groceries, zelle, salary], splits: splits, ledger: ledger)
        #expect(personal.count == 2, "the fully repaid Zelle drops out")
        #expect(personal.first { $0.id == groceries.id }?.amountMinorUnits == 3_000)
        #expect(personal.first { $0.id == salary.id }?.amountMinorUnits == 500_000)

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let s = FinanceCalculationService(calendar: cal).summary(of: personal, in: cal.monthRange(containing: day), currencyCode: "USD")
        #expect(s.expenseMinorUnits == 3_000)
        #expect(s.incomeMinorUnits == 500_000)
    }

    @Test func partialRepaymentLeavesTheRestAsIncome() {
        let zelle = TransactionRecord(transactionDate: day, amountMinorUnits: 10_000, title: "Zelle", transactionType: .income)
        let ledger = [SplitLedgerValue(id: UUID(), personId: UUID(), kind: .theyPaidMe, amountMinorUnits: 4_000, currencyCode: "USD",
                                       linkedTransactionId: zelle.id)]
        #expect(SplitMath.personalRecords([zelle], splits: [], ledger: ledger).first?.amountMinorUnits == 6_000)
    }

    @Test func balancesNetSharesPaymentsAndIOUs() {
        let g = expense(9_000), eur = expense(5_000, currency: "EUR")
        let sai = UUID(), ravi = UUID()
        let splits = [SplitShare(transactionId: g.id, personId: sai, shareMinorUnits: 3_000),
                      SplitShare(transactionId: g.id, personId: ravi, shareMinorUnits: 3_000),
                      SplitShare(transactionId: eur.id, personId: sai, shareMinorUnits: 2_500),
                      SplitShare(transactionId: UUID(), personId: sai, shareMinorUnits: 99_999)]   // deleted expense: ignored
        let ledger = [SplitLedgerValue(id: UUID(), personId: sai, kind: .theyPaidMe, amountMinorUnits: 1_000, currencyCode: "USD"),
                      SplitLedgerValue(id: UUID(), personId: ravi, kind: .iOwe, amountMinorUnits: 5_000, currencyCode: "USD"),
                      SplitLedgerValue(id: UUID(), personId: ravi, kind: .iPaidThem, amountMinorUnits: 500, currencyCode: "USD")]
        let b = SplitMath.balances(splits: splits, ledger: ledger, transactions: [g, eur], currencyCode: "USD")
        #expect(b[sai] == 2_000)        // owes me $20
        #expect(b[ravi] == -1_500)      // I owe Ravi $15
    }
}

@MainActor
@Suite struct SplitRepositoryTests {
    @Test func splitReplaceRemoveAndValidation() throws {
        let p = try PersistenceService(inMemory: true)
        let repo = SplitRepository(context: p.context)
        let sai = try repo.addPerson(name: " Sai ")
        #expect(sai.name == "Sai")
        #expect(try repo.addPerson(name: "sai").id == sai.id, "same name is the same person")
        #expect(throws: SplitError.invalidName) { try repo.addPerson(name: "  ") }

        let t = TransactionRecord(transactionDate: .now, amountMinorUnits: 9_000, title: "Groceries", transactionType: .expense)
        try repo.setSplit(transaction: t, shares: [sai.id: 3_000])
        try repo.setSplit(transaction: t, shares: [sai.id: 4_500])
        #expect(try repo.shares(for: t.id).map(\.shareMinorUnits) == [4_500])
        #expect(throws: SplitError.sharesTooLarge) { try repo.setSplit(transaction: t, shares: [sai.id: 9_001]) }
        let income = TransactionRecord(transactionDate: .now, amountMinorUnits: 100, title: "Pay", transactionType: .income)
        #expect(throws: SplitError.notAnExpense) { try repo.setSplit(transaction: income, shares: [sai.id: 50]) }
        try repo.removeSplit(transactionId: t.id)
        #expect(try repo.shares(for: t.id).isEmpty)
    }

    @Test func deletingATransactionRemovesItsSplitAndUnlinksPayments() throws {
        let p = try PersistenceService(inMemory: true)
        let txRepo = TransactionRepository(context: p.context)
        let repo = SplitRepository(context: p.context)
        let sai = try repo.addPerson(name: "Sai")
        let g = TransactionRecord(transactionDate: .now, amountMinorUnits: 6_000, title: "Groceries", transactionType: .expense)
        let z = TransactionRecord(transactionDate: .now, amountMinorUnits: 3_000, title: "Zelle", transactionType: .income)
        p.context.insert(MoneyTransaction(record: g)); p.context.insert(MoneyTransaction(record: z)); try p.context.save()
        try repo.setSplit(transaction: g, shares: [sai.id: 3_000])
        let entry = try repo.record(kind: .theyPaidMe, personId: sai.id, amountMinorUnits: 3_000, currencyCode: "USD", date: .now,
                                    note: nil, linkedTransactionId: z.id)
        #expect(throws: SplitError.linkAlreadyUsed) {
            try repo.record(kind: .theyPaidMe, personId: sai.id, amountMinorUnits: 1, currencyCode: "USD", date: .now, note: nil, linkedTransactionId: z.id)
        }
        try txRepo.delete(id: g.id)
        try txRepo.delete(id: z.id)
        #expect(try p.context.fetchCount(FetchDescriptor<TransactionSplit>()) == 0)
        #expect(entry.linkedTransactionId == nil)
        #expect(try p.context.fetchCount(FetchDescriptor<SplitLedgerEntry>()) == 1)
    }

    @Test func backupRoundTrip() throws {
        let source = try PersistenceService(inMemory: true)
        let repo = SplitRepository(context: source.context)
        let sai = try repo.addPerson(name: "Sai")
        let g = TransactionRecord(transactionDate: .now, amountMinorUnits: 6_000, title: "Groceries", transactionType: .expense)
        try repo.setSplit(transaction: g, shares: [sai.id: 3_000])
        try repo.record(kind: .iOwe, personId: sai.id, amountMinorUnits: 1_200, currencyCode: "USD", date: .now, note: "Pizza", linkedTransactionId: nil)
        let data = try BackupSplitData.make(from: source.context)
        try data.validate()
        let target = try PersistenceService(inMemory: true)
        try data.restore(into: target.context)
        try data.restore(into: target.context)
        #expect(try target.context.fetchCount(FetchDescriptor<SplitPerson>()) == 1)
        #expect(try target.context.fetchCount(FetchDescriptor<TransactionSplit>()) == 1)
        #expect(try target.context.fetch(FetchDescriptor<SplitLedgerEntry>()).first?.note == "Pizza")
    }
}
