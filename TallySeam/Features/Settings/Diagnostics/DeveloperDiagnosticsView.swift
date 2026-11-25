import SwiftUI

/// Settings → Developer Diagnostics. Off until the user turns it on; reports stay on the iPhone.
struct DeveloperDiagnosticsView: View {
    static let privacyText = "Diagnostics collect technical information to help improve TallySeam. Personal information, financial records, receipts, and account details are not included. Reports remain on your device and are shared only when you explicitly export them."

    private let diagnostics = DiagnosticsService.shared
    @State private var enabled = false
    @State private var profile: LoggingProfile = .standard
    @State private var performance = false
    @State private var crashReports = false
    @State private var usedBytes = 0
    @State private var lastEvent: Date?
    @State private var showExport = false
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Toggle("Enable Diagnostics", isOn: Binding(get: { enabled }, set: { setEnabled($0) }))
            } footer: {
                Text(Self.privacyText)
            }
            Section {
                Picker("Logging level", selection: Binding(get: { profile }, set: { profile = $0; diagnostics.settings.profile = $0 })) {
                    ForEach(LoggingProfile.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Performance monitoring", isOn: Binding(get: { performance }, set: {
                    performance = $0
                    diagnostics.setPerformance($0)
                    CrashDiagnosticsService.shared.refresh()
                }))
                Toggle("Crash and diagnostic reports", isOn: Binding(get: { crashReports }, set: {
                    crashReports = $0
                    diagnostics.settings.crashReports = $0
                    CrashDiagnosticsService.shared.refresh()
                }))
            } header: { Text("Collect") } footer: {
                Text("iOS delivers crash reports later, often after the app restarts, and doesn't capture every crash.")
            }
            .disabled(!enabled)
            Section("Review") {
                NavigationLink { LogViewerView() } label: { Label("Application Logs", systemImage: "list.bullet.rectangle") }
                NavigationLink { CrashReportsView() } label: { Label("Crash Reports", systemImage: "exclamationmark.triangle") }
                NavigationLink { PerformanceMetricsView() } label: { Label("Performance", systemImage: "speedometer") }
                Button { showExport = true } label: { Label("Export Diagnostic Report", systemImage: "square.and.arrow.up") }
                    .disabled(usedBytes == 0)
            }
            Section("Storage") {
                LabeledContent("Used", value: "\(ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file)) of 5 MB")
                LabeledContent("Kept for", value: "7 days")
                LabeledContent("Last event", value: lastEvent?.formatted(date: .abbreviated, time: .shortened) ?? "None")
                Button("Clear All Diagnostics", role: .destructive) { confirmClear = true }.disabled(usedBytes == 0)
            }
            #if DEBUG
            DiagnosticsTestSection(onChange: refresh)
            #endif
        }
        .brandScreen()
        .navigationTitle("Developer Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showExport, onDismiss: refresh) { DiagnosticExportView() }
        .confirmationDialog("Clear all diagnostics?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                diagnostics.clearAll()
                CrashDiagnosticsService.shared.refresh()
                refresh()
            }
        } message: { Text("Your financial records are not affected.") }
    }

    private func setEnabled(_ on: Bool) {
        diagnostics.setEnabled(on)
        CrashDiagnosticsService.shared.refresh()
        refresh()
    }

    private func refresh() {
        enabled = diagnostics.settings.isEnabled
        profile = diagnostics.settings.profile
        performance = diagnostics.settings.performance
        crashReports = diagnostics.settings.crashReports
        diagnostics.store.enforceLimits()
        usedBytes = diagnostics.store.usedBytes()
        lastEvent = diagnostics.store.lastEventDate()
    }
}

#if DEBUG
/// Safe test actions, compiled into debug builds only. There is no deliberate-crash action.
struct DiagnosticsTestSection: View {
    let onChange: () -> Void
    private struct TestFailure: Error {}

    var body: some View {
        Section {
            Button("Log INFO event") { DiagnosticsService.shared.log(.testInfo); onChange() }
            Button("Log WARNING event") { DiagnosticsService.shared.log(.testWarning); onChange() }
            Button("Log ERROR event") { DiagnosticsService.shared.log(.testError); onChange() }
            Button("Simulate service failure") {
                try? DiagnosticsService.shared.measure(.testOperation) { throw TestFailure() }
                onChange()
            }
            Button("Simulate slow operation") {
                Task {
                    let token = DiagnosticsService.shared.begin(.testOperation)
                    try? await Task.sleep(for: .milliseconds(600))
                    DiagnosticsService.shared.end(token)
                    onChange()
                }
            }
            Button("Add synthetic crash report") {
                let d = DiagnosticsService.shared
                d.storeCrashes([CrashRecord(receivedAt: Date(), kind: .crash, isSynthetic: true, appVersion: d.currentVersion.app,
                                            buildNumber: d.currentVersion.build, signal: 6)], generation: d.currentGeneration)
                onChange()
            }
        } header: { Text("Debug build only") } footer: { Text("Synthetic events. They do nothing while diagnostics are off.") }
    }
}
#endif

