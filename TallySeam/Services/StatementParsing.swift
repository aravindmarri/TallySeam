import Foundation

// MARK: - Document classification

enum FinancialDocumentKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case bankStatement, creditCardStatement, receipt, invoice, paymentConfirmation, transactionExport, unknown
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bankStatement: "Bank statement"
        case .creditCardStatement: "Credit card statement"
        case .receipt: "Receipt"
        case .invoice: "Invoice"
        case .paymentConfirmation: "Payment confirmation"
        case .transactionExport: "Transaction export"
        case .unknown: "Unknown document"
        }
    }
    var isStatement: Bool { self == .bankStatement || self == .creditCardStatement }
}

struct DocumentClassification: Equatable, Sendable {
    var kind: FinancialDocumentKind
    /// Phrases that led to the suggestion, shown to the user.
    var reasons: [String]
    /// Every kind's score, for "also possible" hints.
    var scores: [FinancialDocumentKind: Int]
}

/// Keyword-based, deterministic suggestion of what a document is. The user always confirms it.
enum DocumentClassifier {
    static let phrases: [FinancialDocumentKind: [String]] = [
        .creditCardStatement: ["minimum payment", "payment due date", "credit limit", "available credit", "new balance",
                               "previous balance", "annual percentage rate", "interest charge", "cash advance",
                               "purchases", "credit card", "card ending", "late payment"],
        .bankStatement: ["checking", "savings", "beginning balance", "ending balance", "deposits and other additions",
                         "withdrawals and other subtractions", "daily balance", "routing number", "account summary",
                         "deposits", "withdrawals", "checks paid", "overdraft"],
        .receipt: ["subtotal", "sales tax", "change due", "thank you for shopping", "qty", "cashier", "receipt",
                   "items sold", "tender"],
        .invoice: ["invoice", "bill to", "invoice number", "amount due", "terms", "net 30", "remit to", "ship to"],
        .paymentConfirmation: ["payment confirmation", "confirmation number", "payment received", "payment successful",
                               "you paid", "scheduled payment", "payment details", "transaction id"],
    ]

    static func classify(lines: [String], format: DocumentFormat) -> DocumentClassification {
        if format == .csv {
            return DocumentClassification(kind: .transactionExport, reasons: ["Spreadsheet (CSV) file"], scores: [.transactionExport: 1])
        }
        let text = " " + lines.prefix(400).map { MerchantName.normalize($0) }.joined(separator: " ") + " "
        var scores: [FinancialDocumentKind: Int] = [:]
        var reasons: [FinancialDocumentKind: [String]] = [:]
        for (kind, list) in phrases {
            for p in list where text.contains(" \(MerchantName.normalize(p)) ") {
                scores[kind, default: 0] += 1
                reasons[kind, default: []].append(p)
            }
        }
        // Many dated lines ending in an amount look like a statement's transaction list.
        let datedAmountLines = lines.filter { StatementLineParser.leadingDates($0) != nil && !MoneyText.tokens(in: $0).isEmpty }.count
        if datedAmountLines >= 3 {
            for k in [FinancialDocumentKind.bankStatement, .creditCardStatement] { scores[k, default: 0] += 1 }
            for k in [FinancialDocumentKind.bankStatement, .creditCardStatement] {
                reasons[k, default: []].append("\(datedAmountLines) dated transaction lines")
            }
        }
        // Prefer the more specific statement type on a tie; then fixed order for determinism.
        let order: [FinancialDocumentKind] = [.creditCardStatement, .bankStatement, .invoice, .paymentConfirmation, .receipt]
        let top = order.map { scores[$0] ?? 0 }.max() ?? 0
        let chosen = order.first { (scores[$0] ?? 0) == top } ?? .unknown
        guard top >= 2 else { return DocumentClassification(kind: .unknown, reasons: [], scores: scores) }
        return DocumentClassification(kind: chosen, reasons: reasons[chosen] ?? [], scores: scores)
    }
}

// MARK: - Money and dates in free text

