import Foundation

/// Allowlist checks applied before anything is written and again before anything is exported.
/// A value is kept only if it is in a fixed list or has a fixed technical shape.
enum DiagnosticPrivacyFilter {
    static let otherDomain = "other"
    /// Domains whose name and numeric code identify a kind of failure and nothing about the user.
    static let allowedErrorDomains: Set<String> = [
        otherDomain, "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain", "com.apple.LocalAuthentication",
        "com.apple.Vision", "SwiftData.SwiftDataError", "Swift.CancellationError", "Swift.DecodingError", "Swift.EncodingError",
        "TallySeam.DocumentReadError", "TallySeam.CSVError", "TallySeam.ReceiptOCRError", "TallySeam.RepositoryError",
        "TallySeam.BackupError", "TallySeam.BackupCryptoError", "TallySeam.InvestmentError", "TallySeam.SplitError",
        "TallySeam.SubscriptionError",
    ]

    /// Only the domain (if allowed) and the numeric code of an error. Descriptions and userInfo,
    /// which can hold file names or user text, are never read.
    static func safeError(_ error: any Error) -> (domain: String, code: Int) {
        let e = error as NSError
        return allowedErrorDomains.contains(e.domain) ? (e.domain, e.code) : (otherDomain, 0)
    }

    static func isOperationId(_ s: String) -> Bool {
        s.utf8.count == 8 && s.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }

    /// "1.3" or "58": digits and dots only, short.
    static func isVersion(_ s: String) -> Bool {
        (1...12).contains(s.utf8.count) && s.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
    }

    /// A binary (framework) name in a call stack: no paths, spaces or other text.
    static func isBinaryName(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && s.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0)
        }
    }

    static func isDuration(_ ms: Int) -> Bool { (0...86_400_000).contains(ms) }

    static func isAllowed(_ e: LogEvent) -> Bool {
        guard let code = DiagnosticCode(rawValue: e.eventCode),
              e.level == code.level, e.category == code.category, e.message == code.message,
              e.schemaVersion == LogEvent.currentSchema,
              isVersion(e.appVersion), isVersion(e.buildNumber),
              e.operationId.map(isOperationId) ?? true,
              e.durationMs.map(isDuration) ?? true,
              e.errorDomain.map(allowedErrorDomains.contains) ?? true,
              e.errorCode == nil || e.errorDomain != nil
        else { return false }
        return true
    }

    static func isAllowed(_ r: CrashRecord) -> Bool {
        isVersion(r.appVersion) && isVersion(r.buildNumber)
            && r.frames.count <= CrashRecord.maximumFrames
            && r.frames.allSatisfy { isBinaryName($0.binary) && UUID(uuidString: $0.binaryUUID) != nil && $0.offset >= 0 }
            && (r.valueMs.map { $0 >= 0 } ?? true) && (r.writtenBytes.map { $0 >= 0 } ?? true)
            && (r.exits?.keys.allSatisfy { CrashRecord.exitKinds.contains($0) } ?? true)
            && (r.exits?.values.allSatisfy { $0 >= 0 } ?? true)
    }

    static func isAllowed(_ b: Breadcrumb) -> Bool { isOperationId(b.operationId) }

    static func isAllowed(_ m: OperationMetrics) -> Bool {
        m.count >= 0 && m.success >= 0 && m.failure >= 0 && m.slow >= 0 && m.success + m.failure == m.count
            && m.totalMs >= 0 && m.minMs >= 0 && m.maxMs >= m.minMs
    }
}
