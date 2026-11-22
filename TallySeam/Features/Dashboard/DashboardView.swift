import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query(filter: #Predicate<RecurringBill> { $0.isActive }, sort: \RecurringBill.nextDueDate) private var bills: [RecurringBill]
    @Query private var budgets: [Budget]
    @Query private var settings: [AppSettings]
    @Query private var paymentMethods: [PaymentMethod]
    @Query private var statementLines: [StatementTransaction]
    @Query private var splitShares: [TransactionSplit]
    @Query private var splitLedger: [SplitLedgerEntry]
    @State private var showAccountSetup = false
    @State private var showCheckIn = false
    @State private var model = DashboardViewModel()
    @State private var editorRoute: TransactionEditorRoute?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        let allRecords = transactions.map(\.record)
        // Split expenses count only the user's share; repayments received aren't income.
        let records = SplitMath.personalRecords(allRecords, splits: splitShares.map(\.value), ledger: splitLedger.map(\.value))
        let summary = model.summary(records: records, currencyCode: currency, finance: app.finance)
        let monthTransactions = transactions.filter { model.range.contains($0.record.reportingDate(in: app.finance.calendar)) }
        let categoryByID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    monthSelector
                    summaryGrid(summary)
                    if summary.excludedOtherCurrencyCount > 0 {
                        Label("\(summary.excludedOtherCurrencyCount) transactions in other currencies are not included.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    quickActions
                    NetWorthCard(currencyCode: currency) { showCheckIn = true }
                    OwedToMeCard(currencyCode: currency)
                    if paymentMethods.isEmpty { accountSetupPrompt }
                    if !statementLines.isEmpty { verifiedSpendingCard(allRecords) }
                    spendingSection(records: records, categories: categories)
                    cashFlowSection(records: records)
                    budgetsSection(records: records, categoryByID: categoryByID)
                    recentSection(monthTransactions, categoryByID: categoryByID)
                    billsSection
                }
                .padding(.horizontal)
                .padding(.bottom, Theme.spacing)
            }
            .brandScreen()
            .navigationTitle("Home")
            .sheet(item: $editorRoute) { TransactionEditorView(route: $0) }
            .sheet(isPresented: $showAccountSetup) { AccountSetupView() }
            .sheet(isPresented: $showCheckIn) { MonthlyCheckInView() }
        }
    }

    private var monthSelector: some View {
        HStack {
            Button { withAnimation { model.moveMonth(by: -1) } } label: {
                Image(systemName: "chevron.left").padding(8)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(model.monthTitle).font(.headline)
            Spacer()
            Button { withAnimation { model.moveMonth(by: 1) } } label: {
                Image(systemName: "chevron.right").padding(8)
            }
            .accessibilityLabel("Next month")
        }
        .hero()
    }

    private func summaryGrid(_ s: PeriodSummary) -> some View {
        let ratio = s.expenseToIncomeRatio.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            SummaryCard(title: "Income", value: CurrencyMath.format(s.incomeMinorUnits, currencyCode: currency),
                        systemImage: "arrow.down.circle.fill", tint: Theme.income)
            SummaryCard(title: "Expenses", value: CurrencyMath.format(s.expenseMinorUnits, currencyCode: currency),
                        systemImage: "arrow.up.circle.fill", tint: Theme.expense)
            SummaryCard(title: "Net Cash Flow", value: CurrencyMath.format(s.netCashFlowMinorUnits, currencyCode: currency),
                        systemImage: "equal.circle.fill", tint: Theme.net)
            SummaryCard(title: "Spent of Income", value: ratio, systemImage: "percent", tint: .orange)
        }
    }

    private func verifiedSpendingCard(_ records: [TransactionRecord]) -> some View {
        let verified = Set(statementLines.filter { $0.status == .matched || $0.status == .created }.compactMap(\.matchedTransactionId))
        let c = ReconciliationSummaryService.coverage(records: records, verifiedIds: verified, range: model.range,
                                                      currencyCode: currency, calendar: app.finance.calendar)
        return NavigationLink { ReconciliationOverviewView() } label: {
            HStack {
                Label("\(c.percentVerified)% of this month's spending verified", systemImage: "checkmark.seal")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
    }

    private var accountSetupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Add your cards and cash", systemImage: "creditcard.and.123").font(.headline)
            Text("See spending by Wells Fargo debit, Capital One, Amex, cash, or whatever you use.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Set Up Accounts") { showAccountSetup = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button { editorRoute = .new(currencyCode: currency) } label: {
                Label("Add", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            Button { app.selectedTab = .scan } label: {
                Label("Import Receipt", systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func spendingSection(records: [TransactionRecord], categories: [SpendingCategory]) -> some View {
        let totals = app.finance.expensesByCategory(records, in: model.range, currencyCode: currency)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Spending by Category").font(.headline)
            if totals.isEmpty {
                Text("No spending recorded for \(model.monthTitle).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                CategoryChart(slices: ChartSlices.categories(totals, categories: categories), currencyCode: currency)
            }
        }
        .card()
    }

    private func cashFlowSection(records: [TransactionRecord]) -> some View {
        let flows = app.finance.monthlyFlows(records, endingWith: model.selectedMonth, count: 6, currencyCode: currency)
        let hasData = flows.contains { $0.incomeMinorUnits != 0 || $0.expenseMinorUnits != 0 }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Income vs. Expenses").font(.headline)
            Text("Last 6 months").font(.caption).foregroundStyle(.secondary)
            if hasData {
                MonthlyCashFlowChart(flows: flows, currencyCode: currency)
            } else {
                Text("No income or expenses in the last 6 months.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    @ViewBuilder
    private func recentSection(_ items: [MoneyTransaction], categoryByID: [UUID: SpendingCategory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Transactions").font(.headline)
            if items.isEmpty {
                Text("No transactions recorded for \(model.monthTitle).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(5)) { t in
                    TransactionRow(transaction: t, category: t.categoryId.flatMap { categoryByID[$0] })
                }
            }
        }
        .card()
    }

    private var billsSection: some View {
        let now = Date.now
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming Bills").font(.headline)
                Spacer()
                NavigationLink("All") { BillsView() }.font(.subheadline)
            }
            if bills.isEmpty {
                Text("No recurring bills. Unpaid bills are tracked separately and never counted as spending.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(bills.prefix(3)) { bill in
                    NavigationLink { BillDetailView(bill: bill) } label: { BillRow(bill: bill, now: now) }
                        .buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private func budgetsSection(records: [TransactionRecord], categoryByID: [UUID: SpendingCategory]) -> some View {
        let progress = app.budgetCalculator.progress(budgets: budgets.map(\.record), records: records, month: model.range.start)
        if !progress.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Budgets").font(.headline)
                    Spacer()
                    NavigationLink("All") { BudgetsView() }.font(.subheadline)
                }
                ForEach(progress.prefix(3)) { p in
                    BudgetProgressRow(progress: p, name: BudgetsView.name(p.budget, categoryByID.mapValues(\.name)))
                }
            }
            .card()
        }
    }
}