enum MoneyText {
    /// Amounts with cents, as printed on statements: "1,234.56", "-45.00", "- $45.00", "(12.00)", "$8.10", "8.10 CR", "8.10-".
    private static let regex = try! NSRegularExpression(
        pattern: #"(?<![\w.,])\(?(?:[-−]\s?(?=\$)|[-−])?\$?[-−]?(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}\)?(?:\s?(?:CR|DR)\b|-(?![\d]))?"#,
        options: [.caseInsensitive])

    struct Token: Equatable, Sendable {
        var text: String
        var range: Range<String.Index>
        /// Signed minor units as printed (negative for "-", "( )" or "DR"; positive for "CR").
        var value: Int64
        var isCreditMarked: Bool
        var isDebitMarked: Bool
        var isNegative: Bool
    }

    static func tokens(in line: String, currencyCode: String = "USD") -> [Token] {
        let ns = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: ns).compactMap { m in
            guard let r = Range(m.range, in: line) else { return nil }
            let text = String(line[r]).trimmingCharacters(in: .whitespaces)
            guard let v = CSVAmountParser.parse(text, currencyCode: currencyCode) else { return nil }
            let upper = text.uppercased()
            return Token(text: text, range: r, value: v, isCreditMarked: upper.hasSuffix("CR"), isDebitMarked: upper.hasSuffix("DR"),
                         isNegative: v < 0 && !upper.hasSuffix("DR"))
        }
    }

    private static let fullDateRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\b\d{1,2}/\d{1,2}/(?:\d{4}|\d{2})\b"#),
        try! NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#),
        try! NSRegularExpression(pattern: #"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4}\b"#,
                                 options: [.caseInsensitive]),
    ]

    /// Dates with a year anywhere in the line, in order of appearance.
    static func fullDates(in line: String, calendar: Calendar) -> [Date] {
        let ns = NSRange(line.startIndex..., in: line)
        var found: [(Int, Date)] = []
        for (i, re) in fullDateRegexes.enumerated() {
            for m in re.matches(in: line, range: ns) {
                guard let r = Range(m.range, in: line) else { continue }
                let s = String(line[r])
                let order: CSVDateOrder = i == 1 ? .yearMonthDay : .monthDayYear
                if let d = CSVDateParser.parse(s, order: order, calendar: calendar) { found.append((m.range.location, d)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

// MARK: - Statement header

enum StatementAccountType: String, CaseIterable, Identifiable, Sendable, Codable {
    case checking, savings, creditCard, other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .creditCard: "Credit card"
        case .other: "Other"
        }
    }
}

/// Document-level facts. Every field is optional and editable; amounts are signed minor units.
struct StatementHeader: Equatable, Sendable {
    var institution: String?
    var accountType: StatementAccountType = .other
    /// Only the last four digits are ever kept.
    var lastFour: String?
    var periodStart: Date?
    var periodEnd: Date?
    var openingBalance: Int64?
    var closingBalance: Int64?
    var totalDeposits: Int64?
    var totalWithdrawals: Int64?
    var totalPaymentsAndCredits: Int64?
    var totalPurchases: Int64?
    var totalFees: Int64?
    var totalInterest: Int64?
    var paymentDueDate: Date?
    var minimumPayment: Int64?
    var currencyCode: String
}

enum StatementHeaderExtractor {
    static let institutions = [
        "JPMorgan Chase", "Wells Fargo", "Bank of America", "Capital One", "American Express", "Citibank", "U.S. Bank",
        "US Bank", "PNC", "Discover", "Ally", "TD Bank", "Truist", "Barclays", "Synchrony", "Apple Card", "Goldman Sachs",
        "USAA", "Navy Federal", "Charles Schwab", "Fidelity", "HSBC", "Santander", "Citizens", "Fifth Third", "Regions",
        "KeyBank", "Huntington", "SoFi", "Chime", "Chase", "Citi",
    ]

    private static let labels: [(WritableKeyPath<StatementHeader, Int64?>, [String])] = [
        (\.openingBalance, ["beginning balance", "opening balance", "previous balance", "balance forward", "starting balance", "prior balance"]),
        (\.closingBalance, ["ending balance", "closing balance", "new balance", "statement balance"]),
        (\.totalDeposits, ["deposits/additions", "deposits and other additions", "deposits and other credits", "total deposits", "deposits and credits"]),
        (\.totalWithdrawals, ["withdrawals/subtractions", "withdrawals and other subtractions", "withdrawals and other debits", "total withdrawals",
                              "checks and other debits", "withdrawals and debits"]),
        (\.totalPaymentsAndCredits, ["payments/credits", "payments and other credits", "payments and credits", "payments credits"]),
        (\.totalPurchases, ["purchases and adjustments", "total purchases", "new charges", "purchases"]),
        (\.totalFees, ["fees charged", "total fees", "total fees charged"]),
        (\.totalInterest, ["interest charged", "total interest", "interest charge"]),
        (\.minimumPayment, ["minimum payment due", "minimum amount due", "minimum payment"]),
    ]

    private static let lastFourRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?:ending|ends)\s*(?:in)?\s*[:#]?\s*[xX*•.\-\s]*(\d{4})\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"[xX*•]{2,}[\s\-]?(\d{4})\b"#),
        try! NSRegularExpression(pattern: #"(?:account|acct|card)\s*(?:number|no\.?|#)?\s*[:#]?\s*((?:\d[\s\-]?){4,19})"#, options: [.caseInsensitive]),
    ]

    static func extract(lines: [String], kind: FinancialDocumentKind, defaultCurrency: String, calendar: Calendar) -> StatementHeader {
        var h = StatementHeader(currencyCode: detectCurrency(lines, fallback: defaultCurrency))
        let head = Array(lines.prefix(80))

        // Institution: the earliest known name on the first lines.
        var bestLine = Int.max
        for name in institutions {
            let key = MerchantName.normalize(name)
            if let i = head.firstIndex(where: { MerchantName.containsPhrase(MerchantName.normalize($0), key) }), i < bestLine {
                bestLine = i; h.institution = name
            }
        }
        if h.institution == "US Bank" { h.institution = "U.S. Bank" }

        switch kind {
        case .creditCardStatement: h.accountType = .creditCard
        default:
            let text = head.joined(separator: " ").lowercased()
            h.accountType = text.contains("savings") && !text.contains("checking") ? .savings : (text.contains("checking") ? .checking : .other)
        }

        h.lastFour = lastFour(in: head)

        // Statement period.
        for line in head {
            let lower = line.lowercased()
            guard ["period", "through", " to ", "closing date", "billing cycle", "statement date", " - "].contains(where: lower.contains) else { continue }
            let dates = MoneyText.fullDates(in: line, calendar: calendar)
            if dates.count >= 2, dates[0] <= dates[1] {
                h.periodStart = dates[0]; h.periodEnd = dates[1]; break
            }
            if dates.count == 1, lower.contains("closing date") || lower.contains("statement date"), h.periodEnd == nil {
                h.periodEnd = dates[0]
                h.periodStart = calendar.date(byAdding: DateComponents(month: -1, day: 1), to: dates[0])
            }
        }

        // No period printed: use a statement date near the top (e.g. "November 6, 2026   Page 1 of 6").
        if h.periodEnd == nil,
           let d = head.prefix(10).lazy.compactMap({ MoneyText.fullDates(in: $0, calendar: calendar).first }).first {
            h.periodEnd = d
        }

        for line in head where line.lowercased().contains("due date") {
            if let d = MoneyText.fullDates(in: line, calendar: calendar).first { h.paymentDueDate = d; break }
        }

        // Labelled amounts: first line with the label and an amount (or an amount on the next line).
        for (key, names) in labels {
            outer: for (i, line) in lines.enumerated() {
                let lower = line.lowercased()
                guard StatementLineParser.leadingDates(line) == nil, names.contains(where: lower.contains) else { continue }
                if let t = MoneyText.tokens(in: line, currencyCode: h.currencyCode).last {
                    h[keyPath: key] = t.value; break outer
                }
                if i + 1 < lines.count, StatementLineParser.leadingDates(lines[i + 1]) == nil,
                   let t = MoneyText.tokens(in: lines[i + 1], currencyCode: h.currencyCode).first {
                    h[keyPath: key] = t.value; break outer
                }
            }
        }
        return h
    }

    /// Last four digits of a masked or full account/card number. A full number is cut to four digits.
    static func lastFour(in lines: [String]) -> String? {
        for line in lines {
            let ns = NSRange(line.startIndex..., in: line)
            for re in lastFourRegexes {
                guard let m = re.firstMatch(in: line, range: ns), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) else { continue }
                let digits = line[r].filter(\.isNumber)
                if digits.count >= 4 { return String(digits.suffix(4)) }
            }
        }
        return nil
    }

    static func detectCurrency(_ lines: [String], fallback: String) -> String {
        let text = lines.prefix(120).joined(separator: " ")
        if text.contains("€") || text.contains(" EUR") { return "EUR" }
        if text.contains("£") || text.contains(" GBP") { return "GBP" }
        if text.contains("₹") || text.contains(" INR") { return "INR" }
        if text.contains("C$") || text.contains(" CAD") { return "CAD" }
        if text.contains("A$") || text.contains(" AUD") { return "AUD" }
        if text.contains("$") || text.contains(" USD") { return "USD" }
        return fallback
    }
}

// MARK: - Transaction lines

/// Money moving into the account (deposit; card payment or refund) or out of it (withdrawal; card purchase).
enum StatementDirection: String, Sendable, Codable {
    case moneyIn, moneyOut
}

enum StatementLineKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case purchase, deposit, withdrawal, cardPayment, refund, fee, interest, transfer, cashWithdrawal, unknown

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .purchase: "Purchase"
        case .deposit: "Deposit"
        case .withdrawal: "Withdrawal"
        case .cardPayment: "Card payment"
        case .refund: "Refund or credit"
        case .fee: "Fee"
        case .interest: "Interest"
        case .transfer: "Transfer"
        case .cashWithdrawal: "Cash withdrawal"
        case .unknown: "Unclassified"
        }
    }
}