// MARK: - Logs

struct LogViewerView: View {
    private let diagnostics = DiagnosticsService.shared
    @State private var query = LogQuery()
    @State private var day: Date = .now
    @State private var limitToDay = false
    @State private var events: [LogEvent] = []
    @State private var next: LogCursor?
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Picker("Severity", selection: $query.level) {
                    Text("All").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases) { Text($0.rawValue.capitalized).tag(LogLevel?.some($0)) }
                }
                Picker("Component", selection: $query.category) {
                    Text("All").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases) { Text($0.rawValue).tag(LogCategory?.some($0)) }
                }
                Toggle("One day only", isOn: $limitToDay)
                if limitToDay { DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date) }
                Picker("Order", selection: $query.newestFirst) {
                    Text("Newest first").tag(true)
                    Text("Oldest first").tag(false)
                }
            }
            Section {
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    NavigationLink { LogEventView(event: e) } label: { LogEventRow(event: e) }
                }
                if next != nil { Button("Load more") { load(more: true) } }
            }
        }
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("No Log Records", systemImage: "doc.text.magnifyingglass",
                                       description: Text(diagnostics.isEnabled ? "Nothing recorded matches." : "Diagnostics are off, so nothing is being recorded."))
                    .allowsHitTesting(false)
                    .padding(.top, 220)
            }
        }
        .searchable(text: $query.text, prompt: "Event code or message")
        .brandScreen()
        .navigationTitle("Logs")
        .toolbar {
            Button("Clear", role: .destructive) { confirmClear = true }
        }
        .onAppear { load(more: false) }
        .onChange(of: query) { _, _ in load(more: false) }
        .onChange(of: limitToDay) { _, _ in applyDay() }
        .onChange(of: day) { _, _ in applyDay() }
        .confirmationDialog("Clear all diagnostics?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                diagnostics.clearAll()
                CrashDiagnosticsService.shared.refresh()
                load(more: false)
            }
        } message: { Text("Your financial records are not affected.") }
    }

    private func applyDay() {
        let start = Calendar.current.startOfDay(for: day)
        query.since = limitToDay ? start : nil
        query.until = limitToDay ? Calendar.current.date(byAdding: .day, value: 1, to: start) : nil
    }

    private func load(more: Bool) {
        let page = diagnostics.store.page(query, after: more ? next : nil)
        events = more ? events + page.events : page.events
        next = page.next
    }
}

