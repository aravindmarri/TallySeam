import SwiftUI
import SwiftData

struct ReportsView: View {
    @Environment(AppContainer.self) private var app
    @Query private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]
    @Query private var settings: [AppSettings]
    @Query private var splitShares: [TransactionSplit]
    @Query private var splitLedger: [SplitLedgerEntry]
    @State private var model = ReportsViewModel()

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    EmptyStateView(title: "No Data to Report",
                                   systemImage: "chart.bar.xaxis",
                                   message: "Reports are calculated from your recorded transactions. Add income or expenses to see them here.")
                } else {
                    let snap = model.snapshot(records: SplitMath.personalRecords(transactions.map(\.record), splits: splitShares.map(\.value),
                                                                         ledger: splitLedger.map(\.value)), currencyCode: currency, finance: app.finance)
                    ScrollView {
                        VStack(spacing: Theme.spacing) {
                            periodPicker
                            summaryCard(snap)
                            if snap.summary.transactionCount == 0 {
                                Text("No \(currency) transactions in this period.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).card()
                            } else {
                                incomeVsExpenses(snap)
                                categorySection(snap)
                                paymentSection(snap)
                                merchantsSection(snap)
                                dailySection(snap)
                            }
                            comparisonSection(snap.monthOverMonth)
                            yearToDateSection(snap.yearToDate)
                            Text("Net cash flow is income minus expenses for the period. It is not your bank balance or net worth. Transfers, including credit-card payments, are not counted.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, Theme.spacing)
                    }
                }
            }
            .brandScreen()
            .navigationTitle("Reports")
        }
    }

    // MARK: Sections

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Period", selection: $model.period) {
                ForEach(ReportPeriod.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            if model.period == .custom {
                DatePicker("From", selection: $model.customStart, displayedComponents: .date)
                DatePicker("To", selection: $model.customEnd, displayedComponents: .date)
            }
        }
        .card()
    }

    private func summaryCard(_ s: ReportSnapshot) -> some View {
        let lastDay = s.range.end.addingTimeInterval(-1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(s.range.start.formatted(date: .abbreviated, time: .omitted)) – \(lastDay.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            row("Income", s.summary.incomeMinorUnits, Theme.income)
            row("Expenses", s.summary.expenseMinorUnits, Theme.expense)
            Divider()
            row("Net cash flow", s.summary.netCashFlowMinorUnits, .primary).fontWeight(.semibold)
            if s.summary.excludedOtherCurrencyCount > 0 {
                Text("\(s.summary.excludedOtherCurrencyCount) transaction(s) in other currencies are not included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func incomeVsExpenses(_ s: ReportSnapshot) -> some View {
        section("Monthly Income vs. Expenses") {
            MonthlyCashFlowChart(flows: s.monthly, currencyCode: currency)
        }
    }

    private func categorySection(_ s: ReportSnapshot) -> some View {
        section("Spending by Category") {
            if s.byCategory.isEmpty { emptyLine("No spending in this period.") }
            else { CategoryChart(slices: ChartSlices.categories(s.byCategory, categories: categories), currencyCode: currency) }
        }
    }

    private func paymentSection(_ s: ReportSnapshot) -> some View {
        section("Spending by Payment Method") {
            if s.byPaymentMethod.isEmpty { emptyLine("No spending in this period.") }
            else { RankedBarChart(slices: ChartSlices.paymentMethods(s.byPaymentMethod, methods: methods), currencyCode: currency) }
        }
    }

    private func merchantsSection(_ s: ReportSnapshot) -> some View {
        section("Top Merchants") {
            if s.topMerchants.isEmpty { emptyLine("No merchants in this period.") }
            else {
                VStack(spacing: 10) {
                    ForEach(Array(s.topMerchants.enumerated()), id: \.element.id) { i, m in
                        HStack {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading) {
                                Text(m.name).lineLimit(1)
                                Text("\(m.count) transaction\(m.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(CurrencyMath.format(m.minorUnits, currencyCode: currency)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func dailySection(_ s: ReportSnapshot) -> some View {
        section("Daily Spending") {
            DailySpendingChart(days: s.daily, currencyCode: currency)
        }
    }

    private func comparisonSection(_ c: PeriodComparison) -> some View {
        section("This Month vs. Last Month") {
            VStack(spacing: 10) {
                comparisonRow("Income", current: c.current.incomeMinorUnits, previous: c.previous.incomeMinorUnits,
                              change: c.incomeChange, higherIsGood: true)
                comparisonRow("Expenses", current: c.current.expenseMinorUnits, previous: c.previous.expenseMinorUnits,
                              change: c.expenseChange, higherIsGood: false)
            }
        }
    }

    private func yearToDateSection(_ s: PeriodSummary) -> some View {
        section("Year to Date") {
            VStack(spacing: 10) {
                row("Income", s.incomeMinorUnits, Theme.income)
                row("Expenses", s.expenseMinorUnits, Theme.expense)
                row("Net cash flow", s.netCashFlowMinorUnits, .primary)
                if let ratio = s.expenseToIncomeRatio {
                    HStack {
                        Text("Spent of income")
                        Spacer()
                        Text(ratio.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .card()
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ minor: Int64, _ tint: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(CurrencyMath.format(minor, currencyCode: currency)).monospacedDigit().foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func comparisonRow(_ label: String, current: Int64, previous: Int64, change: Decimal?, higherIsGood: Bool) -> some View {
        let changeText = change.map { $0.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())) } ?? "—"
        let isUp = (change ?? 0) > 0
        let good = change == nil || change == 0 ? nil : (isUp == higherIsGood)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text("Last month \(CurrencyMath.format(previous, currencyCode: currency))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyMath.format(current, currencyCode: currency)).monospacedDigit()
                Label(changeText, systemImage: isUp ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(good == nil ? Color.secondary : (good! ? Theme.income : Theme.expense))
                    .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
