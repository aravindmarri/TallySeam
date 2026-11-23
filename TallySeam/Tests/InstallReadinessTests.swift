import Foundation
import SwiftData
import UIKit
import XCTest
@testable import TallySeam

/// Data must survive force-closing the app and installing updates. These tests use a real on-disk
/// SwiftData store that is closed and reopened, which is what happens when iOS terminates the app.
@MainActor
final class PersistenceAcrossRestartTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "RestartTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var storeURL: URL { folder.appending(path: "TallySeam.store") }

    func testEverythingSurvivesClosingAndReopeningTheStore() throws {
        var expectedTransactions: [TransactionRecord] = []
        var billId = UUID()
        do {
            let first = try PersistenceService(storeURL: storeURL)
            try first.seedDefaultsIfNeeded()
            let kinds = try ReferenceDataRepository(context: first.context).categoryKinds()
            let groceries = try XCTUnwrap(first.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.name == "Groceries" })
            let repo = TransactionRepository(context: first.context)
            var d = TransactionDraft(currencyCode: "USD", date: Date(timeIntervalSince1970: 1_710_000_000))
            d.title = "Synthetic groceries"; d.amountText = "47.80"; d.categoryId = groceries.id
            try repo.save(d, categoryKinds: kinds)
            var refund = TransactionDraft(currencyCode: "USD", date: Date(timeIntervalSince1970: 1_710_100_000))
            refund.title = "Synthetic refund"; refund.amountText = "5.00"; refund.isRefund = true
            try repo.save(refund, categoryKinds: kinds)
            var bill = BillDraft(currencyCode: "USD", nextDueDate: Date(timeIntervalSince1970: 1_712_000_000))
            bill.title = "Phone"; bill.amountText = "50"
            billId = try BillRepository(context: first.context).save(bill).id
            let settings = try first.settings()
            settings.preferredCurrencyCode = "EUR"
            try first.context.save()
            expectedTransactions = try repo.allRecords().sorted { $0.transactionDate < $1.transactionDate }
        }
        // The first container is gone, as after a force-close. Open the same file again.
        let second = try PersistenceService(storeURL: storeURL)
        try second.seedDefaultsIfNeeded()   // runs on every launch; must not duplicate anything
        let reloaded = try TransactionRepository(context: second.context).allRecords().sorted { $0.transactionDate < $1.transactionDate }
        XCTAssertEqual(reloaded, expectedTransactions)
        XCTAssertEqual(try BillRepository(context: second.context).fetch(id: billId)?.title, "Phone")
        XCTAssertEqual(try second.settings().preferredCurrencyCode, "EUR")
        XCTAssertEqual(try second.context.fetchCount(FetchDescriptor<SpendingCategory>()), DefaultCategories.makeAll().count)
        XCTAssertEqual(try second.context.fetchCount(FetchDescriptor<AppSettings>()), 1)

        let summary = FinanceCalculationService().summary(of: reloaded, in: DateRange(start: .distantPast, end: .distantFuture), currencyCode: "USD")
        XCTAssertEqual(summary.expenseMinorUnits, 4_280)
    }

    func testReopeningRepeatedlyKeepsDataAndAddsNothing() throws {
        do {
            let p = try PersistenceService(storeURL: storeURL)
            try p.seedDefaultsIfNeeded()
            p.context.insert(MoneyTransaction(record: TransactionRecord(transactionDate: .now, amountMinorUnits: 100, title: "x", transactionType: .expense)))
            try p.context.save()
        }
        for _ in 0..<3 {
            let p = try PersistenceService(storeURL: storeURL)
            try p.seedDefaultsIfNeeded()
            XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<MoneyTransaction>()), 1)
            XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<SpendingCategory>()), DefaultCategories.makeAll().count)
        }
    }
}

