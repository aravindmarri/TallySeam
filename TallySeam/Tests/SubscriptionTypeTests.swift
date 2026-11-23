import Foundation
import SwiftData
import Testing
@testable import TallySeam

@Suite struct SubscriptionMathTests {
    @Test func suggestionsFromMerchantNames() {
        #expect(SubscriptionMath.suggestedTypeName(for: "PLANET FITNESS #1234 DENTON TX") == "Gym & Fitness")
        #expect(SubscriptionMath.suggestedTypeName(for: "NETFLIX.COM") == "Streaming")
        #expect(SubscriptionMath.suggestedTypeName(for: "PROGRESSIVE INS MAYFIELD VLG OH") == "Car")
        #expect(SubscriptionMath.suggestedTypeName(for: "OPENAI *CHATGPT SUBSCR") == "Software & Apps")
        #expect(SubscriptionMath.suggestedTypeName(for: "Walmart+ Member") == "News & Memberships")
        #expect(SubscriptionMath.suggestedTypeName(for: "VERIZON WIRELESS") == "Phone & Internet")
        #expect(SubscriptionMath.suggestedTypeName(for: "CORNER BAKERY") == nil)
        #expect(SubscriptionMath.suggestedTypeName(for: "GYMNASTICS SUPPLY") == nil, "whole words only")
    }

    @Test func everySuggestionNamesADefaultType() {
        let names = Set(DefaultSubscriptionTypes.all.map(\.name))
        #expect(SubscriptionMath.keywords.allSatisfy { names.contains($0.type) })
    }

    @Test func monthlyAmounts() {
        #expect(SubscriptionMath.monthlyAmount(expected: 4_000, rule: .monthly, customDays: nil) == 4_000)
        #expect(SubscriptionMath.monthlyAmount(expected: 12_000, rule: .yearly, customDays: nil) == 1_000)
        #expect(SubscriptionMath.monthlyAmount(expected: 9_999, rule: .yearly, customDays: nil) == 833)      // 833.25
        #expect(SubscriptionMath.monthlyAmount(expected: 1_000, rule: .weekly, customDays: nil) == 4_333)    // 4333.33
        #expect(SubscriptionMath.monthlyAmount(expected: 3_000, rule: .custom, customDays: 30) == 3_042)     // 3041.67
        #expect(SubscriptionMath.monthlyAmount(expected: nil, rule: .monthly, customDays: nil) == nil)
        #expect(SubscriptionMath.monthlyAmount(expected: 100, rule: .custom, customDays: 0) == nil)
    }

    @Test func subscriptionCategoryIsFoundByIconOrName() {
        #expect(SubscriptionMath.isSubscriptionCategory(name: "Subscriptions", symbol: "repeat.circle.fill", kind: .expense))
        #expect(SubscriptionMath.isSubscriptionCategory(name: "Monthly stuff", symbol: "repeat.circle.fill", kind: .expense))
        #expect(!SubscriptionMath.isSubscriptionCategory(name: "Groceries", symbol: "cart.fill", kind: .expense))
        #expect(!SubscriptionMath.isSubscriptionCategory(name: "Subscriptions", symbol: "repeat.circle.fill", kind: .income))
    }
}

@MainActor
@Suite struct SubscriptionRepositoryTests {
    @Test func defaultsAreSeededOnce() throws {
        let p = try PersistenceService(inMemory: true)
        try p.seedDefaultsIfNeeded()
        try p.seedDefaultsIfNeeded()
        #expect(try p.context.fetchCount(FetchDescriptor<SubscriptionType>()) == DefaultSubscriptionTypes.all.count)
    }

    @Test func setChangeClearAndDeleteType() throws {
        let p = try PersistenceService(inMemory: true)
        let repo = SubscriptionRepository(context: p.context)
        let gym = try repo.addType(name: "Gym")
        #expect(try repo.addType(name: " gym ").id == gym.id)
        #expect(throws: SubscriptionError.invalidName) { try repo.addType(name: "") }
        let car = try repo.addType(name: "Car")
        let target = UUID()
        try repo.setType(gym.id, for: target)
        try repo.setType(car.id, for: target)
        #expect(try repo.typeId(for: target) == car.id)
        #expect(try p.context.fetchCount(FetchDescriptor<SubscriptionLink>()) == 1)
        try repo.deleteType(car)
        #expect(try repo.typeId(for: target) == nil)
        try repo.setType(gym.id, for: target)
        try repo.setType(nil, for: target)
        #expect(try repo.typeId(for: target) == nil)
    }

    @Test func deletingATransactionOrBillRemovesItsLink() throws {
        let p = try PersistenceService(inMemory: true)
        let repo = SubscriptionRepository(context: p.context)
        let gym = try repo.addType(name: "Gym")
        let t = TransactionRecord(transactionDate: .now, amountMinorUnits: 4_000, title: "Gym", transactionType: .expense)
        p.context.insert(MoneyTransaction(record: t))
        let bill = RecurringBill(title: "Gym", expectedAmountMinorUnits: 4_000, recurrenceRule: .monthly, nextDueDate: .now)
        p.context.insert(bill)
        try p.context.save()
        try repo.setType(gym.id, for: t.id)
        try repo.setType(gym.id, for: bill.id)
        try TransactionRepository(context: p.context).delete(id: t.id)
        try BillRepository(context: p.context).delete(id: bill.id)
        #expect(try p.context.fetchCount(FetchDescriptor<SubscriptionLink>()) == 0)
    }

    @Test func backupMergesTypesByName() throws {
        let source = try PersistenceService(inMemory: true)
        let a = SubscriptionRepository(context: source.context)
        let gym = try a.addType(name: "Gym & Fitness")
        let target = UUID()
        try a.setType(gym.id, for: target)
        let data = try BackupSubscriptionData.make(from: source.context)
        try data.validate()

        let other = try PersistenceService(inMemory: true)
        let b = SubscriptionRepository(context: other.context)
        let existing = try b.addType(name: "gym & fitness")
        try data.restore(into: other.context)
        try data.restore(into: other.context)
        #expect(try other.context.fetchCount(FetchDescriptor<SubscriptionType>()) == 1)
        #expect(try b.typeId(for: target) == existing.id)
    }
}
