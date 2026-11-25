import Foundation

/// What the app was doing: written before and after important operations, so the last entries
/// survive a crash.
struct Breadcrumb: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable { case started, succeeded, failed }
    var timestamp: Date
    var operation: DiagnosticOperation
    var operationId: String
    var phase: Phase
}

struct LogQuery: Sendable, Equatable {
    var text = ""
    var level: LogLevel?
    var category: LogCategory?
    var since: Date?
    var until: Date?
    var newestFirst = true

    func matches(_ e: LogEvent) -> Bool {
        if let level, e.level != level { return false }
        if let category, e.category != category { return false }
        if let since, e.timestamp < since { return false }
        if let until, e.timestamp > until { return false }
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || e.message.localizedCaseInsensitiveContains(t) || e.eventCode.localizedCaseInsensitiveContains(t)
    }
}

/// Where a page stopped: a file and the number of its records already examined.
struct LogCursor: Sendable, Equatable { var file: Int; var record: Int }

struct LogPage: Sendable { var events: [LogEvent]; var next: LogCursor? }

/// JSON Lines files in Application Support/Diagnostics, apart from all financial data. Protected by
/// iOS Data Protection and excluded from device backups. Every failure is swallowed: diagnostics
/// must never disturb the app. All access goes through one lock.
final class LocalLogStore: @unchecked Sendable {
    struct Limits: Sendable {
        var totalBytes = 5 * 1024 * 1024
        var segmentBytes = 256 * 1024
        var maximumAge: TimeInterval = 7 * 24 * 3600
        var minimumFreeBytes: Int64 = 20 * 1024 * 1024
        var breadcrumbBytes = 16 * 1024
        var crashRecords = 50
    }

