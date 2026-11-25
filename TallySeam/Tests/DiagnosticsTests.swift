import Foundation
import SwiftData
import XCTest
@testable import TallySeam

/// Privacy-first diagnostics. All "personal" values here are made up.
final class DiagnosticsTests: XCTestCase {
    private var folder: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    private final class Clock: @unchecked Sendable { var date = Date() }

    /// Error whose description and userInfo are full of data that must never be logged.
    private struct LeakyError: LocalizedError {
        var errorDescription: String? { "Chase account 4111111111111111 jane.doe@example.com paid CORNER BAKERY $5,420.17" }
    }
    private let forbidden = ["Chase", "4111", "jane", "example.com", "BAKERY", "5,420", "statement-jane", "/Users/", "Jane"]

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appending(path: "DiagTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        suite = "DiagTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store(_ limits: LocalLogStore.Limits = .init(), clock: Clock = Clock(), free: Int64? = nil) -> LocalLogStore {
        LocalLogStore(directory: folder, limits: limits, now: { clock.date }, freeBytes: { free })
    }

    private func service(_ s: LocalLogStore? = nil, enabled: Bool = true) -> DiagnosticsService {
        let d = DiagnosticsService(settings: DiagnosticsSettings(defaults: defaults), store: s ?? store())
        if enabled { d.setEnabled(true) }
        return d
    }

    private func event(_ code: DiagnosticCode = .testInfo, at date: Date = Date()) -> LogEvent {
        LogEvent(code: code, timestamp: date, appVersion: "1.3", buildNumber: "60")
    }

    private func allText() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    private func codes(_ d: DiagnosticsService) -> [String] { d.store.allEvents().map(\.eventCode) }

    // MARK: On and off

    func testOffByDefaultForNewAndExistingUsers() {
        defaults.set(true, forKey: "assist.useOnDeviceModel")   // an existing user's other choices
        let d = service(enabled: false)
        XCTAssertFalse(d.isEnabled)
        XCTAssertEqual(d.settings.profile, .standard)
        XCTAssertFalse(d.settings.performance)
        XCTAssertFalse(d.settings.crashReports)
    }

    func testNothingIsWrittenWhileOff() {
        let d = service(enabled: false)
        d.settings.performance = true
        d.settings.crashReports = true
        d.log(.startupFailed, error: LeakyError())
        XCTAssertNil(d.begin(.databaseSave))
        _ = try? d.measure(.databaseSave) { throw LeakyError() }
        d.storeCrashes([crash()], generation: d.currentGeneration)
        d.flushMetrics()
        XCTAssertEqual(d.store.usedBytes(), 0)
        XCTAssertFalse(d.collectsCrashes)
        XCTAssertFalse(d.collectsPerformance)
    }

    func testTurningOffStopsRunningOperationsAndLateCallbacks() {
        let d = service()
        d.settings.performance = true
        d.settings.crashReports = true
        let token = d.begin(.receiptOCR)
        let generation = d.currentGeneration
        d.setEnabled(false)
        let before = d.store.usedBytes()
        d.end(token, error: LeakyError())
        d.storeCrashes([crash()], generation: generation)
        XCTAssertEqual(d.store.usedBytes(), before)
        // Turning it on again does not revive what belonged to the old session.
        d.setEnabled(true)
        d.end(token, error: LeakyError())
        d.storeCrashes([crash()], generation: generation)
        XCTAssertFalse(codes(d).contains("OCR_500"))
        XCTAssertTrue(d.store.crashes().isEmpty)
    }

    func testReportsStayReadableAfterTurningOff() {
        let d = service()
        d.log(.testError)
        d.setEnabled(false)
        XCTAssertTrue(codes(d).contains("TEST_500"))
        d.clearAll()
        XCTAssertEqual(d.store.usedBytes(), 0)
    }

    func testLevels() {
        let d = service()
        d.settings.profile = .errorsOnly
        d.log(.testInfo); d.log(.testWarning); d.log(.testError)
        d.settings.profile = .standard
        d.log(.testInfo); d.log(.operationCompleted)
        d.settings.profile = .verbose
        d.log(.operationCompleted)
        XCTAssertEqual(codes(d), ["DIAG_001", "TEST_500", "TEST_001", "PERF_001"])
    }

    func testSubscriptionFollowsSettings() {
        let d = service()
        let c = CrashDiagnosticsService(diagnostics: d)
        c.refresh()
        XCTAssertFalse(c.isSubscribed)
        d.settings.crashReports = true
        c.refresh()
        XCTAssertTrue(c.isSubscribed)
        d.setEnabled(false)
        c.refresh()
        XCTAssertFalse(c.isSubscribed)
    }

    func testNoOpLogger() {
        let n: any AppLogger = NoOpLogger()
        n.log(.testError)
        XCTAssertNil(n.begin(.startup))
        XCTAssertEqual(n.measure(.startup) { 7 }, 7)
    }

    // MARK: Privacy

    func testErrorsAreReducedToAllowedDomainAndCode() {
        let d = service()
        d.settings.profile = .verbose
        d.settings.performance = true
        _ = try? d.measure(.documentRead) { throw LeakyError() }
        d.log(.backupFailed, error: NSError(domain: "Jane's Chase account", code: 4111, userInfo: [NSLocalizedDescriptionKey: "statement-jane.pdf"]))
        d.log(.databaseSaveFailed, error: NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSFilePathErrorKey: "/Users/Jane/statement-jane.pdf"]))
        let text = allText()
        for f in forbidden { XCTAssertFalse(text.contains(f), f) }
        let saved = d.store.allEvents()
        XCTAssertEqual(saved.first { $0.eventCode == "BACKUP_500" }?.errorDomain, "other")
        XCTAssertEqual(saved.first { $0.eventCode == "BACKUP_500" }?.errorCode, 0)
        XCTAssertEqual(saved.first { $0.eventCode == "DB_501" }?.errorDomain, NSCocoaErrorDomain)
        XCTAssertEqual(saved.first { $0.eventCode == "DB_501" }?.errorCode, 512)
    }

    func testOnlyCatalogEventsAreAllowed() {
        XCTAssertTrue(DiagnosticPrivacyFilter.isAllowed(event()))
        func rejected(_ change: (inout LogEvent) -> Void) {
            var e = event(); change(&e)
            XCTAssertFalse(DiagnosticPrivacyFilter.isAllowed(e))
            XCTAssertFalse(store().append(e))
        }
        rejected { $0.message = "Paid CORNER BAKERY $5,420.17" }
        rejected { $0.eventCode = "JANE_001" }
        rejected { $0.appVersion = "jane" }
        rejected { $0.operationId = UUID().uuidString }
        rejected { $0.errorDomain = "Chase" }
        rejected { $0.errorCode = 4111 }
        rejected { $0.durationMs = -1 }
        rejected { $0.level = .trace }
        XCTAssertEqual(store().usedBytes(), 0)
    }

    func testOperationIdsAreShortRandomAndNew() {
        let ids = (0..<200).map { _ in DiagnosticsService.newOperationId() }
        XCTAssertTrue(ids.allSatisfy(DiagnosticPrivacyFilter.isOperationId))
        XCTAssertGreaterThan(Set(ids).count, 190)
    }

    func testCallStackIsReducedToApprovedFields() {
        let json = """
        {"callStackPerThread":true,"callStacks":[{"threadAttributed":false,"callStackRootFrames":[]},
        {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"TallySeam","binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743",
        "offsetIntoBinaryTextSegment":123,"address":999,"note":"Jane 4111","subFrames":[{"binaryName":"/Users/Jane/x","binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743",
        "offsetIntoBinaryTextSegment":5,"subFrames":[{"binaryName":"UIKitCore","binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743","offsetIntoBinaryTextSegment":7}]}]}]}]}
        """
        let frames = CrashSanitizer.frames(fromCallStackTree: Data(json.utf8))
        XCTAssertEqual(frames.map(\.binary), ["TallySeam", "UIKitCore"])
        XCTAssertEqual(frames.map(\.offset), [123, 7])
        XCTAssertTrue(CrashSanitizer.frames(fromCallStackTree: Data("not json".utf8)).isEmpty)
        XCTAssertEqual(CrashSanitizer.version("Jane 1.3"), "0")
        XCTAssertNil(CrashSanitizer.whole(.nan))
    }

    private func crash() -> CrashRecord {
        CrashRecord(receivedAt: Date(), kind: .crash, isSynthetic: true, appVersion: "1.3", buildNumber: "60", signal: 6,
                    frames: [.init(binary: "TallySeam", binaryUUID: UUID().uuidString, offset: 10)])
    }

    func testCrashReportsNeedTheirOwnSetting() {
        let d = service()
        d.storeCrashes([crash()], generation: d.currentGeneration)
        XCTAssertTrue(d.store.crashes().isEmpty)
        d.settings.crashReports = true
        var bad = crash()
        bad.frames[0].binary = "/Users/Jane/4111"
        var daily = crash()
        daily.kind = .dailyMetrics
        d.storeCrashes([crash(), bad, daily], generation: d.currentGeneration)
        XCTAssertEqual(d.store.crashes().map(\.kind), [.crash])
        XCTAssertTrue(codes(d).contains("CRASH_001"))
    }

    // MARK: Operations

    func testBreadcrumbsAreOnDiskBeforeAFailure() {
        let d = service()
        _ = d.begin(.backupRestore)   // never ends, as in a crash
        let after = store().breadcrumbs()   // a new launch
        XCTAssertEqual(after.map(\.operation), [.backupRestore])
        XCTAssertEqual(after.map(\.phase), [.started])
    }

    func testPerformanceAggregates() {
        var m = OperationMetrics()
        m.add(ms: 10, failed: false, slow: false, at: .now)
        m.add(ms: 40, failed: true, slow: true, at: .now)
        XCTAssertEqual([m.count, m.success, m.failure, m.slow, m.minMs, m.maxMs, m.averageMs], [2, 1, 1, 1, 10, 40, 25])

        let d = service()
        d.measure(.reconciliation) {}
        XCTAssertTrue(d.performance().isEmpty, "needs its own setting")
        d.setPerformance(true)
        d.measure(.reconciliation) {}
        _ = try? d.measure(.reconciliation) { throw LeakyError() }
        XCTAssertEqual(d.performance()[.reconciliation]?.count, 2)
        XCTAssertEqual(d.performance()[.reconciliation]?.failure, 1)
        XCTAssertEqual(store().metrics()[.reconciliation]?.count, 2)
    }

    func testEndingAnOperationTwiceIsIgnored() {
        let d = service()
        d.setPerformance(true)
        let token = d.begin(.backupCreate)
        d.end(token)
        d.end(token, error: LeakyError())
        XCTAssertEqual(d.performance()[.backupCreate]?.count, 1)
        XCTAssertFalse(codes(d).contains("BACKUP_500"))
    }

    func testStartupFailureIsLoggedWithoutTheDatabase() {
        let d = service()
        d.end(d.begin(.startup), error: LeakyError())
        let e = d.store.allEvents().last
        XCTAssertEqual(e?.eventCode, "APP_500")
        XCTAssertEqual(e?.level, .critical)
        XCTAssertFalse(allText().contains("Chase"))
    }

    // MARK: Storage

    func testConcurrentWritesKeepEveryRecord() {
        let s = store()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in s.append(LogEvent(code: .testInfo, timestamp: Date(), appVersion: "1", buildNumber: "1")) }
        XCTAssertEqual(s.allEvents().count, 200)
    }

    func testWritingAndReadingStaysLight() {
        let s = store()
        let began = ContinuousClock.now
        for _ in 0..<300 { s.append(event()) }
        XCTAssertEqual(s.allEvents().count, 300)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
    }

    func testRotationAndTotalLimit() {
        var limits = LocalLogStore.Limits()
        limits.totalBytes = 8_000
        limits.segmentBytes = 2_000
        let s = store(limits)
        for _ in 0..<100 { s.append(event()) }
        s.append(event(.testError))
        XCTAssertLessThanOrEqual(s.usedBytes(), 8_000)
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        XCTAssertEqual(s.allEvents().last?.eventCode, "TEST_500", "the newest record is kept")
        XCTAssertEqual(LocalLogStore.Limits().totalBytes, 5_242_880)
    }

    func testSevenDayRetention() {
        let clock = Clock()
        let s = store(clock: clock)
        let start = clock.date
        s.append(event(.testInfo, at: start))
        s.append(event(.testError, at: start.addingTimeInterval(6 * 86_400)))
        s.append(crash())
        clock.date = start.addingTimeInterval(7 * 86_400 + 120)
        s.enforceLimits()
        XCTAssertEqual(s.allEvents().map(\.eventCode), ["TEST_500"])
        XCTAssertTrue(s.crashes().isEmpty)
        XCTAssertEqual(LocalLogStore.Limits().maximumAge, 604_800)
    }

    func testLowDiskSpaceIsHandled() {
        let s = store(free: 1_000)
        XCTAssertFalse(s.append(event()))
        let d = service(s)
        d.log(.testError)
        XCTAssertEqual(s.usedBytes(), 0)
    }

    func testUnwritableFolderDoesNotCrash() throws {
        try Data("file".utf8).write(to: folder)   // a file where the folder should be
        XCTAssertFalse(store().append(event()))
        XCTAssertTrue(store().allEvents().isEmpty)
    }

    func testCorruptAndPartialRecordsAreSkipped() throws {
        let s = store()
        s.append(event())
        let log = folder.appending(path: "logs-00000001.jsonl")
        let h = try FileHandle(forWritingTo: log)
        try h.seekToEnd()
        try h.write(contentsOf: Data("garbage\n{\"level\":\"ERR".utf8))   // cut off mid-record
        try h.close()
        s.append(event(.testError))
        XCTAssertEqual(s.allEvents().map(\.eventCode), ["TEST_001", "TEST_500"])
    }

    func testTamperedRecordIsNeverShownOrExported() throws {
        let s = store()
        s.append(event())
        let log = folder.appending(path: "logs-00000001.jsonl")
        let text = try String(contentsOf: log, encoding: .utf8)
        try text.replacingOccurrences(of: DiagnosticCode.testInfo.message, with: "Jane 4111").write(to: log, atomically: true, encoding: .utf8)
        XCTAssertTrue(s.allEvents().isEmpty)
    }

    func testPagingAndFilters() {
        var limits = LocalLogStore.Limits()
        limits.segmentBytes = 1_000
        let s = store(limits)
        // Whole seconds, as stored times have no fraction.
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 1_000).rounded(.down))
        for i in 0..<25 { s.append(event(i % 5 == 0 ? .testError : .testInfo, at: start.addingTimeInterval(Double(i)))) }
        var seen: [LogEvent] = []
        var cursor: LogCursor?
        repeat {
            let p = s.page(LogQuery(), after: cursor, limit: 10)
            seen += p.events
            cursor = p.next
        } while cursor != nil
        XCTAssertEqual(seen.count, 25)
        XCTAssertEqual(seen.map(\.timestamp), seen.map(\.timestamp).sorted(by: >))
        XCTAssertEqual(s.page(LogQuery(level: .error)).events.count, 5)
        XCTAssertEqual(s.page(LogQuery(text: "test_500")).events.count, 5)
        XCTAssertEqual(s.page(LogQuery(category: .backup)).events.count, 0)
        XCTAssertEqual(s.page(LogQuery(since: start.addingTimeInterval(20.5))).events.count, 4)
        let oldest = s.page(LogQuery(newestFirst: false), limit: 25).events.map(\.timestamp)
        XCTAssertEqual(oldest, oldest.sorted())
    }

    func testFolderIsExcludedFromDeviceBackups() throws {
        let s = store()
        s.append(event())
        XCTAssertEqual(try URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    // MARK: Export

    @MainActor
    func testExportContainsOnlyApprovedContent() throws {
        let d = service()
        d.settings.crashReports = true
        d.setPerformance(true)
        _ = try? d.measure(.documentRead) { throw LeakyError() }
        d.storeCrashes([crash()], generation: d.currentGeneration)
        let report = DiagnosticExportService.makeReport(d)
        let files = try DiagnosticExportService.files(report)
        XCTAssertEqual(files.map(\.name), ["summary.json", "application-logs.jsonl", "crash-reports.json", "performance-metrics.json",
                                           "app-information.json", "README.txt"])
        let text = files.filter { $0.name != "README.txt" }.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        for f in forbidden { XCTAssertFalse(text.contains(f), f) }

        let url = try DiagnosticExportService.writeZip(report)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("TallySeam-Diagnostics-"))
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        DiagnosticExportService.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testExportIsBlockedWhenThePrivacyCheckFails() {
        var report = DiagnosticExportService.makeReport(service())
        var e = event()
        e.message = "Jane 4111"
        report.events.append(e)
        XCTAssertThrowsError(try DiagnosticExportService.writeZip(report)) {
            XCTAssertEqual($0 as? DiagnosticExportError, .privacyCheckFailed)
        }
        var named = DiagnosticExportService.makeReport(service())
        named.app.deviceModel = "Jane's iPhone"
        XCTAssertThrowsError(try DiagnosticExportService.validate(named))
    }

    func testZipChecksum() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        let zip = ZipWriter.archive([("a.txt", Data("hi".utf8))])
        XCTAssertEqual(Array(zip.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
    }

    // MARK: Separation from financial data

    @MainActor
    func testClearingDiagnosticsAndBackupsDoNotMix() throws {
        let d = service()
        d.log(.testError)
        let p = try PersistenceService(inMemory: true)
        p.context.insert(MoneyTransaction(record: TransactionRecord(transactionDate: .now, amountMinorUnits: 999, title: "Kept", transactionType: .expense)))
        try p.context.save()
        let storage = ReceiptStorageService(rootURL: folder.appending(path: "receipts"))
        let payload = try BackupService(context: p.context, storage: storage, logger: d).makePayload()
        let text = String(decoding: try BackupService.encode(payload), as: UTF8.self)
        XCTAssertFalse(text.contains("TEST_500"))
        XCTAssertFalse(text.lowercased().contains("diagnostic"))
        d.clearAll()
        XCTAssertEqual(try p.context.fetchCount(FetchDescriptor<MoneyTransaction>()), 1)
    }
}
