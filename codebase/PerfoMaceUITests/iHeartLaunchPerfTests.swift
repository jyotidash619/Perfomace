import XCTest
import Foundation

final class iHeartLaunchPerfTests: XCTestCase {
    private let coldLaunchInteractiveTimeout: TimeInterval = 12
    private let warmResumeInteractiveTimeout: TimeInterval = 10

    private enum Env {
        static let appBundleId = "PERF_APP_BUNDLE_ID"
        static let appKey = "PERF_APP"
        static let currentIteration = "PERF_CURRENT_ITERATION"
        static let repeatCount = "PERF_REPEAT_COUNT"
    }

    private func makeApp() -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let bundleId = resolveBundleId(from: env)
        print("ℹ️ XCTest using bundle id: \(bundleId)")
        return XCUIApplication(bundleIdentifier: bundleId)
    }

    private func readConfig(_ key: String, from env: [String: String]) -> String? {
        if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return v
        }
        if let v = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let v = UserDefaults.standard.string(forKey: key) {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func resolveBundleId(from env: [String: String]) -> String {
        let explicit = readConfig(Env.appBundleId, from: env)
        if let explicit { return explicit }
        #if PERF_APP_LEGACY
        return "com.clearchannel.iheartradio.legacy.qa"
        #elseif PERF_APP_QA
        return "com.clearchannel.iheartradio.qa"
        #endif
        let appKey = readConfig(Env.appKey, from: env) ?? "qa"
        switch appKey.lowercased() {
        case "legacy":
            return "com.clearchannel.iheartradio.legacy.qa"
        case "qa":
            return "com.clearchannel.iheartradio.qa"
        default:
            return "com.clearchannel.iheartradio.qa"
        }
    }

    func testColdLaunchTime() {
        let app = makeApp()
        app.terminate()
        XCUIDevice.shared.press(.home)
        emitScenarioEvent(name: "ColdLaunch", state: "started")
        defer { emitScenarioEvent(name: "ColdLaunch", state: "finished") }

        let options = XCTMeasureOptions()
        options.iterationCount = 1

        var duration: TimeInterval = 0
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            XCUIDevice.shared.press(.home)
            app.terminate()
            let start = CFAbsoluteTimeGetCurrent()
            app.launch()
            XCTAssertTrue(
                waitForAppInteractive(app: app, timeout: coldLaunchInteractiveTimeout),
                "App did not become interactive after cold launch."
            )
            duration = CFAbsoluteTimeGetCurrent() - start
            app.terminate()
        }

        emitPerfMetric(name: "ColdLaunch", duration: duration)
    }

    func testWarmResumeTime() {
        let app = makeApp()
        app.terminate()
        app.launch()
        XCTAssertTrue(
            waitForAppInteractive(app: app, timeout: coldLaunchInteractiveTimeout),
            "App did not finish launching before warm resume test."
        )
        emitScenarioEvent(name: "WarmResume", state: "started")
        defer { emitScenarioEvent(name: "WarmResume", state: "finished") }

        // Put app in background
        XCUIDevice.shared.press(.home)

        let start = CFAbsoluteTimeGetCurrent()
        app.activate()
        let resumed = waitForAppInteractive(app: app, timeout: warmResumeInteractiveTimeout)

        let duration = CFAbsoluteTimeGetCurrent() - start
        emitPerfMetric(name: "WarmResume", duration: duration)
        XCTAssertTrue(resumed)
    }

    private func waitForAppInteractive(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isInteractiveUIVisible(in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func isInteractiveUIVisible(in app: XCUIApplication) -> Bool {
        guard app.state == .runningForeground else { return false }

        let strongIndicators: [XCUIElement] = [
            app.tabBars.firstMatch,
            app.otherElements["StaticOnboardingViewController-WelcomeView"],
            app.buttons["WelcomeView-LoginButton-UIButton"],
            app.navigationBars["Log In"],
            app.textFields["TextInputView-EmailAddress"],
            app.staticTexts["Radio. Music. Podcasts."],
            app.staticTexts["All Free."],
            app.buttons["Sign up with email"],
            app.links["Having issues with log in or sign up? Get help now."]
        ]
        if strongIndicators.contains(where: \.exists) {
            return true
        }

        let window = app.windows.firstMatch
        guard window.exists else { return false }
        return app.buttons.firstMatch.exists
            || app.staticTexts.firstMatch.exists
            || app.textFields.firstMatch.exists
            || app.images.firstMatch.exists
    }

    private func emitPerfMetric(name: String, duration: TimeInterval) {
        let iteration = Int(ProcessInfo.processInfo.environment[Env.currentIteration] ?? "") ?? 1
        let total = max(Int(ProcessInfo.processInfo.environment[Env.repeatCount] ?? "") ?? 1, 1)
        let formatted = String(format: "%.3f", duration)
        print("PERF iteration=\(iteration)/\(total) metric=\(name) value=\(formatted)s")
    }

    private func emitScenarioEvent(name: String, state: String) {
        let iteration = Int(ProcessInfo.processInfo.environment[Env.currentIteration] ?? "") ?? 1
        let total = max(Int(ProcessInfo.processInfo.environment[Env.repeatCount] ?? "") ?? 1, 1)
        print("PERF_STATUS iteration=\(iteration)/\(total) metric=\(name) state=\(state)")
    }
}
