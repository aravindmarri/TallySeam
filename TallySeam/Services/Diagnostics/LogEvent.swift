import Foundation

enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case trace = "TRACE", debug = "DEBUG", info = "INFO", warning = "WARNING", error = "ERROR", critical = "CRITICAL"
    var id: String { rawValue }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// What the user can choose in Settings.
enum LoggingProfile: String, CaseIterable, Identifiable, Sendable {
    case errorsOnly, standard, verbose
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .errorsOnly: "Errors only"
        case .standard: "Standard"
        case .verbose: "Verbose"
        }
    }
    var minimumLevel: LogLevel {
        switch self {
        case .errorsOnly: .error
        case .standard: .info
        case .verbose: .trace
        }
    }
}

enum LogCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case lifecycle = "Lifecycle", persistence = "Persistence", migration = "Migration", transactions = "Transactions"
    case receiptOCR = "ReceiptOCR", documentImport = "DocumentImport", parsing = "Parsing", reconciliation = "Reconciliation"
    case calculations = "Calculations", investments = "Investments", monthlyCheckIn = "MonthlyCheckIn"
    case appleIntelligence = "AppleIntelligence", backup = "Backup", authentication = "Authentication"
    case fileStorage = "FileStorage", uiResponsiveness = "UIResponsiveness", performance = "Performance"
    case memory = "Memory", crash = "CrashDiagnostics"
    var id: String { rawValue }
}

/// Every event the app can log. This catalog is the allowlist: the level, category and message of
/// an event come from here, never from a caller, so no free text can enter the log.
enum DiagnosticCode: String, Codable, CaseIterable, Sendable {
    case appLaunched = "APP_001"
    case startupFailed = "APP_500"
    case databaseOpenFailed = "DB_500"
    case databaseSaveFailed = "DB_501"
    case migrationFailed = "MIG_500"
    case operationCompleted = "PERF_001"
    case operationSlow = "PERF_300"
    case transactionSaveFailed = "TXN_500"
    case transactionFetchFailed = "TXN_501"
    case ocrFailed = "OCR_500"
    case documentImportFailed = "DOC_500"
    case documentUnsupported = "DOC_300"
    case statementParseFailed = "STATEMENT_PARSE_001"
    case csvParseFailed = "CSV_500"
    case reconciliationFailed = "RECON_500"
    case calculationFailed = "CALC_500"
    case investmentSaveFailed = "INV_500"
    case checkInFailed = "CHECKIN_500"
    case aiFallback = "AI_300"
    case backupFailed = "BACKUP_500"
    case restoreFailed = "BACKUP_501"
    case authenticationFailed = "AUTH_300"
    case fileStorageFailed = "FILE_500"
    case memoryWarning = "MEM_300"
    case crashReportReceived = "CRASH_001"
    case testInfo = "TEST_001"
    case testWarning = "TEST_300"
    case testError = "TEST_500"

    var level: LogLevel {
        switch self {
        // Routine or user-caused: only with Verbose.
        case .operationCompleted, .appLaunched, .authenticationFailed, .documentUnsupported: .debug
        case .startupFailed, .databaseOpenFailed, .migrationFailed: .critical
        case .operationSlow, .aiFallback, .memoryWarning, .crashReportReceived, .testWarning: .warning
        case .testInfo: .info
        default: .error
        }
    }

    var category: LogCategory {
        switch self {
        case .appLaunched, .startupFailed, .testInfo, .testWarning, .testError: .lifecycle
        case .databaseOpenFailed, .databaseSaveFailed: .persistence
        case .migrationFailed: .migration
        case .operationCompleted, .operationSlow: .performance
        case .transactionSaveFailed, .transactionFetchFailed: .transactions
        case .ocrFailed: .receiptOCR
        case .documentImportFailed, .documentUnsupported: .documentImport
        case .statementParseFailed, .csvParseFailed: .parsing
        case .reconciliationFailed: .reconciliation
        case .calculationFailed: .calculations
        case .investmentSaveFailed: .investments
        case .checkInFailed: .monthlyCheckIn
        case .aiFallback: .appleIntelligence
        case .backupFailed, .restoreFailed: .backup
        case .authenticationFailed: .authentication
        case .fileStorageFailed: .fileStorage
        case .memoryWarning: .memory
        case .crashReportReceived: .crash
        }
    }

