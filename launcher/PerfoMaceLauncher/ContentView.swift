import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var config = RunConfiguration()
    @State private var compareBaselineURL: URL?
    @State private var compareCandidateURL: URL?

    @State private var reportURL: URL?
    @State private var reportReloadToken: Int = 0
    @AppStorage("perfomace_project_path") private var projectPath: String = ""
    @State private var didAutoDetect: Bool = false
    @State private var detailTab: DetailTab = .report
    @State private var showReadyChecks: Bool = false

    private let repeatFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 25
        return formatter
    }()

    private let sapphire = Color(red: 0.78, green: 0.16, blue: 0.34)
    private let deepSapphire = Color(red: 0.09, green: 0.10, blue: 0.13)
    private let golden = Color(red: 0.69, green: 0.18, blue: 0.56)
    private let warmGold = Color(red: 0.96, green: 0.89, blue: 0.93)
    private let ivory = Color(red: 0.98, green: 0.99, blue: 1.00)
    private let mist = Color(red: 0.95, green: 0.95, blue: 0.97)
    private let rose = Color(red: 0.62, green: 0.12, blue: 0.24)
    private let panelBorder = Color(red: 0.88, green: 0.83, blue: 0.90)
    private let panelFill = Color.white
    private let brandInk = Color(red: 0.07, green: 0.09, blue: 0.13)
    private let brandCyan = Color(red: 0.22, green: 0.77, blue: 0.97)
    private let brandBlue = Color(red: 0.18, green: 0.47, blue: 0.99)
    private let brandOrange = Color(red: 0.98, green: 0.56, blue: 0.18)
    private let brandEmber = Color(red: 0.95, green: 0.34, blue: 0.15)

    private var projectRoot: URL? {
        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private var harnessRoot: URL? { projectRoot.map(resolveHarnessRoot(from:)) }

    private var workspaceRoot: URL? {
        guard let harnessRoot else { return nil }
        return harnessRoot.lastPathComponent == "codebase" ? harnessRoot.deletingLastPathComponent() : harnessRoot
    }

    private var resultsRoot: URL? { harnessRoot.map(resolveResultsRoot(from:)) }

    private var readyCheckAppURL: URL? {
        workspaceRoot?.appendingPathComponent("launcher/dist/PerfoMace Ready Check.app")
    }

    private var reportPath: URL? { latestSavedRunReportURL(in: resultsRoot) }

    private var configuredPassCount: Int {
        switch config.appChoice {
        case .combine, .compare:
            return 2
        default:
            return 1
        }
    }

    private var iterationSummaryValue: String {
        if config.appChoice == .combine {
            return "\(configuredPassCount) passes"
        }
        if config.appChoice == .compare {
            return compareSelectionCount == 2 ? "2 files" : "\(compareSelectionCount)/2"
        }
        return "\(max(config.repeatCount, 1))x"
    }

    private var iterationSummarySubtitle: String {
        if runner.isRunning {
            if config.appChoice == .compare {
                return runner.currentTestCase
            }
            return currentIterationLabel
        }
        if config.appChoice == .combine {
            return "Re-Write -> Legacy"
        }
        if config.appChoice == .compare {
            return compareSelectionCount == 2 ? "Ready to compare" : "Pick two reports"
        }
        return "Configured"
    }

    private var compareSelectionCount: Int {
        [compareBaselineURL, compareCandidateURL].compactMap { $0 }.count
    }

    private var baselineCompareError: String? {
        runner.comparisonSelectionMessage(for: compareBaselineURL, expectedAppChoice: .qa)
    }

    private var candidateCompareError: String? {
        runner.comparisonSelectionMessage(for: compareCandidateURL, expectedAppChoice: .legacy)
    }

    private var compareInputReady: Bool {
        compareBaselineURL != nil &&
        compareCandidateURL != nil &&
        baselineCompareError == nil &&
        candidateCompareError == nil
    }

    private var footerPrimaryActionTitle: String {
        if runner.isCheckingSetup { return "Checking Setup…" }
        if runner.isRunning { return "\(overallRunStatus)…" }
        return config.appChoice == .compare ? "Create Compared Report" : "Run"
    }

    private var orderedSetupChecks: [SetupCheckStatus] {
        guard let summary = runner.setupSummary else { return [] }
        return summary.checks.sorted { lhs, rhs in
            let leftRank = setupRank(for: lhs.state)
            let rightRank = setupRank(for: rhs.state)
            if leftRank == rightRank {
                return lhs.title < rhs.title
            }
            return leftRank < rightRank
        }
    }

    private var readySetupChecks: [SetupCheckStatus] {
        orderedSetupChecks.filter { $0.state == .ok }
    }

    private var primarySetupIssue: SetupCheckStatus? {
        guard let summary = runner.setupSummary else { return nil }
        return summary.blockingChecks.first ?? summary.warningChecks.first
    }

    var body: some View {
        NavigationSplitView {
            ZStack(alignment: .topLeading) {
                sidebarBackground

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        runSummaryStrip

                        GroupBox("Codebase") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("PerfoMace codebase (contains run_perf.sh)", text: $projectPath)
                                    .textFieldStyle(.roundedBorder)
                                HStack {
                                    Spacer()
                                    Button("Browse…") { browseForProject() }
                                        .buttonStyle(.bordered)
                                        .tint(sapphire)
                                }
                            }
                        }
                        .groupBoxStyle(CardGroupBoxStyle())

                        GroupBox("Setup Readiness") {
                            setupReadinessCard
                        }
                        .groupBoxStyle(CardGroupBoxStyle())

                        GroupBox("App") {
                            Picker("Target", selection: $config.appChoice) {
                                ForEach(RunConfiguration.AppChoice.allCases) { choice in
                                    Text(choice.displayName).tag(choice)
                                }
                            }
                            .pickerStyle(.segmented)
                            if config.appChoice == .custom {
                                TextField("Bundle id", text: $config.customBundleId)
                                    .textFieldStyle(.roundedBorder)
                            } else if config.appChoice == .combine {
                                Text("Runs Re-Write -> Legacy once, then builds a comparison report with multi-view graphs.")
                                    .font(.system(size: 11, weight: .medium, design: .default))
                                    .foregroundStyle(.secondary)
                            } else if config.appChoice == .compare {
                                VStack(alignment: .leading, spacing: 12) {
                                    compareSourceRow(
                                        title: "Re-Write / Baseline",
                                        subtitle: "Recommended: pick a QA_PerfoMace_<timestamp> folder",
                                        url: compareBaselineURL,
                                        validationError: baselineCompareError,
                                        resolvedStatus: runner.comparisonSelectionResolvedLabel(for: compareBaselineURL, expectedAppChoice: .qa),
                                        browseAction: { browseForCompareFile(role: .baseline) },
                                        clearAction: { compareBaselineURL = nil }
                                    )
                                    compareSourceRow(
                                        title: "Legacy / Candidate",
                                        subtitle: "Recommended: pick a Legacy_PerfoMace_<timestamp> folder",
                                        url: compareCandidateURL,
                                        validationError: candidateCompareError,
                                        resolvedStatus: runner.comparisonSelectionResolvedLabel(for: compareCandidateURL, expectedAppChoice: .legacy),
                                        browseAction: { browseForCompareFile(role: .candidate) },
                                        clearAction: { compareCandidateURL = nil }
                                    )
                                    Text("Best option: choose the whole QA_PerfoMace_<timestamp> or Legacy_PerfoMace_<timestamp> run folders. File picks still work if the matching PerformanceReport.json sits beside them.")
                                        .font(.system(size: 11, weight: .medium, design: .default))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .groupBoxStyle(CardGroupBoxStyle())

                        if config.appChoice != .compare {
                        GroupBox("Scenarios") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Choose exactly which measured scenarios to run.")
                                        .font(.system(size: 11, weight: .medium, design: .default))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("All") {
                                        config.selectedScenarios = Set(RunConfiguration.Scenario.allCases)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Button("Clear") {
                                        config.selectedScenarios = []
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                LazyVGrid(columns: [
                                    GridItem(.flexible(), spacing: 10, alignment: .leading),
                                    GridItem(.flexible(), spacing: 10, alignment: .leading),
                                ], alignment: .leading, spacing: 8) {
                                    ForEach(RunConfiguration.Scenario.allCases) { scenario in
                                        Toggle(scenario.displayName, isOn: scenarioBinding(scenario))
                                            .toggleStyle(.checkbox)
                                    }
                                }

                                Text("Fresh-state prep stays automatic when needed. It is not counted as one of these scenarios.")
                                    .font(.system(size: 10.5, weight: .regular, design: .default))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .groupBoxStyle(CardGroupBoxStyle())
                        }

                        if config.appChoice != .compare {
                        GroupBox("Advanced") {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Credentials")
                                        .font(.system(size: 12, weight: .semibold, design: .default))
                                        .foregroundStyle(deepSapphire.opacity(0.72))
                                        .textCase(.uppercase)
                                        .tracking(0.9)

                                    TextField("Email", text: $config.email)
                                        .textFieldStyle(.roundedBorder)
                                    SecureField("Password", text: $config.password)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Run options")
                                        .font(.system(size: 12, weight: .semibold, design: .default))
                                        .foregroundStyle(deepSapphire.opacity(0.72))
                                        .textCase(.uppercase)
                                        .tracking(0.9)

                                    Toggle("Strict ads", isOn: $config.strictAds)
                                    Toggle("Reset simulator", isOn: $config.resetSimulator)
                                    Toggle("Time Profiler", isOn: $config.instrumentsTimeProfiler)
                                    Toggle("Allocations", isOn: $config.instrumentsAllocations)
                                    Toggle("Network tracing", isOn: $config.instrumentsNetwork)
                                    Toggle("Leaks tracing", isOn: $config.instrumentsLeaks)
                                    Toggle("Zip results", isOn: $config.zipResults)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }

                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Repeat / Iteration")
                                        .font(.system(size: 12, weight: .semibold, design: .default))
                                        .foregroundStyle(deepSapphire.opacity(0.72))
                                        .textCase(.uppercase)
                                        .tracking(0.9)
                                    Text("Repeat count.")
                                        .font(.system(size: 11, weight: .regular, design: .default))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 8) {
                                    TextField("1", value: $config.repeatCount, formatter: repeatFormatter)
                                        .frame(width: 56)
                                        .textFieldStyle(.roundedBorder)
                                    Stepper("", value: $config.repeatCount, in: 1...25)
                                        .labelsHidden()
                                }
                                .frame(width: 100, alignment: .trailing)
                            }
                            .padding(.top, 4)
                        }
                        .groupBoxStyle(CardGroupBoxStyle())
                        }

                    }
                    .padding(16)
                    .frame(minWidth: 500, maxWidth: 820, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sidebarFooter
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .navigationSplitViewColumnWidth(min: 500, ideal: 560, max: 620)
        } detail: {
            ZStack(alignment: .topTrailing) {
                detailBackground

                switch detailTab {
                case .report:
                    reportTab
                case .live:
                    liveTab
                }
            }
            .onAppear {
                autoDetectProjectPathIfNeeded()
                refreshSetupIfPossible()
                if detailTab == .report {
                    loadReportIfPresent()
                }
            }
            .onChange(of: runner.isRunning) { _, running in
                if running {
                    detailTab = .live
                }
                if !running {
                    if config.appChoice == .compare {
                        detailTab = .report
                    }
                    if detailTab == .report {
                        loadReportIfPresent()
                    }
                }
            }
            .onChange(of: runner.latestReportURL) { _, newValue in
                guard newValue != nil else { return }
                loadReportIfPresent()
                reportReloadToken += 1
                if config.appChoice == .compare {
                    detailTab = .report
                }
            }
            .onChange(of: projectPath) { _, _ in
                refreshSetupIfPossible()
                if detailTab == .report {
                    loadReportIfPresent()
                }
            }
            .onChange(of: config.appChoice) { _, _ in
                refreshSetupIfPossible()
            }
            .onChange(of: config.customBundleId) { _, _ in
                if config.appChoice == .custom {
                    refreshSetupIfPossible()
                }
            }
            .onChange(of: compareBaselineURL) { _, _ in
                runner.lastError = nil
            }
            .onChange(of: compareCandidateURL) { _, _ in
                runner.lastError = nil
            }
            .onChange(of: detailTab) { _, tab in
                if tab == .report {
                    loadReportIfPresent()
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            watermarkBadge
                .padding(.trailing, 18)
                .padding(.bottom, 16)
        }
    }

    private var sidebarBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.99, green: 0.99, blue: 1.00), Color(red: 0.97, green: 0.96, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [brandInk, Color(red: 0.11, green: 0.11, blue: 0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 72)
                .overlay(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(brandCyan.opacity(0.72))
                        .frame(width: 92, height: 1.5)
                        .padding(.leading, 22)
                        .padding(.bottom, 18)
                }
                .ignoresSafeArea(edges: .top)

            RoundedRectangle(cornerRadius: 120, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brandOrange.opacity(0.10), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 240, height: 160)
                .rotationEffect(.degrees(-14))
                .offset(x: 220, y: 420)

            RoundedRectangle(cornerRadius: 120, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brandCyan.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 180, height: 120)
                .rotationEffect(.degrees(20))
                .offset(x: -180, y: 250)
        }
        .ignoresSafeArea()
    }

    private var detailBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white, Color(red: 0.995, green: 0.99, blue: 1.00), Color(red: 0.98, green: 0.97, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RoundedRectangle(cornerRadius: 180, style: .continuous)
                .fill(sapphire.opacity(0.04))
                .frame(width: 340, height: 220)
                .rotationEffect(.degrees(-12))
                .offset(x: 250, y: -120)

            RoundedRectangle(cornerRadius: 220, style: .continuous)
                .fill(golden.opacity(0.03))
                .frame(width: 420, height: 280)
                .rotationEffect(.degrees(10))
                .offset(x: -260, y: 260)
        }
        .ignoresSafeArea()
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(footerPrimaryActionTitle) {
                    guard let root = projectRoot else { return }
                    if config.appChoice == .compare,
                       let compareBaselineURL,
                       let compareCandidateURL {
                        runner.compareReports(
                            projectRoot: root,
                            baselineSelection: compareBaselineURL,
                            candidateSelection: compareCandidateURL
                        )
                    } else {
                        runner.run(projectRoot: root, config)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(sapphire)
                .controlSize(.small)
                .disabled(
                    runner.isRunning
                    || runner.isCheckingSetup
                    || projectRoot == nil
                    || (config.appChoice == .custom && config.customBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    || (config.appChoice != .compare && config.selectedScenarios.isEmpty)
                    || (config.appChoice == .compare && !compareInputReady)
                )

                Button("Stop") { runner.stop() }
                    .buttonStyle(.bordered)
                    .tint(rose)
                    .controlSize(.small)
                    .disabled(!runner.isRunning)

                Button("Results") {
                    guard let root = projectRoot else { return }
                    runner.openResults(projectRoot: root)
                }
                .buttonStyle(.bordered)
                .tint(golden)
                .controlSize(.small)
                .disabled(projectRoot == nil)

                Spacer(minLength: 8)

                statusPill(overallRunStatus, isRunning: runner.isRunning, isFailed: overallRunStatus == "Stopping" || overallRunStatus == "Needs Attention")
            }

            Text(projectRoot == nil ? "Select codebase to run." : (config.appChoice == .compare ? "Create a compared report from two saved results." : "Run controls stay pinned."))
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(deepSapphire.opacity(0.60))

            if let lastError = runner.lastError, !lastError.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(rose)
                    Text(lastError)
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundStyle(rose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(rose.opacity(0.07))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(panelBorder, lineWidth: 1)
                )
        )
        .shadow(color: sapphire.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    private var setupReadinessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(setupHeadline)
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire)
                    Text(setupSubheadline)
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                statusPill(
                    runner.isCheckingSetup ? "Checking" : setupStatusLabel,
                    isRunning: runner.isCheckingSetup,
                    isFailed: runner.setupSummary?.overallState == .fail
                )
            }

            if config.appChoice == .compare {
                Text("Compare mode only needs saved reports, so device and signing checks are skipped.")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
            } else if projectRoot == nil {
                Text("Choose the PerfoMace codebase first, then the launcher will inspect your Mac and show exact fixes here.")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
            } else if runner.setupSummary != nil {
                if let summary = runner.setupSummary {
                    setupGuidanceCard(summary)

                    if !summary.blockingChecks.isEmpty {
                        setupSection(title: "Blockers", checks: summary.blockingChecks)
                    }

                    if !summary.warningChecks.isEmpty {
                        setupSection(title: "Warnings", checks: summary.warningChecks)
                    }

                    if !readySetupChecks.isEmpty {
                        DisclosureGroup(isExpanded: $showReadyChecks) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(readySetupChecks) { check in
                                    setupCheckRow(check)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(Color.green.opacity(0.85))
                                Text("Ready checks (\(readySetupChecks.count))")
                                    .font(.system(size: 11.5, weight: .semibold, design: .default))
                                    .foregroundStyle(deepSapphire)
                            }
                        }
                        .padding(10)
                        .background(cardBackground(cornerRadius: 14))
                    }
                }

                if let checkedAt = runner.setupCheckedAt {
                    Text("Last checked at \(setupTimestampFormatter.string(from: checkedAt)).")
                        .font(.system(size: 10.5, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Run a setup refresh to inspect the machine before your next run.")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Run Ready Check") {
                    openReadyCheckApp()
                }
                .buttonStyle(.bordered)
                .tint(golden)
                .disabled(projectRoot == nil || config.appChoice == .compare)

                Button("Refresh Setup") {
                    refreshSetupIfPossible(force: true)
                }
                .buttonStyle(.bordered)
                .tint(sapphire)
                .disabled(projectRoot == nil || runner.isCheckingSetup || config.appChoice == .compare)
            }
        }
    }

    private func loadReportIfPresent() {
        if let preferredReportURL = runner.latestReportURL,
           FileManager.default.fileExists(atPath: preferredReportURL.path),
           let resultsRoot,
           preferredReportURL.path.hasPrefix(resultsRoot.path) || preferredReportURL.path.contains("/manual_compare_sessions/") {
            reportURL = preferredReportURL
            return
        }
        if config.appChoice == .compare {
            reportURL = nil
            return
        }
        guard let reportPath else {
            reportURL = nil
            return
        }
        reportURL = FileManager.default.fileExists(atPath: reportPath.path) ? reportPath : nil
    }

    private func latestSavedRunReportURL(in resultsRoot: URL?) -> URL? {
        guard let resultsRoot else { return nil }
        let fm = FileManager.default
        let rootReport = resultsRoot.appendingPathComponent("PerformanceReport.html")
        if fm.fileExists(atPath: rootReport.path) {
            return rootReport
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: resultsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = entries.filter { url in
            guard url.lastPathComponent.contains("PerfoMace_") else { return false }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            return fm.fileExists(atPath: url.appendingPathComponent("PerformanceReport.html").path)
        }

        let latest = candidates.max { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }

        return latest?.appendingPathComponent("PerformanceReport.html")
    }

    private func browseForProject() {
        let panel = NSOpenPanel()
        panel.title = "Select PerfoMace codebase"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }

    private func refreshSetupIfPossible(force: Bool = false) {
        guard let root = projectRoot else { return }
        guard config.appChoice != .compare else { return }
        if force || !runner.isCheckingSetup {
            runner.refreshSetup(projectRoot: root, config: config)
        }
    }

    private func openReadyCheckApp() {
        guard let readyCheckAppURL else { return }
        if FileManager.default.fileExists(atPath: readyCheckAppURL.path) {
            let opened = NSWorkspace.shared.open(readyCheckAppURL)
            if !opened {
                runner.lastError = "PerfoMace Ready Check.app could not be opened from: \(readyCheckAppURL.path)"
            }
            return
        }

        runner.lastError = "PerfoMace Ready Check.app was not found at: \(readyCheckAppURL.path). Rebuild the launcher bundle to regenerate it."
    }

    private func openXcodeApp() {
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: xcodeURL.path) else {
            runner.lastError = "Xcode.app was not found in /Applications. Install Xcode first."
            return
        }
        if !NSWorkspace.shared.open(xcodeURL) {
            runner.lastError = "Xcode.app could not be opened."
        }
    }

    private func copyTextToClipboard(_ value: String, successMessage: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        runner.lastError = successMessage
    }

    private func copySetupDiagnostics(_ summary: SetupSummary) {
        var lines: [String] = []
        lines.append("PerfoMace Setup Diagnostics")
        lines.append("Project: \(projectRoot?.path ?? "Unknown")")
        lines.append("App target: \(config.appChoice.displayName)")
        if let checkedAt = runner.setupCheckedAt {
            lines.append("Checked at: \(setupTimestampFormatter.string(from: checkedAt))")
        }
        lines.append("Status: \(summary.headline)")
        lines.append("Summary: \(summary.summaryLine)")
        lines.append("")
        for check in summary.checks {
            lines.append("[\(check.state.displayName)] \(check.title)")
            lines.append(check.detail)
            if !check.action.isEmpty {
                lines.append("Fix: \(check.action)")
            }
            lines.append("")
        }
        copyTextToClipboard(lines.joined(separator: "\n"), successMessage: "Setup diagnostics copied.")
    }

    private func shouldOfferOpenXcode(for check: SetupCheckStatus) -> Bool {
        switch check.id {
        case "xcode_select", "developer_dir", "swift_toolchain", "xcodebuild", "ios_targets", "codesigning":
            return true
        default:
            return false
        }
    }

    private func shouldOfferOpenResults(for check: SetupCheckStatus) -> Bool {
        check.id == "results_dirs"
    }

    private func setupRank(for state: SetupCheckState) -> Int {
        switch state {
        case .fail:
            return 0
        case .warn:
            return 1
        case .ok:
            return 2
        }
    }

    private var setupHeadline: String {
        if config.appChoice == .compare {
            return "Compare-only mode"
        }
        if runner.isCheckingSetup {
            return "Checking this Mac now"
        }
        return runner.setupSummary?.headline ?? "Ready check available"
    }

    private var setupSubheadline: String {
        if config.appChoice == .compare {
            return "Pick saved reports and compare them without rechecking devices or signing."
        }
        if runner.isCheckingSetup {
            return "PerfoMace is validating Xcode, toolchain, targets, and signing hints before you run."
        }
        return runner.setupSummary?.summaryLine ?? "Refresh setup to see exact blockers and fix steps before a run starts."
    }

    private var setupStatusLabel: String {
        switch runner.setupSummary?.overallState {
        case .ok:
            return "Ready"
        case .warn:
            return "Warn"
        case .fail:
            return "Blocked"
        case .none:
            return "Unknown"
        }
    }

    private var setupTimestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private func setupSection(title: String, checks: [SetupCheckStatus]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .default))
                .foregroundStyle(deepSapphire.opacity(0.78))
                .textCase(.uppercase)
                .tracking(0.8)
            ForEach(checks) { check in
                setupCheckRow(check)
            }
        }
    }

    private func setupGuidanceCard(_ summary: SetupSummary) -> some View {
        let issue = primarySetupIssue
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.blockingChecks.isEmpty ? "Next Best Fix" : "Primary Blocker")
                    .font(.system(size: 11.5, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.78))
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                if let issue {
                    statusPill(issue.state.displayName, isFailed: issue.state == .fail)
                }
            }

            if let issue {
                Text(issue.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire)
                Text(issue.detail)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(issue.state == .fail ? rose : deepSapphire.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                if !issue.action.isEmpty {
                    Text("Suggested fix: \(issue.action)")
                        .font(.system(size: 10.5, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if shouldOfferOpenXcode(for: issue) {
                        Button("Open Xcode") {
                            openXcodeApp()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(golden)
                    }
                    if shouldOfferOpenResults(for: issue), let root = projectRoot {
                        Button("Open Results") {
                            runner.openResults(projectRoot: root)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(golden)
                    }
                    if !issue.action.isEmpty {
                        Button("Copy Fix") {
                            copyTextToClipboard(issue.action, successMessage: "Suggested fix copied.")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Copy Diagnostics") {
                        copySetupDiagnostics(summary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text("Everything important passed. You can still copy the setup diagnostics if you want to share the exact readiness state with someone else.")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Diagnostics") {
                    copySetupDiagnostics(summary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(cardBackground(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke((summary.overallState == .fail ? rose : sapphire).opacity(0.18), lineWidth: 1)
        )
    }

    private func setupCheckRow(_ check: SetupCheckStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(check.title)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire)
                Spacer()
                statusPill(
                    check.state.displayName,
                    isFailed: check.state == .fail
                )
            }

            Text(check.detail)
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(check.state == .fail ? rose : deepSapphire.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            if !check.action.isEmpty {
                Text("Fix: \(check.action)")
                    .font(.system(size: 10.5, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(cardBackground(cornerRadius: 14))
    }

    private func scenarioBinding(_ scenario: RunConfiguration.Scenario) -> Binding<Bool> {
        Binding(
            get: { config.selectedScenarios.contains(scenario) },
            set: { isSelected in
                if isSelected {
                    config.selectedScenarios.insert(scenario)
                } else {
                    config.selectedScenarios.remove(scenario)
                }
            }
        )
    }

    private func browseForCompareFile(role: CompareRole) {
        let panel = NSOpenPanel()
        panel.title = role == .baseline ? "Choose Re-Write / Baseline run folder or report" : "Choose Legacy / Candidate run folder or report"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .commaSeparatedText, .html]
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            switch role {
            case .baseline:
                compareBaselineURL = url
            case .candidate:
                compareCandidateURL = url
            }
        }
    }

    private func autoDetectProjectPathIfNeeded() {
        guard !didAutoDetect else { return }
        didAutoDetect = true

        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            home.appendingPathComponent("Desktop/PerfoMace v2", isDirectory: true),
            home.appendingPathComponent("Desktop/perfomace by codex", isDirectory: true),
            home.appendingPathComponent("Desktop/PerfoMace", isDirectory: true),
            home.appendingPathComponent("PerfoMace", isDirectory: true),
            home.appendingPathComponent("Projects/PerfoMace", isDirectory: true)
        ]

        for candidate in candidates {
            for codebaseCandidate in [
                candidate,
                candidate.appendingPathComponent("codebase", isDirectory: true)
            ] {
                let script = codebaseCandidate.appendingPathComponent("run_perf.sh")
                if FileManager.default.isExecutableFile(atPath: script.path) {
                    projectPath = codebaseCandidate.path
                    return
                }
            }
        }
    }

    private func compareSourceRow(
        title: String,
        subtitle: String,
        url: URL?,
        validationError: String?,
        resolvedStatus: String,
        browseAction: @escaping () -> Void,
        clearAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire)
                Spacer()
                Button("Browse…", action: browseAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(sapphire)
                Button("Clear", action: clearAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(url == nil)
            }

            Text(url?.path ?? "No file selected")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(url == nil ? .secondary : deepSapphire)
                .lineLimit(2)
                .textSelection(.enabled)

            Text(subtitle)
                .font(.system(size: 10.5, weight: .regular, design: .default))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(validationError == nil && url != nil ? Color.green.opacity(0.9) : (url == nil ? Color.gray.opacity(0.7) : rose))
                    .frame(width: 8, height: 8)
                Text(validationError ?? resolvedStatus)
                    .font(.system(size: 10.5, weight: .semibold, design: .default))
                    .foregroundStyle(validationError == nil ? deepSapphire.opacity(0.72) : rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(cardBackground(cornerRadius: 14))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        PerfoMaceLogoMark(size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PerfoMace Launcher v2")
                                .font(.system(size: 20, weight: .semibold, design: .default))
                                .foregroundStyle(Color.white)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Winged performance control for repeatable Re-Write runs.")
                                .font(.system(size: 12, weight: .medium, design: .default))
                                .foregroundStyle(Color.white.opacity(0.78))
                        }
                    }

                    HStack(spacing: 8) {
                        heroBadge("JD with iHeart")
                    }
                }

                Spacer()
                statusPill(
                    overallRunStatus,
                    isRunning: runner.isRunning && !runner.isStopping,
                    isFailed: overallRunStatus == "Stopping" || overallRunStatus == "Needs Attention"
                )
            }

            heroAccentBar
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.14, green: 0.11, blue: 0.16), Color(red: 0.08, green: 0.09, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [brandCyan.opacity(0.75), brandOrange.opacity(0.65)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: brandBlue.opacity(0.16), radius: 14, x: 0, y: 8)
    }

    private var heroAccentBar: some View {
        HStack(spacing: 10) {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brandCyan, brandBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 94, height: 5)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brandOrange, brandEmber],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 64, height: 5)

            Circle()
                .fill(brandCyan.opacity(0.95))
                .frame(width: 6, height: 6)

            Circle()
                .fill(brandOrange.opacity(0.95))
                .frame(width: 6, height: 6)

            Spacer()
        }
        .opacity(0.95)
    }

    private var watermarkBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [brandCyan, brandBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 8, height: 8)

            Text("JD with iHeart")
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(brandInk.opacity(0.78))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(panelBorder.opacity(0.9), lineWidth: 1)
        )
        .shadow(color: brandInk.opacity(0.08), radius: 8, x: 0, y: 2)
        .allowsHitTesting(false)
    }

    private var runSummaryStrip: some View {
        HStack(spacing: 10) {
            summaryCard(title: config.appChoice == .combine ? "Sequence" : (config.appChoice == .compare ? "Compare" : "Iterations"), value: iterationSummaryValue, subtitle: iterationSummarySubtitle)
            summaryCard(title: "Planned", value: "\(runner.totalPlannedTests)", subtitle: runner.totalPlannedTests == 0 ? "Awaiting tests" : "Queued")
            summaryCard(title: "Completed", value: "\(runner.completedTests)", subtitle: runner.totalPlannedTests == 0 ? "No run" : progressLabel)
        }
    }

    private var reportTab: some View {
        VStack(spacing: 0) {
            HStack {
                viewToggle
                Text(config.appChoice == .compare ? "Compared Report" : "Report")
                    .font(.system(size: 16, weight: .semibold, design: .default))
                Spacer()
                Button("Reload") {
                    loadReportIfPresent()
                    reportReloadToken += 1
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.white.opacity(0.55))

            Divider()

            if reportURL == nil {
                VStack(spacing: 10) {
                    Text("No report yet")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                    Text(config.appChoice == .compare ? "Pick two saved reports and create the compared report." : "Run a test to generate the report.")
                        .foregroundStyle(.secondary)
                    if let lastError = runner.lastError, !lastError.isEmpty {
                        Text(lastError)
                            .font(.system(size: 12, weight: .medium, design: .default))
                            .foregroundStyle(rose)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebReportView(url: reportURL, reloadToken: reportReloadToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var liveTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                viewToggle
                Spacer()
                statusPill(
                        currentIterationLabel,
                        isRunning: runner.isRunning,
                        isFailed: runner.isStopping
                    )
                }

                executionHeroCard
                instrumentsTraceCard

                if !runner.isRunning, reportURL != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(sapphire)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.appChoice == .compare ? "Compared report ready" : "Results ready")
                                .font(.system(size: 13, weight: .semibold, design: .default))
                            .foregroundStyle(deepSapphire)
                            Text(config.appChoice == .compare ? "Open the Compared view." : "Open the Report tab.")
                            .font(.system(size: 11, weight: .regular, design: .default))
                            .foregroundStyle(deepSapphire.opacity(0.68))
                        }
                        Spacer()
                        Button("Open Report") {
                            detailTab = .report
                        }
                        .buttonStyle(.bordered)
                        .tint(sapphire)
                    }
                    .padding(14)
                    .background(premiumPanelBackground(cornerRadius: 18))
                }

                executionPanels

                liveLogCard
            }
            .padding(20)
        }
    }

    private var viewToggle: some View {
        Picker("View", selection: $detailTab) {
            ForEach(DetailTab.allCases) { tab in
                Text(tab == .report && config.appChoice == .compare ? "Compared" : tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
        .tint(sapphire)
    }

    private var progressValue: Double {
        guard runner.totalPlannedTests > 0 else { return 0 }
        return Double(runner.completedTests) / Double(runner.totalPlannedTests)
    }

    private var progressLabel: String {
        if runner.totalPlannedTests == 0 {
            return config.appChoice == .compare ? "Pick two reports" : "Running…"
        }
        return "\(runner.completedTests) of \(runner.totalPlannedTests) resolved"
    }

    private var overallRunStatus: String {
        if runner.isCheckingSetup { return "Checking Setup" }
        if runner.isStopping { return "Stopping" }
        if runner.isRunning {
            switch runner.currentTestCase {
            case "Preparing Build…":
                return "Building"
            case "Running Launch Tests":
                return "Launching"
            case "Running Login Test":
                return "Login"
            case "Running Content Tests":
                return "Content"
            case "Capturing Instruments":
                return "Tracing"
            case "Generating Report", "Report Ready":
                return "Reporting"
            case "Done":
                return "Done"
            case "Running Tests":
                return "Testing"
            default:
                return runner.currentTestCase
            }
        }
        if let code = runner.lastExitCode {
            return code == 0 ? "Done" : "Needs Attention"
        }
        return "Idle"
    }

    private var currentIterationLabel: String {
        if config.appChoice == .compare && !runner.isRunning {
            return compareInputReady ? "Compared Report Ready" : "Awaiting 2 inputs"
        }
        let current = runner.activeIteration > 0 ? runner.activeIteration : 1
        return "Iteration \(current)/\(max(runner.totalIterations, 1))"
    }

    private var resolvedPlannedCount: Int {
        runner.completedTests
    }

    private var openPlannedCount: Int {
        max(runner.totalPlannedTests - resolvedPlannedCount, 0)
    }

    private var normalizedTraceStates: [String] {
        runner.traceStatuses.values.map { $0.lowercased() }
    }

    private var instrumentsOverviewState: String {
        let states = normalizedTraceStates
        if states.contains(where: { $0 == "running" }) {
            return "Live"
        }
        if states.contains(where: { $0 == "failed" }) {
            return "Needs Attention"
        }
        if states.contains(where: { $0 == "captured" }) {
            return runner.isRunning ? "Captured" : "Ready"
        }
        if states.allSatisfy({ $0 == "disabled" || $0 == "pending" }) {
            return states.contains("disabled") ? "Skipped" : (runner.isRunning ? "Waiting" : "Idle")
        }
        return runner.isRunning ? "Waiting" : "Idle"
    }

    private var instrumentsOverviewIsRunning: Bool {
        instrumentsOverviewState == "Live" || instrumentsOverviewState == "Waiting" || instrumentsOverviewState == "Captured"
    }

    private var instrumentsOverviewIsFailed: Bool {
        instrumentsOverviewState == "Needs Attention"
    }

    private var instrumentsSummaryText: String {
        switch instrumentsOverviewState {
        case "Live":
            return "Tracing is in progress."
        case "Captured", "Ready":
            return "At least one trace is ready for report."
        case "Needs Attention":
            return "One or more traces are incomplete."
        case "Skipped":
            return "This run skipped Instruments capture."
        case "Waiting":
            return "Waiting for trace capture to begin."
        default:
            return "No active trace capture."
        }
    }

    private func executionMetricCard(title: String, value: String, subtitle: String, accent: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .default))
                .foregroundStyle(deepSapphire.opacity(0.62))
                .textCase(.uppercase)
                .tracking(0.7)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(cardBackground(cornerRadius: 16))
    }

    private func executionBadge(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title) \(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .default))
                .foregroundStyle(deepSapphire.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }

    private func premiumPanelBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                panelFill
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(panelBorder, lineWidth: 1)
            )
            .shadow(color: deepSapphire.opacity(0.022), radius: 8, x: 0, y: 3)
    }

    private var pendingPlannedCount: Int {
        runner.plannedTestCases.filter { $0.status == "Pending" }.count
    }

    private var runningPlannedCount: Int {
        runner.plannedTestCases.filter { $0.status == "Running" }.count
    }

    private var passedPlannedCount: Int {
        runner.plannedTestCases.filter { $0.status == "Passed" }.count
    }

    private var failedPlannedCount: Int {
        runner.plannedTestCases.filter { $0.status == "Failed" }.count
    }

    private var finishedPlannedCount: Int {
        runner.plannedTestCases.filter { $0.status == "Finished" || $0.status == "Stopped" }.count
    }

    private var executionHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(runner.isRunning ? "Execution in Progress" : "Last Execution")
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(sapphire.opacity(0.85))
                        .textCase(.uppercase)
                        .tracking(1.0)
                    Text(runner.currentTestCase == "Idle" && runner.isRunning ? "Starting…" : runner.currentTestCase)
                        .font(.system(size: 22, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progressLabel)
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.72))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    statusPill(
                        overallRunStatus,
                        isRunning: runner.isRunning && !runner.isStopping,
                        isFailed: overallRunStatus == "Stopping" || overallRunStatus == "Needs Attention"
                    )
                    Text(currentIterationLabel)
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.72))
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 118), spacing: 10)
                ],
                spacing: 10
            ) {
                executionMetricCard(title: "Total", value: "\(runner.totalPlannedTests)", subtitle: "Planned checks", accent: sapphire)
                executionMetricCard(title: "Resolved", value: "\(resolvedPlannedCount)", subtitle: "Latest state", accent: golden)
                executionMetricCard(title: "Open", value: "\(openPlannedCount)", subtitle: "Pending or running", accent: deepSapphire)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progressValue, total: 1)
                    .tint(sapphire)
                HStack {
                    Text("Run progress")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.65))
                    Spacer()
                    Text("\(Int(progressValue * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.8))
                }
            }
        }
        .padding(18)
        .background(premiumPanelBackground(cornerRadius: 20))
    }

    private var instrumentsTraceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instruments")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire)
                    Text("Activity, profiling, leaks, and network.")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.66))
                }
                Spacer()
                statusPill(
                    instrumentsOverviewState,
                    isRunning: instrumentsOverviewIsRunning,
                    isFailed: instrumentsOverviewIsFailed
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 150), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(["Activity Monitor", "Time Profiler", "Allocations", "Leaks", "Network"], id: \.self) { traceName in
                    traceStatusCard(name: traceName)
                }
            }
        }
        .padding(16)
        .background(premiumPanelBackground(cornerRadius: 18))
    }

    private func traceStatusCard(name: String) -> some View {
        let state = runner.traceStatuses[name] ?? "Pending"
        let accent = traceAccentColor(for: state)
        return TraceLaneChip(
            name: name,
            state: state,
            accent: accent,
            subtitle: traceStatusSubtitle(for: name, state: state)
        )
    }

    private func traceAccentColor(for state: String) -> Color {
        switch state.lowercased() {
        case "captured", "exported", "done":
            return sapphire
        case "started", "retrying", "running":
            return warmGold
        case "disabled":
            return deepSapphire.opacity(0.45)
        case "failed", "no payload", "missing":
            return rose
        default:
            return deepSapphire
        }
    }

    private func traceStatusSubtitle(for name: String, state: String) -> String {
        switch state.lowercased() {
        case "captured", "exported", "done":
            return "Ready for report."
        case "started", "retrying", "running":
            return "Capture in progress."
        case "disabled":
            return "Skipped for this run."
        case "failed", "no payload", "missing":
            return "No usable data."
        default:
            return "Waiting."
        }
    }

    private var executionBoardCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Execution Board")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire)
                    Text("Live test state.")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.66))
                }
                Spacer()
                statusPill("\(resolvedPlannedCount)/\(max(runner.totalPlannedTests, 1))", isRunning: runner.isRunning)
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 92), spacing: 8)
                ],
                spacing: 8
            ) {
                executionBadge("Pend.", count: pendingPlannedCount, color: deepSapphire.opacity(0.72))
                executionBadge("Run", count: runningPlannedCount, color: golden)
                executionBadge("Fin.", count: finishedPlannedCount, color: warmGold.opacity(0.92))
                executionBadge("Pass", count: passedPlannedCount, color: sapphire)
                executionBadge("Fail", count: failedPlannedCount, color: rose)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !runner.plannedTestCases.isEmpty {
                        ForEach(orderedPlannedTests) { item in
                            HStack(spacing: 12) {
                                statusIcon(for: item.status)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.system(size: 11, weight: .semibold, design: .default))
                                        .foregroundStyle(deepSapphire)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    Text(item.status.uppercased())
                                        .font(.system(size: 9, weight: .semibold, design: .default))
                                        .foregroundStyle(deepSapphire.opacity(0.5))
                                        .tracking(0.9)
                                }
                                Spacer()
                                statusPill(item.status, isRunning: item.status == "Running", isFailed: item.status == "Failed")
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(item.status == "Running" ? sapphire.opacity(0.05) : Color.white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        item.status == "Running" ? sapphire.opacity(0.28) : panelBorder,
                                        lineWidth: item.status == "Running" ? 1.1 : 1
                                    )
                            )
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Waiting for tests…")
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(deepSapphire)
                            Text("Start a run to populate live status.")
                                .font(.system(size: 11, weight: .regular, design: .default))
                                .foregroundStyle(deepSapphire.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(cardBackground(cornerRadius: 14))
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(premiumPanelBackground(cornerRadius: 18))
    }

    private var executionPanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                executionBoardCard
                    .frame(minWidth: 420)
                executionTimelineCard
                    .frame(minWidth: 420)
            }

            VStack(alignment: .leading, spacing: 16) {
                executionBoardCard
                executionTimelineCard
            }
        }
    }

    private var executionTimelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                    Text("Execution Timeline")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire)
                    Text("Current phase and latest transitions.")
                        .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.66))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { index, item in
                        timelineRow(item, isLast: index == timelineEntries.count - 1)
                    }

                    if timelineEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No activity yet.")
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(deepSapphire)
                            Text("Once the run starts, the most recent test transitions will appear here.")
                                .font(.system(size: 11, weight: .regular, design: .default))
                                .foregroundStyle(deepSapphire.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(cardBackground(cornerRadius: 14))
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(premiumPanelBackground(cornerRadius: 18))
    }

    private var liveLogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Log")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundStyle(deepSapphire)
                    Text("Trimmed active run output.")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundStyle(deepSapphire.opacity(0.66))
                }
                Spacer()
                statusPill(runner.isRunning ? "Streaming" : "Paused", isRunning: runner.isRunning, isFailed: runner.isStopping)
            }

            ScrollView {
                Text(runner.log.isEmpty ? "(no output yet)" : runner.log)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundStyle(Color(red: 0.10, green: 0.14, blue: 0.20))
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(red: 0.99, green: 0.995, blue: 1.00))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(panelBorder, lineWidth: 1)
                            )
                    )
            }
            .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
        }
        .padding(18)
        .background(premiumPanelBackground(cornerRadius: 18))
    }

    private var orderedPlannedTests: [TestCaseStatus] {
        let priority: [String: Int] = [
            "Running": 0,
            "Failed": 1,
            "Passed": 2,
            "Finished": 3,
            "Stopped": 4,
            "Pending": 5,
        ]

        return runner.plannedTestCases.sorted { lhs, rhs in
            let leftPriority = priority[lhs.status] ?? 99
            let rightPriority = priority[rhs.status] ?? 99
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.name < rhs.name
        }
    }

    private var activeRunCard: some View {
        HStack {
            if runner.isRunning {
                ProgressView().scaleEffect(0.6)
                Text(runner.isStopping ? "Stopping…" : (runner.currentTestCase == "Idle" ? "Starting…" : runner.currentTestCase))
                    .font(.system(size: 13, weight: .semibold, design: .default))
                Spacer()
                statusPill(overallRunStatus, isRunning: runner.isRunning && !runner.isStopping, isFailed: overallRunStatus == "Stopping" || overallRunStatus == "Needs Attention")
            } else {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                Text("No active test")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(.secondary)
                Spacer()
                statusPill("Idle")
            }
        }
        .padding(8)
        .background(cardBackground(cornerRadius: 8))
    }

    private func summaryCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.60))
                    .textCase(.uppercase)
                    .tracking(0.9)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(sapphire)
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .regular, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.58))
                    .lineLimit(1)
            }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .padding(9)
        .background(summaryBackground)
    }

    private func statusIcon(for status: String) -> some View {
        if status == "Running" {
            return AnyView(ProgressView().scaleEffect(0.6))
        }
        if status == "Passed" {
            return AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(sapphire))
        }
        if status == "Finished" {
            return AnyView(Image(systemName: "clock.badge.checkmark.fill").foregroundStyle(deepSapphire.opacity(0.8)))
        }
        if status == "Failed" {
            return AnyView(Image(systemName: "xmark.circle.fill").foregroundStyle(rose))
        }
        if status == "Stopped" {
            return AnyView(Image(systemName: "stop.circle.fill").foregroundStyle(deepSapphire.opacity(0.7)))
        }
        return AnyView(Image(systemName: "circle").foregroundStyle(golden.opacity(0.8)))
    }

    private func statusPill(_ text: String, isRunning: Bool = false, isFailed: Bool = false) -> some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isFailed
                    ? rose.opacity(0.16)
                    : (isRunning ? warmGold.opacity(0.88) : mist)
                )
                .foregroundStyle(
                    isFailed
                    ? rose
                : (isRunning ? deepSapphire : sapphire)
            )
            .clipShape(Capsule())
    }

    private func heroBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), brandCyan.opacity(0.10)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.20), lineWidth: 1)
            )
            .foregroundStyle(Color.white.opacity(0.88))
            .clipShape(Capsule())
    }

    private var summaryBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(panelFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(panelBorder, lineWidth: 1)
            )
            .shadow(color: sapphire.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(panelFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(panelBorder, lineWidth: 1)
            )
            .shadow(color: sapphire.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    private struct TimelineEntry: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let status: String
        let timestamp: String
        let accent: Color
        let isCurrent: Bool
    }

    private var timelineEntries: [TimelineEntry] {
        var entries: [TimelineEntry] = []

        entries.append(
            TimelineEntry(
                title: runner.isRunning ? "Current phase" : "Last phase",
                detail: runner.currentTestCase,
                status: overallRunStatus,
                timestamp: runner.isRunning ? currentIterationLabel : (runner.lastExitCode == nil ? "Idle" : "Completed"),
                accent: sapphire,
                isCurrent: true
            )
        )

        if runner.traceStatuses.values.contains(where: { $0.lowercased() != "pending" }) {
            entries.append(
                TimelineEntry(
                    title: "Instruments",
                    detail: instrumentsSummaryText,
                    status: instrumentsOverviewState,
                    timestamp: traceSummaryTimestamp,
                    accent: golden,
                    isCurrent: instrumentsOverviewState == "Live"
                )
            )
        }

        for item in runner.recentTestCases.sorted(by: { $0.timestamp > $1.timestamp }).prefix(5) {
            entries.append(
                TimelineEntry(
                    title: item.name,
                    detail: timelineDetail(for: item.status),
                    status: item.status,
                    timestamp: item.timestamp.formatted(date: .omitted, time: .standard),
                    accent: accentForTimelineStatus(item.status),
                    isCurrent: item.status == "Running"
                )
            )
        }

        return entries
    }

    private var traceSummaryTimestamp: String {
        let states = normalizedTraceStates
        if states.contains(where: { $0 == "started" || $0 == "running" || $0 == "retrying" }) {
            return "Live"
        }
        if states.contains(where: { $0 == "captured" || $0 == "exported" }) {
            return "Captured"
        }
        if states.contains(where: { $0 == "failed" || $0 == "no payload" || $0 == "missing" }) {
            return "Attention"
        }
        if states.contains("disabled") {
            return "Skipped"
        }
        return "Pending"
    }

    private func timelineDetail(for status: String) -> String {
        switch status.lowercased() {
        case "running":
            return "In flight."
        case "passed":
            return "Completed cleanly."
        case "failed":
            return "Needs attention."
        case "finished":
            return "Wrapped without a final assertion."
        case "stopped":
            return "Stopped."
        default:
            return "Recent event."
        }
    }

    private func accentForTimelineStatus(_ status: String) -> Color {
        switch status.lowercased() {
        case "running":
            return golden
        case "passed":
            return sapphire
        case "failed":
            return rose
        case "finished":
            return deepSapphire.opacity(0.72)
        case "stopped":
            return deepSapphire.opacity(0.52)
        default:
            return golden.opacity(0.72)
        }
    }

    private func timelineRow(_ entry: TimelineEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(entry.accent.opacity(entry.isCurrent ? 0.18 : 0.12))
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(entry.accent)
                        .frame(width: entry.isCurrent ? 10 : 8, height: entry.isCurrent ? 10 : 8)
                }
                .padding(.top, 1)

                if !isLast {
                    Rectangle()
                        .fill(panelBorder)
                        .frame(width: 1)
                        .padding(.vertical, 4)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire)
                Text(entry.detail)
                    .font(.system(size: 11, weight: .regular, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.66))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(entry.timestamp)
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.50))
                statusPill(entry.status, isRunning: entry.status == "Running", isFailed: entry.status == "Failed")
            }
        }
        .padding(.vertical, 8)
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case report
    case live

    var id: String { rawValue }
    var title: String {
        switch self {
        case .report: "Report"
        case .live: "Live"
        }
    }
}

