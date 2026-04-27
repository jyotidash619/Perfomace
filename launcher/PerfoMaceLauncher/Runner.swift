import Foundation
import AppKit

struct RunConfiguration: Sendable {
    enum Scenario: String, CaseIterable, Hashable, Identifiable, Sendable {
        case coldLaunch = "cold_launch"
        case warmResume = "warm_resume"
        case warmStart30s = "warm_start_30s"
        case backgroundForegroundCycle = "background_foreground_cycle"
        case login = "login"
        case tabSwitchJourney = "tab_switch_journey"
        case search = "search"
        case imageLoading = "image_loading"
        case radioPlayStart = "radio_play_start"
        case podcastPlayStart = "podcast_play_start"
        case playlistPlayStart = "playlist_play_start"
        case radioScroll = "radio_scroll"
        case miniToFullPlayer = "mini_to_full_player"
        case skipBurst = "skip_burst"
        case logout = "logout"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .coldLaunch: "Cold Launch"
            case .warmResume: "Warm Resume"
            case .warmStart30s: "Warm Start (<30s)"
            case .backgroundForegroundCycle: "BG/FG Cycle"
            case .login: "Login"
            case .tabSwitchJourney: "Tab Switch Journey"
            case .search: "Search"
            case .imageLoading: "Image Loading"
            case .radioPlayStart: "Radio Play Start"
            case .podcastPlayStart: "Podcast Play Start"
            case .playlistPlayStart: "Playlist Play Start"
            case .radioScroll: "Radio Scroll"
            case .miniToFullPlayer: "Mini → Full Player"
            case .skipBurst: "Skip Burst"
            case .logout: "Logout"
            }
        }
    }

    enum AppChoice: String, CaseIterable, Identifiable, Sendable {
        case qa
        case legacy
        case custom
        case combine
        case compare

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .qa: "Re-Write"
            case .legacy: "Legacy QA"
            case .custom: "Custom"
            case .combine: "Combined"
            case .compare: "Compare"
            }
        }

        var runLabel: String {
            switch self {
            case .qa: "Re-Write"
            case .legacy: "Legacy"
            case .custom: "Custom"
            case .combine: "Combined"
            case .compare: "Compare"
            }
        }
    }

    var appChoice: AppChoice = .qa
    var customBundleId: String = ""

    var email: String = "testjp100@test.com"
    var password: String = ""

    var strictAds: Bool = false
    var instrumentsLeaks: Bool = true
    var instrumentsNetwork: Bool = true
    var instrumentsTimeProfiler: Bool = true
    var instrumentsAllocations: Bool = true
    var resetSimulator: Bool = false
    var zipResults: Bool = true
    var repeatCount: Int = 1
    var selectedScenarios: Set<Scenario> = Set(Scenario.allCases)

    var selectedScenarioKeys: [String] {
        Scenario.allCases
            .filter { selectedScenarios.contains($0) }
            .map(\.rawValue)
    }

    var shouldRunPreflight: Bool {
        selectedScenarios.contains(.login)
            || selectedScenarios.contains(.tabSwitchJourney)
            || selectedScenarios.contains(.search)
            || selectedScenarios.contains(.imageLoading)
            || selectedScenarios.contains(.radioPlayStart)
            || selectedScenarios.contains(.podcastPlayStart)
            || selectedScenarios.contains(.playlistPlayStart)
            || selectedScenarios.contains(.radioScroll)
            || selectedScenarios.contains(.warmStart30s)
            || selectedScenarios.contains(.backgroundForegroundCycle)
            || selectedScenarios.contains(.miniToFullPlayer)
            || selectedScenarios.contains(.skipBurst)
            || selectedScenarios.contains(.logout)
    }
}

private struct PlannedExecution: Hashable {
    let name: String
    let iteration: Int
    let totalIterations: Int

    var displayName: String {
        totalIterations > 1 ? "[\(iteration)/\(totalIterations)] \(name)" : name
    }
}

private struct PerfStatusEvent {
    let name: String
    let state: String
}

private struct PerfDoneEvent {
    let exitCode: Int32
}

private struct PerfOutputDirectoryEvent {
    let url: URL
}

private struct CombinedRunStep: Codable {
    let order: Int
    let appChoice: String
    let title: String
    let jsonFile: String
    let csvFile: String
    let htmlFile: String
}

private struct CombinedSessionManifest: Codable {
    let generatedAt: String
    let sequenceLabel: String
    let reportMode: String?
    let steps: [CombinedRunStep]
}

private struct ComparisonSource {
    let appChoice: RunConfiguration.AppChoice
    let order: Int
    let resolvedJSON: URL
    let selectedCSV: URL?
    let selectedHTML: URL?
}

enum SetupCheckState: String, Sendable {
    case ok
    case warn
    case fail

    var displayName: String {
        switch self {
        case .ok: return "Ready"
        case .warn: return "Warning"
        case .fail: return "Blocked"
        }
    }
}

struct SetupCheckStatus: Identifiable, Sendable {
    let id: String
    let state: SetupCheckState
    let title: String
    let detail: String
    let action: String
}

struct SetupSummary: Sendable {
    let checks: [SetupCheckStatus]
    let overallState: SetupCheckState
    let warningCount: Int
    let rawOutput: String

    var blockingChecks: [SetupCheckStatus] {
        checks.filter { $0.state == .fail }
    }

    var warningChecks: [SetupCheckStatus] {
        checks.filter { $0.state == .warn }
    }

    var isReady: Bool {
        blockingChecks.isEmpty
    }

    var headline: String {
        switch overallState {
        case .ok:
            return "Ready to run"
        case .warn:
            return "Ready with warnings"
        case .fail:
            return "Needs attention"
        }
    }

    var summaryLine: String {
        if !blockingChecks.isEmpty {
            let blockerLabel = blockingChecks.count == 1 ? "1 blocker" : "\(blockingChecks.count) blockers"
            if warningCount > 0 {
                let warningLabel = warningCount == 1 ? "1 warning" : "\(warningCount) warnings"
                return "\(blockerLabel) · \(warningLabel)"
            }
            return blockerLabel
        }
        if warningCount > 0 {
            return warningCount == 1 ? "1 warning to review" : "\(warningCount) warnings to review"
        }
        return "All setup checks passed"
    }

    var primaryFailureMessage: String {
        if let blocker = blockingChecks.first {
            if blocker.action.isEmpty {
                return blocker.detail
            }
            return "\(blocker.detail) \(blocker.action)"
        }
        if let warning = warningChecks.first {
            if warning.action.isEmpty {
                return warning.detail
            }
            return "\(warning.detail) \(warning.action)"
        }
        return "PerfoMace setup check complete. Ready to go."
    }
}

private struct SetupRunResult: Sendable {
    let summary: SetupSummary?
    let exitCode: Int32
    let errorMessage: String?
}

