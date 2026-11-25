import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(AppContainer.self) private var app
    @Query private var settings: [AppSettings]

    private var colorScheme: ColorScheme? {
        switch settings.first?.preferredAppearance ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            DashboardView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.transactions)
            ReceiptScannerView()
                .tabItem { Label("Import", systemImage: "doc.viewfinder") }
                .tag(AppTab.scan)
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.reports)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            app.diagnostics.log(.memoryWarning)
        }
    }
}

#Preview {
    let app = AppContainer.preview()
    return RootTabView()
        .environment(app)
        .modelContainer(app.persistence.container)
}