private enum CompareRole {
    case baseline
    case candidate
}

private struct TraceLaneChip: View {
    let name: String
    let state: String
    let accent: Color
    let subtitle: String

    @State private var pulse = false
    private let sapphire = Color(red: 0.05, green: 0.26, blue: 0.60)
    private let deepSapphire = Color(red: 0.04, green: 0.14, blue: 0.35)
    private let rose = Color(red: 0.80, green: 0.23, blue: 0.27)
    private let surfaceFill = Color.white
    private let surfaceBorder = Color(red: 0.86, green: 0.89, blue: 0.93)

    private var isLive: Bool {
        switch state.lowercased() {
        case "started", "running", "retrying":
            return true
        default:
            return false
        }
    }

    private var stateTone: Color {
        switch state.lowercased() {
        case "captured", "exported", "done":
            return accent
        case "started", "retrying", "running":
            return warmPulse
        case "disabled":
            return accent.opacity(0.55)
        case "failed", "no payload", "missing":
            return rose
        default:
            return accent
        }
    }

    private var warmPulse: Color {
        Color(red: 0.96, green: 0.74, blue: 0.17)
    }

    private var glowOpacity: Double {
        if isLive { return pulse ? 0.65 : 0.25 }
        if state.lowercased() == "disabled" { return 0.10 }
        return 0.18
    }

