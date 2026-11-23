import SwiftUI
import SwiftData

/// "Type" row for a transaction or bill in the Subscriptions category, with a suggestion from its name.
struct SubscriptionTypeSection: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \SubscriptionType.displayOrder) private var types: [SubscriptionType]
    @Query private var links: [SubscriptionLink]
    @Query private var categories: [SpendingCategory]
    let targetId: UUID
    let categoryId: UUID?
    let name: String
    @State private var errorMessage: String?

    init(targetId: UUID, categoryId: UUID?, name: String) {
        self.targetId = targetId; self.categoryId = categoryId; self.name = name
        _links = Query(filter: #Predicate<SubscriptionLink> { $0.targetId == targetId })
    }

    private var isSubscription: Bool {
        guard let id = categoryId, let c = categories.first(where: { $0.id == id }) else { return false }
        return SubscriptionMath.isSubscriptionCategory(name: c.name, symbol: c.symbol, kind: c.kind)
    }

    var body: some View {
        if isSubscription {
            let current = links.first?.typeId
            let suggested = SubscriptionMath.suggestedTypeName(for: name).flatMap { n in types.first { $0.name == n } }
            Section {
                Picker("Type", selection: Binding(get: { current }, set: { set($0) })) {
                    Text("Not set").tag(UUID?.none)
                    ForEach(types) { Label($0.name, systemImage: $0.symbol).tag(UUID?.some($0.id)) }
                }
                if current == nil, let s = suggested {
                    Button { set(s.id) } label: { Label("Use suggestion: \(s.name)", systemImage: "sparkles") }
                }
            } header: { Text("Subscription") } footer: {
                Text("Groups this with similar subscriptions on the Subscriptions page.")
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func set(_ id: UUID?) {
        do { try app.subscriptions.setType(id, for: targetId) } catch { errorMessage = error.localizedDescription }
    }
}

/// Subscriptions grouped by type: what they cost each month and year, and this month's spending.
struct SubscriptionsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \SubscriptionType.displayOrder) private var types: [SubscriptionType]
    @Query private var links: [SubscriptionLink]
    @Query private var categories: [SpendingCategory]
    @Query(filter: #Predicate<RecurringBill> { $0.isActive }, sort: \RecurringBill.title) private var bills: [RecurringBill]
    @Query private var transactions: [MoneyTransaction]
    @Query private var settings: [AppSettings]
    @State private var newType = ""
    @State private var renaming: SubscriptionType?
    @State private var renameText = ""
    @State private var errorMessage: String?

    private var currency: String { settings.first?.preferredCurrencyCode ?? CurrencyMath.defaultCode }

    private struct SubGroup: Identifiable {
        let id: String
        let name: String
        let symbol: String
        var monthly: Int64 = 0
        var varies = 0
        var bills: [RecurringBill] = []
        var spentThisMonth: Int64 = 0
    }

    var body: some View {
        let subscriptionCategoryIds = Set(categories.filter { SubscriptionMath.isSubscriptionCategory(name: $0.name, symbol: $0.symbol, kind: $0.kind) }.map(\.id))
        let typeOf = Dictionary(links.map { ($0.targetId, $0.typeId) }, uniquingKeysWith: { a, _ in a })
        let groups = makeGroups(subscriptionCategoryIds: subscriptionCategoryIds, typeOf: typeOf)
        let totalMonthly = groups.map(\.monthly).reduce(0, +)

        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recurring subscriptions").font(.subheadline).opacity(0.85)
                    Text("\(CurrencyMath.format(totalMonthly, currencyCode: currency)) / month")
                        .font(.title.weight(.bold).monospacedDigit())
                    Text("\(CurrencyMath.format(totalMonthly * 12, currencyCode: currency)) / year").font(.subheadline.monospacedDigit()).opacity(0.85)
                }
                .hero()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("From active recurring bills in the Subscriptions category. Bills whose amount varies aren't included in the totals.")
            }
            ForEach(groups) { g in
                Section {
                    if g.bills.isEmpty && g.spentThisMonth == 0 {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                    ForEach(g.bills) { b in
                        NavigationLink { BillDetailView(bill: b) } label: {
                            HStack {
                                Text(b.title).lineLimit(1)
                                Spacer()
                                Text(billText(b)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if g.spentThisMonth > 0 {
                        LabeledContent("Spent this month", value: CurrencyMath.format(g.spentThisMonth, currencyCode: currency))
                    }
                } header: {
                    HStack {
                        Label(g.name, systemImage: g.symbol)
                        Spacer()
                        if g.monthly > 0 {
                            Text("\(CurrencyMath.format(g.monthly, currencyCode: currency))/mo · \(CurrencyMath.format(g.monthly * 12, currencyCode: currency))/yr")
                                .monospacedDigit()
                        }
                    }
                }
            }
            Section {
                ForEach(types) { t in
                    Label(t.name, systemImage: t.symbol)
                        .swipeActions {
                            Button("Delete", role: .destructive) { run { try app.subscriptions.deleteType(t) } }
                            Button("Rename") { renameText = t.name; renaming = t }
                        }
                }
                HStack {
                    TextField("Add a type", text: $newType).submitLabel(.done).onSubmit(addType)
                    Button("Add", action: addType).disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Types") } footer: {
                Text("Swipe a type to rename or delete it. Deleting a type only removes the grouping; transactions and bills stay as they are. Set a type from a transaction or bill in the Subscriptions category.")
            }
        }
        .brandScreen()
        .navigationTitle("Subscriptions")
        .alert("Rename Type", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let t = renaming { run { try app.subscriptions.renameType(t, to: renameText) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func makeGroups(subscriptionCategoryIds: Set<UUID>, typeOf: [UUID: UUID]) -> [SubGroup] {
        var groups: [String: SubGroup] = [:]
        for t in types { groups[t.id.uuidString] = SubGroup(id: t.id.uuidString, name: t.name, symbol: t.symbol) }
        let other = "unsorted"
        func key(_ target: UUID) -> String {
            if let type = typeOf[target], groups[type.uuidString] != nil { return type.uuidString }
            if groups[other] == nil { groups[other] = SubGroup(id: other, name: "Not sorted", symbol: "questionmark.circle") }
            return other
        }
        for b in bills where b.currencyCode == currency && b.categoryId.map(subscriptionCategoryIds.contains) == true {
            let k = key(b.id)
            groups[k]?.bills.append(b)
            if let m = SubscriptionMath.monthlyAmount(expected: b.expectedAmountMinorUnits, rule: b.recurrenceRule, customDays: b.customIntervalDays) {
                groups[k]?.monthly += m
            } else {
                groups[k]?.varies += 1
            }
        }
        let range = app.finance.calendar.monthRange(containing: .now)
        for t in transactions where t.transactionType == .expense && t.currencyCode == currency
            && t.categoryId.map(subscriptionCategoryIds.contains) == true
            && range.contains(t.record.reportingDate(in: app.finance.calendar)) {
            let k = key(t.id)
            groups[k]?.spentThisMonth += t.isRefund ? -t.amountMinorUnits : t.amountMinorUnits
        }
        let order = Dictionary(uniqueKeysWithValues: types.map { ($0.id.uuidString, $0.displayOrder) })
        return groups.values
            .filter { !$0.bills.isEmpty || $0.spentThisMonth != 0 || $0.id != other }
            .sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }

    private func billText(_ b: RecurringBill) -> String {
        guard let amount = b.expectedAmountMinorUnits else { return "varies" }
        return "\(CurrencyMath.format(amount, currencyCode: b.currencyCode)) \(b.recurrenceRule.displayName.lowercased())"
    }

    private func addType() {
        run { try app.subscriptions.addType(name: newType); newType = "" }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}
