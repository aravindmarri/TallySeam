import Foundation

// MARK: - Merchant normalization

/// Turns statement descriptions into a comparable merchant key:
/// "WAL-MART STORE #2456" → "walmart", "SQ *BLUE BOTTLE 1234 OAKLAND CA" → "blue bottle",
/// "PURCHASE AUTHORIZED ON 10/04 STARBUCKS STORE 1234 SEATTLE WA" → "starbucks".
enum StatementMerchantNormalizer {
    /// Payment processor and bank wording that comes before the merchant name.
    static let prefixes = [
        "purchase authorized on", "recurring payment authorized on", "pos purchase", "pos debit", "pos", "debit card purchase",
        "checkcard", "check card", "card purchase", "visa purchase", "dbt crd", "pmnt sent", "sq", "tst", "sp", "pp",
        "paypal", "py", "ach debit", "ach credit", "ach", "recurring", "purchase", "online", "web", "ppd", "ccd",
    ]
    /// Words that don't identify the merchant.
    static let noise: Set<String> = [
        "store", "stores", "supercenter", "super", "center", "market", "inc", "llc", "co", "corp", "the", "com", "www", "us",
        "usa", "pos", "card", "purchase", "debit", "credit", "payment", "online", "on", "at",
    ]
    /// US state and territory codes, removed from the end ("SEATTLE WA").
    static let states: Set<String> = [
        "al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in", "ia", "ks", "ky", "la", "me", "md",
        "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm", "ny", "nc", "nd", "oh", "ok", "or", "pa", "ri", "sc",
        "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv", "wi", "wy", "dc", "pr",
    ]
    /// Well-known spellings that statements use for the same merchant.
    static let builtInAliases: [String: String] = [
        "wal mart": "walmart", "wm supercenter": "walmart", "wm": "walmart", "walmart com": "walmart", "wal mart com": "walmart",
        "amzn": "amazon", "amzn mktp": "amazon", "amazon mktplace": "amazon", "amazon com": "amazon", "amazon mktp": "amazon",
        "amzn digital": "amazon", "prime video": "amazon",
        "sbux": "starbucks", "mcdonald s": "mcdonalds", "mcdonalds": "mcdonalds", "trader joe s": "trader joes",
        "whole foods": "whole foods", "wholefds": "whole foods", "target com": "target", "costco whse": "costco",
        "uber trip": "uber", "uber eats": "uber eats", "lyft ride": "lyft", "apple com bill": "apple", "google": "google",
        "netflix com": "netflix", "spotify usa": "spotify",
    ]

