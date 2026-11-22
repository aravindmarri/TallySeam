import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var settings: [AppSettings]

    var body: some View {
        NavigationStack {
            List {
                Section("Organize") {
                    NavigationLink { CategoriesView() } label: { Label("Categories", systemImage: "square.grid.2x2") }
                    NavigationLink { PaymentMethodsView() } label: { Label("Payment Methods", systemImage: "creditcard") }
                    NavigationLink { BillsView() } label: { Label("Recurring Bills", systemImage: "calendar.badge.clock") }
                    NavigationLink { BudgetsView() } label: { Label("Budgets", systemImage: "gauge.with.dots.needle.33percent") }
                    NavigationLink { InvestmentsView() } label: { Label("Investments", systemImage: "chart.line.uptrend.xyaxis") }
                    NavigationLink { SplitsView() } label: { Label("Splits", systemImage: "person.2") }
                }
                if let s = settings.first {
                    PreferencesSection(settings: s)
                }
                if let s = settings.first {
                    SecuritySection(settings: s)
                }
                SmartSuggestionsSection()
                Section("Data") {
                    NavigationLink { DataManagementView() } label: { Label("Backup & Data", systemImage: "externaldrive") }
                }
                Section("About") {
                    NavigationLink { PrivacyInfoView() } label: { Label("Privacy", systemImage: "lock.shield") }
                    NavigationLink { AboutDeveloperView() } label: { Label("About the Developer", systemImage: "person.crop.circle") }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .brandScreen()
            .navigationTitle("Settings")
        }
    }
}

private struct PreferencesSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Preferences") {
            Picker("Currency", selection: $settings.preferredCurrencyCode) {
                ForEach(CurrencyMath.supportedCodes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Appearance", selection: Binding(get: { settings.preferredAppearance },
                                                    set: { settings.preferredAppearance = $0 })) {
                ForEach(AppearancePreference.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }
}

/// Optional Apple Intelligence for statement suggestions. Off by default; the built-in rules always work.
private struct SmartSuggestionsSection: View {
    @AppStorage(DescriptionAssistantFactory.preferenceKey) private var useOnDeviceModel = false

    var body: some View {
        Section {
            Toggle(isOn: $useOnDeviceModel) { Label("Use Apple Intelligence", systemImage: "sparkles") }
                .disabled(!DescriptionAssistantFactory.isOnDeviceModelAvailable)
        } header: {
            Text("Smart Suggestions")
        } footer: {
            Text(DescriptionAssistantFactory.isOnDeviceModelAvailable
                 ? "Helps explain unusual statement descriptions and suggest merchant names, on this iPhone only. It never changes amounts or saves anything by itself."
                 : DescriptionAssistantFactory.onDeviceModelStatus + " The built-in rules work fully offline.")
        }
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        List {
            Section {
                Label("Works fully offline", systemImage: "airplane")
                Label("No account, ads or analytics", systemImage: "person.crop.circle.badge.xmark")
                Label("Data never leaves this iPhone", systemImage: "iphone")
                Label("No iCloud sync", systemImage: "icloud.slash")
                Label("Receipts read on-device with Apple Vision", systemImage: "text.viewfinder")
            }
            Section {
                Text("TallySeam stores your records in an encrypted-at-rest database protected by iOS Data Protection. It never connects to your bank and never stores full card numbers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .brandScreen()
        .navigationTitle("Privacy")
    }
}

/// A short note about who made the app. Links open in Safari; the app itself never goes online.
struct AboutDeveloperView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Text("•   A   •   M   •")
                        .font(.system(.title2, design: .serif).weight(.medium))
                        .accessibilityLabel("A M")
                    Text("Aravind Marri").font(.title3.weight(.semibold))
                    Text("Developer of TallySeam").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("About Me") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hi, I'm Aravind. I build software, and I like things that are simple and honest.")
                    Text("For a long time I tracked my money in notes and spreadsheets. Every month I'd sit down, add up my cash, my bank balance and my card bills, and try to answer one question: where did it all go?")
                    Text("I tried a lot of apps. Most wanted an account, a bank login or a subscription, and sent my spending to someone's server. My money is personal. I didn't want it living anywhere but my own phone.")
                    Text("So I built the app I wanted. TallySeam reads your receipts and statements on the iPhone itself, checks every number and stitches it all into one clear picture.")
                    Text("The name says it: a tally of every rupee, dollar and cent, joined at the seams. The dashed stitch on the icon is that seam.")
                    Text("No cloud, no ads, no tracking. Just you and your numbers. I hope it helps you the way it helps me.")
                    Text("— Aravind").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            }
            Section("Find Me") {
                Link(destination: URL(string: "https://aravindmarri.com")!) {
                    Label("Website", systemImage: "person.crop.square")
                }
                Link(destination: URL(string: "https://blogs.aravindmarri.com")!) {
                    Label("Blog", systemImage: "globe")
                }
                Link(destination: URL(string: "https://github.com/aravindmarri")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .brandScreen()
        .navigationTitle("About the Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
