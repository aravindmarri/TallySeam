import SwiftUI
import SwiftData

/// Looks the transaction up by id, so the view stays safe after the record is deleted.
struct TransactionDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [MoneyTransaction]
    @Query private var categories: [SpendingCategory]
    @Query private var methods: [PaymentMethod]
    @State private var editorRoute: TransactionEditorRoute?
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var showReceipt = false

    init(transactionID: UUID) {
        _matches = Query(filter: #Predicate<MoneyTransaction> { $0.id == transactionID })
    }

    var body: some View {
        Group {
            if let t = matches.first {
                content(t)
            } else {
                ContentUnavailableView("Transaction Deleted", systemImage: "trash")
            }
        }
        .sheet(item: $editorRoute) { TransactionEditorView(route: $0) }
        .alert("Something Went Wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func methodName(_ id: UUID?) -> String? {
        guard let id, let m = methods.first(where: { $0.id == id }) else { return nil }
        return m.lastFourDigits.map { "\(m.name) •••• \($0)" } ?? m.name
    }

    private func content(_ t: MoneyTransaction) -> some View {
        let record = t.record
        let category = t.categoryId.flatMap { id in categories.first { $0.id == id } }
        return List {
            headerSection(t)
            detailsSection(t, category: category)
            if let receiptId = t.receiptId {
                receiptSection(receiptId)
            }
            TransactionSplitSection(record: record)
            SubscriptionTypeSection(targetId: t.id, categoryId: t.categoryId, name: t.merchant ?? t.title)
            if let notes = t.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
            timestampsSection(t)
            actionsSection(record)
        }
        .brandScreen()
        .navigationTitle(t.merchant ?? t.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { editorRoute = .edit(record) }
        }
        .confirmationDialog("Delete Transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try app.transactions.delete(id: record.id)
                    dismiss()
                } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: Sections

    private func headerSection(_ t: MoneyTransaction) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(CurrencyMath.format(t.amountMinorUnits, currencyCode: t.currencyCode))
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                Label(typeLabel(t), systemImage: t.transactionType.symbol)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func typeLabel(_ t: MoneyTransaction) -> String {
        t.transactionType.displayName + (t.isRefund ? " · Refund" : "")
    }

    private func detailsSection(_ t: MoneyTransaction, category: SpendingCategory?) -> some View {
        Section("Details") {
            LabeledContent("Title", value: t.title)
            if let m = t.merchant {
                LabeledContent("Merchant", value: m)
            }
            LabeledContent("Date", value: t.transactionDate.formatted(date: .long, time: .omitted))
            if t.record.isCountedInOtherMonth(calendar: .current) {
                LabeledContent("Counts in", value: t.record.reportingDate(in: .current).formatted(.dateTime.month(.wide).year()))
            }
            if t.transactionType.categoryKind != nil {
                LabeledContent("Category", value: category?.name ?? "Uncategorized")
            }
            paymentRows(t)
            LabeledContent("Source", value: t.source.displayName)
        }
    }

    @ViewBuilder
    private func paymentRows(_ t: MoneyTransaction) -> some View {
        let notSpecified = "Not specified"
        if t.transactionType == .transfer {
            LabeledContent("From", value: methodName(t.paymentMethodId) ?? notSpecified)
            LabeledContent("To", value: methodName(t.transferDestinationPaymentMethodId) ?? notSpecified)
        } else {
            LabeledContent("Payment", value: methodName(t.paymentMethodId) ?? notSpecified)
        }
    }

    private func receiptSection(_ receiptId: UUID) -> some View {
        let image = app.receipts.imageData(forReceipt: receiptId).flatMap(UIImage.init(data:))
        return Section("Receipt") {
            if let image {
                Button { showReceipt = true } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Receipt image. Double-tap to enlarge.")
                .fullScreenCover(isPresented: $showReceipt) {
                    NavigationStack {
                        ScrollView([.vertical, .horizontal]) {
                            Image(uiImage: image).resizable().scaledToFit().frame(minWidth: 300)
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showReceipt = false } }
                        }
                    }
                }
            } else {
                Label("Receipt image unavailable", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timestampsSection(_ t: MoneyTransaction) -> some View {
        Section {
            LabeledContent("Recorded", value: t.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Last edited", value: t.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.footnote)
    }

    private func actionsSection(_ record: TransactionRecord) -> some View {
        Section {
            Button {
                editorRoute = .duplicate(record)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Transaction", systemImage: "trash")
            }
        }
    }
}