    private var laneSymbol: String {
        switch name {
        case "Activity Monitor":
            return "waveform.path.ecg"
        case "Time Profiler":
            return "timer"
        case "Allocations":
            return "memorychip.fill"
        case "Leaks":
            return "memorychip"
        case "Network":
            return "network"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }

    private var trailingDots: [Double] {
        [0.18, 0.46, 0.76]
    }

    private var trailTone: Color {
        switch state.lowercased() {
        case "failed", "no payload", "missing":
            return rose
        case "disabled":
            return deepSapphire.opacity(0.35)
        case "captured", "exported", "done":
            return sapphire
        default:
            return warmPulse
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.96),
                                    Color(red: 0.98, green: 0.98, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(accent.opacity(0.26), lineWidth: 1)
                        )

                    Circle()
                        .fill(accent.opacity(glowOpacity))
                        .frame(width: 24, height: 24)
                        .scaleEffect(isLive ? (pulse ? 1.18 : 0.88) : 1.0)
                        .blur(radius: 1.1)

                    ForEach(trailingDots.indices, id: \.self) { index in
                        Circle()
                            .fill(trailTone.opacity(isLive ? (pulse ? 0.56 : 0.25) : 0.16))
                            .frame(width: 4.5, height: 4.5)
                            .offset(x: CGFloat(-8 + (index * 5)), y: CGFloat(index % 2 == 0 ? -7 : 7))
                            .scaleEffect(isLive ? (pulse ? 1.1 : 0.9) : 1.0)
                            .opacity(isLive ? 1.0 : 0.6)
                    }

                    Circle()
                        .fill(stateTone)
                        .frame(width: isLive ? 10 : 8, height: isLive ? 10 : 8)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.85), lineWidth: 1)
                        )
                        .scaleEffect(isLive ? (pulse ? 1.08 : 0.94) : 1.0)

                    Image(systemName: laneSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(deepSapphire.opacity(0.90))
                        .offset(y: -0.5)
                }
                .frame(width: 40, height: 40)
                .shadow(color: accent.opacity(0.16), radius: 10, x: 0, y: 4)
                .shadow(color: accent.opacity(isLive ? 0.10 : 0.04), radius: isLive ? 14 : 8, x: 0, y: 0)

                Capsule(style: .continuous)
                    .fill(stateTone.opacity(0.12))
                    .frame(width: 8, height: 8)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                Text(state)
                    .font(.system(size: 12.5, weight: .semibold, design: .default))
                    .foregroundStyle(stateTone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 9, weight: .regular, design: .default))
                    .foregroundStyle(deepSapphire.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(surfaceFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(surfaceBorder, lineWidth: 1)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(isLive ? 0.10 : 0.05),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blendMode(.plusLighter)
        )
        .shadow(color: deepSapphire.opacity(0.03), radius: 8, x: 0, y: 3)
        .onAppear {
            pulse = isLive
        }
        .onChange(of: state) { _, _ in
            pulse = isLive
        }
        .animation(
            isLive ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true) : .default,
            value: pulse
        )
    }
}

