import Foundation
import os

/// Diagnostic choices, kept in UserDefaults rather than the database so a database that won't open
/// can still be diagnosed. Everything is off until the user turns it on.
struct DiagnosticsSettings: @unchecked Sendable {
    static let enabledKey = "diagnostics.enabled"
    static let profileKey = "diagnostics.profile"
    static let performanceKey = "diagnostics.performance"
    static let crashKey = "diagnostics.crash"

    let defaults: UserDefaults   // UserDefaults is thread-safe.
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    var profile: LoggingProfile {
        get { defaults.string(forKey: Self.profileKey).flatMap(LoggingProfile.init(rawValue:)) ?? .standard }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.profileKey) }
    }
    /// The two options below only count while diagnostics are enabled.
    var performance: Bool {
        get { defaults.bool(forKey: Self.performanceKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.performanceKey) }
    }
    var crashReports: Bool {
        get { defaults.bool(forKey: Self.crashKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.crashKey) }
    }
}

/// A running timed operation. Holds nothing about the data being worked on.
struct OperationToken: Sendable {
    let operation: DiagnosticOperation
    let id: String
    fileprivate let start: ContinuousClock.Instant
    /// Collection session it belongs to; a token from before diagnostics were turned off is ignored.
    fileprivate let generation: Int
}

/// Logging used by the rest of the app.
protocol AppLogger: Sendable {
    func log(_ code: DiagnosticCode, error: (any Error)?)
    func begin(_ operation: DiagnosticOperation) -> OperationToken?
    func end(_ token: OperationToken?, error: (any Error)?)
}

/// Does nothing. Used where no diagnostics are wanted.
struct NoOpLogger: AppLogger {
    func log(_ code: DiagnosticCode, error: (any Error)?) {}
    func begin(_ operation: DiagnosticOperation) -> OperationToken? { nil }
    func end(_ token: OperationToken?, error: (any Error)?) {}
}

extension AppLogger {
    func log(_ code: DiagnosticCode) { log(code, error: nil) }
    func end(_ token: OperationToken?) { end(token, error: nil) }

    func measure<T>(_ operation: DiagnosticOperation, _ body: () throws -> T) rethrows -> T {
        let token = begin(operation)
        do {
            let value = try body()
            end(token)
            return value
        } catch {
            end(token, error: error)
            throw error
        }
    }
}

/// The app's one diagnostics object. Checks the user's choice and writes under a single lock, so
/// nothing can be written after `setEnabled(false)` returns.
final class DiagnosticsService: AppLogger, @unchecked Sendable {
    static let shared = DiagnosticsService()

    let settings: DiagnosticsSettings
    let store: LocalLogStore
    private let lock = NSRecursiveLock()
    private let appVersion: String
    private let buildNumber: String
    private var generation = 0
    /// Operations still running, by operation id.
    private var intervals: [String: OSSignpostIntervalState] = [:]
    private var metrics: [DiagnosticOperation: OperationMetrics]?
    private var lastMetricsSave = ContinuousClock.now
    private let signposter = OSSignposter(subsystem: "io.github.aravindmarri.tallyseam", category: "Operations")

