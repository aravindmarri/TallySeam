import SwiftUI
import SwiftData

struct BillDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [MoneyTransaction]
    let bill: RecurringBill
    @State private var editing: BillEditorRoute?
    @State private var payingBill: RecurringBill?
    @State private var confirmDelete = false
    @State private var confirmSkip = false
    @State private var errorMessage: String?

    var body: some View {
        let payments = transactions.filter { $0.recurringBillId == bill.id }.sorted { $0.transactionDate > $1.transactionDate }
        let status = BillSchedule.status(dueDate: bill.nextDueDate, isActive: bill.isActive, now: .now, calendar: .current)
        List {
            Section {
                LabeledContent("Next due", value: bill.nextDueDate.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Status") {
                    Label(status.label, systemImage: status.symbol).foregroundStyle(BillRow.color(for: status))
                }
                LabeledContent("Expected", value: bill.expectedAmountMinorUnits
                    .map { CurrencyMath.format($0, currencyCode: bill.currencyCode) } ?? "Varies")
                LabeledContent("Repeats", value: repeatText)
                if let notes = bill.notes { Text(notes).foregroundStyle(.secondary) }
            }
            if bill.isActive {
                Section {
                    Button { payingBill = bill } label: { Label("Record Payment", systemImage: "checkmark.circle.fill") }
                    Button { confirmSkip = true } label: { Label("Skip This Payment", systemImage: "forward.end") }
                }
            }
            SubscriptionTypeSection(targetId: bill.id, categoryId: bill.categoryId, name: bill.title)
            paymentsSection(payments)
            Section {
                Button(bill.isActive ? "Pause Bill" : "Resume Bill") { setActive(!bill.isActive) }
                Button("Delete Bill", role: .destructive) { confirmDelete = true }
            }
        }
        .brandScreen()
        .navigationTitle(bill.title)
        .toolbar { Button("Edit") { editing = .edit(bill) } }
        .sheet(item: $editing) { BillEditorView(route: $0) }
        .sheet(item: $payingBill) { BillPaymentView(bill: $0) }
        .confirmationDialog("Skip this payment?", isPresented: $confirmSkip, titleVisibility: .visible) {
            Button("Skip to Next Due Date") { run { try app.bills.skipPeriod(billId: bill.id) } }
        } message: { Text("No transaction is recorded. The bill moves to its next due date.") }
        .confirmationDialog("Delete \(bill.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Bill", role: .destructive) {
                // Leave the screen first so nothing reads the bill after it is deleted.
                let id = bill.id, bills = app.bills
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    try? bills.delete(id: id)
                }
            }
        } message: { Text("Payments you already recorded stay in your transactions.") }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var repeatText: String {
        if bill.recurrenceRule == .custom, let n = bill.customIntervalDays { return "Every \(n) days" }
        return bill.recurrenceRule.displayName
    }

    @ViewBuilder
    private func paymentsSection(_ payments: [MoneyTransaction]) -> some View {
        Section("Payments") {
            if payments.isEmpty {
                Text("No payments recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(payments) { t in
                    LabeledContent(t.transactionDate.formatted(date: .abbreviated, time: .omitted),
                                   value: CurrencyMath.format(t.amountMinorUnits, currencyCode: t.currencyCode))
                }
            }
        }
    }

    private func setActive(_ active: Bool) { run { try app.bills.setActive(active, billId: bill.id) } }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// Records a bill payment: a new expense, or an expense that is already recorded.
struct BillPaymentView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case new = "New Expense", existing = "Existing Expense"
        var id: String { rawValue }
    }

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \PaymentMethod.createdAt) private var methods: [PaymentMethod]
    let bill: RecurringBill
    @State private var mode: Mode = .new
    @State private var amountText: String
    @State private var date = Date.now
    @State private var paymentMethodId: UUID?
    @State private var selectedTransactionId: UUID?
    @State private var errorMessage: String?

    init(bill: RecurringBill) {
        self.bill = bill
        _amountText = State(initialValue: bill.expectedAmountMinorUnits
            .map { TransactionDraft.editableAmount($0, currencyCode: bill.currencyCode) } ?? "")
        _paymentMethodId = State(initialValue: bill.paymentMethodId)
    }

    private var amount: Int64? {
        guard let v = CurrencyMath.parse(amountText, currencyCode: bill.currencyCode), v > 0 else { return nil }
        return v
    }

    private var candidates: [TransactionRecord] {
        BillSchedule.paymentCandidates(transactions.map(\.record), dueDate: bill.nextDueDate,
                                       expectedAmount: bill.expectedAmountMinorUnits, currencyCode: bill.currencyCode,
                                       calendar: .current)
    }

    private var canSave: Bool { mode == .new ? amount != nil : selectedTransactionId != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Record as", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if mode == .new { newSection } else { existingSection }
                Section {
                    Text("The bill then moves to its next due date. Only the payment is counted as spending.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .brandScreen()
            .navigationTitle("Pay \(bill.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .alert("Couldn't Record Payment", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var newSection: some View {
        Section("Payment") {
            HStack {
                TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                Text(bill.currencyCode).foregroundStyle(.secondary)
            }
            DatePicker("Paid on", selection: $date, displayedComponents: .date)
            Picker("Paid with", selection: $paymentMethodId) {
                Text("Not specified").tag(UUID?.none)
                ForEach(methods.filter { $0.isActive || $0.id == paymentMethodId }) { (m: PaymentMethod) in
                    Text(m.name).tag(UUID?.some(m.id))
                }
            }
        }
    }

    @ViewBuilder
    private var existingSection: some View {
        Section {
            if candidates.isEmpty {
                Text("No unlinked \(bill.currencyCode) expenses within 10 days of the due date.").foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { r in
                    Button { selectedTransactionId = r.id } label: { candidateRow(r) }
                }
            }
        } header: {
            Text("Choose the expense")
        } footer: {
            Text("Use this when the payment is already recorded, for example from a receipt, so it isn't counted twice.")
        }
    }

    private func candidateRow(_ r: TransactionRecord) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(r.title).foregroundStyle(.primary)
                Text(r.transactionDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(CurrencyMath.format(r.amountMinorUnits, currencyCode: r.currencyCode)).monospacedDigit().foregroundStyle(.primary)
            if selectedTransactionId == r.id {
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
            }
        }
    }

    private func save() {
        let payment: BillPayment
        if mode == .new {
            guard let amount else { return }
            payment = .newTransaction(amountMinorUnits: amount, date: date, paymentMethodId: paymentMethodId)
        } else {
            guard let id = selectedTransactionId else { return }
            payment = .existingTransaction(id: id)
        }
        do {
            try app.bills.markPaid(billId: bill.id, payment: payment)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