/// One transaction read from a statement. Nothing here is saved until the user approves it.
struct ParsedStatementLine: Identifiable, Equatable, Sendable {
    var id = UUID()
    var page: Int
    var line: Int
    var transactionDate: Date
    var postingDate: Date?
    var description: String
    /// Always positive; `direction` says which way the money moved.
    var amountMinorUnits: Int64
    var direction: StatementDirection
    var runningBalance: Int64?
    var kind: StatementLineKind
    var isPending: Bool
    var confidence: ParseConfidence
    /// Why confidence isn't high, if it isn't.
    var note: String?
    var isEdited = false
}

/// A line that looks like a transaction but couldn't be read. Kept for manual correction.
struct StatementParseIssue: Identifiable, Equatable, Sendable {
    var id = UUID()
    var page: Int
    var line: Int
    var text: String
    var reason: String
}

struct StatementParseResult: Equatable, Sendable {
    var lines: [ParsedStatementLine]
    var issues: [StatementParseIssue]

    var totalIn: Int64 { lines.filter { $0.direction == .moneyIn }.reduce(0) { $0 + $1.amountMinorUnits } }
    var totalOut: Int64 { lines.filter { $0.direction == .moneyOut }.reduce(0) { $0 + $1.amountMinorUnits } }
}

enum StatementLineParser {
    private static let numericDate = try! NSRegularExpression(pattern: #"^(\d{1,2})[/\-](\d{1,2})(?:[/\-](\d{4}|\d{2}))?(?![\d/])"#)
    private static let namedDate = try! NSRegularExpression(
        pattern: #"^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:,?\s+(\d{4}))?\b"#,
        options: [.caseInsensitive])
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    struct DateParts: Equatable { var month: Int; var day: Int; var year: Int? }

    /// One or two dates at the start of the line, and the text after them.
    static func leadingDates(_ raw: String) -> (first: DateParts, second: DateParts?, rest: String)? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard let first = takeDate(&s) else { return nil }
        s = s.drop { $0 == " " || $0 == "\t" }
        var copy = s
        let second = takeDate(&copy)
        if second != nil { s = copy.drop { $0 == " " || $0 == "\t" } }
        return (first, second, String(s))
    }

