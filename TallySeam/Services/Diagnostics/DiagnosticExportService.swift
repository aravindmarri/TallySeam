import Foundation
import UIKit

enum DiagnosticExportError: Error, Equatable, LocalizedError {
    case privacyCheckFailed, couldNotWrite
    var errorDescription: String? {
        switch self {
        case .privacyCheckFailed: "The report didn't pass the privacy check, so it wasn't created."
        case .couldNotWrite: "The report couldn't be written. Check the free space on this iPhone."
        }
    }
}

/// Everything that goes into a report.
struct DiagnosticReport: Sendable {
    struct AppInformation: Codable, Equatable, Sendable {
        var appVersion: String
        var buildNumber: String
        var iosVersion: String
        /// Hardware model such as "iPhone16,1"; never the name the user gave the phone.
        var deviceModel: String
        var exportedAt: Date
        var diagnosticSchema: Int
    }
    struct Summary: Codable, Equatable, Sendable {
        var events: Int
        var warnings: Int
        var errors: Int
        var crashReports: Int
        var breadcrumbs: Int
        var measuredOperations: Int
    }
    struct Crashes: Codable, Sendable {
        var reports: [CrashRecord]
        var breadcrumbs: [Breadcrumb]
    }

    var app: AppInformation
    var events: [LogEvent]
    var crashes: Crashes
    var metrics: [DiagnosticOperation: OperationMetrics]

    var summary: Summary {
        Summary(events: events.count, warnings: events.filter { $0.level == .warning }.count,
                errors: events.filter { $0.level >= .error }.count, crashReports: crashes.reports.count,
                breadcrumbs: crashes.breadcrumbs.count, measuredOperations: metrics.count)
    }
}

/// Builds and checks the report. Nothing is sent anywhere: the user shares the file, or not.
enum DiagnosticExportService {
    static let readme = """
    TallySeam diagnostic report

    summary.json              Counts of what is inside.
    app-information.json      App, iOS version and iPhone model.
    application-logs.jsonl    One technical event per line (JSON).
    crash-reports.json        Sanitized reports from iOS and recent operation breadcrumbs.
    performance-metrics.json  Aggregated operation times in milliseconds.

    Contains no names, accounts, amounts, merchants, notes, documents or receipts.
    All times are UTC. Match crash frames to symbols with the dSYM of the same build:
    see docs/DIAGNOSTICS.md in the TallySeam repository.

    """

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let name = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return isModel(name) ? name : "iPhone"
    }

    static func isModel(_ s: String) -> Bool {
        (1...24).contains(s.utf8.count) && s.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 44 || $0 == 95
        }
    }

    @MainActor
    static func makeReport(_ diagnostics: DiagnosticsService, now: Date = .now) -> DiagnosticReport {
        let v = diagnostics.currentVersion
        return DiagnosticReport(
            app: .init(appVersion: v.app, buildNumber: v.build, iosVersion: UIDevice.current.systemVersion,
                       deviceModel: deviceModel(), exportedAt: now, diagnosticSchema: LogEvent.currentSchema),
            events: diagnostics.store.allEvents(),
            crashes: .init(reports: diagnostics.store.crashes(), breadcrumbs: diagnostics.store.breadcrumbs()),
            metrics: diagnostics.performance())
    }

    /// The last check before anything leaves the app's private storage.
    static func validate(_ r: DiagnosticReport) throws {
        guard DiagnosticPrivacyFilter.isVersion(r.app.appVersion), DiagnosticPrivacyFilter.isVersion(r.app.buildNumber),
              DiagnosticPrivacyFilter.isVersion(r.app.iosVersion), isModel(r.app.deviceModel),
              r.events.allSatisfy(DiagnosticPrivacyFilter.isAllowed),
              r.crashes.reports.allSatisfy(DiagnosticPrivacyFilter.isAllowed),
              r.crashes.breadcrumbs.allSatisfy(DiagnosticPrivacyFilter.isAllowed),
              r.metrics.values.allSatisfy(DiagnosticPrivacyFilter.isAllowed)
        else { throw DiagnosticExportError.privacyCheckFailed }
    }

    static func files(_ r: DiagnosticReport) throws -> [(name: String, data: Data)] {
        try validate(r)
        let pretty = DiagnosticJSON.encoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let line = DiagnosticJSON.encoder()
        var logs = Data()
        for e in r.events { logs.append(try line.encode(e)); logs.append(0x0A) }
        let metrics = Dictionary(uniqueKeysWithValues: r.metrics.map { ($0.key.rawValue, $0.value) })
        return [
            ("summary.json", try pretty.encode(r.summary)),
            ("application-logs.jsonl", logs),
            ("crash-reports.json", try pretty.encode(r.crashes)),
            ("performance-metrics.json", try pretty.encode(metrics)),
            ("app-information.json", try pretty.encode(r.app)),
            ("README.txt", Data(readme.utf8)),
        ]
    }

    static func filename(_ date: Date) -> String {
        "TallySeam-Diagnostics-\(date.formatted(.iso8601.year().month().day())).zip"
    }

    private static var exportFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "DiagnosticExport", directoryHint: .isDirectory)
    }

    /// Writes the ZIP to a temporary folder. Call `removeTemporaryFiles` when done sharing.
    static func writeZip(_ r: DiagnosticReport) throws -> URL {
        let data = ZipWriter.archive(try files(r))
        removeTemporaryFiles()
        let url = exportFolder.appending(path: filename(r.app.exportedAt))
        do {
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            removeTemporaryFiles()
            throw DiagnosticExportError.couldNotWrite
        }
        return url
    }

    static func removeTemporaryFiles() { try? FileManager.default.removeItem(at: exportFolder) }
}

/// A minimal ZIP file: entries stored without compression, readable by Windows Explorer.
enum ZipWriter {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), directory = Data()
        func put16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func put32(_ v: UInt32, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for f in files {
            let name = Data(f.name.utf8), offset = UInt32(out.count), size = UInt32(f.data.count)
            // Shared by the local header and the directory entry: version, flags, method, time, date, crc, sizes, lengths.
            var common = Data()
            put16(20, &common); put16(0x0800, &common); put16(0, &common); put16(0, &common); put16(0x21, &common)
            put32(crc32(f.data), &common); put32(size, &common); put32(size, &common)
            put16(name.count, &common); put16(0, &common)
            put32(0x0403_4B50, &out); out.append(common); out.append(name); out.append(f.data)
            put32(0x0201_4B50, &directory); put16(20, &directory); directory.append(common)
            put16(0, &directory); put16(0, &directory); put16(0, &directory); put32(0, &directory)
            put32(offset, &directory); directory.append(name)
        }
        let start = UInt32(out.count)
        out.append(directory)
        put32(0x0605_4B50, &out); put16(0, &out); put16(0, &out)
        put16(files.count, &out); put16(files.count, &out)
        put32(UInt32(directory.count), &out); put32(start, &out); put16(0, &out)
        return out
    }
}