    let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    private let freeBytes: @Sendable () -> Int64?
    private let lock = NSRecursiveLock()
    private var lastPrune = Date.distantPast

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    init(directory: URL = LocalLogStore.defaultDirectory, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() },
         freeBytes: (@Sendable () -> Int64?)? = nil) {
        self.directory = directory; self.limits = limits; self.now = now
        self.freeBytes = freeBytes ?? {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map { Int64($0) }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: Writing

    @discardableResult
    func append(_ event: LogEvent) -> Bool {
        guard DiagnosticPrivacyFilter.isAllowed(event), let line = try? DiagnosticJSON.encoder().encode(event) else { return false }
        return locked {
            guard prepare(adding: line.count) else { return false }
            return appendLine(line, to: currentSegment(adding: line.count))
        }
    }

    @discardableResult
    func append(_ crumb: Breadcrumb) -> Bool {
        guard DiagnosticPrivacyFilter.isAllowed(crumb), let line = try? DiagnosticJSON.encoder().encode(crumb) else { return false }
        return locked {
            guard prepare(adding: line.count) else { return false }
            let url = directory.appending(path: "breadcrumbs.jsonl")
            if size(of: url) > limits.breadcrumbBytes {
                write(lines(in: url).suffix(40).map { Data($0) }, to: url)
            }
            return appendLine(line, to: url)
        }
    }

    @discardableResult
    func append(_ record: CrashRecord) -> Bool {
        guard DiagnosticPrivacyFilter.isAllowed(record), let line = try? DiagnosticJSON.encoder().encode(record) else { return false }
        return locked {
            guard prepare(adding: line.count) else { return false }
            let url = directory.appending(path: "crashes.jsonl")
            let ok = appendLine(line, to: url)
            let all = lines(in: url)
            if all.count > limits.crashRecords { write(all.suffix(limits.crashRecords).map { Data($0) }, to: url) }
            return ok
        }
    }

    @discardableResult
    func save(_ metrics: [DiagnosticOperation: OperationMetrics]) -> Bool {
        let safe = metrics.filter { DiagnosticPrivacyFilter.isAllowed($0.value) }
        let byName = Dictionary(uniqueKeysWithValues: safe.map { ($0.key.rawValue, $0.value) })
        guard let data = try? DiagnosticJSON.encoder().encode(byName) else { return false }
        return locked {
            guard prepare(adding: data.count) else { return false }
            return (try? data.write(to: directory.appending(path: "performance.json"), options: writeOptions)) != nil
        }
    }

    // MARK: Reading

    /// One page of matching events, reading one file at a time.
    func page(_ query: LogQuery, after cursor: LogCursor? = nil, limit: Int = 100) -> LogPage {
        locked {
            pruneExpired()
            let files = query.newestFirst ? Array(segments().reversed()) : segments()
            var events: [LogEvent] = []
            var position = cursor ?? LogCursor(file: 0, record: 0)
            while position.file < files.count {
                var records = lines(in: files[position.file])
                if query.newestFirst { records.reverse() }
                while position.record < records.count {
                    if let e = decodeEvent(records[position.record]), query.matches(e) { events.append(e) }
                    position.record += 1
                    if events.count >= limit { return LogPage(events: events, next: position) }
                }
                position = LogCursor(file: position.file + 1, record: 0)
            }
            return LogPage(events: events, next: nil)
        }
    }

    func allEvents() -> [LogEvent] {
        locked { pruneExpired(); return segments().flatMap { lines(in: $0).compactMap(decodeEvent) } }
    }

    func crashes() -> [CrashRecord] {
        locked {
            pruneExpired()
            return decodeLines("crashes.jsonl", CrashRecord.self).filter(DiagnosticPrivacyFilter.isAllowed)
        }
    }

    func breadcrumbs() -> [Breadcrumb] {
        locked {
            pruneExpired()
            return decodeLines("breadcrumbs.jsonl", Breadcrumb.self).filter(DiagnosticPrivacyFilter.isAllowed)
        }
    }

    func metrics() -> [DiagnosticOperation: OperationMetrics] {
        locked {
            guard let data = try? Data(contentsOf: directory.appending(path: "performance.json")),
                  let byName = try? DiagnosticJSON.decoder().decode([String: OperationMetrics].self, from: data) else { return [:] }
            var out: [DiagnosticOperation: OperationMetrics] = [:]
            let cutoff = now().addingTimeInterval(-limits.maximumAge)
            for (name, m) in byName {
                if let op = DiagnosticOperation(rawValue: name), m.lastRun >= cutoff, DiagnosticPrivacyFilter.isAllowed(m) { out[op] = m }
            }
            return out
        }
    }

    func usedBytes() -> Int { locked { files().reduce(0) { $0 + size(of: $1) } } }

    func lastEventDate() -> Date? { page(LogQuery(), limit: 1).events.first?.timestamp }

    func clear() {
        locked { for f in files() { try? FileManager.default.removeItem(at: f) } }
    }

    // MARK: Retention

    /// Drops everything older than the maximum age, then the oldest logs until the total fits.
    func enforceLimits(reserving extra: Int = 0) {
        locked {
            lastPrune = .distantPast
            pruneExpired()
            trim(reserving: extra)
        }
    }

    private func trim(reserving extra: Int) {
        var total = usedBytes() + extra
        for s in segments() where total > limits.totalBytes {
            total -= size(of: s)
            try? FileManager.default.removeItem(at: s)
        }
        for name in ["breadcrumbs.jsonl", "crashes.jsonl", "performance.json"] where total > limits.totalBytes {
            let url = directory.appending(path: name)
            total -= size(of: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Runs at most once a minute.
    private func pruneExpired() {
        let t = now()
        guard abs(t.timeIntervalSince(lastPrune)) >= 60 else { return }
        lastPrune = t
        let cutoff = t.addingTimeInterval(-limits.maximumAge)
        for s in segments() {
            let records = lines(in: s)
            // Records are in time order, so a file whose first one is recent has nothing to drop.
            if let first = records.first, let e = decodeEvent(first), e.timestamp >= cutoff { continue }
            let kept = records.filter { (decodeEvent($0)?.timestamp ?? .distantPast) >= cutoff }
            replace(s, records: records, kept: kept)
        }
        let c = directory.appending(path: "crashes.jsonl")
        let crashLines = lines(in: c)
        replace(c, records: crashLines, kept: crashLines.filter {
            ((try? DiagnosticJSON.decoder().decode(CrashRecord.self, from: Data($0)))?.receivedAt ?? .distantPast) >= cutoff
        })
        let b = directory.appending(path: "breadcrumbs.jsonl")
        let crumbLines = lines(in: b)
        replace(b, records: crumbLines, kept: crumbLines.filter {
            ((try? DiagnosticJSON.decoder().decode(Breadcrumb.self, from: Data($0)))?.timestamp ?? .distantPast) >= cutoff
        })
        let p = directory.appending(path: "performance.json")
        if let data = try? Data(contentsOf: p) {
            let byName = (try? DiagnosticJSON.decoder().decode([String: OperationMetrics].self, from: data)) ?? [:]
            let kept = byName.filter { $0.value.lastRun >= cutoff }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: p)
            } else if kept.count != byName.count, let out = try? DiagnosticJSON.encoder().encode(kept) {
                try? out.write(to: p, options: writeOptions)
            }
        }
    }

    private func replace(_ url: URL, records: [Data.SubSequence], kept: [Data.SubSequence]) {
        guard kept.count != records.count else { return }
        if kept.isEmpty { try? FileManager.default.removeItem(at: url) } else { write(kept.map { Data($0) }, to: url) }
    }

    // MARK: Files

    private var writeOptions: Data.WritingOptions { [.atomic, .completeFileProtectionUntilFirstUserAuthentication] }

    private func prepare(adding bytes: Int) -> Bool {
        if let free = freeBytes(), free < limits.minimumFreeBytes { return false }
        var dir = directory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])) != nil
            else { return false }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        pruneExpired()
        if usedBytes() + bytes + 1 > limits.totalBytes { trim(reserving: bytes + 1) }
        return true
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Log files, oldest first. Names sort in time order: logs-00000001.jsonl, logs-00000002.jsonl…
    private func segments() -> [URL] {
        files().filter { $0.lastPathComponent.hasPrefix("logs-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func currentSegment(adding bytes: Int) -> URL {
        let last = segments().last
        if let last, size(of: last) + bytes + 1 <= limits.segmentBytes { return last }
        let number = last.flatMap { Int($0.deletingPathExtension().lastPathComponent.dropFirst(5)) } ?? 0
        return directory.appending(path: String(format: "logs-%08d.jsonl", number + 1))
    }

    private func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func lines(in url: URL) -> [Data.SubSequence] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A)
    }

    private func decodeEvent(_ line: Data.SubSequence) -> LogEvent? {
        guard let e = try? DiagnosticJSON.decoder().decode(LogEvent.self, from: Data(line)),
              DiagnosticPrivacyFilter.isAllowed(e) else { return nil }
        return e
    }

    private func decodeLines<T: Decodable>(_ name: String, _ type: T.Type) -> [T] {
        lines(in: directory.appending(path: name)).compactMap { try? DiagnosticJSON.decoder().decode(T.self, from: Data($0)) }
    }

    private func write(_ records: [Data], to url: URL) {
        var out = Data()
        for r in records { out.append(r); out.append(0x0A) }
        try? out.write(to: url, options: writeOptions)
    }

    /// Appends one line. A partly written last line (after a crash) is closed first, so it spoils
    /// only itself.
    private func appendLine(_ line: Data, to url: URL) -> Bool {
        var out = line
        out.append(0x0A)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (try? out.write(to: url, options: writeOptions)) != nil
        }
        do {
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            let end = try h.seekToEnd()
            if end > 0 {
                try h.seek(toOffset: end - 1)
                if try h.read(upToCount: 1) != Data([0x0A]) { out.insert(0x0A, at: 0) }
                try h.seekToEnd()
            }
            try h.write(contentsOf: out)
            return true
        } catch {
            return false
        }
    }
}