    private static func takeDate(_ s: inout Substring) -> DateParts? {
        let str = String(s)
        let ns = NSRange(str.startIndex..., in: str)
        if let m = numericDate.firstMatch(in: str, range: ns), let r = Range(m.range, in: str) {
            func group(_ i: Int) -> Int? { Range(m.range(at: i), in: str).flatMap { Int(str[$0]) } }
            guard let a = group(1), let b = group(2), (1...12).contains(a), (1...31).contains(b) else { return nil }
            var year = group(3)
            if let y = year, y < 100 { year = 2000 + y }
            s = s.dropFirst(str.distance(from: str.startIndex, to: r.upperBound))
            return DateParts(month: a, day: b, year: year)
        }
        if let m = namedDate.firstMatch(in: str, range: ns), let r = Range(m.range, in: str),
           let nameRange = Range(m.range(at: 1), in: str), let dayRange = Range(m.range(at: 2), in: str),
           let month = monthNames.firstIndex(of: String(str[nameRange].lowercased().prefix(3))), let day = Int(str[dayRange]) {
            let year = Range(m.range(at: 3), in: str).flatMap { Int(str[$0]) }
            s = s.dropFirst(str.distance(from: str.startIndex, to: r.upperBound))
            return DateParts(month: month + 1, day: day, year: year)
        }
        return nil
    }

