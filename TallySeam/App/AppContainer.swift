import Foundation
import Observation
import SwiftData

enum AppTab: Hashable {
    case home, transactions, scan, reports, settings
}

/// Dependency container injected through the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    let persistence: PersistenceService
    let finance: FinanceCalculationService
    let transactions: TransactionRepository
    let referenceData: ReferenceDataRepository
    let receipts: ReceiptRepository
    let bills: BillRepository
    let budgets: BudgetRepository
    let budgetCalculator: BudgetCalculationService
    let backup: BackupService
    let statements: StatementRepository
    let investments: InvestmentRepository
    let splits: SplitRepository
    let lock: AppLockController
    let textRecognizer: any ReceiptTextRecognizing
    let categorySuggester: any CategorySuggesting
    var selectedTab: AppTab = .home

    init(persistence: PersistenceService,
         receiptStorage: ReceiptStorageService,
         finance: FinanceCalculationService = FinanceCalculationService(),
         textRecognizer: any ReceiptTextRecognizing = VisionReceiptOCRService(),
         categorySuggester: any CategorySuggesting = HeuristicCategorySuggestionService(),
         authenticator: any DeviceAuthenticating = LocalDeviceAuthenticator()) {
        self.persistence = persistence
        self.finance = finance
        self.transactions = TransactionRepository(context: persistence.context)
        self.referenceData = ReferenceDataRepository(context: persistence.context)
        self.receipts = ReceiptRepository(context: persistence.context, storage: receiptStorage)
        self.bills = BillRepository(context: persistence.context)
        self.budgets = BudgetRepository(context: persistence.context)
        self.budgetCalculator = BudgetCalculationService(finance: finance)
        self.backup = BackupService(context: persistence.context, storage: receiptStorage)
        self.statements = StatementRepository(context: persistence.context)
        self.investments = InvestmentRepository(context: persistence.context)
        self.splits = SplitRepository(context: persistence.context)
        let lockEnabled = (try? persistence.context.fetch(FetchDescriptor<AppSettings>()).first?.requireBiometricUnlock) ?? false
        self.lock = AppLockController(isEnabled: lockEnabled, authenticator: authenticator)
        self.textRecognizer = textRecognizer
        self.categorySuggester = categorySuggester
    }

    static func live() throws -> AppContainer {
        let persistence = try PersistenceService()
        try persistence.seedDefaultsIfNeeded()
        let container = AppContainer(persistence: persistence, receiptStorage: try ReceiptStorageService.live())
        _ = try? container.receipts.removeOrphanedImages()
        return container
    }

    /// In-memory container for SwiftUI previews and tests. Contains only system categories.
    static func preview() -> AppContainer {
        // swiftlint:disable:next force_try
        let persistence = try! PersistenceService(inMemory: true)
        try? persistence.seedDefaultsIfNeeded()
        let storage = ReceiptStorageService(rootURL: FileManager.default.temporaryDirectory.appending(path: "TallySeamPreview"))
        return AppContainer(persistence: persistence, receiptStorage: storage)
    }
}