func resolveHarnessRoot(from projectRoot: URL) -> URL {
    let directScript = projectRoot.appendingPathComponent("run_perf.sh")
    if FileManager.default.isExecutableFile(atPath: directScript.path) {
        return projectRoot
    }

    let codebaseRoot = projectRoot.appendingPathComponent("codebase", isDirectory: true)
    let codebaseScript = codebaseRoot.appendingPathComponent("run_perf.sh")
    if FileManager.default.isExecutableFile(atPath: codebaseScript.path) {
        return codebaseRoot
    }

    return projectRoot
}

func resolveResultsRoot(from harnessRoot: URL) -> URL {
    let candidates = [
        harnessRoot.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true),
        harnessRoot.appendingPathComponent("results", isDirectory: true),
    ]

    for candidate in candidates where directoryLooksPopulated(candidate) {
        return candidate
    }

    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }

    return candidates[0]
}

private extension FileManager {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}

private func directoryLooksPopulated(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let interestingNames = [
        "perf.log",
        "Performance.xcresult",
        "PerformanceReport.html",
        "PerformanceReport.json",
        "PerformanceReport.csv",
        "PerformanceReport.txt",
        "traces",
        "iterations",
    ]
    for name in interestingNames {
        let candidate = url.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return true
        }
    }
    if let contents = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ), !contents.isEmpty {
        return true
    }
    return false
}