    /// Resolves a date without a year against the statement period: the year that puts it
    /// closest to (and not long after) the period end, so December lines in a January statement
    /// get the previous year.
    static func resolve(_ p: DateParts, periodEnd: Date, calendar: Calendar) -> Date? {
        func make(_ y: Int) -> Date? {
            guard let d = calendar.date(from: DateComponents(year: y, month: p.month, day: p.day, hour: 12)),
                  calendar.component(.day, from: d) == p.day else { return nil }
            return d
        }
        if let y = p.year { return make(y) }
        let endYear = calendar.component(.year, from: periodEnd)
        guard let d = make(endYear) else { return make(endYear - 1) }   // Feb 29 in a non-leap end year
        if let limit = calendar.date(byAdding: .day, value: 31, to: periodEnd), d > limit { return make(endYear - 1) }
        return d
    }

    private static let summaryWords = ["beginning balance", "ending balance", "previous balance", "new balance", "balance forward",
                                       "opening balance", "closing balance", "daily balance", "total ", "subtotal"]
    /// Section headings start with one of these words. Matching the start (not anywhere in the line)
    /// keeps a wrapped description such as "ONLINE PAYMENT THANK YOU" from being read as a heading.
    private static let inSections = ["deposits", "other deposits", "electronic deposits", "payments", "credits", "other credits",
                                     "additions", "money in", "paid in"]
    private static let outSections = ["withdrawals", "electronic withdrawals", "other withdrawals", "atm", "checks", "debits",
                                      "other debits", "purchases", "fees", "interest charged", "charges", "money out", "paid out",
                                      "card transactions", "subtractions", "new charges"]

    /// A short line with no date and no amount that names a section of the statement:
    /// `.some(direction)` for a heading, `.some(nil)` for a heading that mixes both, nil for any other line.
    static func sectionDirection(_ line: String) -> StatementDirection?? {
        guard line.count <= 70, leadingDates(line) == nil, MoneyText.tokens(in: line).isEmpty else { return nil }
        let n = MerchantName.normalize(line)
        guard !n.isEmpty, n.split(separator: " ").count <= 7 else { return nil }
        func starts(_ list: [String]) -> Bool { list.contains { n == $0 || n.hasPrefix($0 + " ") } }
        let isIn = starts(inSections), isOut = starts(outSections)
        let mentionsBoth = n.contains("debits and credits") || n.contains("credits and debits")
        if mentionsBoth { return .some(nil) }
        if isIn && !isOut { return .some(.moneyIn) }
        if isOut && !isIn { return .some(.moneyOut) }
        return nil
    }

