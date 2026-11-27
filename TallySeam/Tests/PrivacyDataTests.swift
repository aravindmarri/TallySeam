import Foundation
import SwiftData
import Testing
import XCTest
@testable import TallySeam

// MARK: - Backup encryption

@Suite struct BackupCryptoTests {
    private func hex(_ key: Data) -> String { key.map { String(format: "%02x", $0) }.joined() }

    @Test func pbkdf2MatchesPublishedTestVectors() throws {
        // RFC 7914 §11 / widely published PBKDF2-HMAC-SHA256 vectors (dkLen 32).
        let one = try BackupCrypto.deriveKey(password: "password", salt: Data("salt".utf8), iterations: 1)
        #expect(hex(one.withUnsafeBytes { Data($0) }) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let many = try BackupCrypto.deriveKey(password: "password", salt: Data("salt".utf8), iterations: 4096)
        #expect(hex(many.withUnsafeBytes { Data($0) }) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    @Test func roundTripAndRejections() throws {
        let secret = Data("Synthetic: Corner Cafe 8.39".utf8)
        let file = try BackupCrypto.encrypt(secret, password: "correct horse")
        #expect(try BackupCrypto.decrypt(file, password: "correct horse") == secret)
        #expect(file.range(of: Data("Corner Cafe".utf8)) == nil, "Plaintext must not appear in the file")
        #expect(throws: BackupError.wrongPasswordOrDamaged) { try BackupCrypto.decrypt(file, password: "wrong horse") }

        // Same input encrypts differently each time (random salt and nonce).
        #expect(try BackupCrypto.encrypt(secret, password: "correct horse") != file)

        // Tampering with the ciphertext or the authenticated header is detected.
        var envelope = try JSONDecoder().decode(BackupCrypto.Envelope.self, from: file)
        var flipped = envelope
        flipped.sealed[flipped.sealed.count - 20] ^= 0x01
        #expect(throws: BackupError.wrongPasswordOrDamaged) {
            try BackupCrypto.decrypt(try JSONEncoder().encode(flipped), password: "correct horse")
        }
        envelope.version = 99
        #expect(throws: BackupError.unsupportedVersion) {
            try BackupCrypto.decrypt(try JSONEncoder().encode(envelope), password: "correct horse")
        }
    }

    @Test func rejectsWeakPasswordsAndForeignFiles() {
        #expect(throws: BackupError.weakPassword) { try BackupCrypto.encrypt(Data(), password: "short") }
        #expect(throws: BackupError.notABackup) { try BackupCrypto.decrypt(Data("{\"hello\":1}".utf8), password: "whatever1") }
        #expect(throws: BackupError.notABackup) { try BackupCrypto.decrypt(Data("not json".utf8), password: "whatever1") }
        #expect(BackupCrypto.isAcceptable(password: "12345678"))
    }
}

// MARK: - App lock

private final class FakeAuthenticator: DeviceAuthenticating, @unchecked Sendable {
    var available: Bool
    var succeeds: Bool
    private(set) var prompts = 0
    init(available: Bool = true, succeeds: Bool = true) { self.available = available; self.succeeds = succeeds }
    func canAuthenticate() -> Bool { available }
    func authenticate(reason: String) async -> Bool { prompts += 1; return succeeds }
    var biometryName: String { "Face ID" }
}

@MainActor
final class AppLockTests: XCTestCase {
    func testStartsLockedOnlyWhenEnabledAndAvailable() {
        XCTAssertTrue(AppLockController(isEnabled: true, authenticator: FakeAuthenticator()).isLocked)
        XCTAssertFalse(AppLockController(isEnabled: false, authenticator: FakeAuthenticator()).isLocked)
        XCTAssertFalse(AppLockController(isEnabled: true, authenticator: FakeAuthenticator(available: false)).isLocked,
                       "Without a device passcode the owner can't be verified, so the user is never locked out")
    }

    func testUnlockRequiresSuccessfulAuthentication() async {
        let auth = FakeAuthenticator(succeeds: false)
        let lock = AppLockController(isEnabled: true, authenticator: auth)
        await lock.unlock()
        XCTAssertTrue(lock.isLocked)
        auth.succeeds = true
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        await lock.unlock()
        XCTAssertEqual(auth.prompts, 2, "No prompt when already unlocked")
        lock.lockIfEnabled(false)
        XCTAssertFalse(lock.isLocked)
        lock.lockIfEnabled(true)
        XCTAssertTrue(lock.isLocked)
    }

    func testChangingTheSettingRequiresAuthentication() async {
        let auth = FakeAuthenticator(succeeds: false)
        let lock = AppLockController(isEnabled: false, authenticator: auth)
        let denied = await lock.confirmChange()
        XCTAssertFalse(denied)
        auth.succeeds = true
        let allowed = await lock.confirmChange()
        XCTAssertTrue(allowed)
    }
}

// MARK: - Backup, restore and deletion (in-memory SwiftData)