@MainActor
final class Runner: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var isStopping: Bool = false
    @Published var isCheckingSetup: Bool = false
    @Published var log: String = ""
    @Published var currentTestCase: String = "Idle"
    @Published var recentTestCases: [TestCaseStatus] = []
    @Published var plannedTestCases: [TestCaseStatus] = []
    @Published var totalPlannedTests: Int = 0
    @Published var completedTests: Int = 0
    @Published var activeIteration: Int = 0
    @Published var totalIterations: Int = 1
    @Published var lastExitCode: Int32?
    @Published var lastError: String?
    @Published var traceStatuses: [String: String] = [
        "Activity Monitor": "Pending",
        "Time Profiler": "Pending",
        "Allocations": "Pending",
        "Leaks": "Pending",
        "Network": "Pending",
    ]
    @Published var latestReportURL: URL?
    @Published var latestResultsURL: URL?
    @Published var setupSummary: SetupSummary?
    @Published var setupCheckedAt: Date?

    private var process: Process?
    private var currentProjectRoot: URL?
    private var currentHarnessRoot: URL?
    private var currentResultsRoot: URL?
    private var baseConfig: RunConfiguration?
    private var lineBuffer: String = ""
    private var plannedTestNames: [String] = []
    private var executionPlan: [PlannedExecution] = []
    private var executionStatuses: [PlannedExecution: String] = [:]
    private var executionUpdatedAt: [PlannedExecution: Date] = [:]
    private var currentExecution: PlannedExecution?
    private var pendingLogText: String = ""
    private var flushTask: Task<Void, Never>?
    private let maxVisibleLogCharacters: Int = 16_000
    private var stopRequested: Bool = false
    private var pendingExitCode: Int32?
    private var didFinalizeRun: Bool = false
    private var doneFallbackTask: Task<Void, Never>?
    private var currentOutputDirectory: URL?
    private var combinedSequence: [RunConfiguration.AppChoice] = []
    private var combinedStepIndex: Int = 0
    private var combinedSessionDirectory: URL?
    private var combinedSessionSteps: [CombinedRunStep] = []
    private var temporaryComparisonWorkspace: URL?
    private var currentAppChoice: RunConfiguration.AppChoice?
    private var currentRunLabel: String?

    func run(projectRoot: URL, _ config: RunConfiguration) {
        guard !isRunning, !isCheckingSetup else { return }

        if config.appChoice == .compare {
            lastError = "Choose two report files in Compare mode, then generate the comparison report."
            return
        }

        refreshSetup(projectRoot: projectRoot, config: config, shouldLaunchAfterCheck: true)
    }

    func refreshSetup(projectRoot: URL, config: RunConfiguration) {
        guard !isCheckingSetup else { return }
        refreshSetup(projectRoot: projectRoot, config: config, shouldLaunchAfterCheck: false)
    }

    func compareReports(projectRoot: URL, baselineSelection: URL, candidateSelection: URL) {
        guard !isRunning else { return }

        let harnessRoot = resolveHarnessRoot(from: projectRoot)
        let resultsRoot = resolveResultsRoot(from: harnessRoot)
        currentProjectRoot = projectRoot
        currentHarnessRoot = harnessRoot
        currentResultsRoot = resultsRoot
        baseConfig = nil

        var compareConfig = RunConfiguration()
        compareConfig.appChoice = .compare
        resetRunState(for: compareConfig, clearLog: true)
        currentAppChoice = .compare
        currentRunLabel = "Compare"
        log = "========== Compare Reports ==========\n"
        configureComparePlan()
        updateCompareStep(named: "Resolve Inputs", status: "Running")
        currentTestCase = "Resolving Compare Inputs…"

        guard let baseline = resolveComparisonSource(selection: baselineSelection, appChoice: .qa, order: 1) else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }
        guard let candidate = resolveComparisonSource(selection: candidateSelection, appChoice: .legacy, order: 2) else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }
        updateCompareStep(named: "Resolve Inputs", status: "Passed")
        updateCompareStep(named: "Stage Sources", status: "Running")

        guard let outputDirectory = makeComparisonSessionDirectory(resultsRoot: resultsRoot, folderName: "compared_reports") else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }
        guard let workspaceDirectory = makeTemporaryComparisonWorkspace() else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }
        temporaryComparisonWorkspace = workspaceDirectory
        latestResultsURL = outputDirectory
        latestReportURL = nil

        guard let baselineStep = prepareComparisonStep(from: baseline, sessionDirectory: workspaceDirectory) else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }
        guard let candidateStep = prepareComparisonStep(from: candidate, sessionDirectory: workspaceDirectory) else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }
        updateCompareStep(named: "Stage Sources", status: "Passed")
        updateCompareStep(named: "Build Compared Report", status: "Running")

        let manifest = CombinedSessionManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            sequenceLabel: "Compared Report · Re-Write vs Legacy",
            reportMode: "manual",
            steps: [baselineStep, candidateStep]
        )
        let manifestURL = workspaceDirectory.appendingPathComponent("session_manifest.json")
        currentTestCase = "Building Compared Report…"

        generateComparisonReport(
            sessionDirectory: workspaceDirectory,
            outputDirectory: outputDirectory,
            manifestURL: manifestURL,
            manifest: manifest,
            projectRoot: projectRoot,
            comparisonFailureMessage: "Compared report generation failed.",
            outputStem: "ComparedReport"
        ) { [weak self] success in
            guard let self else { return }
            self.updateCompareStep(named: "Build Compared Report", status: success ? "Passed" : "Failed")
        }
    }

    func comparisonSelectionMessage(for selection: URL?, expectedAppChoice: RunConfiguration.AppChoice) -> String? {
        guard let selection else { return nil }
        guard let resolvedJSON = resolveReportJSON(from: selection) else {
            return comparisonInputErrorMessage(for: selection)
        }
        return validateComparisonSelection(selection: selection, resolvedJSON: resolvedJSON, expectedAppChoice: expectedAppChoice)
    }

    func comparisonSelectionResolvedLabel(for selection: URL?, expectedAppChoice: RunConfiguration.AppChoice) -> String {
        guard let selection else { return "Awaiting selection" }
        if let message = comparisonSelectionMessage(for: selection, expectedAppChoice: expectedAppChoice) {
            return message
        }
        if FileManager.default.directoryExists(at: selection) {
            return "Ready: \(selection.lastPathComponent)"
        }
        return "Ready: \(selection.deletingLastPathComponent().lastPathComponent)"
    }

    private func resetRunState(for config: RunConfiguration, clearLog: Bool) {
        isRunning = true
        isStopping = false
        stopRequested = false
        lastExitCode = nil
        lastError = nil
        if clearLog {
            log = ""
        }
        currentTestCase = "Preparing Build…"
        recentTestCases = []
        plannedTestCases = []
        totalPlannedTests = 0
        completedTests = 0
        activeIteration = 0
        totalIterations = max(1, config.repeatCount)
        plannedTestNames = []
        executionPlan = []
        executionStatuses = [:]
        executionUpdatedAt = [:]
        currentExecution = nil
        traceStatuses = [
            "Activity Monitor": "Pending",
            "Time Profiler": "Pending",
            "Allocations": "Pending",
            "Leaks": "Pending",
            "Network": "Pending",
        ]
        latestReportURL = nil
        latestResultsURL = nil
        lineBuffer = ""
        pendingLogText = ""
        pendingExitCode = nil
        didFinalizeRun = false
        temporaryComparisonWorkspace = nil
        currentOutputDirectory = nil
        currentAppChoice = nil
        currentRunLabel = nil
        doneFallbackTask?.cancel()
        doneFallbackTask = nil
        flushTask?.cancel()
        flushTask = nil
    }

    private func refreshSetup(projectRoot: URL, config: RunConfiguration, shouldLaunchAfterCheck: Bool) {
        let harnessRoot = resolveHarnessRoot(from: projectRoot)
        let setupScriptURL = harnessRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("setup_env.sh")

        guard FileManager.default.isExecutableFile(atPath: setupScriptURL.path) || FileManager.default.fileExists(atPath: setupScriptURL.path) else {
            let message = "setup_env.sh not found at: \(setupScriptURL.path)"
            if shouldLaunchAfterCheck {
                lastError = message
            }
            setupSummary = nil
            return
        }

        if shouldLaunchAfterCheck {
            currentTestCase = "Checking Setup…"
            lastError = nil
        }
        isCheckingSetup = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.executeSetupCheck(
                projectRoot: projectRoot,
                harnessRoot: harnessRoot,
                setupScriptURL: setupScriptURL,
                config: config
            )

            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingSetup = false
                self.setupSummary = result.summary
                self.setupCheckedAt = Date()

                if shouldLaunchAfterCheck {
                    guard result.exitCode == 0, let summary = result.summary, summary.isReady else {
                        self.isRunning = false
                        self.currentTestCase = "Setup Needs Attention"
                        self.lastError = result.summary?.primaryFailureMessage ?? result.errorMessage ?? "PerfoMace setup needs attention before you run."
                        return
                    }
                    self.startRun(projectRoot: projectRoot, harnessRoot: harnessRoot, config: config)
                    return
                }

                if let summary = result.summary {
                    self.lastError = summary.isReady ? nil : summary.primaryFailureMessage
                } else if let errorMessage = result.errorMessage {
                    self.lastError = errorMessage
                }
            }
        }
    }

    private func startRun(projectRoot: URL, harnessRoot: URL, config: RunConfiguration) {
        let resultsRoot = resolveResultsRoot(from: harnessRoot)
        currentProjectRoot = projectRoot
        currentHarnessRoot = harnessRoot
        currentResultsRoot = resultsRoot
        baseConfig = config

        resetRunState(for: config, clearLog: true)

        let scriptURL = harnessRoot.appendingPathComponent("run_perf.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            isRunning = false
            lastError = "run_perf.sh not found or not executable at: \(scriptURL.path)"
            return
        }
        preloadPlannedTests(for: config)

        if config.appChoice == .combine {
            combinedSequence = [.qa, .legacy]
            combinedStepIndex = 0
            combinedSessionSteps = []
            combinedSessionDirectory = makeCombinedSessionDirectory(resultsRoot: resultsRoot)
            guard combinedSessionDirectory != nil else {
                isRunning = false
                return
            }
            latestResultsURL = combinedSessionDirectory ?? resultsRoot
            launchNextCombinedRun()
            return
        }

        launchProcess(
            projectRoot: projectRoot,
            scriptURL: scriptURL,
            config: config,
            label: config.appChoice.runLabel
        )
    }

    nonisolated private static func configureEnvironment(_ env: inout [String: String], for config: RunConfiguration) {
        switch config.appChoice {
        case .qa:
            env["PERF_APP"] = "qa"
            env.removeValue(forKey: "PERF_APP_BUNDLE_ID")
        case .legacy:
            env["PERF_APP"] = "legacy"
            env["PERF_APP_BUNDLE_ID"] = "com.clearchannel.iheartradio.legacy.qa"
        case .custom:
            env["PERF_APP"] = "custom"
            env["PERF_APP_BUNDLE_ID"] = config.customBundleId
        case .combine:
            env["PERF_APP"] = "qa"
            env.removeValue(forKey: "PERF_APP_BUNDLE_ID")
        case .compare:
            env["PERF_APP"] = "qa"
            env.removeValue(forKey: "PERF_APP_BUNDLE_ID")
        }

        if !config.email.isEmpty { env["PERF_EMAIL"] = config.email }
        if !config.password.isEmpty { env["PERF_PASSWORD"] = config.password }
        env["PERF_AD_BEHAVIOR"] = config.strictAds ? "fail" : "bypass"
        env["TEST_ITERATIONS"] = String(max(1, config.repeatCount))

        env["RESET_SIM"] = config.resetSimulator ? "1" : "0"
        env["ZIP_RESULTS"] = config.zipResults ? "1" : "0"
        env["AUTO_OPEN_RESULTS"] = "0"
        env["AUTO_OPEN_TRACES"] = "0"
        env["AUTO_OPEN_RESULTS_FOLDER"] = "0"
        env["AUTO_PACKAGE_RESULTS"] = config.zipResults ? "1" : "0"
        env["PERF_SCENARIOS"] = config.selectedScenarioKeys.joined(separator: ",")

        env["INSTRUMENTS"] = "1"
        env["INSTRUMENTS_NETWORK"] = config.instrumentsNetwork ? "1" : "0"
        env["INSTRUMENTS_LEAKS"] = config.instrumentsLeaks ? "1" : "0"
        env["INSTRUMENTS_TIME_PROFILER"] = config.instrumentsTimeProfiler ? "1" : "0"
        env["INSTRUMENTS_ALLOCATIONS"] = config.instrumentsAllocations ? "1" : "0"
    }

    nonisolated private static func executeSetupCheck(
        projectRoot: URL,
        harnessRoot: URL,
        setupScriptURL: URL,
        config: RunConfiguration
    ) -> SetupRunResult {
        let process = Process()
        process.currentDirectoryURL = harnessRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [setupScriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        Self.configureEnvironment(&environment, for: config)
        environment["PERFOMACE_SETUP_FORMAT"] = "structured"
        environment["PERFOMACE_PROJECT_ROOT"] = projectRoot.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return SetupRunResult(summary: nil, exitCode: 1, errorMessage: "Unable to launch the setup check: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let summary = parseSetupSummary(from: output)
        let errorMessage: String?
        if summary == nil {
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "PerfoMace setup check returned no output."
            } else {
                errorMessage = output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            errorMessage = nil
        }
        return SetupRunResult(summary: summary, exitCode: process.terminationStatus, errorMessage: errorMessage)
    }

    nonisolated private static func parseSetupSummary(from output: String) -> SetupSummary? {
        var checks: [SetupCheckStatus] = []
        var overallState: SetupCheckState = .ok
        var warningCount = 0

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("SETUP_CHECK|") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 6 else { continue }
                let state = SetupCheckState(rawValue: parts[2]) ?? .warn
                checks.append(
                    SetupCheckStatus(
                        id: parts[1],
                        state: state,
                        title: parts[3],
                        detail: parts[4],
                        action: parts[5]
                    )
                )
                continue
            }

            if line.hasPrefix("SETUP_SUMMARY|") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 4 {
                    switch parts[1] {
                    case "ready":
                        overallState = .ok
                    case "warning":
                        overallState = .warn
                    case "failed":
                        overallState = .fail
                    default:
                        overallState = .warn
                    }
                    warningCount = Int(parts[3]) ?? warningCount
                }
            }
        }

        guard !checks.isEmpty else { return nil }
        return SetupSummary(
            checks: checks,
            overallState: overallState,
            warningCount: warningCount,
            rawOutput: output
        )
    }

    private func launchProcess(projectRoot: URL, scriptURL: URL, config: RunConfiguration, label: String) {
        currentAppChoice = config.appChoice
        currentRunLabel = label
        currentTestCase = combinedSequence.isEmpty ? "Preparing Build…" : "Preparing \(label)…"

        if !log.isEmpty {
            log.append("\n")
        }
        log.append("========== \(label) Run ==========\n")

        let p = Process()
        p.currentDirectoryURL = projectRoot
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        Self.configureEnvironment(&env, for: config)
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.enqueueLogChunk(chunk)
            }
        }

        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.flushPendingLog()
                let exitCode = self?.pendingExitCode ?? proc.terminationStatus
                self?.handleProcessExit(exitCode: exitCode)
                self?.process = nil
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            process = nil
        }
    }

    func stop() {
        guard let process else { return }
        stopRequested = true
        isStopping = true
        currentTestCase = "Stopping…"
        Task.detached {
            if process.isRunning {
                process.interrupt()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func openResults(projectRoot: URL) {
        let harnessRoot = resolveHarnessRoot(from: projectRoot)
        let resultsURL = resolveResultsRoot(from: harnessRoot)
        NSWorkspace.shared.open(resultsURL)
    }

    private func handleProcessExit(exitCode: Int32) {
        let wasStopped = stopRequested
        if !combinedSequence.isEmpty || combinedSessionDirectory != nil {
            handleCombinedProcessExit(exitCode: exitCode, wasStopped: wasStopped)
            return
        }
        completeRunIfNeeded(exitCode: exitCode, wasStopped: wasStopped)
    }

    private func handleCombinedProcessExit(exitCode: Int32, wasStopped: Bool) {
        doneFallbackTask?.cancel()
        doneFallbackTask = nil
        pendingExitCode = nil

        guard !wasStopped else {
            completeRunIfNeeded(exitCode: exitCode, wasStopped: wasStopped)
            combinedSequence = []
            combinedSessionDirectory = nil
            combinedSessionSteps = []
            return
        }

        let didCaptureReport = snapshotCombinedStep()
        if !didCaptureReport {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            combinedSequence = []
            combinedSessionDirectory = nil
            combinedSessionSteps = []
            return
        }

        if exitCode != 0 {
            log.append("Combined note: \(currentAppChoice?.runLabel ?? "Pass") finished with exit \(exitCode), but report artifacts were captured and comparison will continue.\n")
        }

        combinedStepIndex += 1
        if combinedStepIndex < combinedSequence.count {
            launchNextCombinedRun()
            return
        }

        currentTestCase = "Building Comparison Graphs…"
        generateCombinedComparisonReport()
    }

    private func launchNextCombinedRun() {
        guard let baseConfig, let currentProjectRoot, let currentHarnessRoot else { return }
        guard combinedStepIndex < combinedSequence.count else { return }

        var childConfig = baseConfig
        let choice = combinedSequence[combinedStepIndex]
        childConfig.appChoice = choice

        let scriptURL = currentHarnessRoot.appendingPathComponent("run_perf.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            isRunning = false
            lastError = "run_perf.sh not found or not executable at: \(scriptURL.path)"
            return
        }

        let clearLog = combinedStepIndex == 0
        resetRunState(for: childConfig, clearLog: clearLog)
        preloadPlannedTests(for: childConfig)
        latestResultsURL = combinedSessionDirectory ?? currentResultsRoot
        currentTestCase = "Pass \(combinedStepIndex + 1) of \(combinedSequence.count) · \(choice.runLabel)"
        launchProcess(
            projectRoot: currentProjectRoot,
            scriptURL: scriptURL,
            config: childConfig,
            label: "Pass \(combinedStepIndex + 1)/\(combinedSequence.count) · \(choice.runLabel)"
        )
    }

    private func makeCombinedSessionDirectory(resultsRoot: URL) -> URL? {
        makeComparisonSessionDirectory(resultsRoot: resultsRoot, folderName: "combined_sessions")
    }

    private func makeComparisonSessionDirectory(resultsRoot: URL, folderName: String) -> URL? {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let sessionRoot = resultsRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            return sessionRoot
        } catch {
            lastError = "Unable to create comparison session folder: \(error.localizedDescription)"
            return nil
        }
    }

    private func makeTemporaryComparisonWorkspace() -> URL? {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory
            .appendingPathComponent("PerfoMaceCompare-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            return workspace
        } catch {
            lastError = "Unable to create comparison workspace: \(error.localizedDescription)"
            return nil
        }
    }

    private func snapshotCombinedStep() -> Bool {
        guard let combinedSessionDirectory, let currentAppChoice else { return false }
        let fm = FileManager.default
        let order = combinedStepIndex + 1
        let prefix = String(format: "%02d_%@", order, currentAppChoice.rawValue)
        let sourceRoot = currentOutputDirectory ?? currentResultsRoot

        guard let sourceRoot else {
            lastError = "Missing output folder after \(currentAppChoice.runLabel) pass \(order)."
            return false
        }

        let sourceJSON = sourceRoot.appendingPathComponent("PerformanceReport.json")
        let sourceCSV = sourceRoot.appendingPathComponent("PerformanceReport.csv")
        let sourceHTML = sourceRoot.appendingPathComponent("PerformanceReport.html")

        guard fm.fileExists(atPath: sourceJSON.path),
              fm.fileExists(atPath: sourceCSV.path),
              fm.fileExists(atPath: sourceHTML.path) else {
            lastError = "Missing report files after \(currentAppChoice.runLabel) pass \(order)."
            return false
        }

        let targetJSON = combinedSessionDirectory.appendingPathComponent("\(prefix).json")
        let targetCSV = combinedSessionDirectory.appendingPathComponent("\(prefix).csv")
        let targetHTML = combinedSessionDirectory.appendingPathComponent("\(prefix).html")

        do {
            try replaceItemIfNeeded(at: targetJSON, with: sourceJSON)
            try replaceItemIfNeeded(at: targetCSV, with: sourceCSV)
            try replaceItemIfNeeded(at: targetHTML, with: sourceHTML)
            combinedSessionSteps.append(
                CombinedRunStep(
                    order: order,
                    appChoice: currentAppChoice.rawValue,
                    title: "Pass \(order) · \(currentAppChoice.runLabel)",
                    jsonFile: targetJSON.lastPathComponent,
                    csvFile: targetCSV.lastPathComponent,
                    htmlFile: targetHTML.lastPathComponent
                )
            )
            return true
        } catch {
            lastError = "Unable to snapshot \(currentAppChoice.runLabel) report: \(error.localizedDescription)"
            return false
        }
    }

    private func replaceItemIfNeeded(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private func generateCombinedComparisonReport() {
        guard let sessionDirectory = combinedSessionDirectory, let currentProjectRoot else {
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }

        let manifest = CombinedSessionManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            sequenceLabel: "Re-Write -> Legacy",
            reportMode: "combined",
            steps: combinedSessionSteps
        )
        let manifestURL = sessionDirectory.appendingPathComponent("session_manifest.json")
        currentTestCase = "Building Comparison Graphs…"
        generateComparisonReport(
            sessionDirectory: sessionDirectory,
            outputDirectory: sessionDirectory,
            manifestURL: manifestURL,
            manifest: manifest,
            projectRoot: currentProjectRoot,
            comparisonFailureMessage: "Combined comparison report generation failed."
        )
    }

    private func generateComparisonReport(
        sessionDirectory: URL,
        outputDirectory: URL,
        manifestURL: URL,
        manifest: CombinedSessionManifest,
        projectRoot: URL,
        comparisonFailureMessage: String,
        outputStem: String = "CombinedComparisonReport",
        completion: ((Bool) -> Void)? = nil
    ) {
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            lastError = "Unable to write comparison manifest: \(error.localizedDescription)"
            completion?(false)
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
            return
        }

        let scriptURL = projectRoot
            .appendingPathComponent("codebase", isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("perf_compare_report.py")
        let outputURL = outputDirectory.appendingPathComponent("\(outputStem).html")
        let csvURL = outputDirectory.appendingPathComponent("\(outputStem).csv")

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            scriptURL.path,
            "--session-dir", sessionDirectory.path,
            "--manifest", manifestURL.path,
            "--out", outputURL.path,
            "--csv", csvURL.path,
            "--project-root", projectRoot.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.enqueueLogChunk(chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.flushPendingLog()
                if proc.terminationStatus == 0 {
                    self.latestReportURL = outputURL
                    self.latestResultsURL = outputDirectory
                    self.combinedSequence = []
                    self.combinedSessionDirectory = nil
                    self.combinedSessionSteps = []
                    self.cleanupTemporaryComparisonWorkspace()
                    completion?(true)
                    self.completeRunIfNeeded(exitCode: 0, wasStopped: false)
                } else {
                    self.lastError = comparisonFailureMessage
                    self.combinedSequence = []
                    self.combinedSessionDirectory = nil
                    self.combinedSessionSteps = []
                    self.cleanupTemporaryComparisonWorkspace()
                    completion?(false)
                    self.completeRunIfNeeded(exitCode: proc.terminationStatus, wasStopped: false)
                }
                self.process = nil
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            lastError = "Unable to launch comparison report generation: \(error.localizedDescription)"
            combinedSequence = []
            combinedSessionDirectory = nil
            combinedSessionSteps = []
            cleanupTemporaryComparisonWorkspace()
            completion?(false)
            completeRunIfNeeded(exitCode: 1, wasStopped: false)
        }
    }

    private func prepareComparisonStep(
        from source: ComparisonSource,
        sessionDirectory: URL
    ) -> CombinedRunStep? {
        let prefix = String(format: "%02d_%@", source.order, source.appChoice.rawValue)
        let targetJSON = sessionDirectory.appendingPathComponent("\(prefix).json")
        let targetCSV = source.selectedCSV != nil ? sessionDirectory.appendingPathComponent("\(prefix).csv") : nil
        let targetHTML = source.selectedHTML != nil ? sessionDirectory.appendingPathComponent("\(prefix).html") : nil

        do {
            try replaceItemIfNeeded(at: targetJSON, with: source.resolvedJSON)
            if let selectedCSV = source.selectedCSV, let targetCSV {
                try replaceItemIfNeeded(at: targetCSV, with: selectedCSV)
            }
            if let selectedHTML = source.selectedHTML, let targetHTML {
                try replaceItemIfNeeded(at: targetHTML, with: selectedHTML)
            }
        } catch {
            lastError = "Unable to stage compare input \(source.resolvedJSON.lastPathComponent): \(error.localizedDescription)"
            return nil
        }

        let label = source.appChoice == .qa ? "Re-Write" : "Legacy"
        log.append("Prepared \(label) compare source: \(source.resolvedJSON.lastPathComponent)\n")
        return CombinedRunStep(
            order: source.order,
            appChoice: source.appChoice.rawValue,
            title: "\(label) Snapshot",
            jsonFile: targetJSON.lastPathComponent,
            csvFile: targetCSV?.lastPathComponent ?? "",
            htmlFile: targetHTML?.lastPathComponent ?? ""
        )
    }

    private func resolveComparisonSource(
        selection: URL,
        appChoice: RunConfiguration.AppChoice,
        order: Int
    ) -> ComparisonSource? {
        guard let resolvedJSON = resolveReportJSON(from: selection) else {
            lastError = comparisonInputErrorMessage(for: selection)
            return nil
        }
        if let validationError = validateComparisonSelection(selection: selection, resolvedJSON: resolvedJSON, expectedAppChoice: appChoice) {
            lastError = validationError
            return nil
        }
        let selectedExt = selection.pathExtension.lowercased()
        let exactCSV: URL?
        let exactHTML: URL?
        let isDirectorySelection = FileManager.default.directoryExists(at: selection)
        switch selectedExt {
        case "csv":
            exactCSV = selection
            exactHTML = expectedComparisonSibling(for: selection, resolvedJSON: resolvedJSON, newExtension: "html")
        case "html":
            exactCSV = expectedComparisonSibling(for: selection, resolvedJSON: resolvedJSON, newExtension: "csv")
            exactHTML = selection
        default:
            if isDirectorySelection {
                exactCSV = expectedComparisonSibling(for: selection, resolvedJSON: resolvedJSON, newExtension: "csv")
                exactHTML = expectedComparisonSibling(for: selection, resolvedJSON: resolvedJSON, newExtension: "html")
            } else {
                exactCSV = siblingReportFile(for: resolvedJSON, newExtension: "csv")
                exactHTML = siblingReportFile(for: resolvedJSON, newExtension: "html")
            }
        }
        return ComparisonSource(
            appChoice: appChoice,
            order: order,
            resolvedJSON: resolvedJSON,
            selectedCSV: exactCSV,
            selectedHTML: exactHTML
        )
    }

    private func validateComparisonSelection(selection: URL, resolvedJSON: URL, expectedAppChoice: RunConfiguration.AppChoice) -> String? {
        let normalizedSelection = selection.path.lowercased()
        let normalizedJSON = resolvedJSON.path.lowercased()
        if normalizedSelection.contains("/compared_reports/") || normalizedSelection.contains("/manual_compare_sessions/") ||
            normalizedJSON.contains("/compared_reports/") || normalizedJSON.contains("/manual_compare_sessions/") {
            return "Compare only supports real run reports. Pick PerformanceReport.json/csv/html from a QA_PerfoMace_<timestamp> or Legacy_PerfoMace_<timestamp> folder, not a previous ComparedReport."
        }

        guard
            let data = try? Data(contentsOf: resolvedJSON),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "Could not read compare input \(resolvedJSON.lastPathComponent)."
        }

        let scenarioCards = payload["scenario_cards"] as? [[String: Any]] ?? []
        let scenarioSummary = payload["custom_timings_summary"] as? [String: Any] ?? [:]
        let hasScenarioData = !scenarioCards.isEmpty || !scenarioSummary.isEmpty
        let hasRunShape =
            payload["trace_summaries"] != nil ||
            payload["custom_timings"] != nil ||
            payload["tested_app"] != nil
        let testedApp = payload["tested_app"] as? [String: Any]
        let testedKey = (testedApp?["key"] as? String ?? "").lowercased()

        if !hasRunShape {
            return "Compare input \(selection.lastPathComponent) is not a PerfoMace run report. Pick a PerformanceReport.json/csv/html file from a run folder."
        }

        if !hasScenarioData {
            return "Compare input \(selection.lastPathComponent) is a partial report with no scenario timings. Pick a full run report from a QA_PerfoMace_<timestamp> or Legacy_PerfoMace_<timestamp> folder."
        }

        switch expectedAppChoice {
        case .qa, .legacy:
            if testedKey != expectedAppChoice.rawValue {
                return "Compare input \(selection.lastPathComponent) is a \(testedKey.uppercased()) report, but this slot expects \(expectedAppChoice.runLabel)."
            }
        default:
            break
        }

        return nil
    }

    private func resolveReportJSON(from selection: URL) -> URL? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let direct = selection.appendingPathComponent("PerformanceReport.json")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            return nil
        }
        let ext = selection.pathExtension.lowercased()
        let fm = FileManager.default
        if ext == "json", fm.fileExists(atPath: selection.path) {
            return selection
        }
        if ext == "csv" || ext == "html" {
            let candidate = selection.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func siblingReportFile(for jsonURL: URL, newExtension: String) -> URL? {
        let candidate = jsonURL.deletingPathExtension().appendingPathExtension(newExtension)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func expectedComparisonSibling(for selection: URL, resolvedJSON: URL, newExtension: String) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: selection.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let direct = selection.appendingPathComponent("PerformanceReport.\(newExtension)")
            return fm.fileExists(atPath: direct.path) ? direct : nil
        }
        return siblingReportFile(for: resolvedJSON, newExtension: newExtension)
    }

    private func comparisonInputErrorMessage(for selection: URL) -> String {
        "Compare input \(selection.lastPathComponent) needs a real run report. Pick a QA_PerfoMace_<timestamp> or Legacy_PerfoMace_<timestamp> folder, or choose a PerformanceReport.json/csv/html file from inside that folder."
    }

    private func configureComparePlan() {
        totalPlannedTests = 3
        completedTests = 0
        plannedTestCases = [
            TestCaseStatus(name: "Resolve Inputs", status: "Pending", timestamp: .distantPast),
            TestCaseStatus(name: "Stage Sources", status: "Pending", timestamp: .distantPast),
            TestCaseStatus(name: "Build Compared Report", status: "Pending", timestamp: .distantPast),
        ]
        recentTestCases = []
    }

    private func cleanupTemporaryComparisonWorkspace() {
        guard let temporaryComparisonWorkspace else { return }
        try? FileManager.default.removeItem(at: temporaryComparisonWorkspace)
        self.temporaryComparisonWorkspace = nil
    }

    private func updateCompareStep(named name: String, status: String) {
        let timestamp = Date()
        plannedTestCases = plannedTestCases.map { item in
            item.name == name ? TestCaseStatus(name: item.name, status: status, timestamp: timestamp) : item
        }
        completedTests = plannedTestCases.filter {
            ["Passed", "Failed", "Finished", "Stopped"].contains($0.status)
        }.count
        recordRecentTestCase(name: name, status: status)
    }

    private func ingestLogChunk(_ chunk: String) {
        lineBuffer.append(chunk)
        let lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return }
        lineBuffer = String(lines.last ?? "")
        for line in lines.dropLast() {
            let value = String(line)
            guard shouldParseLogLine(value) else { continue }
            processLogLine(value)
        }
    }

    private func enqueueLogChunk(_ chunk: String) {
        pendingLogText.append(chunk)
        ingestLogChunk(chunk)

        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.flushPendingLog()
        }
    }

    private func flushPendingLog() {
        guard !pendingLogText.isEmpty else {
            flushTask = nil
            return
        }

        log.append(pendingLogText)
        pendingLogText = ""

        if log.count > maxVisibleLogCharacters {
            log = String(log.suffix(maxVisibleLogCharacters))
        }

        flushTask?.cancel()
        flushTask = nil
    }

    private func processLogLine(_ line: String) {
        if executionPlan.isEmpty, let planned = parsePlannedTests(line: line), !planned.isEmpty {
            if planned != plannedTestNames {
                plannedTestNames = uniqueOrdered(planned)
                rebuildExecutionPlan()
            }
        }
        if let traceEvent = parseTraceEvent(line: line) {
            updateTraceStatus(name: traceEvent.name, state: traceEvent.state)
        }
        if let done = parseDone(line: line) {
            pendingExitCode = done.exitCode
            lastExitCode = done.exitCode
            currentTestCase = done.exitCode == 0 ? "Finalizing Results…" : "Wrapping Up After Errors…"
            settleCurrentExecutionIfNeeded(as: done.exitCode == 0 ? "Finished" : "Failed")
            scheduleDoneFallback()
            return
        }
        if let outputDirectory = parseOutputDirectory(line: line) {
            currentOutputDirectory = outputDirectory.url
        }
        if let phase = parsePhase(line: line) {
            handlePhase(phase)
        }
        updateIteration(from: line)
        if let perfEvent = parsePerfStatus(line: line) {
            switch perfEvent.state {
            case "started":
                let execution = markExecution(named: perfEvent.name, as: "Running")
                currentExecution = execution
                currentTestCase = execution?.displayName ?? perfEvent.name
            case "finished":
                let execution = markExecution(named: perfEvent.name, as: "Finished")
                if currentExecution?.name == perfEvent.name {
                    currentExecution = nil
                    currentTestCase = "Running Tests"
                }
                if execution == nil {
                    currentTestCase = "Running Tests"
                }
            default:
                break
            }
            return
        }
        if let started = parseTestCase(line: line, keyword: "started.") {
            let execution = markExecution(named: started, as: "Running")
            currentExecution = execution
            currentTestCase = execution?.displayName ?? started
            return
        }
        if let passed = parseTestCase(line: line, keyword: "passed") {
            currentTestCase = "Running Tests"
            _ = markExecution(named: passed, as: "Passed")
            return
        }
        if let failed = parseTestCase(line: line, keyword: "failed") {
            currentTestCase = "Running Tests"
            _ = markExecution(named: failed, as: "Failed")
        }
    }

    private func parseTestCase(line: String, keyword: String) -> String? {
        guard line.contains("Test Case '-[") && line.contains(keyword) else { return nil }
        let pattern = "Test Case '\\-\\[[^ ]+ ([^\\]]+)\\]'"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let nameRange = Range(match.range(at: 1), in: line) else { return nil }
        let rawName = String(line[nameRange])
        guard !isInternalExecutionIdentifier(rawName) else { return nil }
        return displayName(forExecutionIdentifier: rawName)
    }

    private func parsePlannedTests(line: String) -> [String]? {
        guard line.contains("-only-testing:") else { return nil }
        let pattern = "-only-testing:([^\\s\\\"]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, options: [], range: range)
        let names = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1, let nameRange = Range(match.range(at: 1), in: line) else { return nil }
            guard let rawName = String(line[nameRange]).components(separatedBy: "/").last else { return nil }
            if isInternalExecutionIdentifier(rawName) { return nil }
            return displayName(forExecutionIdentifier: rawName)
        }
        return names
    }

    private func isInternalExecutionIdentifier(_ identifier: String) -> Bool {
        identifier == "testPrepareFreshLoggedOutState" || identifier == "testInstrumentsProbeJourney"
    }

    private func parseTraceEvent(line: String) -> PerfStatusEvent? {
        let pattern = #"PERF_TRACE\s+name=(.+?)\s+state=(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 2,
              let nameRange = Range(match.range(at: 1), in: line),
              let stateRange = Range(match.range(at: 2), in: line) else { return nil }
        return PerfStatusEvent(
            name: String(line[nameRange]),
            state: String(line[stateRange])
        )
    }

    private func preloadPlannedTests(for config: RunConfiguration) {
        plannedTestNames = config.selectedScenarios
            .sorted { lhs, rhs in
                guard
                    let leftIndex = RunConfiguration.Scenario.allCases.firstIndex(of: lhs),
                    let rightIndex = RunConfiguration.Scenario.allCases.firstIndex(of: rhs)
                else {
                    return lhs.displayName < rhs.displayName
                }
                return leftIndex < rightIndex
            }
            .map(\.displayName)
        rebuildExecutionPlan()
    }

    private func parsePerfStatus(line: String) -> PerfStatusEvent? {
        let pattern = #"PERF_STATUS\s+iteration=\d+/\d+\s+metric=(.+?)\s+state=(started|finished)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 2,
              let metricRange = Range(match.range(at: 1), in: line),
              let stateRange = Range(match.range(at: 2), in: line) else { return nil }
        return PerfStatusEvent(
            name: displayName(forExecutionIdentifier: String(line[metricRange])),
            state: String(line[stateRange])
        )
    }

    private func parsePhase(line: String) -> String? {
        let pattern = #"PERF_PHASE\s+phase=(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let phaseRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[phaseRange])
    }

    private func parseDone(line: String) -> PerfDoneEvent? {
        let pattern = #"PERF_DONE\s+exit=(-?\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let exitRange = Range(match.range(at: 1), in: line),
              let exitCode = Int32(String(line[exitRange])) else { return nil }
        return PerfDoneEvent(exitCode: exitCode)
    }

    private func parseOutputDirectory(line: String) -> PerfOutputDirectoryEvent? {
        let pattern = #"PERF_OUTPUT_DIR\s+path=(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let pathRange = Range(match.range(at: 1), in: line) else { return nil }
        let path = String(line[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return PerfOutputDirectoryEvent(url: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func displayName(forExecutionIdentifier identifier: String) -> String {
        let aliases: [String: String] = [
            "testColdLaunchTime": "Cold Launch",
            "ColdLaunch": "Cold Launch",
            "testWarmResumeTime": "Warm Resume",
            "WarmResume": "Warm Resume",
            "testWarmStart30s": "Warm Start (<30s)",
            "WarmStart30s": "Warm Start (<30s)",
            "testBackgroundForegroundCycle": "BG/FG Cycle",
            "BackgroundForegroundCycle": "BG/FG Cycle",
            "testLoginSpeed": "Login",
            "Login": "Login",
            "testTabSwitchJourney": "Tab Switch Journey",
            "TabSwitchJourney": "Tab Switch Journey",
            "testSearchSpeed": "Search",
            "Search": "Search",
            "testImageLoading": "Image Loading",
            "ImageLoading": "Image Loading",
            "testAlbumArtworkFirstPaint": "Image Loading",
            "AlbumArtworkFirstPaint": "Image Loading",
            "testRadioPlayStart": "Radio Play Start",
            "RadioPlayStart": "Radio Play Start",
            "testRadioScrollPerformance": "Radio Scroll",
            "RadioScroll": "Radio Scroll",
            "testPodcastTabLoad": "Podcast Play Start",
            "PodcastPlayStart": "Podcast Play Start",
            "testPlaylistLoad": "Playlist Play Start",
            "PlaylistPlayStart": "Playlist Play Start",
            "testMiniToFullPlayerTransition": "Mini → Full Player",
            "MiniToFullPlayer": "Mini → Full Player",
            "testSkipBurst": "Skip Burst",
            "SkipBurst": "Skip Burst",
            "testLogoutSpeed": "Logout",
            "Logout": "Logout",
        ]
        if let alias = aliases[identifier] {
            return alias
        }
        return identifier
            .replacingOccurrences(of: "test", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private func trimRecent() {
        if recentTestCases.count > 12 {
            recentTestCases = Array(recentTestCases.suffix(12))
        }
    }

    private func recordRecentTestCase(name: String, status: String) {
        if let index = recentTestCases.lastIndex(where: { $0.name == name }) {
            recentTestCases.remove(at: index)
        }
        recentTestCases.append(TestCaseStatus(name: name, status: status, timestamp: Date()))
        trimRecent()
    }

    private func handlePhase(_ phase: String) {
        let previousPhase = currentTestCase
        currentTestCase = phase
        if phase != "Running Tests", previousPhase == "Running Tests" || currentExecution != nil {
            settleCurrentExecutionIfNeeded(as: "Finished")
        }
    }

    private func completeRunIfNeeded(exitCode: Int32, wasStopped: Bool) {
        guard !didFinalizeRun else { return }
        didFinalizeRun = true
        doneFallbackTask?.cancel()
        doneFallbackTask = nil
        completeRun(exitCode: exitCode, wasStopped: wasStopped)
    }

    private func completeRun(exitCode: Int32, wasStopped: Bool) {
        isRunning = false
        isStopping = false
        lastExitCode = exitCode
        currentTestCase = wasStopped ? "Stopped" : (exitCode == 0 ? "Done" : "Finished with issues")
        currentExecution = nil
        stopRequested = false
        pendingExitCode = nil
        if wasStopped {
            markRunningExecutionsStopped()
        } else {
            for execution in executionPlan {
                switch executionStatuses[execution] {
                case "Running":
                    setExecutionStatus(execution, to: exitCode == 0 ? "Passed" : "Failed")
                case "Finished":
                    setExecutionStatus(execution, to: exitCode == 0 ? "Passed" : "Finished")
                default:
                    break
                }
            }
            syncPublishedStatuses()
        }

        if combinedSequence.isEmpty {
            let preferredResultsURL = currentOutputDirectory ?? currentResultsRoot
            if latestResultsURL == nil {
                latestResultsURL = preferredResultsURL
            }
            if latestReportURL == nil, let preferredResultsURL {
                let reportURL = preferredResultsURL.appendingPathComponent("PerformanceReport.html")
                if FileManager.default.fileExists(atPath: reportURL.path) {
                    latestReportURL = reportURL
                }
            }
        }

        if !wasStopped {
            combinedSequence = []
            combinedStepIndex = 0
            combinedSessionDirectory = nil
            combinedSessionSteps = []
        }
    }

    private func scheduleDoneFallback() {
        doneFallbackTask?.cancel()
        doneFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isRunning, let exitCode = self.pendingExitCode, !self.didFinalizeRun else { return }
            if let process = self.process, process.isRunning {
                process.terminate()
            }
            self.flushPendingLog()
            self.completeRunIfNeeded(exitCode: exitCode, wasStopped: self.stopRequested)
        }
    }

    private func shouldParseLogLine(_ line: String) -> Bool {
        line.contains("PERF_")
            || line.contains("Test Case '-[")
            || line.contains("-only-testing:")
            || line.contains("PERF_TRACE")
            || line.contains("🔁 Iteration")
    }

    private func rebuildExecutionPlan() {
        guard !plannedTestNames.isEmpty else {
            executionPlan = []
            executionStatuses = [:]
            plannedTestCases = []
            totalPlannedTests = 0
            completedTests = 0
            return
        }

        let previousStatuses = executionStatuses
        let previousUpdatedAt = executionUpdatedAt
        let previousPlan = executionPlan
        var nextPlan: [PlannedExecution] = []

        for iteration in 1...max(1, totalIterations) {
            for name in plannedTestNames {
                nextPlan.append(PlannedExecution(name: name, iteration: iteration, totalIterations: totalIterations))
            }
        }

        executionPlan = nextPlan
        executionStatuses = [:]
        executionUpdatedAt = [:]
        for execution in executionPlan {
            if let existing = previousPlan.first(where: { $0 == execution }),
               let status = previousStatuses[existing] {
                executionStatuses[execution] = status
                executionUpdatedAt[execution] = previousUpdatedAt[existing]
            } else {
                executionStatuses[execution] = "Pending"
            }
        }
        syncPublishedStatuses()
    }

    private func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func updateTraceStatus(name: String, state: String) {
        let normalizedName = name.replacingOccurrences(of: "_", with: " ")
        traceStatuses[normalizedName] = normalizeTraceState(state)
    }

    private func markExecution(named name: String, as status: String) -> PlannedExecution? {
        let execution: PlannedExecution?
        if let currentExecution, currentExecution.name == name, executionStatuses[currentExecution] == "Running" {
            execution = currentExecution
        } else {
            execution = executionPlan.first(where: { planned in
                planned.name == name && (executionStatuses[planned] == "Pending" || executionStatuses[planned] == "Running")
            })
        }

        if let execution {
            setExecutionStatus(execution, to: status)
            if status == "Passed" || status == "Failed" || status == "Finished" || status == "Stopped" {
                currentExecution = nil
            } else if status == "Running" {
                currentExecution = execution
            }
        }
        return execution
    }

    private func syncPublishedStatuses() {
        totalPlannedTests = executionPlan.count
        completedTests = executionPlan.filter {
            let status = executionStatuses[$0] ?? "Pending"
            return status == "Passed" || status == "Failed" || status == "Stopped" || status == "Finished"
        }.count
        plannedTestCases = executionPlan.map { execution in
            TestCaseStatus(
                name: execution.displayName,
                status: executionStatuses[execution] ?? "Pending",
                timestamp: executionUpdatedAt[execution] ?? .distantPast
            )
        }
    }

    private func markRunningExecutionsStopped() {
        for execution in executionPlan where executionStatuses[execution] == "Running" {
            setExecutionStatus(execution, to: "Stopped")
        }
        syncPublishedStatuses()
    }

    private func settleCurrentExecutionIfNeeded(as terminalStatus: String) {
        if let currentExecution, executionStatuses[currentExecution] == "Running" {
            setExecutionStatus(currentExecution, to: terminalStatus)
            self.currentExecution = nil
            return
        }

        if let fallbackExecution = executionPlan.last(where: { executionStatuses[$0] == "Running" }) {
            setExecutionStatus(fallbackExecution, to: terminalStatus)
            currentExecution = nil
        }
    }

    private func setExecutionStatus(_ execution: PlannedExecution, to status: String) {
        let previous = executionStatuses[execution]
        guard previous != status || executionUpdatedAt[execution] == nil else { return }
        executionStatuses[execution] = status
        executionUpdatedAt[execution] = Date()
        if status != "Pending" {
            recordRecentTestCase(name: execution.displayName, status: status)
        }
        syncPublishedStatuses()
    }

    private func normalizeTraceState(_ state: String) -> String {
        switch state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "started", "running", "retrying":
            return "Running"
        case "captured", "exported", "done":
            return "Captured"
        case "disabled":
            return "Disabled"
        case "failed", "no payload", "missing":
            return "Failed"
        default:
            return state.capitalized
        }
    }

    private func updateIteration(from line: String) {
        guard let match = line.range(of: #"^\s*🔁 Iteration (\d+)/(\d+)"#, options: .regularExpression) else { return }
        let content = String(line[match])
        let numbers = content
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard numbers.count >= 2 else { return }
        activeIteration = numbers[0]
        totalIterations = max(numbers[1], 1)
        if executionPlan.isEmpty || executionPlan.first?.totalIterations != totalIterations {
            rebuildExecutionPlan()
        }
    }
}

struct TestCaseStatus: Identifiable {
    var id: String { name }
    let name: String
    let status: String
    let timestamp: Date
}