    static func classify(description: String, direction: StatementDirection, isCard: Bool) -> StatementLineKind {
        let d = " " + MerchantName.normalize(description) + " "
        func has(_ words: [String]) -> Bool { words.contains { d.contains(" \($0) ") } }
        if has(["interest charge", "interest charged", "finance charge", "purchase interest"]) { return .interest }
        if has(["interest paid", "interest earned", "interest payment"]) && direction == .moneyIn { return .deposit }
        if has(["fee", "service charge", "overdraft", "late fee", "annual fee", "foreign transaction"]) { return .fee }
        if has(["atm", "cash withdrawal", "withdrawal at"]) && direction == .moneyOut { return .cashWithdrawal }
        if isCard {
            if direction == .moneyIn {
                return has(["payment", "thank you", "autopay", "auto pay", "pymt", "online pmt"]) ? .cardPayment : .refund
            }
            return .purchase
        }
        if has(["credit card", "card payment", "crd pmt", "epay", "autopay", "amex", "capital one", "discover", "citi card", "chase card", "applecard"])
            && direction == .moneyOut { return .cardPayment }
        if has(["transfer", "xfer", "zelle", "venmo", "online banking transfer"]) { return .transfer }
        return direction == .moneyIn ? .deposit : .withdrawal
    }

    /// Column headings and per-cardholder headings ("Trans Date Post Date Description Amount",
    /// "JANE DOE #1234: Transactions"). Never part of a description.
    static func isTableHeading(_ line: String) -> Bool {
        let n = " " + MerchantName.normalize(line) + " "
        if n.contains(" date ") && (n.contains(" amount ") || n.contains(" description ")) { return true }
        if n.contains(" continued on ") || n.contains(" continued from ") { return true }
        return n.hasSuffix(" transactions ") || n.hasSuffix(" activity ")
    }

    /// Words in a bank description that say which way money moved, used only to break ties.
    static func directionHint(_ description: String) -> StatementDirection? {
        let d = " " + MerchantName.normalize(description) + " "
        if [" zelle from ", " payroll ", " direct dep ", " deposit ", " refund ", " interest paid ", " transfer from "].contains(where: d.contains) {
            return .moneyIn
        }
        if [" zelle to ", " withdrawal ", " fee ", " pmt ", " payment ", " purchase ", " transfer to ", " billpay "].contains(where: d.contains) {
            return .moneyOut
        }
        return nil
    }

    /// A dated line whose text can't start a transaction: a date range ("Sep 13, 2026 - Oct 13, 2026"),
    /// a bare date, a page header ("November 6, 2026  Page 1 of 6") or a sentence ("11/18/26. This date…").
    static func isNonTransactionText(_ rest: String) -> Bool {
        let t = rest.trimmingCharacters(in: .whitespaces)
        guard let c = t.first else { return true }
        if !(c.isLetter || c.isNumber || c == "*" || c == "#" || c == "&") { return true }
        let lower = t.lowercased()
        // Rate tables ("05/02/2026 11/03/2026 11.99% $0.00") are not transactions either.
        return lower.hasPrefix("page ") || t.contains("%")
    }

