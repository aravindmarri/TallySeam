import SwiftUI
import SwiftData

// MARK: - Shared helpers

private extension Int64 {
    func money(_ code: String) -> String { CurrencyMath.format(self, currencyCode: code) }
}

/// "Sai owes you $20.00" / "You owe Sai $15.00" / "Settled".
enum BalanceText {
    static func text(_ name: String, _ balance: Int64, _ code: String) -> String {
        if balance > 0 { return "\(name) owes you \(balance.money(code))" }
        if balance < 0 { return "You owe \(name) \((-balance).money(code))" }
        return "\(name) · settled"
    }
    static func color(_ balance: Int64) -> Color { balance > 0 ? Theme.income : (balance < 0 ? Theme.expense : .secondary) }
}

// MARK: - Home card

/// Shows who owes whom on Home, only when something is outstanding.
struct OwedToMeCard: View {
    @Query(sort: \SplitPerson.name) private var people: [SplitPerson]
    @Query private var shares: [TransactionSplit]
    @Query private var ledger: [SplitLedgerEntry]
    @Query private var transactions: [MoneyTransaction]
    let currencyCode: String

    var body: some View {
        let balances = SplitMath.balances(splits: shares.map(\.value), ledger: ledger.map(\.value),
                                          transactions: transactions.map(\.record), currencyCode: currencyCode)
        let open: [(SplitPerson, Int64)] = people.compactMap { p -> (SplitPerson, Int64)? in
            guard let b = balances[p.id], b != 0 else { return nil }
            return (p, b)
        }
        if !open.isEmpty {
            let owedToMe = open.map(\.1).filter { $0 > 0 }.reduce(0, +)
            let iOwe = -open.map(\.1).filter { $0 < 0 }.reduce(0, +)
            NavigationLink { SplitsView() } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Splits", systemImage: "person.2.fill").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) {
                            Text("Owed to you").font(.caption).foregroundStyle(.secondary)
                            Text(owedToMe.money(currencyCode)).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.income)
                        }
                        VStack(alignment: .leading) {
                            Text("You owe").font(.caption).foregroundStyle(.secondary)
                            Text(iOwe.money(currencyCode)).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(iOwe > 0 ? Theme.expense : .secondary)
                        }
                    }
                    ForEach(Array(open.prefix(3)), id: \.0.id) { item in
                        Text(BalanceText.text(item.0.name, item.1, currencyCode)).font(.subheadline).foregroundStyle(BalanceText.color(item.1))
                    }
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - People and balances