    var message: String {
        switch self {
        case .appLaunched: "Application started"
        case .startupFailed: "Application failed to start"
        case .databaseOpenFailed: "Database could not be opened"
        case .databaseSaveFailed: "Database save failed"
        case .migrationFailed: "Database migration failed"
        case .operationCompleted: "Operation completed"
        case .operationSlow: "Operation was slow"
        case .transactionSaveFailed: "Transaction could not be saved"
        case .transactionFetchFailed: "Transactions could not be read"
        case .ocrFailed: "Text recognition failed"
        case .documentImportFailed: "Document could not be read"
        case .documentUnsupported: "Document format was unsupported"
        case .statementParseFailed: "Statement parsing failed"
        case .csvParseFailed: "Spreadsheet parsing failed"
        case .reconciliationFailed: "Statement reconciliation failed"
        case .calculationFailed: "Calculation failed"
        case .investmentSaveFailed: "Investment could not be saved"
        case .checkInFailed: "Monthly check-in could not be saved"
        case .aiFallback: "On-device model unavailable or failed; built-in rules were used"
        case .backupFailed: "Backup could not be created"
        case .restoreFailed: "Backup could not be restored"
        case .authenticationFailed: "Authentication did not succeed"
        case .fileStorageFailed: "File could not be stored"
        case .memoryWarning: "Memory warning received"
        case .crashReportReceived: "Diagnostic report received from iOS"
        case .testInfo: "Synthetic test event (information)"
        case .testWarning: "Synthetic test event (warning)"
        case .testError: "Synthetic test event (error)"
        }
    }
}

/// Timed operations. Names are fixed, so they carry no user data.
enum DiagnosticOperation: String, Codable, CaseIterable, Sendable {
    case startup, databaseOpen, dashboardLoad, transactionFetch, databaseSave, receiptOCR, documentRead, csvParse
    case statementParse, reconciliation, reportGeneration, calculation, backupCreate, backupRestore, aiResponse
    case investmentSave, checkInSave, authentication, fileStore, testOperation

    var slowMilliseconds: Int {
        switch self {
        case .startup, .databaseOpen: 2_000
        case .receiptOCR, .documentRead, .backupCreate, .backupRestore, .aiResponse: 5_000
        case .authentication: 60_000
        case .statementParse, .reconciliation: 1_000
        default: 300
        }
    }

    /// Frequent operations (screen redraws) are timed but leave no breadcrumb.
    var leavesBreadcrumb: Bool {
        switch self {
        case .dashboardLoad, .reportGeneration, .calculation, .transactionFetch: false
        default: true
        }
    }

    var failureCode: DiagnosticCode {
        switch self {
        case .startup: .startupFailed
        case .databaseOpen: .databaseOpenFailed
        case .databaseSave: .transactionSaveFailed
        case .transactionFetch: .transactionFetchFailed
        case .receiptOCR: .ocrFailed
        case .documentRead: .documentImportFailed
        case .csvParse: .csvParseFailed
        case .statementParse: .statementParseFailed
        case .reconciliation: .reconciliationFailed
        case .dashboardLoad, .reportGeneration, .calculation: .calculationFailed
        case .backupCreate: .backupFailed
        case .backupRestore: .restoreFailed
        case .aiResponse: .aiFallback
        case .investmentSave: .investmentSaveFailed
        case .checkInSave: .checkInFailed
        case .authentication: .authenticationFailed
        case .fileStore: .fileStorageFailed
        case .testOperation: .testError
        }
    }
}

/// One stored event. Decoding does not trust the file: `DiagnosticPrivacyFilter` re-checks every record.
struct LogEvent: Codable, Hashable, Sendable, Identifiable {
    static let currentSchema = 1
    var id: String { "\(timestamp.timeIntervalSince1970)-\(eventCode)-\(operationId ?? "")" }
    var timestamp: Date
    var level: LogLevel
    var category: LogCategory
    var eventCode: String
    var message: String
    var appVersion: String
    var buildNumber: String
    var operation: DiagnosticOperation?
    /// Eight random characters, new for each operation. Never derived from a record or device.
    var operationId: String?
    var durationMs: Int?
    var errorDomain: String?
    var errorCode: Int?
    var schemaVersion: Int

    init(code: DiagnosticCode, timestamp: Date, appVersion: String, buildNumber: String, operation: DiagnosticOperation? = nil,
         operationId: String? = nil, durationMs: Int? = nil, errorDomain: String? = nil, errorCode: Int? = nil) {
        self.timestamp = timestamp; self.level = code.level; self.category = code.category
        self.eventCode = code.rawValue; self.message = code.message
        self.appVersion = appVersion; self.buildNumber = buildNumber; self.operation = operation
        self.operationId = operationId; self.durationMs = durationMs
        self.errorDomain = errorDomain; self.errorCode = errorCode; self.schemaVersion = Self.currentSchema
    }
}

enum DiagnosticJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