struct LogEventRow: View {
    let event: LogEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.level.rawValue).font(.caption.weight(.semibold)).foregroundStyle(color)
                Text(event.category.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(event.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(event.message)
            Text([event.eventCode, event.operation?.rawValue, event.durationMs.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if event.level >= .error { return Theme.expense }
        return event.level == .warning ? .orange : Theme.brand
    }
}

struct LogEventView: View {
    let event: LogEvent

    private var json: String {
        let e = DiagnosticJSON.encoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var body: some View {
        List {
            Section { Text(json).font(.footnote.monospaced()).textSelection(.enabled) }
            Button { UIPasteboard.general.string = json } label: { Label("Copy Event", systemImage: "doc.on.doc") }
        }
        .brandScreen()
        .navigationTitle(event.eventCode)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Crash reports

struct CrashReportsView: View {
    @State private var records: [CrashRecord] = []
    @State private var crumbs: [Breadcrumb] = []

    var body: some View {
        List {
            Section {
                if records.isEmpty { Text("No reports from iOS.").foregroundStyle(.secondary) }
                ForEach(records) { r in
                    NavigationLink { CrashRecordView(record: r) } label: {
                        VStack(alignment: .leading) {
                            Text(r.isSynthetic ? "\(r.kind.displayName) (synthetic test)" : r.kind.displayName)
                            Text("\(r.receivedAt.formatted(date: .abbreviated, time: .shortened)) · version \(r.appVersion) (\(r.buildNumber))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Reports") } footer: {
                Text("Closing the app yourself, or iOS ending it in the background, is not a crash. Some reports arrive a day later, and some crashes are never reported.")
            }
            Section("Recent operations") {
                if crumbs.isEmpty { Text("None recorded.").foregroundStyle(.secondary) }
                ForEach(Array(crumbs.suffix(40).reversed().enumerated()), id: \.offset) { _, b in
                    LabeledContent("\(b.operation.rawValue) \(b.phase.rawValue)", value: b.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.footnote)
                }
            }
        }
        .brandScreen()
        .navigationTitle("Crash Reports")
        .onAppear {
            records = DiagnosticsService.shared.store.crashes().reversed()
            crumbs = DiagnosticsService.shared.store.breadcrumbs()
        }
    }
}

struct CrashRecordView: View {
    let record: CrashRecord
    var body: some View {
        List {
            Section {
                if let v = record.exceptionType { LabeledContent("Exception type", value: "\(v)") }
                if let v = record.exceptionCode { LabeledContent("Exception code", value: "\(v)") }
                if let v = record.signal { LabeledContent("Signal", value: "\(v)") }
                if let v = record.valueMs { LabeledContent(record.kind == .hang ? "Hang" : "CPU time", value: "\(v) ms") }
                if let v = record.writtenBytes { LabeledContent("Written", value: "\(v) bytes") }
                if let v = record.peakMemoryBytes { LabeledContent("Peak memory", value: "\(v) bytes") }
                ForEach((record.exits ?? [:]).sorted { $0.key < $1.key }, id: \.key) { e in
                    LabeledContent("Exits: \(e.key)", value: "\(e.value)")
                }
            }
            if !record.frames.isEmpty {
                Section("Call stack") {
                    ForEach(Array(record.frames.enumerated()), id: \.offset) { i, f in
                        Text("\(i)  \(f.binary) + \(f.offset)").font(.caption.monospaced())
                    }
                }
            }
        }
        .brandScreen()
        .navigationTitle(record.kind.displayName)
    }
}

// MARK: - Performance

struct PerformanceMetricsView: View {
    @State private var rows: [(DiagnosticOperation, OperationMetrics)] = []

    var body: some View {
        List {
            if rows.isEmpty { Text("No measurements. Turn on Performance monitoring and use the app.").foregroundStyle(.secondary) }
            ForEach(rows, id: \.0) { row in
                Section(row.0.rawValue) {
                    LabeledContent("Count", value: "\(row.1.count)")
                    LabeledContent("Average", value: "\(row.1.averageMs) ms")
                    LabeledContent("Fastest / slowest", value: "\(row.1.minMs) / \(row.1.maxMs) ms")
                    LabeledContent("Slow", value: "\(row.1.slow)")
                    LabeledContent("Succeeded / failed", value: "\(row.1.success) / \(row.1.failure)")
                    LabeledContent("Last run", value: row.1.lastRun.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .brandScreen()
        .navigationTitle("Performance")
        .onAppear {
            rows = DiagnosticsService.shared.performance().sorted { $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value) }
        }
    }
}

// MARK: - Export

/// Preview, explicit confirmation, then the share sheet. The temporary file is removed on closing.
struct DiagnosticExportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiagnosticReport?
    @State private var file: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let r = report {
                    Section {
                        LabeledContent("Events", value: "\(r.summary.events)")
                        LabeledContent("Warnings", value: "\(r.summary.warnings)")
                        LabeledContent("Errors", value: "\(r.summary.errors)")
                        LabeledContent("Reports from iOS", value: "\(r.summary.crashReports)")
                        LabeledContent("Operation breadcrumbs", value: "\(r.summary.breadcrumbs)")
                        LabeledContent("Measured operations", value: "\(r.summary.measuredOperations)")
                        LabeledContent("App", value: "\(r.app.appVersion) (\(r.app.buildNumber))")
                        LabeledContent("iPhone", value: "\(r.app.deviceModel), iOS \(r.app.iosVersion)")
                    } header: { Text("What's included") } footer: { Text(DeveloperDiagnosticsView.privacyText) }
                    if !r.events.isEmpty {
                        Section("Latest events") {
                            ForEach(Array(r.events.suffix(5).reversed().enumerated()), id: \.offset) { _, e in LogEventRow(event: e) }
                        }
                    }
                    Section {
                        if let file {
                            ShareLink(item: file) { Label("Share or Save to Files", systemImage: "square.and.arrow.up") }
                        } else {
                            Button { create(r) } label: { Label("Confirm and Create Report", systemImage: "checkmark.shield") }
                        }
                    } footer: {
                        Text("Nothing is sent automatically. You choose where the file goes.")
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.expense) }
            }
            .brandScreen()
            .navigationTitle("Export Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(file == nil ? "Cancel" : "Done") { dismiss() } }
            }
            .onAppear(perform: prepare)
            .onDisappear { DiagnosticExportService.removeTemporaryFiles() }
        }
    }

    private func prepare() {
        guard report == nil else { return }
        let r = DiagnosticExportService.makeReport(.shared)
        do {
            try DiagnosticExportService.validate(r)
            report = r
        } catch { errorMessage = error.localizedDescription }
    }

    private func create(_ r: DiagnosticReport) {
        do { file = try DiagnosticExportService.writeZip(r) } catch { errorMessage = error.localizedDescription }
    }
}

/// On the "Unable to Open Data" screen, when there is something to export.
struct StartupDiagnosticsButton: View {
    @State private var showExport = false
    var body: some View {
        if DiagnosticsService.shared.store.usedBytes() > 0 {
            Button("Export Diagnostic Report") { showExport = true }
                .sheet(isPresented: $showExport) { DiagnosticExportView() }
        }
    }
}
