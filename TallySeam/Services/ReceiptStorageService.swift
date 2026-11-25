import Foundation

enum ReceiptStorageError: Error, Equatable, LocalizedError {
    case invalidPath
    var errorDescription: String? { "The receipt image path is invalid." }
}

/// Stores receipt images as files in the app's private Application Support directory.
/// SwiftData keeps only the relative path ("Receipts/<uuid>.jpg").
struct ReceiptStorageService: Sendable {
    static let folderName = "Receipts"
    let rootURL: URL

    init(rootURL: URL) { self.rootURL = rootURL }

    static func live() throws -> ReceiptStorageService {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ReceiptStorageService(rootURL: root)
    }

    private var folderURL: URL { rootURL.appending(path: Self.folderName, directoryHint: .isDirectory) }

    static func relativePath(for id: UUID) -> String { "\(folderName)/\(id.uuidString).jpg" }

    /// Only paths this service creates are accepted, which prevents path traversal from imported data.
    func url(forRelativePath path: String) throws -> URL {
        let pattern = #"^Receipts/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.jpg$"#
        guard path.range(of: pattern, options: .regularExpression) != nil else { throw ReceiptStorageError.invalidPath }
        return rootURL.appending(path: path)
    }

    /// Writes atomically with complete file protection (encrypted while the device is locked).
    @discardableResult
    func save(jpegData: Data, id: UUID) throws -> String {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let path = Self.relativePath(for: id)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        let target = try url(forRelativePath: path)
        try DiagnosticsService.shared.measure(.fileStore) { try jpegData.write(to: target, options: options) }
        return path
    }

    func loadData(relativePath: String) -> Data? {
        guard let url = try? url(forRelativePath: relativePath) else { return nil }
        return try? Data(contentsOf: url)
    }

    func fileExists(relativePath: String) -> Bool {
        guard let url = try? url(forRelativePath: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func delete(relativePath: String) throws {
        let url = try url(forRelativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Image files that no Receipt record references.
    func orphanedPaths(referenced: Set<String>) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            .map { "\(Self.folderName)/\($0)" }
            .filter { (try? url(forRelativePath: $0)) != nil && !referenced.contains($0) }
            .sorted()
    }

    /// Removes image files left behind by an interrupted save. Never touches referenced files.
    @discardableResult
    func removeOrphans(referenced: Set<String>) throws -> Int {
        let orphans = try orphanedPaths(referenced: referenced)
        for path in orphans { try delete(relativePath: path) }
        return orphans.count
    }
}
