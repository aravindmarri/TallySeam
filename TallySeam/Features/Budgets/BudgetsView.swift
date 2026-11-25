import SwiftUI
import SwiftData

/// Monthly budgets with progress for the selected month.
struct BudgetsView: View {
    @Environment(AppContainer.self) private var app
    @Query private var budgets: [Budget]
    @Query private var transactions: [MoneyTransaction]
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @Query private var settings: [AppSettings]
    @Query private var splitShares: [TransactionSplit]
    @Query private var splitLedger: [SplitLedgerEntry]
    @State private var month = Calendar.current.monthRange(containing: .now).start
    @State private var editing: BudgetEditorRoute?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        Group {
            if budgets.isEmpty {
                EmptyStateView(title: "No Budgets", systemImage: "gauge.with.dots.needle.33percent",
                               message: "Set a monthly limit overall or per category to track progress.",
                               actionTitle: "Add Budget") { editing = .new(currencyCode: currency) }
            } else {
                list
            }
        }
        .brandScreen()
        .navigationTitle("Budgets")
        .toolbar {
            Button { editing = .new(currencyCode: currency) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add budget")
        }
        .sheet(item: $editing) { BudgetEditorView(route: $0) }
    }

    private var list: some View {
        let progress = DiagnosticsService.shared.measure(.calculation) {
            app.budgetCalculator.progress(
                budgets: budgets.map(\.record),
                records: SplitMath.personalRecords(transactions.map(\.record), splits: splitShares.map(\.value), ledger: splitLedger.map(\.value)),
                month: month)
        }
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let paused = budgets.filter { !$0.isActive }
        return List {
            Section { monthSelector }
            Section("This Month") {
                if progress.isEmpty {
                    Text("No active budgets apply to this month.").foregroundStyle(.secondary)
                }
                ForEach(progress) { p in
                    Button { edit(p.budget.id) } label: { BudgetProgressRow(progress: p, name: Self.name(p.budget, names)) }
                }
            }
            if !paused.isEmpty {
                Section("Paused") {
                    ForEach(paused) { b in
                        Button { editing = .edit(b) } label: {
                            LabeledContent(Self.name(b.record, names), value: CurrencyMath.format(b.amountMinorUnits, currencyCode: b.currencyCode))
                        }
                    }
                }
            }
            Section {
                Text("Progress counts expenses minus refunds in each budget's currency. Transfers, card repayments and unpaid bills are not counted.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var monthSelector: some View {
        HStack {
            Button { month = Calendar.current.addingMonths(-1, to: month) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Spacer()
            Text(month, format: .dateTime.month(.wide).year()).font(.headline)
            Spacer()
            Button { month = Calendar.current.addingMonths(1, to: month) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
    }

    private func edit(_ id: UUID) {
        if let b = budgets.first(where: { $0.id == id }) { editing = .edit(b) }
    }

    static func name(_ b: BudgetRecord, _ names: [UUID: String]) -> String {
        guard let id = b.categoryId else { return "All Spending" }
        return names[id] ?? "Deleted Category"
    }
}

struct BudgetProgressRow: View {
    let progress: BudgetProgress
    let name: String

    private var tint: Color {
        switch progress.status {
        case .onTrack: .green
        case .nearLimit: .orange
        case .over: .red
        }
    }

    private var code: String { progress.budget.currencyCode }

    private var remainingText: String {
        let r = progress.remainingMinorUnits
        return r >= 0 ? "\(CurrencyMath.format(r, currencyCode: code)) left"
                      : "\(CurrencyMath.format(-r, currencyCode: code)) over"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                Text(remainingText).font(.subheadline).foregroundStyle(progress.status == .over ? .red : .secondary)
            }
            ProgressView(value: min(progress.fraction, 1)).tint(tint)
            Text("\(CurrencyMath.format(max(progress.spentMinorUnits, 0), currencyCode: code)) of \(CurrencyMath.format(progress.budget.amountMinorUnits, currencyCode: code))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) budget")
        .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent used, \(remainingText)")
    }
}

enum BudgetEditorRoute: Identifiable {
    case new(currencyCode: String)
    case edit(Budget)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let b): b.id.uuidString
        }
    }
}

struct BudgetEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @State private var draft: BudgetDraft
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    init(route: BudgetEditorRoute) {
        switch route {
        case .new(let code):
            _draft = State(initialValue: BudgetDraft(currencyCode: code))
        case .edit(let b):
            var d = BudgetDraft(currencyCode: b.currencyCode)
            d.editingId = b.id; d.categoryId = b.categoryId; d.isActive = b.isActive
            d.amountText = TransactionDraft.editableAmount(b.amountMinorUnits, currencyCode: b.currencyCode)
            _draft = State(initialValue: d)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Monthly Limit") {
                    Picker("Applies to", selection: $draft.categoryId) {
                        Text("All Spending").tag(UUID?.none)
                        ForEach(categories.filter { $0.kind == .expense }) { (c: SpendingCategory) in
                            Label(c.name, systemImage: c.symbol).tag(UUID?.some(c.id))
                        }
                    }
                    HStack {
                        TextField("Amount", text: $draft.amountText).keyboardType(.decimalPad)
                        Picker("Currency", selection: $draft.currencyCode) {
                            ForEach(CurrencyMath.supportedCodes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    Toggle("Active", isOn: $draft.isActive)
                }
                if draft.editingId != nil {
                    Section {
                        Button("Delete Budget", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deleting a budget removes only the limit. Your transactions are not changed.")
                    }
                }
            }
            .brandScreen()
            .navigationTitle(draft.editingId == nil ? "New Budget" : "Edit Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(draft.amountMinorUnits == nil)
                }
            }
            .confirmationDialog("Delete this budget?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Budget", role: .destructive, action: delete)
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        do {
            try app.budgets.save(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let id = draft.editingId else { return }
        do {
            try app.budgets.delete(id: id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
