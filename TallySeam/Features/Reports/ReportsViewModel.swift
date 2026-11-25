import Foundation
import Observation

/// Preset or custom period for the Reports screen.
enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisMonth, lastMonth, last3Months, last6Months, yearToDate, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .thisMonth: "This Month"
        case .lastMonth: "Last Month"
        case .last3Months: "Last 3 Months"
        case .last6Months: "Last 6 Months"
        case .yearToDate: "Year to Date"
        case .custom: "Custom"
        }
    }

    /// Resolves to a start-inclusive, end-exclusive range. Multi-month presets include the current month.
    func range(now: Date, customStart: Date, customEnd: Date, calendar: Calendar) -> DateRange {
        let thisMonth = calendar.monthRange(containing: now)
        switch self {
        case .thisMonth: return thisMonth
        case .lastMonth: return calendar.monthRange(containing: calendar.addingMonths(-1, to: thisMonth.start))
        case .last3Months: return DateRange(start: calendar.addingMonths(-2, to: thisMonth.start), end: thisMonth.end)
        case .last6Months: return DateRange(start: calendar.addingMonths(-5, to: thisMonth.start), end: thisMonth.end)
        case .yearToDate: return calendar.yearToDateRange(now: now)
        case .custom: return calendar.range(fromDay: customStart, throughDay: customEnd)
        }
    }
}

/// Everything the Reports screen shows, computed in one pass from stored records.
struct ReportSnapshot: Sendable {
    var range: DateRange
    var summary: PeriodSummary
    var byCategory: [GroupTotal]
    var byPaymentMethod: [GroupTotal]
    var topMerchants: [MerchantTotal]
    var daily: [DailyTotal]
    var monthly: [MonthlyFlow]
    var monthOverMonth: PeriodComparison
    var yearToDate: PeriodSummary

    init(records: [TransactionRecord], range: DateRange, currencyCode: String, now: Date, finance: FinanceCalculationService) {
        self.range = range
        summary = finance.summary(of: records, in: range, currencyCode: currencyCode)
        byCategory = finance.expensesByCategory(records, in: range, currencyCode: currencyCode)
        byPaymentMethod = finance.expensesByPaymentMethod(records, in: range, currencyCode: currencyCode)
        topMerchants = finance.topMerchants(records, in: range, currencyCode: currencyCode, limit: 5)
        daily = finance.dailyExpenses(records, in: range, currencyCode: currencyCode)
        monthly = finance.monthlyFlows(records, in: range, currencyCode: currencyCode)
        monthOverMonth = finance.monthOverMonth(records, month: now, currencyCode: currencyCode)
        yearToDate = finance.summary(of: records, in: finance.calendar.yearToDateRange(now: now), currencyCode: currencyCode)
    }
}

@MainActor
@Observable
final class ReportsViewModel {
    var period: ReportPeriod = .thisMonth
    var customStart: Date
    var customEnd: Date
    private let calendar: Calendar

    init(now: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        customStart = calendar.monthRange(containing: now).start
        customEnd = now
    }

    func snapshot(records: [TransactionRecord], currencyCode: String, finance: FinanceCalculationService, now: Date = .now) -> ReportSnapshot {
        let range = period.range(now: now, customStart: customStart, customEnd: customEnd, calendar: calendar)
        return DiagnosticsService.shared.measure(.reportGeneration) {
            ReportSnapshot(records: records, range: range, currencyCode: currencyCode, now: now, finance: finance)
        }
    }
}

/// Turns keyed totals into labeled chart slices using the user's categories and payment methods.
enum ChartSlices {
    static func categories(_ totals: [GroupTotal], categories: [SpendingCategory]) -> [ChartSlice] {
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return totals.map { t in
            let c = t.key.flatMap { byID[$0] }
            return ChartSlice(id: t.id, label: c?.name ?? "Uncategorized", colorIdentifier: c?.colorIdentifier ?? "gray", minorUnits: t.minorUnits)
        }
    }

    static let paymentPalette = ["blue", "indigo", "teal", "purple", "orange", "mint", "pink", "cyan"]

    static func paymentMethods(_ totals: [GroupTotal], methods: [PaymentMethod]) -> [ChartSlice] {
        let byID = Dictionary(uniqueKeysWithValues: methods.map { ($0.id, $0) })
        return totals.enumerated().map { i, t in
            let m = t.key.flatMap { byID[$0] }
            return ChartSlice(id: t.id, label: m?.name ?? "Not specified",
                              colorIdentifier: m == nil ? "gray" : paymentPalette[i % paymentPalette.count], minorUnits: t.minorUnits)
        }
    }

    static func merchants(_ totals: [MerchantTotal]) -> [ChartSlice] {
        totals.map { ChartSlice(id: $0.id, label: $0.name, colorIdentifier: "orange", minorUnits: $0.minorUnits) }
    }
}