struct SplitsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \SplitPerson.name) private var people: [SplitPerson]
    @Query private var shares: [TransactionSplit]
    @Query private var ledger: [SplitLedgerEntry]
    @Query private var transactions: [MoneyTransaction]
    @Query private var settings: [AppSettings]
    @State private var newName = ""
    @State private var paymentRoute: SplitPaymentRoute?
    @State private var errorMessage: String?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        let balances = SplitMath.balances(splits: shares.map(\.value), ledger: ledger.map(\.value),
                                          transactions: transactions.map(\.record), currencyCode: currency)
        List {
            Section {
                Text("Split an expense from its transaction screen. Only your share counts in reports and budgets, and money paid back to you isn't counted as income.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("People") {
                ForEach(people.filter(\.isActive)) { p in
                    NavigationLink { SplitPersonView(personID: p.id) } label: {
                        HStack {
                            Label(p.name, systemImage: "person.crop.circle")
                            Spacer()
                            Text(balanceLabel(balances[p.id] ?? 0)).font(.subheadline.monospacedDigit())
                                .foregroundStyle(BalanceText.color(balances[p.id] ?? 0))
                        }
                    }
                }
                HStack {
                    TextField("Add a person", text: $newName).submitLabel(.done).onSubmit(addPerson)
                    Button("Add", action: addPerson).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !people.filter(\.isActive).isEmpty {
                Section {
                    Button { paymentRoute = .new(personId: nil) } label: { Label("Record a Payment or IOU", systemImage: "arrow.left.arrow.right") }
                }
            }
        }
        .brandScreen()
        .navigationTitle("Splits")
        .sheet(item: $paymentRoute) { SplitPaymentView(route: $0) }
        .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func balanceLabel(_ b: Int64) -> String {
        b > 0 ? "owes you \(b.money(currency))" : (b < 0 ? "you owe \((-b).money(currency))" : "settled")
    }

    private func addPerson() {
        do { try app.splits.addPerson(name: newName); newName = "" } catch { errorMessage = error.localizedDescription }
    }
}

/// One person: balance, shared expenses and payments.
struct SplitPersonView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var match: [SplitPerson]
    @Query private var shares: [TransactionSplit]
    @Query(sort: \SplitLedgerEntry.date, order: .reverse) private var ledger: [SplitLedgerEntry]
    @Query private var transactions: [MoneyTransaction]
    @Query private var settings: [AppSettings]
    @State private var paymentRoute: SplitPaymentRoute?
    @State private var renaming = false
    @State private var name = ""
    @State private var errorMessage: String?
    private let personID: UUID

    init(personID: UUID) {
        self.personID = personID
        _match = Query(filter: #Predicate<SplitPerson> { $0.id == personID })
    }

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    var body: some View {
        if let p = match.first {
            content(p)
        } else {
            ContentUnavailableView("Person Removed", systemImage: "person.slash")
        }
    }

    private func content(_ p: SplitPerson) -> some View {
        let mine = shares.filter { $0.personId == p.id }
        let entries = ledger.filter { $0.personId == p.id }
        let byId = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let balance = SplitMath.balances(splits: mine.map(\.value), ledger: entries.map(\.value),
                                         transactions: transactions.map(\.record), currencyCode: currency)[p.id] ?? 0
        return List {
            Section {
                Text(BalanceText.text(p.name, balance, currency))
                    .font(.title3.weight(.semibold)).foregroundStyle(BalanceText.color(balance))
                Button { paymentRoute = .new(personId: p.id) } label: { Label("Record a Payment or IOU", systemImage: "arrow.left.arrow.right") }
            }
            Section("Shared Expenses") {
                let rows: [(TransactionSplit, MoneyTransaction)] = mine.compactMap { s -> (TransactionSplit, MoneyTransaction)? in
                    byId[s.transactionId].map { (s, $0) }
                }.sorted { $0.1.transactionDate > $1.1.transactionDate }
                if rows.isEmpty { Text("No shared expenses yet.").foregroundStyle(.secondary) }
                ForEach(rows, id: \.0.id) { row in
                    let s = row.0, t = row.1
                    NavigationLink { TransactionDetailView(transactionID: t.id) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(t.merchant ?? t.title).lineLimit(1)
                                Text(t.transactionDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(s.shareMinorUnits.money(t.currencyCode)) of \(t.amountMinorUnits.money(t.currencyCode))")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Payments and IOUs") {
                if entries.isEmpty { Text("Nothing recorded yet.").foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.kind.displayName)
                            Text([e.date.formatted(date: .abbreviated, time: .omitted), e.note, e.linkedTransactionId == nil ? nil : "linked to a transaction"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(e.amountMinorUnits.money(e.currencyCode)).monospacedDigit()
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            do { try app.splits.deleteEntry(e) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            Section {
                Button("Rename") { name = p.name; renaming = true }
                Button("Remove from Lists", role: .destructive) {
                    do { try app.splits.archivePerson(p); dismiss() } catch { errorMessage = error.localizedDescription }
                }
            } footer: {
                Text("Removing hides \(p.name) from pickers. Shared expenses and payments are kept.")
            }
        }
        .brandScreen()
        .navigationTitle(p.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $paymentRoute) { SplitPaymentView(route: $0) }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") { do { try app.splits.renamePerson(p, to: name) } catch { errorMessage = error.localizedDescription } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

// MARK: - Record a payment or IOU

enum SplitPaymentRoute: Identifiable {
    case new(personId: UUID?)
    var id: String {
        switch self {
        case .new(let p): p?.uuidString ?? "new"
        }
    }
}

struct SplitPaymentView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SplitPerson.name) private var people: [SplitPerson]
    @Query(sort: \MoneyTransaction.transactionDate, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var ledger: [SplitLedgerEntry]
    @Query private var settings: [AppSettings]
    @State private var personId: UUID?
    @State private var kind: SplitLedgerKind = .theyPaidMe
    @State private var amountText = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var linkedId: UUID?
    @State private var errorMessage: String?

    init(route: SplitPaymentRoute) {
        if case .new(let p) = route { _personId = State(initialValue: p) }
    }

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }
    private var amount: Int64? { CurrencyMath.parse(amountText, currencyCode: currency) }

    /// Transactions this payment could be: money in for "they paid me", money out for "I paid them".
    private var linkCandidates: [MoneyTransaction] {
        let used = Set(ledger.compactMap(\.linkedTransactionId))
        let type: TransactionType? = kind == .theyPaidMe ? .income : (kind == .iPaidThem ? .expense : nil)
        guard let type else { return [] }
        return transactions.filter { $0.transactionType == type && $0.currencyCode == currency && !used.contains($0.id) }.prefix(40).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Person", selection: $personId) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(people.filter(\.isActive)) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("What happened", selection: $kind) {
                        ForEach(SplitLedgerKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Amount (\(currency))") {
                        TextField("0", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                } footer: {
                    switch kind {
                    case .theyPaidMe: Text("Lowers what they owe you.")
                    case .iPaidThem: Text("Lowers what you owe them.")
                    case .iOwe: Text("They paid for something of yours. Your share counts as spending when you pay them back.")
                    }
                }
                if kind != .iOwe {
                    Section {
                        Picker("Transaction", selection: $linkedId) {
                            Text("None").tag(UUID?.none)
                            ForEach(linkCandidates) { t in
                                Text("\(t.transactionDate.formatted(date: .abbreviated, time: .omitted)) · \(t.merchant ?? t.title) · \(t.amountMinorUnits.money(t.currencyCode))")
                                    .tag(UUID?.some(t.id))
                            }
                        }
                    } header: { Text("Link to a Transaction") } footer: {
                        Text(kind == .theyPaidMe
                             ? "Pick the Zelle or transfer you received, so it isn't counted as income."
                             : "Pick the payment you made, if it's recorded.")
                    }
                }
            }
            .brandScreen()
            .navigationTitle("Record Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(personId == nil || amount == nil) }
            }
            .onChange(of: kind) { _, _ in linkedId = nil }
            .onChange(of: linkedId) { _, id in
                if amountText.isEmpty, let t = transactions.first(where: { $0.id == id }) {
                    amountText = TransactionDraft.editableAmount(t.amountMinorUnits, currencyCode: t.currencyCode)
                }
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard let personId, let amount else { return }
        do {
            try app.splits.record(kind: kind, personId: personId, amountMinorUnits: amount, currencyCode: currency, date: date,
                                  note: note, linkedTransactionId: kind == .iOwe ? nil : linkedId)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Split an expense

struct SplitEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SplitPerson.name) private var people: [SplitPerson]
    let transaction: TransactionRecord
    @State private var selected: Set<UUID> = []
    @State private var includeMe = true
    @State private var equal = true
    @State private var customText: [UUID: String] = [:]
    @State private var newName = ""
    @State private var loaded = false
    @State private var errorMessage: String?

    private var code: String { transaction.currencyCode }
    private var chosen: [SplitPerson] { people.filter { selected.contains($0.id) } }

    /// Other people's shares, or nil while the custom amounts don't make sense.
    private var shares: [UUID: Int64]? {
        if equal {
            let count = chosen.count + (includeMe ? 1 : 0)
            let all = SplitMath.equalShares(total: transaction.amountMinorUnits, count: count)
            guard !all.isEmpty else { return [:] }
            // The user takes the first (possibly one cent larger) share; others split the rest in order.
            let theirs = includeMe ? Array(all.dropFirst()) : all
            return Dictionary(uniqueKeysWithValues: zip(chosen.map(\.id), theirs))
        }
        var out: [UUID: Int64] = [:]
        for p in chosen {
            guard let v = CurrencyMath.parse(customText[p.id] ?? "", currencyCode: code) else { return nil }
            out[p.id] = v
        }
        return out.values.reduce(0, +) <= transaction.amountMinorUnits ? out : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Expense", value: transaction.merchant ?? transaction.title)
                    LabeledContent("Total", value: transaction.amountMinorUnits.money(code))
                }
                Section("Split With") {
                    ForEach(people.filter { $0.isActive || selected.contains($0.id) }) { p in
                        Button { toggle(p.id) } label: {
                            HStack {
                                Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(p.id) ? Theme.brand : .secondary)
                                Text(p.name).foregroundStyle(.primary)
                            }
                        }
                    }
                    HStack {
                        TextField("Add a person", text: $newName).submitLabel(.done).onSubmit(addPerson)
                        Button("Add", action: addPerson).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !chosen.isEmpty {
                    Section {
                        Picker("How", selection: $equal) {
                            Text("Equally").tag(true)
                            Text("By amount").tag(false)
                        }
                        .pickerStyle(.segmented)
                        if equal { Toggle("Include me", isOn: $includeMe) }
                        ForEach(chosen) { p in
                            if equal {
                                LabeledContent(p.name, value: (shares?[p.id] ?? 0).money(code))
                            } else {
                                LabeledContent(p.name) {
                                    TextField("0", text: Binding(get: { customText[p.id] ?? "" }, set: { customText[p.id] = $0 }))
                                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        if let s = shares {
                            LabeledContent("Your share", value: SplitMath.myShare(amount: transaction.amountMinorUnits, others: Array(s.values)).money(code))
                                .fontWeight(.semibold)
                        } else {
                            Text("Other people's shares add up to more than the total.").font(.footnote).foregroundStyle(Theme.expense)
                        }
                    } footer: {
                        Text("Only your share counts in reports and budgets. The full amount stays on the transaction so it still matches your statement.")
                    }
                }
            }
            .brandScreen()
            .navigationTitle("Split Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(shares == nil) }
            }
            .onAppear(perform: load)
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func addPerson() {
        do { let p = try app.splits.addPerson(name: newName); selected.insert(p.id); newName = "" }
        catch { errorMessage = error.localizedDescription }
    }

    /// Opens an existing split as custom amounts so nothing shifts by a cent.
    private func load() {
        guard !loaded else { return }
        loaded = true
        let existing = (try? app.splits.shares(for: transaction.id)) ?? []
        guard !existing.isEmpty else { return }
        selected = Set(existing.map(\.personId))
        equal = false
        for s in existing { customText[s.personId] = TransactionDraft.editableAmount(s.shareMinorUnits, currencyCode: code) }
    }

    private func save() {
        guard let s = shares else { return }
        do { try app.splits.setSplit(transaction: transaction, shares: s); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

/// The split on a transaction's detail screen.
struct TransactionSplitSection: View {
    @Environment(AppContainer.self) private var app
    @Query private var shares: [TransactionSplit]
    @Query private var people: [SplitPerson]
    let record: TransactionRecord
    @State private var editing = false
    @State private var errorMessage: String?

    init(record: TransactionRecord) {
        self.record = record
        let id = record.id
        _shares = Query(filter: #Predicate<TransactionSplit> { $0.transactionId == id })
    }

    var body: some View {
        if record.transactionType == .expense && !record.isRefund {
            Section("Split") {
                if shares.isEmpty {
                    Button { editing = true } label: { Label("Split This Expense", systemImage: "person.2") }
                } else {
                    let names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                    LabeledContent("Your share",
                                   value: SplitMath.myShare(amount: record.amountMinorUnits, others: shares.map(\.shareMinorUnits)).money(record.currencyCode))
                    ForEach(shares) { s in
                        LabeledContent(names[s.personId] ?? "Someone", value: s.shareMinorUnits.money(record.currencyCode))
                    }
                    Button("Edit Split") { editing = true }
                    Button("Remove Split", role: .destructive) {
                        do { try app.splits.removeSplit(transactionId: record.id) } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            .sheet(isPresented: $editing) { SplitEditorView(transaction: record) }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
}
