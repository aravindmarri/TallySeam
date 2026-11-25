import SwiftUI
import SwiftData

@main
struct TallySeamApp: App {
    @State private var launch: Result<AppContainer, Error>
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Diagnostics start first and don't need the database. They do nothing unless the user enabled them.
        let diagnostics = DiagnosticsService.shared
        CrashDiagnosticsService.shared.refresh()
        let token = diagnostics.begin(.startup)
        let result = Result { try AppContainer.live() }
        switch result {
        case .success:
            diagnostics.end(token)
            diagnostics.log(.appLaunched)
        case .failure(let error):
            diagnostics.end(token, error: error)
        }
        _launch = State(initialValue: result)
    }

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .success(let container):
                LockGate { RootTabView() }
                    .tint(Theme.brand)
                    .environment(container)
                    .modelContainer(container.persistence.container)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Unable to Open Data", systemImage: "exclamationmark.triangle")
                } description: {
                    // Never delete or reset the store automatically.
                    Text("Your data was not changed. Restart the app; if this persists, contact support.\n\n\(error.localizedDescription)")
                } actions: {
                    StartupDiagnosticsButton()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            DiagnosticsService.shared.flushMetrics()
        }
    }
}