    static func normalize(_ description: String, learnedAliases: [String: String] = [:]) -> String {
        var s = MerchantName.normalize(description.replacingOccurrences(of: "*", with: " "))
        // Drop dates such as "on 10 04" that survive as words after normalization (digits are removed).
        for p in prefixes.sorted(by: { $0.count > $1.count }) where s == p || s.hasPrefix(p + " ") {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        var words = s.split(separator: " ").map(String.init)
        // Remove a trailing state code and the city before it ("seattle wa"), when enough name remains.
        if words.count >= 3, let last = words.last, states.contains(last) { words.removeLast(2) }
        let joined = words.joined(separator: " ")
        if let learned = learnedAliases[joined] { return learned }
        for (alias, merchant) in builtInAliases.sorted(by: { $0.key.count > $1.key.count })
        where joined == alias || joined.hasPrefix(alias + " ") {
            return merchant
        }
        let meaningful = words.filter { !noise.contains($0) && $0.count > 1 }
        let key = (meaningful.isEmpty ? words : meaningful).prefix(3).joined(separator: " ")
        return learnedAliases[key] ?? builtInAliases[key] ?? key
    }

    /// 0...1. 1 for the same key; partial credit for shared words and close spellings.
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        let contains = (a.contains(b) || b.contains(a)) ? 0.85 : 0
        let compactA = a.replacingOccurrences(of: " ", with: ""), compactB = b.replacingOccurrences(of: " ", with: "")
        let distance = levenshtein(compactA, compactB)
        let edit = 1 - Double(distance) / Double(max(compactA.count, compactB.count))
        return max(jaccard, contains, edit)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

// MARK: - Inputs and results

/// A statement line as the matcher sees it (decoupled from SwiftData for testing).
struct StatementLineInput: Identifiable, Equatable, Sendable {
    var id: UUID
    var transactionDate: Date
    var postingDate: Date?
    var description: String
    var amountMinorUnits: Int64
    var currencyCode: String
    var direction: StatementDirection
    var kind: StatementLineKind
}

enum MatchStrength: String, Codable, Sendable, CaseIterable, Comparable {
    case weak, possible, strong
    var displayName: String {
        switch self {
        case .strong: "Strong match"
        case .possible: "Possible match"
        case .weak: "Weak match"
        }
    }
    private var rank: Int { [.weak: 0, .possible: 1, .strong: 2][self] ?? 0 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

struct MatchCandidate: Equatable, Sendable {
    var transactionId: UUID
    var score: Int
    var strength: MatchStrength
    var reasons: [String]
    /// Calendar days between the transaction and the closer of the statement's dates (signed:
    /// positive when the statement date is later).
    var dateDifferenceDays: Int
    /// Statement amount minus transaction amount, in minor units.
    var amountDifferenceMinorUnits: Int64
    var merchantSimilarity: Int
}

struct LineReconciliation: Equatable, Sendable {
    var lineId: UUID
    /// Every plausible candidate, best first.
    var candidates: [MatchCandidate]
    /// The candidate suggested for this line, if any. One existing transaction is suggested for
    /// at most one line.
    var suggestion: MatchCandidate?
    /// Another candidate scored within `ambiguityMargin` of the best: the user must pick.
    var isAmbiguous: Bool
    /// Plain-language note when nothing is suggested.
    var note: String?
}

/// Calendar-day window around the statement date.
enum MatchDateWindow: Int, CaseIterable, Identifiable, Codable, Sendable {
    case exact = 0, oneDay = 1, twoDays = 2, threeDays = 3, sevenDays = 7
    var id: Int { rawValue }
    var displayName: String { rawValue == 0 ? "Same day only" : "± \(rawValue) day\(rawValue == 1 ? "" : "s")" }
}

struct ReconciliationConfig: Equatable, Sendable {
    var window: MatchDateWindow = .twoDays
    /// Starting weights, not calibrated probabilities. They must sum to 1.
    var amountWeight = 0.45
    var merchantWeight = 0.25
    var dateWeight = 0.15
    var accountWeight = 0.15
    /// Candidates are also looked for this many days beyond the window, with no date credit.
    var extendedSearchDays = 5
    /// Amounts may differ by up to this fraction (tips, adjusted charges) and still be candidates.
    var maximumAmountDifference = 0.25
    var ambiguityMargin = 5

    static let strongScore = 85, possibleScore = 65, weakScore = 45
}

/// The account a statement belongs to, as far as matching is concerned.
struct ReconciliationAccount: Equatable, Sendable {
    var paymentMethodId: UUID?
    var isCreditCard: Bool
    var displayName: String
}

// MARK: - Matching

/// Deterministic, explainable matching of statement lines to existing transactions. It never
/// changes data: it only proposes. Hard rules: same currency, compatible direction, each existing
/// transaction backs at most one line, and transactions already confirmed elsewhere are skipped.
struct StatementReconciliationService: Sendable {
    var config = ReconciliationConfig()
    var calendar: Calendar = .current

    func reconcile(lines: [StatementLineInput], existing: [TransactionRecord], account: ReconciliationAccount,
                   alreadyMatched: Set<UUID> = [], learnedAliases: [String: String] = [:]) -> [LineReconciliation] {
        let token = DiagnosticsService.shared.begin(.reconciliation)
        defer { DiagnosticsService.shared.end(token) }
        // Work out each day number and merchant key once, then compare a line only with transactions
        // dated near it (binary search), so long statements and long histories stay fast.
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        func dayNumber(_ d: Date) -> Int { calendar.dateComponents([.day], from: reference, to: calendar.startOfDay(for: d)).day ?? 0 }
        let pool = existing.filter { !alreadyMatched.contains($0.id) }
            .map { (day: dayNumber($0.transactionDate), record: $0) }
            .sorted { $0.day < $1.day }
        let poolDays = pool.map(\.day)
        var transactionKeys: [UUID: [String]] = [:]
        for t in pool.map(\.record) {
            transactionKeys[t.id] = [t.merchant, t.title].compactMap { $0 }.map { StatementMerchantNormalizer.normalize($0, learnedAliases: learnedAliases) }
        }
        func lowerBound(_ value: Int) -> Int {
            var lo = 0, hi = poolDays.count
            while lo < hi { let mid = (lo + hi) / 2; if poolDays[mid] < value { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        let reach = config.window.rawValue + config.extendedSearchDays
        var all: [UUID: [MatchCandidate]] = [:]
        for line in lines {
            let lineDays = ([line.transactionDate] + (line.postingDate.map { [$0] } ?? [])).map(dayNumber)
            let start = lowerBound((lineDays.min() ?? 0) - reach), end = lowerBound((lineDays.max() ?? 0) + reach + 1)
            let lineKey = StatementMerchantNormalizer.normalize(line.description, learnedAliases: learnedAliases)
            all[line.id] = pool[start..<end].compactMap {
                candidate(line: line, transaction: $0.record, account: account, aliases: learnedAliases,
                          lineKey: lineKey, transactionKeys: transactionKeys[$0.record.id])
            }
            .sorted { ($0.score, -abs($0.dateDifferenceDays), $0.transactionId.uuidString) > ($1.score, -abs($1.dateDifferenceDays), $1.transactionId.uuidString) }
        }

        // Assign best-first across the whole statement so one transaction is never suggested for two
        // lines (two identical coffees stay two separate purchases).
        var taken = Set<UUID>()
        var suggestion: [UUID: MatchCandidate] = [:]
        let ranked = all.flatMap { lineId, cs in cs.map { (lineId, $0) } }
            .sorted { a, b in
                if a.1.score != b.1.score { return a.1.score > b.1.score }
                if abs(a.1.dateDifferenceDays) != abs(b.1.dateDifferenceDays) { return abs(a.1.dateDifferenceDays) < abs(b.1.dateDifferenceDays) }
                return (a.0.uuidString, a.1.transactionId.uuidString) < (b.0.uuidString, b.1.transactionId.uuidString)
            }
        for (lineId, c) in ranked where suggestion[lineId] == nil && !taken.contains(c.transactionId) {
            suggestion[lineId] = c
            taken.insert(c.transactionId)
        }

        return lines.map { line in
            let cs = all[line.id] ?? []
            let chosen = suggestion[line.id]
            let ambiguous: Bool = {
                guard let chosen else { return false }
                // A close runner-up that isn't already suggested for another line.
                return cs.contains { $0.transactionId != chosen.transactionId && chosen.score - $0.score <= config.ambiguityMargin
                    && !taken.contains($0.transactionId) }
            }()
            var note: String?
            if chosen == nil {
                note = cs.isEmpty ? "No transaction in the app matches this line." : "The likely matches are already suggested for other lines."
            }
            return LineReconciliation(lineId: line.id, candidates: cs, suggestion: chosen, isAmbiguous: ambiguous, note: note)
        }
    }

    /// Scores one pair, or nil when a hard rule rules it out.
    func candidate(line: StatementLineInput, transaction t: TransactionRecord, account: ReconciliationAccount,
                   aliases: [String: String] = [:], lineKey precomputedLineKey: String? = nil,
                   transactionKeys precomputedKeys: [String]? = nil) -> MatchCandidate? {
        guard t.currencyCode == line.currencyCode else { return nil }
        guard let directionReason = directionCompatibility(line: line, transaction: t, account: account) else { return nil }

        // Date: calendar days, preferring the transaction date, also trying the posting date.
        let dates = [line.transactionDate] + (line.postingDate.map { [$0] } ?? [])
        let diffs = dates.map { calendarDays(from: t.transactionDate, to: $0) }
        let dayDiff = diffs.min { abs($0) < abs($1) } ?? 0
        let window = config.window.rawValue
        guard abs(dayDiff) <= window + config.extendedSearchDays else { return nil }
        var reasons: [String] = []
        let dateScore: Double
        if abs(dayDiff) <= window {
            dateScore = window == 0 ? 1 : 1 - Double(abs(dayDiff)) / Double(window + 1)
            reasons.append(dayDiff == 0 ? "Same date" : "\(abs(dayDiff)) day\(abs(dayDiff) == 1 ? "" : "s") apart (within ± \(window))"
                           + (line.postingDate != nil && diffs.count > 1 && abs(diffs[1]) < abs(diffs[0]) ? ", using the posting date" : ""))
        } else {
            dateScore = 0
            reasons.append("\(abs(dayDiff)) days apart: outside your ± \(window)-day window, so confidence is lower")
        }

        // Amount: exact is best; small differences (tips, adjustments) need review.
        let diff = line.amountMinorUnits - t.amountMinorUnits
        let ratio = Double(abs(diff)) / Double(max(line.amountMinorUnits, t.amountMinorUnits, 1))
        guard ratio <= config.maximumAmountDifference else { return nil }
        let amountScore: Double
        if diff == 0 {
            amountScore = 1
            reasons.append("Same amount")
        } else {
            amountScore = max(0, 0.6 * (1 - ratio / config.maximumAmountDifference))
            let shown = CurrencyMath.format(abs(diff), currencyCode: line.currencyCode)
            reasons.append(diff > 0 ? "Statement is \(shown) more: a tip or adjusted charge? Review before confirming"
                                    : "Statement is \(shown) less: a partial or adjusted charge? Review before confirming")
        }

        // Merchant.
        let lineKey = precomputedLineKey ?? StatementMerchantNormalizer.normalize(line.description, learnedAliases: aliases)
        let names = precomputedKeys ?? [t.merchant, t.title].compactMap { $0 }.map { StatementMerchantNormalizer.normalize($0, learnedAliases: aliases) }
        let merchant = names.map { StatementMerchantNormalizer.similarity(lineKey, $0) }.max() ?? 0
        if merchant >= 0.99 { reasons.append("Same merchant (\(lineKey))") }
        else if merchant >= 0.6 { reasons.append("Similar merchant names") }
        else { reasons.append("Merchant names differ") }

        // Account / payment method.
        let accountScore: Double
        let methods = [t.paymentMethodId, t.transferDestinationPaymentMethodId].compactMap { $0 }
        if let pm = account.paymentMethodId, methods.contains(pm) {
            accountScore = 1; reasons.append("Recorded on \(account.displayName)")
        } else if methods.isEmpty || account.paymentMethodId == nil {
            accountScore = 0.5; reasons.append("No payment method to compare")
        } else {
            accountScore = 0; reasons.append("Recorded on a different payment method")
        }
        reasons.append(directionReason)

        let raw = config.amountWeight * amountScore + config.merchantWeight * merchant + config.dateWeight * dateScore + config.accountWeight * accountScore
        let score = Int((raw * 100).rounded())
        // Strong needs an exact amount, a date inside the window AND a matching merchant or account:
        // amount and date alone are never enough.
        let strength: MatchStrength?
        if score >= ReconciliationConfig.strongScore, diff == 0, abs(dayDiff) <= window, merchant >= 0.6 || accountScore == 1 {
            strength = .strong
        } else if score >= ReconciliationConfig.possibleScore {
            strength = .possible
        } else if score >= ReconciliationConfig.weakScore {
            strength = .weak
        } else {
            strength = nil
        }
        guard let strength else { return nil }
        return MatchCandidate(transactionId: t.id, score: score, strength: strength, reasons: reasons, dateDifferenceDays: dayDiff,
                              amountDifferenceMinorUnits: diff, merchantSimilarity: Int((merchant * 100).rounded()))
    }

    /// Which existing transaction types a statement line may correspond to. Returns the reason, or
    /// nil when the direction rules it out. Card repayments and transfers match transfers only, so
    /// a repayment is never matched to (or counted as) a purchase.
    func directionCompatibility(line: StatementLineInput, transaction t: TransactionRecord, account: ReconciliationAccount) -> String? {
        let isTransferLine = line.kind == .cardPayment || line.kind == .transfer || line.kind == .cashWithdrawal
        switch (line.direction, t.transactionType) {
        case (.moneyOut, .expense) where !t.isRefund && !isTransferLine:
            return "Money out matches an expense"
        case (.moneyIn, .income) where !t.isRefund && !isTransferLine:
            return "Money in matches income"
        case (.moneyIn, .expense) where t.isRefund:
            return "Credit matches a refund"
        case (.moneyOut, .transfer):
            // Leaving this account: the transfer's source should be this account (or unknown).
            if let pm = account.paymentMethodId, let from = t.paymentMethodId, from != pm { return nil }
            return "Money out matches a transfer from this account"
        case (.moneyIn, .transfer):
            if let pm = account.paymentMethodId, let to = t.transferDestinationPaymentMethodId, to != pm { return nil }
            return account.isCreditCard ? "Card payment matches a transfer to this card" : "Money in matches a transfer to this account"
        default:
            return nil
        }
    }

    /// Whole calendar days between two dates in the user's calendar (not elapsed hours).
    func calendarDays(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }
}