    init(settings: DiagnosticsSettings = DiagnosticsSettings(), store: LocalLogStore = LocalLogStore(), bundle: Bundle = .main) {
        self.settings = settings; self.store = store
        func version(_ key: String) -> String {
            let v = bundle.infoDictionary?[key] as? String ?? "0"
            return DiagnosticPrivacyFilter.isVersion(v) ? v : "0"
        }
        appVersion = version("CFBundleShortVersionString")
        buildNumber = version("CFBundleVersion")
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var isEnabled: Bool { locked { settings.isEnabled } }
    var collectsCrashes: Bool { locked { settings.isEnabled && settings.crashReports } }
    var collectsPerformance: Bool { locked { settings.isEnabled && settings.performance } }
    var currentVersion: (app: String, build: String) { (appVersion, buildNumber) }
    /// Changes whenever collection is turned on or off.
    var currentGeneration: Int { locked { generation } }

    func setEnabled(_ on: Bool) {
        locked {
            guard on != settings.isEnabled else { return }
            flushMetrics()
            generation += 1
            metrics = nil
            settings.isEnabled = on
        }
    }

    func setPerformance(_ on: Bool) {
        locked {
            flushMetrics()
            metrics = nil
            settings.performance = on
        }
    }

    // MARK: Logging

    func log(_ code: DiagnosticCode, error: (any Error)?) {
        write(code, operation: nil, operationId: nil, durationMs: nil, error: error)
    }

    private func write(_ code: DiagnosticCode, operation: DiagnosticOperation?, operationId: String?, durationMs: Int?, error: (any Error)?) {
        locked {
            guard settings.isEnabled, code.level >= settings.profile.minimumLevel else { return }
            let safe = error.map(DiagnosticPrivacyFilter.safeError)
            store.append(LogEvent(code: code, timestamp: Date(), appVersion: appVersion, buildNumber: buildNumber, operation: operation,
                                  operationId: operationId, durationMs: durationMs, errorDomain: safe?.domain, errorCode: safe?.code))
        }
    }

    // MARK: Operations

    static func newOperationId() -> String { String(format: "%08X", UInt32.random(in: 0...UInt32.max)) }

    func begin(_ operation: DiagnosticOperation) -> OperationToken? {
        locked {
            guard settings.isEnabled else { return nil }
            let token = OperationToken(operation: operation, id: Self.newOperationId(), start: .now, generation: generation)
            intervals[token.id] = signposter.beginInterval("Operation", id: signposter.makeSignpostID())
            if operation.leavesBreadcrumb { leave(.started, token) }
            return token
        }
    }

    func end(_ token: OperationToken?, error: (any Error)?) {
        guard let token else { return }
        let elapsed = ContinuousClock.now - token.start
        let ms = max(0, Int(elapsed.components.seconds) * 1_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
        locked {
            // Ending an interval twice traps, so each token counts once and a repeated end is ignored.
            guard let interval = intervals.removeValue(forKey: token.id) else { return }
            signposter.endInterval("Operation", interval)
            guard settings.isEnabled, token.generation == generation else { return }
            let op = token.operation
            let cancelled = error.map(Self.isExpected) ?? false
            let failed = error != nil && !cancelled
            if op.leavesBreadcrumb { leave(failed ? .failed : .succeeded, token) }
            if failed {
                write(op.failureCode, operation: op, operationId: token.id, durationMs: ms, error: error)
            } else if settings.performance, !cancelled {
                write(ms >= op.slowMilliseconds ? .operationSlow : .operationCompleted, operation: op, operationId: token.id, durationMs: ms, error: nil)
            }
            if settings.performance, !cancelled { record(op, ms: ms, failed: failed) }
        }
    }

    /// Everyday situations, not faults: the user cancelled, a PDF needs its password, a photo has no text.
    static func isExpected(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        switch error {
        case DocumentReadError.passwordRequired, DocumentReadError.wrongPassword, ReceiptOCRError.noTextFound: return true
        default: return false
        }
    }

    private func leave(_ phase: Breadcrumb.Phase, _ token: OperationToken) {
        store.append(Breadcrumb(timestamp: Date(), operation: token.operation, operationId: token.id, phase: phase))
    }

    // MARK: Performance

    private func record(_ op: DiagnosticOperation, ms: Int, failed: Bool) {
        var all = metrics ?? store.metrics()
        all[op, default: OperationMetrics()].add(ms: ms, failed: failed, slow: ms >= op.slowMilliseconds, at: Date())
        metrics = all
        // At most one write every five seconds; the rest is flushed when the app leaves the screen.
        if ContinuousClock.now - lastMetricsSave > .seconds(5) { flushMetrics() }
    }

    func flushMetrics() {
        locked {
            guard let m = metrics, settings.isEnabled, settings.performance else { return }
            store.save(m)
            lastMetricsSave = .now
        }
    }

    func performance() -> [DiagnosticOperation: OperationMetrics] {
        flushMetrics()
        return store.metrics()
    }

    // MARK: Crash diagnostics

    /// Stores reports only if the collection session that asked for them is still running.
    func storeCrashes(_ records: [CrashRecord], generation expected: Int) {
        locked {
            guard settings.isEnabled, expected == generation else { return }
            let saved = records.filter { r in
                (r.kind == .dailyMetrics ? settings.performance : settings.crashReports) && store.append(r)
            }
            if !saved.isEmpty { log(.crashReportReceived) }
        }
    }

    func clearAll() {
        locked {
            metrics = nil
            generation += 1   // operations still running don't write into the cleared store
            store.clear()
        }
    }
}