/// Guards for app updates. A store written by this version must open in the next one, and a backup
/// written by any 1.x version must keep importing.
@MainActor
final class UpdateCompatibilityTests: XCTestCase {
    func testLatestVersionedSchemaCoversEveryModel() {
        // If a model is added or changed, a new VersionedSchema and MigrationStage must be added,
        // otherwise existing users' stores would fail to open after an update.
        let latest = TallySeamMigrationPlan.schemas.last.map { ObjectIdentifier($0) }
        XCTAssertEqual(latest, ObjectIdentifier(TallySeamSchemaV7.self))
        XCTAssertEqual(ObjectIdentifier(TallySeamCurrentSchema.self), ObjectIdentifier(TallySeamSchemaV7.self))
        XCTAssertEqual(TallySeamSchemaV7.versionIdentifier, Schema.Version(7, 0, 0))
        XCTAssertEqual(TallySeamSchemaV6.versionIdentifier, Schema.Version(6, 0, 0))
        XCTAssertEqual(TallySeamSchemaV5.versionIdentifier, Schema.Version(5, 0, 0))
        XCTAssertEqual(TallySeamSchemaV4.versionIdentifier, Schema.Version(4, 0, 0))
        let expected: Set<String> = ["MoneyTransaction", "SpendingCategory", "PaymentMethod", "Receipt", "RecurringBill", "Budget", "AppSettings"]
        let expectedV3 = expected.union(["FinancialAccount", "ImportSession", "ImportedStatement", "StatementTransaction",
                                         "ReconciliationMatch", "MerchantAlias"])
        XCTAssertEqual(Set(TallySeamSchemaV3.models.map { String(describing: $0) }), expectedV3)
        XCTAssertEqual(Set(TallySeamSchemaV4.models.map { String(describing: $0) }), expectedV3)
        XCTAssertEqual(Set(TallySeamSchemaV5.models.map { String(describing: $0) }), expectedV3.union(["Investment", "MonthlySnapshot"]))
        XCTAssertEqual(Set(TallySeamSchemaV6.models.map { String(describing: $0) }),
                       expectedV3.union(["Investment", "MonthlySnapshot", "SplitPerson", "TransactionSplit", "SplitLedgerEntry"]))
        XCTAssertEqual(Set(TallySeamSchemaV7.models.map { String(describing: $0) }),
                       expectedV3.union(["Investment", "MonthlySnapshot", "SplitPerson", "TransactionSplit", "SplitLedgerEntry",
                                         "SubscriptionType", "SubscriptionLink"]))
        XCTAssertEqual(TallySeamSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
        XCTAssertEqual(Set(TallySeamSchemaV2.models.map { String(describing: $0) }), expected)
        XCTAssertEqual(Set(TallySeamSchemaV1.models.map { String(describing: $0) }), expected)
        XCTAssertEqual(TallySeamSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(TallySeamSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
        XCTAssertEqual(TallySeamMigrationPlan.stages.count, TallySeamMigrationPlan.schemas.count - 1)
    }

    func testStoreWrittenByThisVersionOpensThroughTheMigrationPlan() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "TallySeam.store")
        let id = UUID()
        do {
            let old = try PersistenceService(storeURL: url)
            old.context.insert(MoneyTransaction(record: TransactionRecord(id: id, transactionDate: .now, amountMinorUnits: 999, title: "Kept",
                                                                          transactionType: .expense, isRefund: true)))
            try old.context.save()
        }
        let updated = try PersistenceService(storeURL: url)
        let kept = try XCTUnwrap(TransactionRepository(context: updated.context).fetch(id: id))
        XCTAssertEqual(kept.amountMinorUnits, 999)
        XCTAssertTrue(kept.isRefund)
    }

    /// A version 1 backup, frozen as text. Future versions must keep decoding and importing it.
    static let frozenV1Backup = """
    {"bills":[{"currencyCode":"USD","expectedAmountMinorUnits":5000,"id":"33333333-3333-3333-3333-333333333333","isActive":true,\
    "nextDueDate":700000000,"recurrence":"monthly","title":"Phone"}],\
    "budgets":[{"amountMinorUnits":40000,"categoryId":"11111111-1111-1111-1111-111111111111","currencyCode":"USD",\
    "effectiveStartMonth":700000000,"id":"44444444-4444-4444-4444-444444444444","isActive":true}],\
    "categories":[{"colorIdentifier":"green","displayOrder":1,"id":"11111111-1111-1111-1111-111111111111","isSystemCategory":true,\
    "kind":"expense","name":"Groceries","symbol":"cart.fill"}],\
    "exportedAt":700000000,"paymentMethods":[],"receipts":[],"schemaVersion":1,\
    "transactions":[{"amountMinorUnits":1234,"categoryId":"11111111-1111-1111-1111-111111111111","createdAt":700000000,\
    "currencyCode":"USD","id":"22222222-2222-2222-2222-222222222222","isRefund":false,"isVerified":true,"source":"manual",\
    "title":"Synthetic","transactionDate":700000000,"transactionType":"expense","updatedAt":700000000}]}
    """

    func testFrozenVersion1BackupStillImports() throws {
        let payload = try BackupService.decode(Data(Self.frozenV1Backup.utf8))
        let persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        let storage = ReceiptStorageService(rootURL: FileManager.default.temporaryDirectory.appending(path: "Frozen-\(UUID().uuidString)"))
        let summary = try BackupService(context: persistence.context, storage: storage).restore(payload)
        XCTAssertEqual(summary.transactionsAdded, 1)
        XCTAssertEqual(summary.billsAdded, 1)
        XCTAssertEqual(summary.budgetsAdded, 1)
        XCTAssertEqual(summary.categoriesAdded, 0, "Matched to this device's Groceries")
        let local = try XCTUnwrap(persistence.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.name == "Groceries" })
        let t = try XCTUnwrap(TransactionRepository(context: persistence.context).allRecords().first)
        XCTAssertEqual(t.amountMinorUnits, 1_234)
        XCTAssertEqual(t.categoryId, local.id)
    }
}

