import Foundation

/// The result of reading one imported file. Nothing in it is saved to the database.
struct ImportedDocument: Identifiable, Sendable {
    enum Content: Sendable {
        /// A PDF or text statement (or other financial document) read into lines.
        case statement(StatementPreview)
        /// A CSV file; it goes through column mapping.
        case csv(CSVTable)
        /// A photo or screenshot; it goes through the receipt scanner.
        case image(Data)
        /// Unsupported or unreadable, with the reason shown to the user.
        case failed(String)
        /// A protected PDF waiting for its password. The bytes stay in memory only.
        case needsPassword(Data)
    }

    let id = UUID()
    var filename: String
    var format: DocumentFormat
    var byteCount: Int
    /// SHA-256 of the file, used to recognise the same document imported twice.
    var fingerprint: String
    var content: Content
}

/// A statement read from a PDF or text file, ready for the user to check and correct.
struct StatementPreview: Equatable, Sendable {
    var classification: DocumentClassification
    /// What the user says the document is (starts as the suggestion).
    var kind: FinancialDocumentKind
    var header: StatementHeader
    var parse: StatementParseResult
    var pageCount: Int
    var usedOCR: Bool
    /// Lines of text, for the "View text" screen.
    var text: DocumentText
}

/// Turns an imported file into an `ImportedDocument`. Runs fully on the device.
struct StatementImportService: Sendable {
    var recognizer: any ReceiptTextRecognizing
    var logger: any AppLogger = DiagnosticsService.shared

    func read(filename: String, data: Data, password: String? = nil, defaultCurrency: String, calendar: Calendar = .current,
              now: Date = .now, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ImportedDocument {
        let format = DocumentFormatDetector.detect(filename: filename, data: data)
        func doc(_ content: ImportedDocument.Content) -> ImportedDocument {
            ImportedDocument(filename: filename, format: format, byteCount: data.count,
                             fingerprint: DocumentFingerprint.sha256(data), content: content)
        }
        guard data.count <= DocumentLimits.maximumFileBytes else { return doc(.failed(DocumentReadError.tooLarge.localizedDescription)) }
        guard format.isSupported else { logger.log(.documentUnsupported); return doc(.failed(DocumentReadError.unsupportedFormat(format).localizedDescription)) }

        switch format {
        case .image:
            return doc(.image(data))
        case .csv:
            do { return doc(.csv(try logger.measure(.csvParse) { try CSVParser.parse(try CSVParser.decode(data)) })) }
            catch { return doc(.failed(error.localizedDescription)) }
        case .pdf, .text:
            let reader: any DocumentReading = format == .pdf ? PDFStatementReader(recognizer: recognizer) : PlainTextDocumentReader()
            let token = logger.begin(.documentRead)
            do {
                let text = try await reader.read(data, password: password, progress: progress)
                logger.end(token)
                return doc(.statement(Self.preview(text: text, format: format, defaultCurrency: defaultCurrency, calendar: calendar, now: now)))
            } catch DocumentReadError.passwordRequired {
                logger.end(token)
                return doc(.needsPassword(data))
            } catch {
                logger.end(token, error: error)
                return doc(.failed(error.localizedDescription))
            }
        case .xlsx, .ofx, .qfx, .unknown:
            return doc(.failed(DocumentReadError.unsupportedFormat(format).localizedDescription))
        }
    }

    /// Classification, header and transaction lines from extracted text. Pure and deterministic.
    static func preview(text: DocumentText, format: DocumentFormat, defaultCurrency: String, calendar: Calendar,
                        now: Date = .now) -> StatementPreview {
        let token = DiagnosticsService.shared.begin(.statementParse)
        defer { DiagnosticsService.shared.end(token) }
        let lines = text.allLines
        let classification = DocumentClassifier.classify(lines: lines, format: format)
        let header = StatementHeaderExtractor.extract(lines: lines, kind: classification.kind, defaultCurrency: defaultCurrency, calendar: calendar)
        let parse = StatementLineParser.parse(text: text, kind: classification.kind, header: header, calendar: calendar, referenceDate: now)
        return StatementPreview(classification: classification, kind: classification.kind, header: header, parse: parse,
                                pageCount: text.pages.count, usedOCR: text.usedOCR, text: text)
    }

    /// Re-reads the lines after the user changes the document type, period or currency, keeping
    /// lines the user corrected by hand.
    static func reparse(_ preview: StatementPreview, calendar: Calendar, now: Date = .now) -> StatementPreview {
        var p = preview
        let edited = preview.parse.lines.filter(\.isEdited)
        let fresh = StatementLineParser.parse(text: preview.text, kind: preview.kind, header: preview.header, calendar: calendar, referenceDate: now)
        let editedPositions = Set(edited.map { "\($0.page):\($0.line)" })
        p.parse = StatementParseResult(
            lines: (fresh.lines.filter { !editedPositions.contains("\($0.page):\($0.line)") } + edited)
                .sorted { ($0.page, $0.line) < ($1.page, $1.line) },
            issues: fresh.issues.filter { !editedPositions.contains("\($0.page):\($0.line)") })
        return p
    }
}

// MARK: - Remembered CSV column mappings

/// Remembers the column setup the user confirmed for a CSV layout (identified by its header names),
/// so the next statement from the same bank maps itself. Only column positions and options are
/// stored, never file contents.
struct CSVMappingStore {
    var defaults: UserDefaults = .standard
    static let key = "csvColumnMappings.v1"

    static func signature(_ source: CSVImportSource) -> String? {
        guard source.hasHeaderRow else { return nil }
        return source.columns.map { MerchantName.normalize($0) }.joined(separator: "|")
    }

    func mapping(for source: CSVImportSource) -> CSVColumnMapping? {
        guard let sig = Self.signature(source), let all = defaults.dictionary(forKey: Self.key) as? [String: Data],
              let data = all[sig], let m = try? JSONDecoder().decode(CSVColumnMapping.self, from: data) else { return nil }
        // Ignore a saved mapping that points past the file's columns.
        let used = [m.date, m.description, m.amount, m.debit, m.credit, m.merchant, m.category, m.notes, m.type, m.refund,
                    m.countedMonth, m.balance, m.status].compactMap { $0 }
        return used.allSatisfy { $0 < source.columns.count } ? m : nil
    }

    func save(_ mapping: CSVColumnMapping, for source: CSVImportSource) {
        guard let sig = Self.signature(source), let data = try? JSONEncoder().encode(mapping) else { return }
        var all = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        all[sig] = data
        // Keep the store small.
        if all.count > 50, let drop = all.keys.sorted().first(where: { $0 != sig }) { all[drop] = nil }
        defaults.set(all, forKey: Self.key)
    }
}