@MainActor
final class BackupServiceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for r in roots { try? FileManager.default.removeItem(at: r) }
    }

    private func makeStore() throws -> (PersistenceService, BackupService, ReceiptRepository, ReceiptStorageService) {
        let persistence = try PersistenceService(inMemory: true)
        try persistence.seedDefaultsIfNeeded()
        let root = FileManager.default.temporaryDirectory.appending(path: "BackupTests-\(UUID().uuidString)")
        roots.append(root)
        let storage = ReceiptStorageService(rootURL: root)
        return (persistence, BackupService(context: persistence.context, storage: storage),
                ReceiptRepository(context: persistence.context, storage: storage), storage)
    }

    private func category(_ name: String, in p: PersistenceService) throws -> SpendingCategory {
        try XCTUnwrap(p.context.fetch(FetchDescriptor<SpendingCategory>()).first { $0.name == name })
    }

    /// Fills a store with one of everything. Synthetic data only.
    private func populate(_ p: PersistenceService, receipts: ReceiptRepository) throws {
        let groceries = try category("Groceries", in: p).id
        let custom = SpendingCategory(name: "Hobbies", symbol: "paintbrush", colorIdentifier: "purple", kind: .expense,
                                      isSystemCategory: false, displayOrder: 99)
        p.context.insert(custom)
        let card = PaymentMethod(name: "Test Card", type: .creditCard, lastFourDigits: "4242")
        p.context.insert(card)
        try p.context.save()
        let kinds = try ReferenceDataRepository(context: p.context).categoryKinds()   // after adding the custom category

        var d = TransactionDraft(currencyCode: "USD", date: Date(timeIntervalSince1970: 1_710_000_000))
        d.title = "Fresh Mart"; d.amountText = "47.80"; d.categoryId = groceries; d.paymentMethodId = card.id
        try receipts.saveNewTransaction(from: d, receipt: ReceiptImport(jpegData: Data([0xFF, 0xD8, 0x01, 0x02]), fingerprint: "dhash:0000000000000001"),
                                        categoryKinds: kinds)
        var hobby = TransactionDraft(currencyCode: "USD", date: Date(timeIntervalSince1970: 1_710_100_000))
        hobby.title = "Paints"; hobby.amountText = "12.00"; hobby.categoryId = custom.id
        try TransactionRepository(context: p.context).save(hobby, categoryKinds: kinds)

        var bill = BillDraft(currencyCode: "USD", nextDueDate: Date(timeIntervalSince1970: 1_712_000_000))
        bill.title = "Phone"; bill.amountText = "50"; bill.categoryId = try category("Utilities", in: p).id
        try BillRepository(context: p.context).save(bill)
        var budget = BudgetDraft(currencyCode: "USD")
        budget.categoryId = groceries; budget.amountText = "400"
        try BudgetRepository(context: p.context).save(budget)
    }

    func testFullRoundTripOntoFreshInstall() throws {
        let (source, sourceBackup, sourceReceipts, _) = try makeStore()
        try populate(source, receipts: sourceReceipts)
        let payload = try sourceBackup.makePayload()
        let file = try BackupCrypto.encrypt(try BackupService.encode(payload), password: "synthetic-pass")

        let (target, targetBackup, targetReceipts, _) = try makeStore()
        let restored = try BackupService.decode(try BackupCrypto.decrypt(file, password: "synthetic-pass"))
        XCTAssertEqual(restored, payload)
        let summary = try targetBackup.restore(restored)

        XCTAssertEqual(summary.transactionsAdded, 2)
        XCTAssertEqual(summary.receiptsAdded, 1)
        XCTAssertEqual(summary.billsAdded, 1)
        XCTAssertEqual(summary.budgetsAdded, 1)
        XCTAssertEqual(summary.paymentMethodsAdded, 1)
        XCTAssertEqual(summary.categoriesAdded, 1, "Only the custom category is new; defaults are matched by name")

        // Default categories have different ids on the fresh install; transactions point at the local ones.
        let records = try TransactionRepository(context: target.context).allRecords()
        let fresh = try XCTUnwrap(records.first { $0.title == "Fresh Mart" })
        XCTAssertEqual(fresh.categoryId, try category("Groceries", in: target).id)
        XCTAssertEqual(fresh.amountMinorUnits, 4_780)
        XCTAssertEqual(records.first { $0.title == "Paints" }?.categoryId, try category("Hobbies", in: target).id)
        let receiptId = try XCTUnwrap(fresh.receiptId)
        XCTAssertEqual(targetReceipts.imageData(forReceipt: receiptId), Data([0xFF, 0xD8, 0x01, 0x02]))
        XCTAssertEqual(try target.context.fetch(FetchDescriptor<PaymentMethod>()).first?.lastFourDigits, "4242")

        // Totals are identical after restore.
        let range = DateRange(start: .distantPast, end: .distantFuture)
        let finance = FinanceCalculationService()
        XCTAssertEqual(finance.summary(of: records, in: range, currencyCode: "USD"),
                       finance.summary(of: try TransactionRepository(context: source.context).allRecords(), in: range, currencyCode: "USD"))

        // Importing again adds nothing.
        let again = try targetBackup.restore(restored)
        XCTAssertEqual(again.transactionsAdded, 0)
        XCTAssertEqual(again.transactionsSkipped, 2)
        XCTAssertEqual(try TransactionRepository(context: target.context).allRecords().count, 2)
    }

    func testClashingBudgetIsImportedPaused() throws {
        let (source, sourceBackup, sourceReceipts, _) = try makeStore()
        try populate(source, receipts: sourceReceipts)
        let payload = try sourceBackup.makePayload()

        let (target, targetBackup, _, _) = try makeStore()
        var own = BudgetDraft(currencyCode: "USD")
        own.categoryId = try category("Groceries", in: target).id; own.amountText = "300"
        try BudgetRepository(context: target.context).save(own)
        let summary = try targetBackup.restore(payload)
        XCTAssertEqual(summary.budgetsPaused, 1)
        XCTAssertEqual(try target.context.fetch(FetchDescriptor<Budget>()).filter(\.isActive).count, 1)
    }

    func testInvalidBackupImportsNothing() throws {
        let (_, backup, _, _) = try makeStore()
        var payload = BackupPayload(exportedAt: .now)
        payload.transactions = [
            TransactionRecord(transactionDate: .now, amountMinorUnits: 100, title: "ok", transactionType: .expense),
            TransactionRecord(transactionDate: .now, amountMinorUnits: -5, title: "bad", transactionType: .expense),
        ]
        XCTAssertThrowsError(try backup.restore(payload)) { XCTAssertEqual($0 as? BackupError, .invalidContents) }
        XCTAssertThrowsError(try BackupService.decode(Data("[]".utf8))) { XCTAssertEqual($0 as? BackupError, .invalidContents) }
    }

    func testDeleteAllDataErasesEverythingAndRestoresDefaults() throws {
        let (p, backup, receipts, storage) = try makeStore()
        try populate(p, receipts: receipts)
        let settings = try p.settings()
        settings.preferredCurrencyCode = "EUR"
        try p.context.save()
        XCTAssertEqual(try storage.orphanedPaths(referenced: []).count, 1)

        try backup.deleteAllData()
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<MoneyTransaction>()), 0)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<Receipt>()), 0)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<RecurringBill>()), 0)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<Budget>()), 0)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<PaymentMethod>()), 0)
        XCTAssertEqual(try storage.orphanedPaths(referenced: []).count, 0, "Receipt images are deleted")
        let categories = try p.context.fetch(FetchDescriptor<SpendingCategory>())
        XCTAssertEqual(categories.count, DefaultCategories.makeAll().count)
        XCTAssertFalse(categories.contains { $0.name == "Hobbies" })
        XCTAssertEqual(try p.context.fetch(FetchDescriptor<AppSettings>()).count, 1)
        XCTAssertEqual(try p.settings().preferredCurrencyCode, CurrencyMath.defaultCode)
    }

    func testUnattachedReceiptCleanupKeepsAttachedReceipts() throws {
        let (p, backup, receipts, storage) = try makeStore()
        try populate(p, receipts: receipts)
        XCTAssertEqual(try backup.unattachedReceipts().count, 0)
        let kinds = try ReferenceDataRepository(context: p.context).categoryKinds()
        var d = TransactionDraft(currencyCode: "USD")
        d.title = "Second"; d.amountText = "5"
        let second = try receipts.saveNewTransaction(from: d, receipt: ReceiptImport(jpegData: Data([0xFF, 0xD8, 0x09])), categoryKinds: kinds)
        try TransactionRepository(context: p.context).delete(id: second.id)

        XCTAssertEqual(try backup.unattachedReceipts().count, 1)
        XCTAssertEqual(try backup.deleteUnattachedReceipts(), 1)
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<Receipt>()), 1, "The attached receipt is kept")
        XCTAssertEqual(try storage.orphanedPaths(referenced: []).count, 1)
        XCTAssertEqual(try TransactionRepository(context: p.context).allRecords().count, 2, "Transactions are not touched")
    }
}

/// Backups from early builds still open in TallySeam; unknown formats don't.
final class BackupFormatCompatibilityTests: XCTestCase {
    func testOldAndNewFormatsOpen() throws {
        let data = Data("synthetic backup".utf8)
        let new = try BackupCrypto.encrypt(data, password: "synthetic-pass", iterations: 100_000)
        XCTAssertTrue(String(decoding: new, as: UTF8.self).contains("TallySeam-Backup"))
        XCTAssertEqual(try BackupCrypto.decrypt(new, password: "synthetic-pass"), data)
        let old = try BackupCrypto.encrypt(data, password: "synthetic-pass", iterations: 100_000, format: "MyMoneyAI-Backup")
        XCTAssertEqual(try BackupCrypto.decrypt(old, password: "synthetic-pass"), data)
        let other = try BackupCrypto.encrypt(data, password: "synthetic-pass", iterations: 100_000, format: "SomethingElse")
        XCTAssertThrowsError(try BackupCrypto.decrypt(other, password: "synthetic-pass")) {
            XCTAssertEqual($0 as? BackupError, .notABackup)
        }
    }
}