/// Records every URL request any URLSession in the process tries to start.
final class NetworkRecorder: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String] = []

    static var requests: [String] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { seen.append(request.url?.absoluteString ?? "?") }
        return false   // never handle it; just record the attempt
    }
}

/// Runs the receipt, calculation, backup and chart-data code paths and checks that none of them
/// tries to use the network. Complements the static source check and the IPA's linked-framework check.
/// Limit: this detects URLSession-based traffic; lower-level sockets are covered by the static checks.
@MainActor
final class NoNetworkTests: XCTestCase {
    override func setUp() async throws {
        NetworkRecorder.reset()
        URLProtocol.registerClass(NetworkRecorder.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(NetworkRecorder.self)
    }

    func testRecorderDetectsARealRequestAttempt() async {
        // Proves the detector works: a request to a reserved, unroutable test domain is recorded.
        let url = URL(string: "https://network-check.invalid/")!
        _ = try? await URLSession.shared.data(from: url)
        XCTAssertTrue(NetworkRecorder.requests.contains { $0.contains("network-check.invalid") })
    }

    func testOCRCalculationsAndBackupMakeNoRequests() async throws {
        let rows: [(String, String)] = [("CORNER CAFE", ""), ("03/15/2024", ""), ("Latte", "4.50"), ("TOTAL", "4.50")]
        let png = try XCTUnwrap(SyntheticReceipt.render(rows).pngData())
        let normalized = try XCTUnwrap(ImageNormalizer.normalize(png))
        let lines = try await VisionReceiptOCRService().recognizeText(in: normalized.cgImage)
        let parsed = ReceiptParserService().parse(lines: lines, defaultCurrency: "USD")
        _ = ImageFingerprint.fingerprint(for: normalized.cgImage)
        _ = HeuristicCategorySuggestionService().suggest(merchant: parsed.merchant?.value, receiptText: lines.joined(separator: "\n"),
                                                         kind: .expense, categories: [], history: [])

        var records: [TransactionRecord] = []
        for i in 0..<50 {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)
            let type: TransactionType = i % 5 == 0 ? .income : .expense
            records.append(TransactionRecord(transactionDate: date, amountMinorUnits: Int64(100 + i), title: "t\(i)", transactionType: type))
        }
        let finance = FinanceCalculationService()
        let range = DateRange(start: .distantPast, end: .distantFuture)
        _ = finance.summary(of: records, in: range, currencyCode: "USD")
        _ = finance.expensesByCategory(records, in: range, currencyCode: "USD")
        _ = finance.dailyExpenses(records, in: Calendar.current.monthRange(containing: records[10].transactionDate), currencyCode: "USD")
        _ = finance.monthlyFlows(records, endingWith: records[49].transactionDate, count: 6, currencyCode: "USD")
        _ = BudgetCalculationService().progress(budgets: [BudgetRecord(categoryId: nil, amountMinorUnits: 1_000, effectiveStartMonth: .distantPast)],
                                                records: records, month: records[10].transactionDate)

        let persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        let storage = ReceiptStorageService(rootURL: FileManager.default.temporaryDirectory.appending(path: "NoNet-\(UUID().uuidString)"))
        let backup = BackupService(context: persistence.context, storage: storage)
        let file = try BackupCrypto.encrypt(try BackupService.encode(try backup.makePayload()), password: "synthetic-pass")
        _ = try BackupCrypto.decrypt(file, password: "synthetic-pass")

        XCTAssertEqual(NetworkRecorder.requests, [], "No network requests may be made")
    }
}
