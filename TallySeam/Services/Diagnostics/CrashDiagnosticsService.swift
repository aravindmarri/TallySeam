import Foundation
import MetricKit

/// Times for one operation, aggregated. Holds no financial data.
struct OperationMetrics: Codable, Hashable, Sendable {
    var count = 0
    var success = 0
    var failure = 0
    var slow = 0
    var totalMs = 0
    var minMs = 0
    var maxMs = 0
    var lastRun = Date.distantPast
    var averageMs: Int { count == 0 ? 0 : totalMs / count }

    mutating func add(ms: Int, failed: Bool, slow isSlow: Bool, at date: Date) {
        minMs = count == 0 ? ms : min(minMs, ms)
        maxMs = max(maxMs, ms)
        count += 1
        totalMs += ms
        if failed { failure += 1 } else { success += 1 }
        if isSlow { slow += 1 }
        lastRun = date
    }
}

/// A report from iOS reduced to approved technical fields.
struct CrashRecord: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case crash, hang, cpuException, diskWrites, dailyMetrics
        var displayName: String {
            switch self {
            case .crash: "Crash"
            case .hang: "Hang"
            case .cpuException: "High CPU use"
            case .diskWrites: "Heavy disk writing"
            case .dailyMetrics: "Daily app metrics"
            }
        }
    }
    struct Frame: Codable, Hashable, Sendable { var binary: String; var binaryUUID: String; var offset: Int }

    static let maximumFrames = 64
    /// Exits counted by iOS. Normal exits and system terminations are not crashes.
    static let exitKinds: Set<String> = ["abnormal", "badAccess", "illegalInstruction", "memoryLimit", "watchdog"]

    var id = UUID()
    var receivedAt: Date
    var kind: Kind
    var isSynthetic = false
    var appVersion: String
    var buildNumber: String
    var exceptionType: Int?
    var exceptionCode: Int?
    var signal: Int?
    /// Hang duration or CPU time.
    var valueMs: Int?
    var writtenBytes: Int?
    var peakMemoryBytes: Int?
    var exits: [String: Int]?
    var frames: [Frame] = []
}

/// Turns MetricKit payloads into `CrashRecord`s. Only numbers, binary names and offsets are copied;
/// termination reasons, paths, regions and device details are left behind.
enum CrashSanitizer {
    /// Frames of the crashed (attributed) thread in a MetricKit call stack tree.
    static func frames(fromCallStackTree data: Data) -> [CrashRecord.Frame] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var out: [CrashRecord.Frame] = []
        var next = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = next, out.count < CrashRecord.maximumFrames {
            if let name = f["binaryName"] as? String, DiagnosticPrivacyFilter.isBinaryName(name),
               let uuid = f["binaryUUID"] as? String, UUID(uuidString: uuid) != nil,
               let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue, offset >= 0 {
                out.append(.init(binary: name, binaryUUID: uuid, offset: offset))
            }
            next = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out
    }

    static func version(_ s: String?) -> String { s.flatMap { DiagnosticPrivacyFilter.isVersion($0) ? $0 : nil } ?? "0" }

    /// A finite, non-negative number as Int; nil for anything else.
    static func whole(_ v: Double) -> Int? { v.isFinite && v >= 0 && v < 1e15 ? Int(v) : nil }

    private static func base(_ d: MXDiagnostic, _ kind: CrashRecord.Kind, _ tree: MXCallStackTree) -> CrashRecord {
        var r = CrashRecord(receivedAt: Date(), kind: kind, appVersion: version(d.applicationVersion),
                            buildNumber: version(d.metaData.applicationBuildVersion))
        r.frames = frames(fromCallStackTree: tree.jsonRepresentation())
        return r
    }

    static func records(from payload: MXDiagnosticPayload) -> [CrashRecord] {
        var out: [CrashRecord] = []
        for d in payload.crashDiagnostics ?? [] {
            var r = base(d, .crash, d.callStackTree)
            r.exceptionType = d.exceptionType?.intValue
            r.exceptionCode = d.exceptionCode?.intValue
            r.signal = d.signal?.intValue
            out.append(r)
        }
        for d in payload.hangDiagnostics ?? [] {
            var r = base(d, .hang, d.callStackTree)
            r.valueMs = whole(d.hangDuration.converted(to: .milliseconds).value)
            out.append(r)
        }
        for d in payload.cpuExceptionDiagnostics ?? [] {
            var r = base(d, .cpuException, d.callStackTree)
            r.valueMs = whole(d.totalCPUTime.converted(to: .milliseconds).value)
            out.append(r)
        }
        for d in payload.diskWriteExceptionDiagnostics ?? [] {
            var r = base(d, .diskWrites, d.callStackTree)
            r.writtenBytes = whole(d.totalWritesCaused.converted(to: .bytes).value)
            out.append(r)
        }
        return out
    }

    static func record(from payload: MXMetricPayload, appVersion: String) -> CrashRecord {
        var r = CrashRecord(receivedAt: Date(), kind: .dailyMetrics, appVersion: version(appVersion),
                            buildNumber: version(payload.metaData?.applicationBuildVersion))
        r.valueMs = payload.cpuMetrics.flatMap { whole($0.cumulativeCPUTime.converted(to: .milliseconds).value) }
        r.peakMemoryBytes = payload.memoryMetrics.flatMap { whole($0.peakMemoryUsage.converted(to: .bytes).value) }
        if let e = payload.applicationExitMetrics {
            let f = e.foregroundExitData, b = e.backgroundExitData
            r.exits = [
                "abnormal": f.cumulativeAbnormalExitCount + b.cumulativeAbnormalExitCount,
                "badAccess": f.cumulativeBadAccessExitCount + b.cumulativeBadAccessExitCount,
                "illegalInstruction": f.cumulativeIllegalInstructionExitCount + b.cumulativeIllegalInstructionExitCount,
                "memoryLimit": f.cumulativeMemoryResourceLimitExitCount + b.cumulativeMemoryResourceLimitExitCount,
                "watchdog": f.cumulativeAppWatchdogExitCount + b.cumulativeAppWatchdogExitCount,
            ]
        }
        return r
    }
}

/// Listens to MetricKit while the user wants crash reports or performance metrics.
final class CrashDiagnosticsService: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnosticsService(diagnostics: .shared)

    private let diagnostics: DiagnosticsService
    private let lock = NSLock()
    private var subscribedGeneration: Int?

    init(diagnostics: DiagnosticsService) { self.diagnostics = diagnostics }

    var isSubscribed: Bool { lock.withLock { subscribedGeneration != nil } }

    /// Subscribes or unsubscribes to match the settings. Call at startup and after every change.
    func refresh() {
        let wanted = diagnostics.collectsCrashes || diagnostics.collectsPerformance
        let generation = diagnostics.currentGeneration
        let change: Bool? = lock.withLock {
            let was = subscribedGeneration != nil
            subscribedGeneration = wanted ? generation : nil
            return was == wanted ? nil : wanted
        }
        if change == true { MXMetricManager.shared.add(self) }
        if change == false { MXMetricManager.shared.remove(self) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let g = lock.withLock({ subscribedGeneration }) else { return }
        diagnostics.storeCrashes(payloads.flatMap(CrashSanitizer.records(from:)), generation: g)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let g = lock.withLock({ subscribedGeneration }) else { return }
        diagnostics.storeCrashes(payloads.map { CrashSanitizer.record(from: $0, appVersion: $0.latestApplicationVersion) }, generation: g)
    }
}