    static func parse(text: DocumentText, kind: FinancialDocumentKind, header: StatementHeader, calendar: Calendar,
                      referenceDate: Date = .now) -> StatementParseResult {
        let isCard = kind == .creditCardStatement
        let periodEnd = header.periodEnd ?? referenceDate
        var lines: [ParsedStatementLine] = []
        var issues: [StatementParseIssue] = []

        for page in text.pages {
            var section: StatementDirection? = nil
            var current: ParsedStatementLine? = nil
            var pendingNoAmount: (parts: (DateParts, DateParts?), text: String, line: Int, description: String, extra: Int)? = nil
            var continuation = 0

            func flush() {
                if let c = current { lines.append(c) }
                current = nil
                if let p = pendingNoAmount {
                    issues.append(StatementParseIssue(page: page.index + 1, line: p.line, text: p.text, reason: "No amount found on this line"))
                }
                pendingNoAmount = nil
                continuation = 0
            }

            for (n, raw) in page.lines.enumerated() {
                let lineNumber = n + 1
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let s = sectionDirection(line) {
                    flush(); section = s; continue
                }
                if let dated = leadingDates(line) {
                    let (d1, d2, rest) = dated
                    flush()
                    let lowerRest = rest.lowercased()
                    if summaryWords.contains(where: lowerRest.contains) { continue }
                    if isNonTransactionText(rest) { continue }
                    let tokens = MoneyText.tokens(in: rest, currencyCode: header.currencyCode)
                    guard let first = resolve(d1, periodEnd: periodEnd, calendar: calendar) else {
                        issues.append(StatementParseIssue(page: page.index + 1, line: lineNumber, text: line, reason: "The date isn't a real calendar date"))
                        continue
                    }
                    let second = d2.flatMap { resolve($0, periodEnd: periodEnd, calendar: calendar) }
                    if tokens.isEmpty {
                        pendingNoAmount = ((d1, d2), line, lineNumber, rest.trimmingCharacters(in: .whitespaces), 0)
                        continue
                    }
                    // Bank lines often end with the running balance; card lines end with the amount.
                    let amountToken: MoneyText.Token
                    var balance: Int64? = nil
                    if !isCard, tokens.count >= 2 {
                        amountToken = tokens[tokens.count - 2]; balance = tokens[tokens.count - 1].value
                    } else {
                        amountToken = tokens[tokens.count - 1]
                    }
                    let description = String(rest[rest.startIndex..<tokens[0].range.lowerBound])
                        .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-–—"))
                        .trimmingCharacters(in: .whitespaces)
                    guard amountToken.value != 0 else {
                        issues.append(StatementParseIssue(page: page.index + 1, line: lineNumber, text: line, reason: "The amount is zero"))
                        continue
                    }
                    let (direction, confidence, note) = resolveDirection(for: amountToken, section: section, isCard: isCard)
                    current = ParsedStatementLine(
                        page: page.index + 1, line: lineNumber, transactionDate: first, postingDate: second,
                        description: description.isEmpty ? "(no description)" : description,
                        amountMinorUnits: abs(amountToken.value), direction: direction, runningBalance: balance,
                        kind: classify(description: description, direction: direction, isCard: isCard),
                        isPending: lowerRest.contains("pending"),
                        confidence: description.isEmpty ? min(confidence, .medium) : confidence,
                        note: description.isEmpty ? "No description on the line" : note)
                    continue
                }
                let tokens = MoneyText.tokens(in: line, currencyCode: header.currencyCode)
                let heading = isTableHeading(line)
                if let p = pendingNoAmount, let last = tokens.last, line.count <= 80, !heading {
                    // The amount was printed below the description (wrapped description or OCR output).
                    let t = !isCard && tokens.count >= 2 ? tokens[tokens.count - 2] : last
                    let balance: Int64? = !isCard && tokens.count >= 2 ? last.value : nil
                    let desc = p.description + " " + (tokens.first.map { String(line[line.startIndex..<$0.range.lowerBound]) } ?? "")
                    guard let first = resolve(p.parts.0, periodEnd: periodEnd, calendar: calendar) else { continue }
                    let (direction, confidence, note) = resolveDirection(for: t, section: section, isCard: isCard)
                    pendingNoAmount = nil
                    current = ParsedStatementLine(
                        page: page.index + 1, line: p.line, transactionDate: first,
                        postingDate: p.parts.1.flatMap { resolve($0, periodEnd: periodEnd, calendar: calendar) },
                        description: desc.trimmingCharacters(in: .whitespaces), amountMinorUnits: abs(t.value), direction: direction,
                        runningBalance: balance, kind: classify(description: desc, direction: direction, isCard: isCard),
                        isPending: false, confidence: min(confidence, .medium), note: note ?? "Amount was below the description")
                    continue
                }
                if var p = pendingNoAmount, tokens.isEmpty, p.extra < 3, line.count <= 80, !heading,
                   !summaryWords.contains(where: line.lowercased().contains) {
                    // More description before the amount (e.g. city and merchant type on their own lines).
                    p.description += " " + line
                    p.extra += 1
                    pendingNoAmount = p
                    continue
                }
                if var c = current, tokens.isEmpty, continuation < 3, line.count <= 80, !heading,
                   !summaryWords.contains(where: line.lowercased().contains) {
                    // A description that wrapped onto the next line.
                    c.description += " " + line
                    c.kind = classify(description: c.description, direction: c.direction, isCard: isCard)
                    current = c
                    continuation += 1
                    continue
                }
                flush()
            }
            flush()
        }
        if !isCard { applyRunningBalances(&lines, openingBalance: header.openingBalance) }
        return StatementParseResult(lines: lines, issues: issues)
    }

