import Foundation
import Observation

@MainActor
@Observable
final class DashboardViewModel {
    var selectedMonth: Date
    private let calendar: Calendar

    init(now: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        self.selectedMonth = calendar.monthRange(containing: now).start
    }

    var range: DateRange { calendar.monthRange(containing: selectedMonth) }

    var monthTitle: String { selectedMonth.formatted(.dateTime.month(.wide).year()) }

    var isCurrentMonth: Bool { range.contains(.now) }

    func moveMonth(by delta: Int) {
        selectedMonth = calendar.addingMonths(delta, to: range.start)
    }

    func summary(records: [TransactionRecord], currencyCode: String, finance: FinanceCalculationService) -> PeriodSummary {
        DiagnosticsService.shared.measure(.dashboardLoad) {
            finance.summary(of: records, in: range, currencyCode: currencyCode)
        }
    }
}
