import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Help understanding a statement description: a readable merchant name, a category suggestion and
/// a short explanation. Advice only: it never calculates totals, never changes records, and the user
/// accepts or ignores it.
struct DescriptionInsight: Equatable, Sendable {
    enum Source: String, Sendable { case rules, onDeviceModel }
    var merchantName: String
    /// One of the category names offered, or nil.
    var categoryName: String?
    var explanation: String
    var source: Source
}

protocol StatementDescriptionAssisting: Sendable {
    func insight(for description: String, kind: StatementLineKind, categoryNames: [String]) async -> DescriptionInsight
}

/// Deterministic assistant used on every iPhone, and as the fallback for the on-device model.
struct RuleBasedDescriptionAssistant: StatementDescriptionAssisting {
    static let processors: [(prefix: String, name: String)] = [
        ("sq ", "Square"), ("tst", "Toast"), ("paypal", "PayPal"), ("pp ", "PayPal"), ("sp ", "Shopify"), ("py ", "a payment processor"),
    ]

    func insight(for description: String, kind: StatementLineKind, categoryNames: [String]) async -> DescriptionInsight {
        let key = StatementMerchantNormalizer.normalize(description)
        let name = StatementRepository.displayName(forMerchantKey: key)
        let options = categoryNames.map { CategoryOption(id: UUID(), name: $0, kind: .expense) }
        let category = HeuristicCategorySuggestionService()
            .suggest(merchant: name, receiptText: description, kind: .expense, categories: options, history: [])
            .flatMap { s in options.first { $0.id == s.categoryId }?.name }

        let lower = MerchantName.normalize(description.replacingOccurrences(of: "*", with: " "))
        var parts: [String] = []
        switch kind {
        case .cardPayment: parts.append("This is a payment to a credit card, not a purchase. Record it as a transfer so it isn't counted as spending.")
        case .transfer: parts.append("This looks like money moving between accounts. Record it as a transfer.")
        case .cashWithdrawal: parts.append("This is a cash withdrawal. If you track cash, record it as a transfer to Cash; the spending is recorded when you use the cash.")
        case .interest: parts.append("Interest charged by the card or bank. It's a real expense.")
        case .fee: parts.append("A fee charged by the bank or card. It's a real expense.")
        case .refund: parts.append("Money back from a merchant. It reduces your spending.")
        default: break
        }
        if let p = Self.processors.first(where: { lower.hasPrefix($0.prefix.trimmingCharacters(in: .whitespaces) + " ") || lower.hasPrefix($0.prefix) }) {
            parts.append("Paid through \(p.name); the merchant is probably “\(name)”.")
        }
        if description.range(of: #"#\s?\d+|\b\d{3,}\b"#, options: .regularExpression) != nil {
            parts.append("Numbers in the description are usually a store or reference number.")
        }
        if parts.isEmpty { parts.append("The merchant is probably “\(name)”.") }
        return DescriptionInsight(merchantName: name, categoryName: category, explanation: parts.joined(separator: " "), source: .rules)
    }
}

#if canImport(FoundationModels)
/// Apple's on-device language model (Apple Intelligence). Runs entirely on the iPhone. Its answer is
/// checked before use: the merchant must be short and the category must be one of the user's own,
/// otherwise the rule-based answer is used.
@available(iOS 26.0, *)
struct OnDeviceModelDescriptionAssistant: StatementDescriptionAssisting {
    func insight(for description: String, kind: StatementLineKind, categoryNames: [String]) async -> DescriptionInsight {
        let fallback = await RuleBasedDescriptionAssistant().insight(for: description, kind: kind, categoryNames: categoryNames)
        guard case .available = SystemLanguageModel.default.availability else { return fallback }
        let instructions = """
        You help a person understand one line from their own bank or credit card statement.
        Reply with exactly three lines and nothing else:
        Merchant: <the business name, at most 4 words>
        Category: <one of the allowed categories, or None>
        Explanation: <one plain sentence about what this line probably is>
        Never invent amounts, dates or balances.
        """
        let prompt = "Statement line: \(description.prefix(200))\nLine type: \(kind.displayName)\nAllowed categories: \(categoryNames.joined(separator: ", "))"
        let token = DiagnosticsService.shared.begin(.aiResponse)
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            DiagnosticsService.shared.end(token)
            return Self.parse(response.content, categoryNames: categoryNames, fallback: fallback)
        } catch {
            DiagnosticsService.shared.end(token, error: error)
            return fallback
        }
    }

    static func parse(_ text: String, categoryNames: [String], fallback: DescriptionInsight) -> DescriptionInsight {
        DescriptionAnswerParser.parse(text, categoryNames: categoryNames, fallback: fallback, source: .onDeviceModel)
    }
}
#endif

/// Checks a model's three-line answer. Anything unexpected falls back to the rule-based answer, so a
/// model can never put an unknown category or a long, made-up name on a record.
enum DescriptionAnswerParser {
    static func parse(_ text: String, categoryNames: [String], fallback: DescriptionInsight, source: DescriptionInsight.Source) -> DescriptionInsight {
        var fields: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let merchant = fields["merchant"], !merchant.isEmpty, merchant.count <= 40, merchant.split(separator: " ").count <= 5,
              !merchant.contains(where: { $0 == "$" || $0.isNumber }) else { return fallback }
        let category = fields["category"].flatMap { c in categoryNames.first { $0.caseInsensitiveCompare(c) == .orderedSame } }
        let explanation = (fields["explanation"].map { String($0.prefix(240)) }).flatMap { $0.isEmpty ? nil : $0 } ?? fallback.explanation
        return DescriptionInsight(merchantName: merchant, categoryName: category, explanation: explanation, source: source)
    }
}

/// Chooses the assistant. The on-device model is used only when the user turned it on and the
/// iPhone supports it; otherwise the rule-based assistant is used.
enum DescriptionAssistantFactory {
    static let preferenceKey = "assist.useOnDeviceModel"

    /// Why the on-device model can or can't be used on this iPhone, in plain language.
    static var onDeviceModelStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Apple Intelligence is ready on this iPhone."
            case .unavailable(.deviceNotEligible):
                return "This iPhone doesn't support Apple Intelligence, so TallySeam's built-in rules are used."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in the iPhone Settings app (Apple Intelligence & Siri) to use it here."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading or getting ready. Try again later."
            case .unavailable:
                return "Apple Intelligence isn't available right now, so TallySeam's built-in rules are used."
            }
        }
        return "Apple Intelligence needs iOS 26 or later. TallySeam's built-in rules are used."
        #else
        return "This build of TallySeam was made without Apple Intelligence support, so its built-in rules are used."
        #endif
    }

    static var isOnDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func make(defaults: UserDefaults = .standard) -> any StatementDescriptionAssisting {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), defaults.bool(forKey: preferenceKey), isOnDeviceModelAvailable {
            return OnDeviceModelDescriptionAssistant()
        }
        #endif
        return RuleBasedDescriptionAssistant()
    }
}