private struct PerfoMaceLogoMark: View {
    let size: CGFloat

    private let ink = Color(red: 0.11, green: 0.15, blue: 0.21)
    private let cyan = Color(red: 0.20, green: 0.78, blue: 0.96)
    private let blue = Color(red: 0.24, green: 0.56, blue: 0.98)
    private let orange = Color(red: 1.00, green: 0.56, blue: 0.18)
    private let ember = Color(red: 0.96, green: 0.36, blue: 0.18)
    private let pale = Color(red: 0.92, green: 0.98, blue: 1.00)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.13, green: 0.16, blue: 0.22), Color(red: 0.07, green: 0.09, blue: 0.13)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [cyan.opacity(0.55), orange.opacity(0.38)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1, size * 0.02)
                        )
                )

            Circle()
                .fill(blue.opacity(0.18))
                .frame(width: size * 0.74, height: size * 0.74)
                .offset(x: -size * 0.08, y: size * 0.07)

            wingBlock
                .rotationEffect(.degrees(-12))
                .offset(x: -size * 0.12, y: -size * 0.08)

            circuitLines
                .offset(x: -size * 0.06, y: size * 0.02)

            gaugeBlock
                .offset(x: size * 0.20, y: -size * 0.06)

            shaftBlock
                .rotationEffect(.degrees(-42))
                .offset(x: -size * 0.02, y: size * 0.08)
        }
        .frame(width: size, height: size)
        .shadow(color: cyan.opacity(0.22), radius: 6, x: 0, y: 3)
        .shadow(color: orange.opacity(0.18), radius: 10, x: 0, y: 0)
    }

    private var wingBlock: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [cyan.opacity(0.92), blue.opacity(0.45)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: size * (0.28 - CGFloat(index) * 0.02), height: max(4, size * 0.045))
                    .rotationEffect(.degrees(-22 + Double(index) * 8))
                    .offset(x: -size * 0.16 + CGFloat(index) * size * 0.02,
                            y: -size * 0.18 + CGFloat(index) * size * 0.08)
            }
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [pale.opacity(0.8), cyan.opacity(0.58)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: size * (0.20 - CGFloat(index) * 0.015), height: max(3, size * 0.03))
                    .rotationEffect(.degrees(-30 + Double(index) * 10))
                    .offset(x: -size * 0.04 + CGFloat(index) * size * 0.015,
                            y: -size * 0.07 + CGFloat(index) * size * 0.05)
            }
        }
    }

    private var circuitLines: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [cyan.opacity(0.95), orange.opacity(index.isMultiple(of: 2) ? 0.90 : 0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: size * (0.18 + CGFloat(index) * 0.015), height: max(2, size * 0.018))
                    .offset(x: -size * 0.12 - CGFloat(index) * size * 0.055,
                            y: size * 0.08 - CGFloat(index) * size * 0.04)
                Circle()
                    .fill(index.isMultiple(of: 2) ? cyan : orange)
                    .frame(width: max(2.5, size * 0.025), height: max(2.5, size * 0.025))
                    .offset(x: -size * 0.05 - CGFloat(index) * size * 0.065,
                            y: size * 0.08 - CGFloat(index) * size * 0.04)
            }
        }
    }

    private var gaugeBlock: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.12, green: 0.15, blue: 0.20))
                .frame(width: size * 0.34, height: size * 0.34)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [cyan.opacity(0.95), orange.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1.5, size * 0.025)
                        )
                )

            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(index >= 5 ? orange.opacity(0.92) : cyan.opacity(0.88))
                    .frame(width: max(1.5, size * 0.008), height: max(5, size * 0.035))
                    .offset(y: -size * 0.145)
                    .rotationEffect(.degrees(Double(index) * 30))
            }

            Circle()
                .fill(ink)
                .frame(width: size * 0.18, height: size * 0.18)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )

            Path { path in
                path.move(to: CGPoint(x: size * 0.17, y: size * 0.17))
                path.addLine(to: CGPoint(x: size * 0.24, y: size * 0.12))
            }
            .stroke(
                LinearGradient(
                    colors: [orange, ember],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: max(1.4, size * 0.02), lineCap: .round)
            )
        }
    }

    private var shaftBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [pale, cyan.opacity(0.65), blue.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.34, height: max(5, size * 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.04, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
        }
    }
}

struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.22))
            configuration.content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(red: 0.86, green: 0.89, blue: 0.93), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 3)
    }
}