    /// Bank statements with separate deposit and withdrawal columns print no sign, and the text
    /// loses the columns. The running balance settles it: between two printed balances, the lines
    /// must add up to the change. When exactly one choice of in/out does, it is used.
    static func applyRunningBalances(_ lines: inout [ParsedStatementLine], openingBalance: Int64?) {
        guard var previous = openingBalance else { return }
        var groupStart = 0
        for i in lines.indices {
            guard let balance = lines[i].runningBalance else { continue }
            let group = Array(groupStart...i)
            groupStart = i + 1
            let delta = balance - previous
            previous = balance
            guard group.count <= 16 else { continue }
            var solutions: [Int] = []
            for mask in 0..<(1 << group.count) {
                var sum: Int64 = 0
                for (bit, index) in group.enumerated() {
                    sum += (mask >> bit) & 1 == 1 ? lines[index].amountMinorUnits : -lines[index].amountMinorUnits
                }
                if sum == delta { solutions.append(mask) }
            }
            guard !solutions.isEmpty else { continue }
            // Several choices add up (e.g. $300 in and $300 out on one day): pick the one the
            // descriptions agree with best, and only if it is the single best.
            func score(_ mask: Int) -> Int {
                group.enumerated().reduce(0) { total, item in
                    let isIn = (mask >> item.offset) & 1 == 1
                    switch directionHint(lines[item.element].description) {
                    case .moneyIn?: return total + (isIn ? 1 : -1)
                    case .moneyOut?: return total + (isIn ? -1 : 1)
                    case nil: return total
                    }
                }
            }
            let scored = solutions.map { ($0, score($0)) }
            let best = scored.map(\.1).max() ?? 0
            let winners = scored.filter { $0.1 == best }
            guard winners.count == 1, let mask = winners.first?.0 else { continue }
            let certain = solutions.count == 1
            for (bit, index) in group.enumerated() {
                let direction: StatementDirection = (mask >> bit) & 1 == 1 ? .moneyIn : .moneyOut
                lines[index].direction = direction
                lines[index].kind = classify(description: lines[index].description, direction: direction, isCard: false)
                lines[index].confidence = certain ? .high : .medium
                lines[index].note = certain ? nil : "In or out was chosen from the running balance and the description"
            }
        }
    }

    private static func resolveDirection(for t: MoneyText.Token, section: StatementDirection?, isCard: Bool)
        -> (StatementDirection, ParseConfidence, String?) {
        if t.isCreditMarked { return (.moneyIn, .high, nil) }
        if t.isDebitMarked { return (.moneyOut, .high, nil) }
        if let section { return (section, .high, nil) }
        if t.isNegative { return (isCard ? .moneyIn : .moneyOut, .high, nil) }
        if isCard { return (.moneyOut, .high, nil) }
        return (.moneyOut, .low, "Couldn't tell if this is money in or out; assumed money out")
    }
}
