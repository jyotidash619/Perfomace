import XCTest
import Foundation

private enum PerfTestConfig {
    static let appBundleId = "PERF_APP_BUNDLE_ID"
    static let appKey = "PERF_APP"

    static func read(_ key: String, from env: [String: String]) -> String? {
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

    static func resolveBundleId(from env: [String: String]) -> String {
        if let explicit = read(appBundleId, from: env) {
            return explicit
        }
        #if PERF_APP_LEGACY
        return "com.clearchannel.iheartradio.legacy.qa"
        #elseif PERF_APP_QA
        return "com.clearchannel.iheartradio.qa"
        #endif
        let appKeyValue = read(appKey, from: env) ?? "qa"
        switch appKeyValue.lowercased() {
        case "legacy":
            return "com.clearchannel.iheartradio.legacy.qa"
        case "qa":
            return "com.clearchannel.iheartradio.qa"
        default:
            return "com.clearchannel.iheartradio.qa"
        }
    }
}

class iHeartPerfTests: XCTestCase {
    private static var suiteLoginUnavailable = false

    private enum Env {
        static let appBundleId = "PERF_APP_BUNDLE_ID"
        static let appKey = "PERF_APP"
        static let email = "PERF_EMAIL"
        static let password = "PERF_PASSWORD"
        static let currentIteration = "PERF_CURRENT_ITERATION"
        static let repeatCount = "PERF_REPEAT_COUNT"
        /// One of: "bypass" (default), "fail"
        static let adBehavior = "PERF_AD_BEHAVIOR"
    }

    private lazy var app: XCUIApplication = {
        let env = ProcessInfo.processInfo.environment
        let bundleId = resolveBundleId(from: env)
        return XCUIApplication(bundleIdentifier: bundleId)
    }()

    private func readConfig(_ key: String, from env: [String: String]) -> String? {
        PerfTestConfig.read(key, from: env)
    }

    private func resolveBundleId(from env: [String: String]) -> String {
        PerfTestConfig.resolveBundleId(from: env)
    }
    
    private enum UI {
        static let homeTab = "Home"
        static let settingsIcon = "settingsIcon"
        static let loginButtonStack = "loginButtonStackLoginButton"
        static let loginText = "Log in"
        static let loginSubmit = "loginViewLoginButton"
        static let emailFieldId = "TextInputView-EmailAddress"
        static let passwordFieldId = "SecureTextInputView-Password"
        static let legacyEmailFieldId = "TextFieldView-TextField-UITextField"
        static let welcomeViewId = "StaticOnboardingViewController-WelcomeView"
        static let welcomeLoginButtonId = "WelcomeView-LoginButton-UIButton"
        static let welcomeCreateAccountButtonId = "WelcomeView-CreateAccountButton-UIButton"
        static let fakeSplashNavId = "iHeartRadio.FakeSplashScreen"
        static let fakeSplashLogoId = "logo"
    }

    private let albumSearchQuery = "Taylor Swift"

    private var isLegacyRun: Bool {
        let env = ProcessInfo.processInfo.environment
        let bundleId = resolveBundleId(from: env).lowercased()
        return bundleId.contains(".legacy.")
    }

    override func setUpWithError() throws {
        // Stop the test immediately if any step fails
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let resolvedBundleId = resolveBundleId(from: env)
        print("ℹ️ XCTest using bundle id: \(resolvedBundleId)")
        let isPreflightSetup = name.contains("testPrepareFreshLoggedOutState")
        if isPreflightSetup, app.state != .notRunning {
            app.terminate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }

        if app.state == .notRunning {
            app.launch()
        } else {
            app.activate()
        }
        waitForInitialAppSurface(timeout: isLegacyRun ? 5 : 4)
        
        // Handle system popups + block unintended Google sign-in flow
        addUIInterruptionMonitor(withDescription: "System Alert") { (alert) -> Bool in
            let text = alert.label.lowercased()
            if text.contains("google.com") || text.contains("sign in") || text.contains("apple") || text.contains("continue with apple") {
                if alert.buttons["Cancel"].exists { alert.buttons["Cancel"].tap(); return true }
                if alert.buttons["Not Now"].exists { alert.buttons["Not Now"].tap(); return true }
                if alert.buttons["Close"].exists { alert.buttons["Close"].tap(); return true }
                return false
            }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["Allow While Using App"].exists { alert.buttons["Allow While Using App"].tap(); return true }
            return false
        }
        
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        clearInterferingPrompts(reason: "setup")
        dismissAdsIfPresent(reason: "setup")
    }

    override func tearDownWithError() throws {
        // Keep the app alive between tests so the ordered perf suite doesn't pay a relaunch cost every time.
    }

    // MARK: - 1. LOGIN PERFORMANCE
    func testLoginSpeed() {
        Self.suiteLoginUnavailable = false
        ensureLoggedOut()
        prepareLoginCredentials()
        _ = measureOnce("Login") {
            submitLoginAndWait()
        }
    }

    // MARK: - PRE-RUN STATE PREP
    func testPrepareFreshLoggedOutState() {
        clearInterferingPrompts(reason: "prepareFreshLoggedOutState", timeout: 1.0)
        dismissAdsIfPresent(reason: "prepareFreshLoggedOutState")
        ensureLoggedOut()
        app.terminate()
    }

    // MARK: - 2. TAB SWITCH JOURNEY
    func testTabSwitchJourney() {
        ensureLoggedIn()
        _ = measureOnce("TabSwitchJourney") {
            returnToRootIfNeeded()
            selectTab(label: UI.homeTab, identifier: "homeTab")
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
            selectTab(label: "Radio", identifier: "radioTab")
            selectTab(label: "Podcasts", identifier: "podcastsTab")
            selectTab(label: "Playlists", identifier: "playlistsTab")
            selectTab(label: "Search", identifier: "searchTab")
            selectTab(label: UI.homeTab, identifier: "homeTab")
        }
    }

    // MARK: - 3. SEARCH PERFORMANCE
    func testSearchSpeed() {
        ensureLoggedIn()
        let query = "Taylor Swift"
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        var duration: TimeInterval = 0
        emitScenarioEvent(name: "Search", state: "started")
        defer { emitScenarioEvent(name: "Search", state: "finished") }

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTStorageMetric()], options: options) {
            var didStartMeasuring = false
            defer {
                if didStartMeasuring {
                    stopMeasuring()
                }
            }

            returnToRootIfNeeded()
            dismissAdsIfPresent(reason: "beforeSearchPerformance")
            prepareSearchQuery(query)

            // Measure the actual search request and result readiness, not the tab navigation or typing.
            startMeasuring()
            didStartMeasuring = true
            let start = CFAbsoluteTimeGetCurrent()
            submitSearchQuery()
            dismissAdsIfPresent(reason: "beforeSearchResults")
            guard waitForSearchResults(query: query, timeout: isLegacyRun ? 8 : 10) else {
                dumpAccessibilityTree("SearchResultsMissing")
                XCTFail("Search results not found.")
                return
            }
            duration = CFAbsoluteTimeGetCurrent() - start
            stopMeasuring()
            didStartMeasuring = false

            guard openFirstSearchResult(query: query) else {
                dumpAccessibilityTree("SearchResultMissing")
                XCTFail("Search result target not found.")
                return
            }

            assertPlaybackStarted(context: "SearchPlaybackNotStarted")
        }

        emitPerfMetric(name: "Search", duration: duration)
    }

    // MARK: - 4. RADIO PLAY START
    func testRadioPlayStart() {
        ensureLoggedIn()
        returnToRootIfNeeded()
        dismissAdsIfPresent(reason: "beforeRadioPlay")
        if isLegacyRun {
            stopExistingPlaybackIfNeeded(reason: "beforeLegacyRadioPlayStart")
        }
        selectTab(label: "Radio", identifier: "radioTab")
        guard let stationTarget = firstRadioStationTarget() else {
            emitScenarioSkip(name: "RadioPlayStart", reason: "no_content")
            return
        }
        _ = measureOptionalMetricsOnce("RadioPlayStart") {
            stationTarget.forceTap()
            guard waitForRadioDetail(timeout: isLegacyRun ? 10 : 8) else { return false }
            startPlaybackIfNeeded(context: "RadioPlaybackNotStarted")
            return waitForPlaybackStarted(timeout: isLegacyRun ? 18 : 10)
        }
    }

    // MARK: - 5. RADIO SCROLL PERFORMANCE
    func testRadioScrollPerformance() {
        ensureLoggedIn()

        _ = measureMetricsOnce("RadioScroll") {
            dismissAdsIfPresent(reason: "beforeRadioScroll")
            selectTab(label: "Radio", identifier: "radioTab")

            // Prefer a scrollable container if it exists; otherwise fall back to any scroll view.
            let container = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            if !container.waitForExistence(timeout: 10) {
                dumpAccessibilityTree("RadioScrollContainerMissing")
                XCTFail("No scrollable container found on Radio tab.")
            }

            // Do a few swipes to simulate user browsing.
            for _ in 0..<6 {
                container.swipeUp()
            }
            for _ in 0..<2 {
                container.swipeDown()
            }
        }
    }

    // MARK: - 6. IMAGE LOADING
    func testImageLoading() {
        ensureLoggedIn()
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        var duration: TimeInterval = 0
        emitScenarioEvent(name: "ImageLoading", state: "started")
        defer { emitScenarioEvent(name: "ImageLoading", state: "finished") }

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTStorageMetric()], options: options) {
            var didStartMeasuring = false
            defer {
                if didStartMeasuring {
                    stopMeasuring()
                }
            }

            returnToRootIfNeeded()
            dismissAdsIfPresent(reason: "beforeImageLoadingSearch")
            prepareSearchQuery(albumSearchQuery)
            submitSearchQuery()
            dismissAdsIfPresent(reason: "beforeImageLoadingResults")
            if !waitForSearchResults(query: albumSearchQuery, timeout: isLegacyRun ? 8 : 10) {
                startMeasuring()
                didStartMeasuring = true
                dumpAccessibilityTree("ImageLoadingResultsMissing")
                XCTFail("Image loading search results not found.")
                return
            }

            guard let target = waitForSearchResultAwaitingArtwork(query: albumSearchQuery, timeout: isLegacyRun ? 8 : 10) else {
                startMeasuring()
                didStartMeasuring = true
                dumpAccessibilityTree("ImageLoadingTargetMissing")
                XCTFail("No search result was found waiting on artwork.")
                return
            }

            let legacyDetailArtworkFallback = isLegacyRun && searchResultArtworkImage(in: target) == nil
            startMeasuring()
            didStartMeasuring = true
            let start = CFAbsoluteTimeGetCurrent()
            if legacyDetailArtworkFallback {
                target.forceTap()
                if !waitForMediaArtworkVisible(timeout: 8) {
                    dumpAccessibilityTree("ImageLoadingNotVisible")
                    XCTFail("Image loading artwork did not become visible.")
                    return
                }
            } else if !waitForArtworkVisible(in: target, timeout: isLegacyRun ? 6 : 8) {
                dumpAccessibilityTree("ImageLoadingNotVisible")
                XCTFail("Image loading artwork did not become visible.")
                return
            }
            duration = CFAbsoluteTimeGetCurrent() - start
        }

        emitPerfMetric(name: "ImageLoading", duration: duration)
    }

    // MARK: - 7. PODCAST PLAY START
    func testPodcastTabLoad() {
        ensureLoggedIn()
        returnToRootIfNeeded()
        dismissAdsIfPresent(reason: "beforePodcastTab")
        if isLegacyRun {
            stopExistingPlaybackIfNeeded(reason: "beforeLegacyPodcastPlayStart")
        }
        selectTab(label: "Podcasts", identifier: "podcastsTab")
        guard let episodeTarget = firstPodcastEpisodeTarget() else {
            dumpAccessibilityTree("PodcastContentMissing")
            XCTFail("No podcast content found.")
            return
        }
        _ = measureMetricsOnce("PodcastPlayStart") {
            episodeTarget.forceTap()
            guard waitForPodcastDetailLoaded(timeout: isLegacyRun ? 10 : 8) else {
                dumpAccessibilityTree("PodcastDetailNotLoaded")
                XCTFail("Podcast detail did not load.")
                return
            }
            assertPlaybackStarted(context: "PodcastPlaybackNotStarted")
        }
    }

    // MARK: - 10. PLAYLIST PLAY START
    func testPlaylistLoad() {
        ensureLoggedIn()
        returnToRootIfNeeded()
        dismissAdsIfPresent(reason: "beforePlaylistTab")
        if isLegacyRun {
            stopExistingPlaybackIfNeeded(reason: "beforeLegacyPlaylistPlayStart")
        }
        selectTab(label: "Playlists", identifier: "playlistsTab")
        guard let playlistTarget = firstPlaylistCardTarget() else {
            dumpAccessibilityTree("PlaylistContentMissing")
            XCTFail("No playlist content found.")
            return
        }
        
        _ = measureMetricsOnce("PlaylistPlayStart") {
            playlistTarget.forceTap()
            guard waitForPlaylistDetail(timeout: isLegacyRun ? 8 : 6) else {
                dumpAccessibilityTree("PlaylistDetailNotLoaded")
                XCTFail("Playlist detail did not load.")
                return
            }
            assertPlaybackStarted(context: "PlaylistPlaybackNotStarted")
        }
    }

    // MARK: - 11. LOGOUT PERFORMANCE
    func testLogoutSpeed() {
        if !isLoggedIn() {
            ensureLoggedIn()
        }
        _ = measureOnce("Logout") {
            performLogout()
        }
    }

    // MARK: - 12. INSTRUMENTS PROBE
    func testInstrumentsProbeJourney() {
        if !isLoggedIn() {
            ensureLoggedIn()
            guard isLoggedIn() else { return }
        }

        if isLegacyRun {
            runLegacyProbeJourney()
            return
        }

        dismissAdsIfPresent(reason: "probeStart")
        returnToRootIfNeeded()

        if app.tabBars.buttons[UI.homeTab].waitForExistence(timeout: 5) {
            selectTab(label: UI.homeTab, identifier: "homeTab")
        }

        if app.tabBars.buttons["Radio"].exists {
            selectTab(label: "Radio", identifier: "radioTab")
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 8)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 2)
            if openFirstRadioStation() {
                startPlaybackIfNeeded(context: "ProbeRadioPlayback")
                _ = playbackIndicators().contains { $0.waitForExistence(timeout: 3) }
            }
        }

        if app.tabBars.buttons["Podcasts"].exists {
            selectTab(label: "Podcasts", identifier: "podcastsTab")
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 8)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 2)
            if openFirstPodcastEpisode() {
                startPlaybackIfNeeded(context: "ProbePodcastPlayback")
                _ = playbackIndicators().contains { $0.waitForExistence(timeout: 3) }
            }
        }

        if app.tabBars.buttons["Playlists"].exists {
            selectTab(label: "Playlists", identifier: "playlistsTab")
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 8)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 2)
            let featured = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'featuredPlaylistSection-CarouselCard-Index'")).firstMatch
            if featured.waitForExistence(timeout: 4) || app.buttons.firstMatch.waitForExistence(timeout: 4) {
                (featured.exists ? featured : app.buttons.firstMatch).forceTap()
                startPlaybackIfNeeded(context: "ProbePlaylistPlayback")
                _ = playbackIndicators().contains { $0.waitForExistence(timeout: 3) }
            }
        }

        if app.tabBars.buttons["Search"].exists {
            prepareSearchQuery("Taylor Swift")
            submitSearchQuery()
            if waitForSearchResults(query: "Taylor Swift", timeout: 8) {
                _ = openFirstSearchResult(query: "Taylor Swift")
                startPlaybackIfNeeded(context: "ProbeSearchPlayback")
                _ = playbackIndicators().contains { $0.waitForExistence(timeout: 3) }
            }
        }
    }

    private func runLegacyProbeJourney() {
        dismissAdsIfPresent(reason: "probeStart")
        returnToRootIfNeeded()

        if app.tabBars.buttons[UI.homeTab].waitForExistence(timeout: 3) {
            selectTab(label: UI.homeTab, identifier: "homeTab")
        }

        if app.tabBars.buttons["Radio"].exists {
            selectTab(label: "Radio", identifier: "radioTab")
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 4)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 2)
        }

        if app.tabBars.buttons["Podcasts"].exists {
            selectTab(label: "Podcasts", identifier: "podcastsTab")
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 4)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 2)
            let listenCandidates = [
                app.buttons["Listen"],
                app.buttons.matching(NSPredicate(format: "label ==[c] 'Listen' OR identifier CONTAINS[c] 'listen'")).firstMatch,
            ]
            _ = tapFirstExisting(listenCandidates, context: "ProbePodcastListenMissing", failIfMissing: false)
            _ = waitForAnyPlaybackIndicator(timeout: 4)
        }

        if app.tabBars.buttons["Playlists"].exists {
            selectTab(label: "Playlists", identifier: "playlistsTab")
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 4)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 2)
        }

        if app.tabBars.buttons["Search"].exists {
            prepareSearchQuery("Taylor Swift")
            submitSearchQuery()
            if waitForSearchResults(query: "Taylor Swift", timeout: 4) {
                _ = openFirstSearchResult(query: "Taylor Swift")
            }
        }

        if app.tabBars.buttons[UI.homeTab].exists {
            selectTab(label: UI.homeTab, identifier: "homeTab")
        }
    }

    // MARK: - --- STATE HELPERS ---
    
    // Ensures we are Logged IN. If not, it logs us in.
    func ensureLoggedIn() {
        if isLoggedIn() { return }
        if Self.suiteLoginUnavailable {
            XCTFail("Login unavailable for this run. Skipping repeated login attempts.")
            return
        }
        print("LOG: App is logged out. Logging in now...")
        _ = performLogin()
    }
    
    // Ensures we are Logged OUT. If not, it logs us out.
    func ensureLoggedOut() {
        if isLoggedIn() {
            print("LOG: App is logged in. Logging out now...")
            performLogout()
        }
    }
    
    @discardableResult
    func performLogin() -> Bool {
        prepareLoginCredentials()
        let didLogin = submitLoginAndWait()
        Self.suiteLoginUnavailable = !didLogin
        return didLogin
    }
    
    func performLogout() {
        if !isLoggedIn() { return }
        let isLegacyApp = isLegacyRun

        unwindToTabRootForLogout()

        if !ensureHomeTabSelectedForLogout() {
            dumpAccessibilityTree("LogoutHomeTabMissing")
            XCTFail("Logout Failed: home tab not reached.")
            return
        }

        let openedSettings = isLegacyApp ? openLegacySettingsForLogout() : openQASettingsForLogout()
        if !openedSettings {
            dumpAccessibilityTree("LogoutSettingsMissing")
            XCTFail("Logout Failed: settings icon not found.")
            return
        }

        let openedLogout = isLegacyApp ? openLegacyLogoutAction() : openQALogoutAction()
        if !openedLogout {
            dumpAccessibilityTree("LogoutButtonMissing")
            XCTFail("Logout Failed: Log Out button not found.")
            return
        }
        if app.alerts.buttons["Log Out"].waitForExistence(timeout: 2) {
            app.alerts.buttons["Log Out"].tap()
        } else if app.alerts.buttons["Logout"].exists {
            app.alerts.buttons["Logout"].tap()
        }

        if !waitForLoggedOut(timeout: isLegacyApp ? 6 : 8) {
            dumpAccessibilityTree("LogoutDidNotReachLoggedOutState")
            XCTFail("Logout Failed: logged-out state not detected.")
            return
        }
        Self.suiteLoginUnavailable = false
    }

    private func openQASettingsForLogout() -> Bool {
        clearInterferingPrompts(reason: "openQASettingsForLogout")
        let settingsCandidates: [XCUIElement] = [
            app.buttons[UI.settingsIcon],
            app.navigationBars.buttons[UI.settingsIcon],
        ]
        return tapVisibleTopBarSettings(settingsCandidates)
    }

    private func openLegacySettingsForLogout() -> Bool {
        clearInterferingPrompts(reason: "openLegacySettingsForLogout")
        let settingsCandidates: [XCUIElement] = [
            app.buttons[UI.settingsIcon],
            app.buttons["Settings"],
            app.buttons["NavBar-Settings-UIButton"],
            app.navigationBars.buttons[UI.settingsIcon],
            app.navigationBars.buttons["Settings"],
            app.navigationBars.buttons["NavBar-Settings-UIButton"],
        ]
        return tapVisibleTopBarSettings(settingsCandidates)
    }

    private func openQALogoutAction() -> Bool {
        navigateToLogoutAction(prioritizeAccount: false)
    }

    private func openLegacyLogoutAction() -> Bool {
        navigateToLogoutAction(prioritizeAccount: true)
    }

    private func logoutAccountCandidates() -> [XCUIElement] {
        [
            app.buttons["Account"],
            app.buttons["My Account"],
            app.buttons["Account Settings"],
            app.staticTexts["Account"],
            app.staticTexts["My Account"],
            app.staticTexts["Account Settings"],
            app.cells.staticTexts["Account"],
            app.cells.staticTexts["My Account"],
            app.cells.staticTexts["Account Settings"],
            app.otherElements.containing(.staticText, identifier: "Account").firstMatch,
            app.otherElements.containing(.staticText, identifier: "My Account").firstMatch,
        ]
    }

    private func logoutActionCandidates() -> [XCUIElement] {
        [
            app.buttons["Log Out"],
            app.buttons["Logout"],
            app.buttons["Sign Out"],
            app.staticTexts["Log Out"],
            app.staticTexts["Logout"],
            app.staticTexts["Sign Out"],
            app.cells.staticTexts["Log Out"],
            app.cells.staticTexts["Logout"],
            app.cells.staticTexts["Sign Out"],
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS[c] 'logout' OR identifier CONTAINS[c] 'signout' OR label ==[c] 'Log Out' OR label ==[c] 'Logout' OR label ==[c] 'Sign Out'")).firstMatch,
        ]
    }

    private func waitForLogoutSurface(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            clearInterferingPrompts(reason: "waitForLogoutSurface", timeout: 0.3)
            if logoutAccountCandidates().contains(where: isVisibleLogoutCandidate(_:)) { return true }
            if logoutActionCandidates().contains(where: isVisibleLogoutCandidate(_:)) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return logoutAccountCandidates().contains(where: isVisibleLogoutCandidate(_:))
            || logoutActionCandidates().contains(where: isVisibleLogoutCandidate(_:))
    }

    @discardableResult
    private func tapFirstPresent(_ candidates: [XCUIElement]) -> Bool {
        for candidate in candidates where isVisibleLogoutCandidate(candidate) {
            candidate.forceTap()
            return true
        }
        return false
    }

    private func isVisibleLogoutCandidate(_ element: XCUIElement) -> Bool {
        element.exists && !element.frame.isEmpty && element.frame.width > 1 && element.frame.height > 1
    }

    private func firstLogoutScrollContainer() -> XCUIElement? {
        let candidates = [
            app.tables.firstMatch,
            app.collectionViews.firstMatch,
            app.scrollViews.firstMatch,
        ]
        return candidates.first(where: { $0.exists && !$0.frame.isEmpty })
    }

    private func navigateToLogoutAction(prioritizeAccount: Bool) -> Bool {
        let accountCandidates = logoutAccountCandidates()
        let logoutCandidates = logoutActionCandidates()

        if prioritizeAccount {
            if tapFirstPresent(accountCandidates) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            }
        } else if tapFirstPresent(logoutCandidates) {
            return true
        }

        for _ in 0..<5 {
            clearInterferingPrompts(reason: "navigateToLogoutAction", timeout: 0.3)

            if tapFirstPresent(logoutCandidates) {
                return true
            }

            if tapFirstPresent(accountCandidates) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                if tapFirstPresent(logoutCandidates) {
                    return true
                }
            }

            guard let container = firstLogoutScrollContainer() else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                continue
            }
            container.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }

        return tapFirstPresent(logoutCandidates)
    }
    
    // MARK: - Element helpers

    private func loggedInShellIndicators() -> [XCUIElement] {
        [
            app.tabBars.firstMatch,
            app.tabBars.buttons[UI.homeTab],
            app.tabBars.buttons["homeTab"],
            app.tabBars.buttons["Search"],
            app.tabBars.buttons["Radio"],
            app.tabBars.buttons["Podcasts"],
            app.tabBars.buttons["Playlists"],
            app.tabBars.buttons["tab_yourHome"],
            app.buttons["tab_yourHome"],
            app.tabBars.buttons["tab_search"],
            app.buttons["tab_search"],
            app.tabBars.buttons["tab_radio"],
            app.buttons["tab_radio"],
            app.tabBars.buttons["tab_podcasts"],
            app.buttons["tab_podcasts"],
            app.tabBars.buttons["tab_playlists"],
            app.buttons["tab_playlists"],
            app.buttons["NavBar-Settings-UIButton"],
            app.buttons["SearchTabContextViewController-SearchButton-UIBarButtonItem"],
            app.navigationBars["iHeartRadio.YourLibraryView"],
            app.collectionViews["YourLibraryViewController-CollectionView-UICollectionView"],
        ]
    }

    private func loggedInShellVisible() -> Bool {
        if homeSurfaceVisible() {
            return true
        }

        return loggedInShellIndicators().contains(where: { $0.exists })
    }

    private func waitForInitialAppSurface(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if loggedInShellVisible() || loginScreenVisible() || welcomeScreenVisible() {
                return
            }
            if fakeSplashVisible() {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            if loggedInShellIndicators().contains(where: { $0.waitForExistence(timeout: 0.1) }) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
    }
    
    private func isLoggedIn() -> Bool {
        if loggedInShellVisible() { return true }

        let deadline = Date().addingTimeInterval(isLegacyRun ? 8 : 6)
        repeat {
            clearInterferingPrompts(reason: "isLoggedIn", timeout: 0.4)
            if loggedInShellVisible() { return true }
            if loggedOutStateVisible() { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return loggedInShellVisible()
    }
    
    private func waitForLoggedIn(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            clearInterferingPrompts(reason: "waitForLoggedIn", timeout: 0.8)
            if loggedInShellVisible() { return true }
            if currentAppErrorMessage() != nil { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return loggedInShellVisible()
    }

    private func loggedOutStateVisible() -> Bool {
        if loggedInShellVisible() { return false }
        if loginScreenVisible() { return true }
        if welcomeScreenVisible() { return true }
        if fakeSplashVisible() { return true }

        let loginCandidates = [
            app.buttons[UI.loginButtonStack],
            app.buttons[UI.welcomeLoginButtonId],
            app.buttons["Log in"],
            app.buttons["Log In"],
            app.navigationBars["Log In"],
        ]
        if loginCandidates.contains(where: { $0.exists }) {
            return true
        }

        if !app.tabBars.buttons[UI.homeTab].exists && !app.tabBars.buttons["Search"].exists {
            let accountLabels = [
                app.textFields["Email Address"],
                app.textFields[UI.emailFieldId],
                app.textFields["Password"],
                app.secureTextFields["Password"],
            ]
            if accountLabels.contains(where: { $0.exists }) {
                return true
            }
        }
        return false
    }

    private func waitForLoggedOut(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            clearInterferingPrompts(reason: "waitForLoggedOut", timeout: 0.5)
            if loggedOutStateVisible() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return loggedOutStateVisible()
    }
    
    private func loginScreenVisible() -> Bool {
        if app.navigationBars["Log In"].exists { return true }
        if app.buttons[UI.loginSubmit].exists { return true }
        if app.textFields["Email Address"].exists { return true }
        if app.textFields[UI.emailFieldId].exists { return true }
        if app.secureTextFields["Password"].exists { return true }
        if app.secureTextFields[UI.passwordFieldId].exists { return true }
        #if PERF_APP_LEGACY
        if app.textFields["Password"].exists { return true }
        if app.textFields["TextFieldView-Password-UITextField"].exists { return true }
        #endif
        return false
    }

    private func welcomeScreenVisible() -> Bool {
        if app.otherElements[UI.welcomeViewId].exists { return true }
        if app.buttons[UI.welcomeLoginButtonId].exists { return true }
        if app.buttons[UI.welcomeCreateAccountButtonId].exists { return true }
        return false
    }

    private func navigateToLoginScreen() {
        clearInterferingPrompts(reason: "beforeNavigateToLogin")
        if loginScreenVisible() { return }
        if isLegacyRun {
            if tapLoginFromWelcomeIfNeeded() {
                return
            }
            _ = waitForWelcomeOrLogin(timeout: 2)
            _ = tapLoginFromWelcomeIfNeeded()
            return
        }
        _ = waitForWelcomeOrLogin(timeout: 8)
        tapLoginFromWelcomeIfNeeded()
    }

    @discardableResult
    private func tapLoginFromWelcomeIfNeeded() -> Bool {
        clearInterferingPrompts(reason: "beforeTapLoginCTA")
        if welcomeScreenVisible() {
            let welcomeLogin = app.buttons[UI.welcomeLoginButtonId]
            if tapLoginCandidate(welcomeLogin, timeout: isLegacyRun ? 4 : 3) {
                return true
            }
        }

        let loginStackButton = app.buttons[UI.loginButtonStack]
        if tapLoginCandidate(loginStackButton, timeout: isLegacyRun ? 4 : 3) {
            return true
        }

        if let fallbackLogin = findWelcomeLoginCandidate(),
           tapLoginCandidate(fallbackLogin, timeout: isLegacyRun ? 4 : 3) {
            return true
        }

        if fakeSplashVisible() {
            let timeout: TimeInterval = isLegacyRun ? 2 : 5
            _ = waitForWelcomeOrLogin(timeout: timeout)
            if welcomeScreenVisible() || app.buttons[UI.loginButtonStack].exists {
                return tapLoginFromWelcomeIfNeeded()
            }
        }

        dumpAccessibilityTree("LoginLinkMissing")
        if let appError = currentAppErrorMessage() {
            XCTFail("Login Failed: \(appError)")
        } else {
            XCTFail("Login Failed: welcome screen stayed visible after tapping Log in.")
        }
        return false
    }

    private func waitForLoginScreen(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            clearInterferingPrompts(reason: "waitForLoginScreen", timeout: 0.8)
            if loginScreenVisible() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return loginScreenVisible()
    }

    private func fakeSplashVisible() -> Bool {
        if app.navigationBars[UI.fakeSplashNavId].exists { return true }
        if app.images[UI.fakeSplashLogoId].exists { return true }
        return false
    }

    private func waitForWelcomeOrLogin(timeout: TimeInterval) -> Bool {
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < timeout {
            clearInterferingPrompts(reason: "waitForWelcomeOrLogin")
            if loginScreenVisible() { return true }
            if welcomeScreenVisible() { return true }
            if fakeSplashVisible() {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func logLoginCandidate(_ element: XCUIElement) {
        let frame = element.frame
        print("LOGIN CANDIDATE type=\(element.elementType) id=\(element.identifier) label=\(element.label) frame=\(frame)")
    }

    @discardableResult
    private func tapLoginCandidate(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: 2) else { return false }
        for attempt in 0..<2 {
            logLoginCandidate(element)
            clearInterferingPrompts(reason: "beforeTapLoginCandidate")
            if element.isHittable {
                element.tap()
            } else {
                tapElementCenter(element)
            }
            clearInterferingPrompts(reason: "afterTapLoginCandidate")
            if waitForLoginScreen(timeout: timeout) {
                return true
            }
            let dismissedAppError = dismissAppErrorAlertIfPresent()
            if attempt == 0 && dismissedAppError && (welcomeScreenVisible() || fakeSplashVisible()) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                continue
            }
            break
        }
        return false
    }
    
    @discardableResult
    private func measureOnce(_ name: String, _ block: () -> Void) -> TimeInterval {
        emitScenarioEvent(name: name, state: "started")
        let start = CFAbsoluteTimeGetCurrent()
        defer { emitScenarioEvent(name: name, state: "finished") }
        block()
        let duration = CFAbsoluteTimeGetCurrent() - start
        emitPerfMetric(name: name, duration: duration)
        return duration
    }

    @discardableResult
    private func measureMetricsOnce(_ name: String, _ block: () -> Void) -> TimeInterval {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        
        var duration: TimeInterval = 0
        emitScenarioEvent(name: name, state: "started")
        defer { emitScenarioEvent(name: name, state: "finished") }
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTStorageMetric()], options: options) {
            startMeasuring()
            let start = CFAbsoluteTimeGetCurrent()
            block()
            duration = CFAbsoluteTimeGetCurrent() - start
            stopMeasuring()
        }
        
        emitPerfMetric(name: name, duration: duration)
        return duration
    }

    @discardableResult
    private func measureOptionalMetricsOnce(_ name: String, _ block: () -> Bool) -> TimeInterval? {
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        var duration: TimeInterval = 0
        var shouldEmitMetric = false
        emitScenarioEvent(name: name, state: "started")
        defer { emitScenarioEvent(name: name, state: "finished") }
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTStorageMetric()], options: options) {
            startMeasuring()
            let start = CFAbsoluteTimeGetCurrent()
            shouldEmitMetric = block()
            duration = CFAbsoluteTimeGetCurrent() - start
            stopMeasuring()
        }

        guard shouldEmitMetric else {
            emitScenarioSkip(name: name, reason: "no_content")
            return nil
        }

        emitPerfMetric(name: name, duration: duration)
        return duration
    }

    private func emitScenarioEvent(name: String, state: String) {
        let iteration = currentIteration()
        let total = repeatCount()
        print("PERF_STATUS iteration=\(iteration)/\(total) metric=\(name) state=\(state)")
    }

    private func emitPerfMetric(name: String, duration: TimeInterval) {
        let iteration = currentIteration()
        let total = repeatCount()
        let formatted = String(format: "%.3f", duration)
        print("PERF iteration=\(iteration)/\(total) metric=\(name) value=\(formatted)s")
    }

    private func emitScenarioSkip(name: String, reason: String) {
        let iteration = currentIteration()
        let total = repeatCount()
        print("PERF_SKIP iteration=\(iteration)/\(total) metric=\(name) reason=\(reason)")
    }

    private func currentIteration() -> Int {
        let env = ProcessInfo.processInfo.environment
        return Int(env[Env.currentIteration] ?? "") ?? 1
    }

    private func repeatCount() -> Int {
        let env = ProcessInfo.processInfo.environment
        return max(Int(env[Env.repeatCount] ?? "") ?? 1, 1)
    }

    private func dumpAccessibilityTree(_ label: String) {
        print("---- AX DUMP \(label) START ----")
        print(app.debugDescription)
        print("---- AX DUMP \(label) END ----")
    }

    private func dismissSearchOverlayIfPresent() {
        let keyboard = app.keyboards.firstMatch
        let activeSearchIndicators = [
            app.textFields["SearchBarActiveView-TextField"],
            app.searchFields.firstMatch,
            app.buttons["SearchBarActiveView-Cancel-Button"],
        ]
        let shouldProbeCancelButtons = keyboard.exists
            || activeSearchIndicators.contains(where: { $0.exists && !$0.frame.isEmpty })

        guard shouldProbeCancelButtons else { return }

        let cancelCandidates = [
            app.buttons["SearchBarActiveView-Cancel-Button"],
            app.buttons["Cancel"],
        ]
        for candidate in cancelCandidates where candidate.exists || candidate.waitForExistence(timeout: 0.15) {
            candidate.forceTap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            return
        }

        if keyboard.exists {
            let searchKey = keyboard.buttons["Search"]
            if searchKey.exists {
                searchKey.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }
    }

    private func unwindToTabRootForLogout() {
        for _ in 0..<5 {
            dismissSearchOverlayIfPresent()
            dismissKeyboardIfPresent()
            clearInterferingPrompts(reason: "unwindToTabRootForLogout", timeout: 0.3)

            if homeSurfaceVisible() {
                return
            }

            let backCandidates = [
                app.buttons["ProfileHeader-backButton"],
                app.navigationBars.buttons["Back"],
                app.buttons["Back"],
                app.navigationBars.buttons.firstMatch,
            ]

            if let back = backCandidates.first(where: {
                $0.exists
                    && !$0.frame.isEmpty
                    && $0.frame.minX < 90
                    && $0.frame.maxY < 140
                    && $0.identifier != UI.settingsIcon
                    && $0.identifier != "NavBar-Settings-UIButton"
            }) {
                back.forceTap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                continue
            }

            if tapHomeTabForLogout() {
                return
            }
        }
    }

    private func ensureHomeTabSelectedForLogout() -> Bool {
        if homeSurfaceVisible() {
            return true
        }

        for attempt in 0..<4 {
            unwindToTabRootForLogout()
            dismissSearchOverlayIfPresent()
            dismissKeyboardIfPresent()
            clearInterferingPrompts(reason: "ensureHomeTabSelectedForLogout", timeout: 0.4)

            if homeSurfaceVisible() || waitForHomeSurface(timeout: 0.8) {
                return true
            }

            if tapHomeTabForLogout() {
                return true
            }

            if attempt == 1, app.buttons["ProfileHeader-backButton"].exists {
                app.buttons["ProfileHeader-backButton"].forceTap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                if tapHomeTabForLogout() {
                    return true
                }
            }
        }
        return waitForHomeSurface(timeout: 1.0)
    }

    private func tapHomeTabForLogout() -> Bool {
        if homeSurfaceVisible() {
            return true
        }

        let homeCandidates = homeTabCandidates()

        for candidate in homeCandidates where candidate.exists && !candidate.frame.isEmpty {
            candidate.forceTap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            if waitForHomeSurface(timeout: isLegacyRun ? 0.8 : 0.45) {
                return true
            }

            if isLegacyRun {
                // Legacy often needs a second tap to pop to the tab root.
                candidate.forceTap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.45))
                if waitForHomeSurface(timeout: 1.0) {
                    return true
                }
            }
        }

        return false
    }

    private func homeTabCandidates() -> [XCUIElement] {
        [
            app.tabBars.buttons[UI.homeTab],
            app.tabBars.buttons["homeTab"],
            app.tabBars.buttons["tab_yourHome"],
            app.buttons[UI.homeTab],
            app.buttons["homeTab"],
            app.buttons["tab_yourHome"],
        ]
    }

    private func homeSurfaceVisible() -> Bool {
        let homeCandidates = homeTabCandidates()
        let anyHomeTabVisible = homeCandidates.contains(where: { $0.exists && !$0.frame.isEmpty })
        let homeSelected = homeCandidates.contains(where: { $0.exists && $0.isSelected })

        if isLegacyRun {
            let legacyTopSettings = [
                app.buttons[UI.settingsIcon],
                app.navigationBars.buttons[UI.settingsIcon],
                app.buttons["Settings"],
                app.navigationBars.buttons["Settings"],
                app.buttons["NavBar-Settings-UIButton"],
                app.navigationBars.buttons["NavBar-Settings-UIButton"],
            ]
            let legacyHomeContent = [
                app.staticTexts["Presets"],
                app.buttons["Presets"],
                app.buttons["Open Presets"],
                app.staticTexts["Recently Played"],
                app.staticTexts["Your Library"],
                app.buttons["Stations"],
                app.buttons["Podcasts"],
                app.buttons["Playlists"],
                app.buttons["MiniPlayer-Presets-Button"],
                app.scrollViews["homeRadioTabMainScrollView"],
            ]
            let hasTopSettings = legacyTopSettings.contains(where: { $0.exists && !$0.frame.isEmpty && $0.frame.maxY < 180 })
            let hasHomeContent = legacyHomeContent.contains(where: { $0.exists && !$0.frame.isEmpty })
            return hasTopSettings && hasHomeContent && (homeSelected || !anyHomeTabVisible)
        }

        let qaTopSettings = [
            app.buttons[UI.settingsIcon],
            app.navigationBars.buttons[UI.settingsIcon],
        ]
        let qaHomeContent = [
            app.staticTexts["Presets"],
            app.buttons["Presets"],
            app.staticTexts["Live Radio Dial"],
            app.staticTexts["Recently Played"],
            app.staticTexts["Your Library"],
            app.staticTexts["Scan Stations"],
            app.buttons["Scan Stations"],
        ]
        let hasTopSettings = qaTopSettings.contains(where: { $0.exists && !$0.frame.isEmpty && $0.frame.maxY < 180 })
        let hasHomeContent = qaHomeContent.contains(where: { $0.exists && !$0.frame.isEmpty })
        let semanticHomeTabVisible = homeCandidates.contains(where: {
            $0.exists
                && !$0.frame.isEmpty
                && ($0.identifier == "homeTab" || $0.identifier == "tab_yourHome" || $0.label.caseInsensitiveCompare(UI.homeTab) == .orderedSame)
        })
        return hasTopSettings && hasHomeContent && (homeSelected || semanticHomeTabVisible || !anyHomeTabVisible)
    }

    private func waitForHomeSurface(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if homeSurfaceVisible() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return homeSurfaceVisible()
    }

    private func tapVisibleTopBarSettings(_ candidates: [XCUIElement]) -> Bool {
        let topBarCandidates = candidates.filter { candidate in
            candidate.exists
                && !candidate.frame.isEmpty
                && candidate.frame.maxY < 180
        }

        for candidate in topBarCandidates {
            if candidate.isHittable {
                candidate.tap()
            } else {
                tapElementCenter(candidate)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            if waitForLogoutSurface(timeout: 1.5) {
                return true
            }
        }
        return false
    }

    private func tabAliases(label: String, identifier: String) -> [String] {
        var aliases = [label, identifier]
        switch label.lowercased() {
        case UI.homeTab.lowercased():
            aliases.append(contentsOf: ["tab_yourHome", "homeTab"])
        case "search":
            aliases.append(contentsOf: ["tab_search", "searchTab"])
        case "radio":
            aliases.append(contentsOf: ["tab_radio", "radioTab"])
        case "podcasts":
            aliases.append(contentsOf: ["tab_podcasts", "podcastsTab"])
        case "playlists":
            aliases.append(contentsOf: ["tab_playlists", "playlistsTab"])
        default:
            break
        }
        return Array(Set(aliases.filter { !$0.isEmpty }))
    }

    private func waitForSelectedTab(label: String, identifier: String, timeout: TimeInterval) -> Bool {
        if (label == UI.homeTab || identifier == "homeTab") && homeSurfaceVisible() {
            return true
        }

        let aliases = tabAliases(label: label, identifier: identifier)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = aliases.flatMap { alias in
                [
                    app.tabBars.buttons[alias],
                    app.buttons[alias],
                ]
            }
            if candidates.contains(where: { $0.exists && $0.isSelected }) {
                return true
            }
            if (label == UI.homeTab || identifier == "homeTab") && homeSurfaceVisible() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }
    
    private func selectTab(label: String, identifier: String) {
        dismissAdsIfPresent(reason: "selectTab")
        if (label == UI.homeTab || identifier == "homeTab") && homeSurfaceVisible() {
            return
        }
        let aliases = tabAliases(label: label, identifier: identifier)
        let candidates = aliases.flatMap { alias in
            [
                app.tabBars.buttons[alias],
                app.buttons[alias],
            ]
        }

        for candidate in candidates {
            if !candidate.waitForExistence(timeout: 1.5) {
                continue
            }
            if !candidate.isSelected {
                if candidate.isHittable {
                    candidate.tap()
                } else {
                    candidate.forceTap()
                }
                _ = waitForSelectedTab(label: label, identifier: identifier, timeout: 1.5)
            }
            if waitForSelectedTab(label: label, identifier: identifier, timeout: 0.8) {
                return
            }
        }
    }
    
    private func findSearchBar(timeout: TimeInterval) -> XCUIElement {
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 2) { return searchField }
        
        let activeId = app.textFields["SearchBarActiveView-TextField"]
        if activeId.waitForExistence(timeout: 2) { return activeId }
        
        let staticView = app.buttons["SearchBarStaticView"]
        if staticView.waitForExistence(timeout: 2) { return staticView }
        
        let searchPlaceholderPredicate = NSPredicate(format: "placeholderValue CONTAINS[c] 'listen' OR label CONTAINS[c] 'listen'")
        let searchByPlaceholder = app.searchFields.matching(searchPlaceholderPredicate).firstMatch
        if searchByPlaceholder.waitForExistence(timeout: 2) { return searchByPlaceholder }
        
        let exact = app.textFields["What do you want to listen to?"]
        if exact.waitForExistence(timeout: 2) { return exact }
        
        let placeholderPredicate = NSPredicate(format: "placeholderValue CONTAINS[c] 'listen'")
        let byPlaceholder = app.textFields.matching(placeholderPredicate).firstMatch
        if byPlaceholder.waitForExistence(timeout: 2) { return byPlaceholder }
        
        let exactStatic = app.staticTexts["What do you want to listen to?"]
        if exactStatic.waitForExistence(timeout: 2) {
            let container = app.otherElements.containing(.staticText, identifier: "What do you want to listen to?").firstMatch
            if container.exists { return container }
            return exactStatic
        }
        
        let exactButton = app.buttons["What do you want to listen to?"]
        if exactButton.waitForExistence(timeout: 2) { return exactButton }
        
        let labelExact = app.otherElements["What do you want to listen to?"]
        if labelExact.waitForExistence(timeout: 2) { return labelExact }
        
        let labelPredicate = NSPredicate(format: "label CONTAINS[c] 'listen'")
        let byLabel = app.descendants(matching: .any).matching(labelPredicate).firstMatch
        if byLabel.waitForExistence(timeout: timeout) { return byLabel }
        
        let idPredicate = NSPredicate(format: "identifier CONTAINS[c] 'search'")
        let byId = app.otherElements.matching(idPredicate).firstMatch
        if byId.waitForExistence(timeout: 2) { return byId }
        
        return searchField
    }
    

    private func activateSearchIfNeeded() {
        let staticView = app.buttons["SearchBarStaticView"]
        if staticView.exists {
            staticView.forceTap()
            _ = app.textFields["SearchBarActiveView-TextField"].waitForExistence(timeout: 2)
        }
    }

    private func prepareLoginCredentials() {
        navigateToLoginScreen()

        let env = ProcessInfo.processInfo.environment
        let isLegacyApp = isLegacyRun
        let emailTimeout: TimeInterval = isLegacyApp ? 4 : 6
        let passwordTimeout: TimeInterval = isLegacyApp ? 4 : 6
        let email = env[Env.email] ?? "testjp100@test.com"
        if isLegacyApp {
            let emailField = legacyEmailField()
            if !app.keyboards.firstMatch.exists {
                emailField.forceTap()
            }
            app.typeText(email)
            _ = advanceLoginKeyboardToPassword()
        } else {
            let emailField = findEmailField(timeout: emailTimeout)
            emailField.clearAndType(email)
            dismissKeyboardIfPresent()
        }

        let password = env[Env.password] ?? "Test1234"
        if isLegacyApp {
            let passField = legacyPasswordField(timeout: passwordTimeout)
            passField.forceTap()
            app.typeText(password)
        } else {
            let passField = findPasswordField(timeout: passwordTimeout)
            passField.clearAndType(password)
        }
        dismissKeyboardIfPresent()
    }

    @discardableResult
    private func submitLoginAndWait() -> Bool {
        let isLegacyApp = isLegacyRun
        if isLegacyApp {
            let legacySubmit = legacyLoginSubmitButton()
            guard legacySubmit.exists else {
                dumpAccessibilityTree("LoginSubmitMissing")
                XCTFail("Login Failed: submit button not found.")
                return false
            }
            legacySubmit.forceTap()
        } else {
            let submitCandidates: [XCUIElement] = [
                app.buttons[UI.loginSubmit],
                app.buttons["Log In"],
                app.buttons["Log in"],
            ]
            if !tapFirstExisting(submitCandidates, context: "LoginSubmitMissing", failIfMissing: false) {
                dumpAccessibilityTree("LoginSubmitMissing")
                XCTFail("Login Failed: submit button \(UI.loginSubmit) not found.")
                return false
            }
        }

        let loggedIn = waitForLoggedIn(timeout: 30)
        if !loggedIn, let appError = currentAppErrorMessage() {
            _ = dismissAppErrorAlertIfPresent()
            XCTFail("Login Failed: \(appError)")
        } else {
            XCTAssertTrue(loggedIn)
        }
        return loggedIn
    }

    private func prepareSearchQuery(_ query: String) {
        returnToRootIfNeeded()
        dismissAdsIfPresent(reason: "beforeSearchTab")
        selectTab(label: "Search", identifier: "searchTab")
        dismissAdsIfPresent(reason: "beforeSearchInput")

        let activeField = app.textFields["SearchBarActiveView-TextField"]
        if !activeField.exists {
            let staticView = app.buttons["SearchBarStaticView"]
            if staticView.waitForExistence(timeout: 3) {
                staticView.forceTap()
            }
        }

        if !activeField.waitForExistence(timeout: 5) {
            let searchField = app.searchFields.firstMatch
            if searchField.waitForExistence(timeout: 2) {
                searchField.forceTap()
                searchField.clearAndType(query)
                return
            }
            dumpAccessibilityTree("SearchFieldMissing")
            XCTFail("Search text field not found.")
        } else {
            activeField.forceTap()
            activeField.clearAndType(query)
        }
    }

    private func submitSearchQuery() {
        let searchButton = app.keyboards.buttons["Search"]
        if searchButton.waitForExistence(timeout: 3) {
            searchButton.tap()
            return
        }

        let returnButton = app.keyboards.buttons["Return"]
        if returnButton.waitForExistence(timeout: 1) {
            returnButton.tap()
            return
        }

        if app.searchFields.firstMatch.exists {
            app.searchFields.firstMatch.typeText("\n")
        }
    }

    private func runSearchPlaybackFlow(query: String) {
        prepareSearchQuery(query)
        submitSearchQuery()

        dismissAdsIfPresent(reason: "beforeSearchResults")
        if !waitForSearchResults(query: query, timeout: 6) {
            dumpAccessibilityTree("SearchResultsMissing")
            XCTFail("Search results not found.")
            return
        }

        if !openFirstSearchResult(query: query) {
            dumpAccessibilityTree("SearchResultsMissing")
            XCTFail("Search result target not found.")
            return
        }

        assertPlaybackStarted(context: "SearchPlaybackNotStarted")
    }

    @discardableResult
    private func prepareAlbumSearchResults(query: String) -> Bool {
        prepareSearchQuery(query)
        submitSearchQuery()
        dismissAdsIfPresent(reason: "beforeAlbumSearchResults")
        guard waitForSearchResults(query: query, timeout: isLegacyRun ? 8 : 10) else {
            return false
        }
        if visibleAlbumResultTargets(maxResults: 1).isEmpty {
            _ = tapAlbumResultsFilterIfPresent(timeout: isLegacyRun ? 1.5 : 2.5)
        }
        return waitForAlbumGridReady(timeout: isLegacyRun ? 8 : 12, minimumVisibleCount: 1)
    }

    @discardableResult
    private func openAlbumResultFromSearch(query: String) -> Bool {
        guard prepareAlbumSearchResults(query: query) else {
            return false
        }
        for target in visibleAlbumResultTargets() {
            target.forceTap()
            if waitForAlbumDetailLoaded(timeout: isLegacyRun ? 10 : 8) {
                return true
            }
            if isInlineAPIErrorVisible() {
                dismissInlineAPIErrorIfPossible()
            }
            returnToAlbumResults()
        }
        return false
    }

    @discardableResult
    private func waitForSearchResults(query: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = firstSearchResultTarget(query: query), result.exists {
                return true
            }
            let resultHeader = app.staticTexts["SearchResultsListView-Header"]
            if resultHeader.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    @discardableResult
    private func openFirstSearchResult(query: String) -> Bool {
        if let preferred = firstSearchResultTarget(query: query) {
            preferred.forceTap()
            return true
        }

        let candidates = [
            app.collectionViews["SearchResultsView"].cells.firstMatch,
            app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'playlist' OR identifier CONTAINS[c] 'artist' OR identifier CONTAINS[c] 'song' OR identifier CONTAINS[c] 'result' OR label CONTAINS[c] 'playlist' OR label CONTAINS[c] 'artist' OR label CONTAINS[c] 'song' OR label CONTAINS[c] %@", query)).firstMatch,
            app.otherElements.matching(NSPredicate(format: "identifier CONTAINS[c] 'playlist' OR identifier CONTAINS[c] 'artist' OR identifier CONTAINS[c] 'song' OR identifier CONTAINS[c] 'result' OR label CONTAINS[c] 'playlist' OR label CONTAINS[c] 'artist' OR label CONTAINS[c] 'song' OR label CONTAINS[c] %@", query)).firstMatch,
            app.collectionViews["SearchResultsView"].descendants(matching: .button).firstMatch,
        ]
        return tapFirstExisting(candidates, context: "SearchResultMissing", failIfMissing: false)
    }

    private func firstSearchResultTarget(query: String) -> XCUIElement? {
        let queryPredicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@", query, query, query)
        let contentPredicate = NSPredicate(format: "identifier CONTAINS[c] 'playlist' OR identifier CONTAINS[c] 'artist' OR identifier CONTAINS[c] 'song' OR identifier CONTAINS[c] 'result' OR label CONTAINS[c] 'playlist' OR label CONTAINS[c] 'artist' OR label CONTAINS[c] 'song' OR label CONTAINS[c] 'station'")
        let searchResultsView = app.collectionViews["SearchResultsView"]

        let candidateGroups: [[XCUIElement]] = [
            searchResultsView.cells.matching(queryPredicate).allElementsBoundByIndex,
            searchResultsView.cells.allElementsBoundByIndex,
            searchResultsView.descendants(matching: .button).matching(queryPredicate).allElementsBoundByIndex,
            searchResultsView.descendants(matching: .other).matching(queryPredicate).allElementsBoundByIndex,
            app.buttons.matching(queryPredicate).allElementsBoundByIndex,
            app.otherElements.matching(queryPredicate).allElementsBoundByIndex,
            searchResultContainers(for: query),
            app.buttons.matching(contentPredicate).allElementsBoundByIndex,
            app.otherElements.matching(contentPredicate).allElementsBoundByIndex,
        ]

        for group in candidateGroups {
            if let match = group.first(where: { isUsableSearchResult($0, query: query) }) {
                return match
            }
        }
        return nil
    }

    @discardableResult
    private func tapAlbumResultsFilterIfPresent(timeout: TimeInterval) -> Bool {
        let filterPredicate = NSPredicate(format: "label ==[c] 'Albums' OR label ==[c] 'Album' OR identifier CONTAINS[c] 'albumFilter' OR identifier CONTAINS[c] 'albums'")
        let candidates = [
            app.segmentedControls.buttons["Albums"],
            app.segmentedControls.buttons["Album"],
            app.buttons["Albums"],
            app.buttons["Album"],
            app.buttons.matching(filterPredicate).firstMatch,
            app.descendants(matching: .button).matching(filterPredicate).firstMatch,
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for candidate in candidates where candidate.exists {
                candidate.forceTap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    private func searchResultContainers(for query: String) -> [XCUIElement] {
        let queryPredicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@", query, query, query)
        let textMatches = app.staticTexts.matching(queryPredicate).allElementsBoundByIndex
        var containers: [XCUIElement] = []
        for text in textMatches where text.exists {
            let label = text.label
            if label.isEmpty { continue }
            if label.count > 120 {
                containers.append(text)
                continue
            }
            let buttonContainer = app.buttons.containing(.staticText, identifier: label).firstMatch
            let cellContainer = app.cells.containing(.staticText, identifier: label).firstMatch
            let otherContainer = app.otherElements.containing(.staticText, identifier: label).firstMatch
            containers.append(contentsOf: [buttonContainer, cellContainer, otherContainer, text])
        }
        return containers
    }

    private func isUsableSearchResult(_ element: XCUIElement, query: String) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }

        let viewport = contentViewportBounds()
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : .greatestFiniteMagnitude
        if frame.maxY >= tabBarTop || frame.minY < 120 || !frame.intersects(viewport) {
            return false
        }

        switch element.elementType {
        case .searchField, .textField, .secureTextField, .keyboard, .key:
            return false
        default:
            break
        }

        let strings = [
            element.identifier,
            element.label,
            element.value as? String ?? "",
        ].joined(separator: " ").lowercased()

        if strings.isEmpty { return false }
        if strings.contains("searchbar") || strings.contains("what do you want to listen to") {
            return false
        }
        if strings.contains("tab_search") || strings.contains("tab_yourhome") || strings.contains("tab_radio") || strings.contains("tab_podcasts") || strings.contains("tab_playlists") {
            return false
        }
        if strings.contains("contenttabswitcher")
            || strings.contains("tabbutton")
            || strings.contains("searchplaylists")
            || strings.contains("searchartists")
            || strings.contains("searchsongs")
            || strings.contains("searchstations")
            || strings.contains("searchpodcasts")
            || strings.contains("searchepisodes")
            || strings.contains("searchall") {
            return false
        }
        if strings.contains("featuredplaylistsection")
            || strings.contains("moodsandactivitiessection")
            || strings.contains("decadessection")
            || strings.contains("playlistgenresgrid")
            || strings.contains("recommendedforyousection")
            || strings.contains("carouselcard")
            || strings.contains("gridcard")
            || strings.contains("playliststab")
            || strings.contains("radiodialcardcell")
            || strings.contains("scan stations") {
            return false
        }

        let searchResultsView = app.collectionViews["SearchResultsView"]
        let isInsideSearchResultsView = searchResultsView.exists && !searchResultsView.frame.isEmpty && searchResultsView.frame.intersects(frame)
        let hasQueryMatch = strings.contains(query.lowercased())
        let looksLikeResult = strings.contains("playlist")
            || strings.contains("artist")
            || strings.contains("song")
            || strings.contains("station")
            || strings.contains("episode")
            || strings.contains("result")

        if isInsideSearchResultsView && (hasQueryMatch || looksLikeResult) {
            return true
        }

        return hasQueryMatch && looksLikeResult
    }

    private func contentViewportBounds() -> CGRect {
        let window = app.windows.firstMatch.exists && !app.windows.firstMatch.frame.isEmpty
            ? app.windows.firstMatch.frame
            : app.frame
        let navBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 90
        let tabTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.maxY
        let miniPlayerTop = miniPlayerTopBoundary() ?? window.maxY
        let top = max(120, navBottom)
        let bottom = min(tabTop, miniPlayerTop)
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    private func visibleMiniPlayerContainers() -> [XCUIElement] {
        app.buttons.matching(identifier: "MiniPlayer-Container").allElementsBoundByIndex.filter {
            $0.exists && !$0.frame.isEmpty
        }
    }

    private func miniPlayerContainerElement() -> XCUIElement {
        visibleMiniPlayerContainers().first ?? app.buttons.matching(identifier: "MiniPlayer-Container").firstMatch
    }

    private func hasVisibleMiniPlayerContainer() -> Bool {
        !visibleMiniPlayerContainers().isEmpty
    }

    private func miniPlayerTopBoundary() -> CGFloat? {
        let candidates = visibleMiniPlayerContainers().map(\.frame.minY)
        return candidates.min()
    }

    private func visibleContentElements(_ elements: [XCUIElement], preferLowerHalf: Bool = false) -> [XCUIElement] {
        let bounds = contentViewportBounds()
        let filtered = elements.filter { element in
            guard element.exists else { return false }
            let frame = element.frame
            guard !frame.isEmpty else { return false }
            guard frame.width >= 44 && frame.height >= 32 else { return false }
            guard frame.intersects(bounds) else { return false }
            guard bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
            let strings = [
                element.identifier,
                element.label,
                element.value as? String ?? "",
            ].joined(separator: " ").lowercased()
            return !strings.contains("tab_")
                && !strings.contains("scroll bar")
                && !strings.contains("loading")
                && !strings.contains("miniplayer")
        }

        let sorted = filtered.sorted { lhs, rhs in
            let lhsScore = (lhs.isHittable ? 1 : 0, preferLowerHalf ? lhs.frame.midY : -lhs.frame.midY, lhs.frame.minX)
            let rhsScore = (rhs.isHittable ? 1 : 0, preferLowerHalf ? rhs.frame.midY : -rhs.frame.midY, rhs.frame.minX)
            return lhsScore > rhsScore
        }
        return sorted
    }

    private func firstVisibleContentElement(in query: XCUIElementQuery, preferLowerHalf: Bool = false) -> XCUIElement? {
        visibleContentElements(query.allElementsBoundByIndex, preferLowerHalf: preferLowerHalf).first
    }

    private func limitedElements(in query: XCUIElementQuery, limit: Int) -> [XCUIElement] {
        guard limit > 0 else { return [] }
        var results: [XCUIElement] = []
        results.reserveCapacity(limit)
        for index in 0..<limit {
            let element = query.element(boundBy: index)
            if !element.exists { break }
            results.append(element)
        }
        return results
    }

    private func preferredLegacyListenButton() -> XCUIElement? {
        let listenPredicate = NSPredicate(format: "label ==[c] 'Listen' OR identifier CONTAINS[c] 'listen'")
        let explicitButtons = app.buttons.matching(listenPredicate)
        if let visible = firstVisibleContentElement(in: explicitButtons) {
            return visible
        }

        let nestedButtons = app.descendants(matching: .button).matching(listenPredicate)
        return firstVisibleContentElement(in: nestedButtons)
    }

    private func preferredLegacyPlayButton() -> XCUIElement? {
        let playPredicate = NSPredicate(format: "identifier CONTAINS[c] 'play' OR label ==[c] 'Play' OR label CONTAINS[c] 'Play'")
        let explicitButtons = app.buttons.matching(playPredicate)
        if let visible = firstVisibleContentElement(in: explicitButtons) {
            return visible
        }

        let nestedButtons = app.descendants(matching: .button).matching(playPredicate)
        return firstVisibleContentElement(in: nestedButtons)
    }

    private func isContentLoadingVisible() -> Bool {
        let loadingIndicators = [
            app.activityIndicators.firstMatch,
            app.staticTexts["Loading"],
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Loading'")).firstMatch,
        ]
        return loadingIndicators.contains(where: { $0.exists })
    }

    private func albumResultQueries() -> [XCUIElementQuery] {
        let albumPredicate = NSPredicate(format: "identifier CONTAINS[c] 'album' OR label CONTAINS[c] 'album' OR value CONTAINS[c] 'album' OR identifier CONTAINS[c] 'cover' OR identifier CONTAINS[c] 'artwork'")
        let searchResultsView = app.collectionViews["SearchResultsView"]
        return [
            searchResultsView.cells.matching(albumPredicate),
            searchResultsView.descendants(matching: .button).matching(albumPredicate),
            searchResultsView.descendants(matching: .other).matching(albumPredicate),
            app.collectionViews.firstMatch.cells.matching(albumPredicate),
            app.collectionViews.firstMatch.descendants(matching: .button).matching(albumPredicate),
            app.collectionViews.firstMatch.descendants(matching: .other).matching(albumPredicate),
            app.buttons.matching(albumPredicate),
            app.otherElements.matching(albumPredicate),
            searchResultsView.cells,
            app.collectionViews.firstMatch.cells,
        ]
    }

    private func isUsableAlbumResult(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        guard frame.height <= 220 else { return false }

        let strings = [
            element.identifier,
            element.label,
            element.value as? String ?? "",
        ].joined(separator: " ").lowercased()

        if strings.isEmpty { return false }
        if strings.contains("searchbar") || strings.contains("what do you want to listen to") {
            return false
        }
        if strings.contains("tab_") || strings.contains("loading") || strings.contains("settings") {
            return false
        }
        if strings.contains("playlist") || strings.contains("podcast") || strings.contains("episode") || strings.contains("station") {
            return false
        }
        if strings.contains("album") {
            return true
        }
        if strings.contains("song") || strings.contains("artist") {
            return false
        }
        let hasArtworkDescendant = element.images.firstMatch.exists || element.descendants(matching: .image).firstMatch.exists
        return hasArtworkDescendant && frame.height >= 60
    }

    private func visibleAlbumResultTargets(maxResults: Int = 6) -> [XCUIElement] {
        var results: [XCUIElement] = []
        var seen = Set<String>()
        for query in albumResultQueries() {
            let limitedTargets = limitedElements(in: query, limit: 8)
            for target in visibleContentElements(limitedTargets) where isUsableAlbumResult(target) {
                let key = "\(target.identifier)|\(target.label)|\(Int(target.frame.minX))|\(Int(target.frame.minY))"
                if seen.insert(key).inserted {
                    results.append(target)
                    if results.count >= maxResults {
                        return results
                    }
                }
            }
        }
        return results
    }

    @discardableResult
    private func waitForAlbumGridReady(timeout: TimeInterval, minimumVisibleCount: Int = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isContentLoadingVisible() && visibleAlbumResultTargets().count >= minimumVisibleCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return visibleAlbumResultTargets().count >= minimumVisibleCount
    }

    private func playlistCardQueries() -> [XCUIElementQuery] {
        if isLegacyRun {
            let legacyStructuredPredicate = NSPredicate(format: "identifier BEGINSWITH[c] 'CUIFeaturedCardListCell-' OR identifier BEGINSWITH[c] 'CUICardListCell-' OR identifier BEGINSWITH[c] 'CUIImageTitleSubtitleTileCell-'")
            return [
                app.descendants(matching: .any).matching(legacyStructuredPredicate),
                app.buttons.matching(legacyStructuredPredicate),
                app.otherElements.matching(legacyStructuredPredicate),
            ]
        }

        let qaPredicate = NSPredicate(format: "identifier BEGINSWITH[c] 'featuredPlaylistSection-CarouselCard-Index' OR identifier BEGINSWITH[c] 'moodsAndActivitiesSection-CarouselCard-Index' OR identifier BEGINSWITH[c] 'decadesSection-CarouselCard-Index' OR identifier BEGINSWITH[c] 'playlistGenresGrid-GridCard-Index' OR identifier CONTAINS[c] 'CarouselCard' OR identifier CONTAINS[c] 'GridCard'")
        let qaScrollView = app.scrollViews["PlaylistsTabView-ScrollView"]
        return [
            qaScrollView.descendants(matching: .button).matching(qaPredicate),
            qaScrollView.descendants(matching: .other).matching(qaPredicate),
            app.buttons.matching(qaPredicate),
            app.otherElements.matching(qaPredicate),
        ]
    }

    @discardableResult
    private func waitForPlaylistContentReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isContentLoadingVisible() {
                if !isLegacyRun, preferredQAPlaylistCardTarget() != nil {
                    return true
                }
                for query in playlistCardQueries() {
                    if !visibleContentElements(limitedElements(in: query, limit: 40)).isEmpty {
                        return true
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        } while Date() < deadline

        for query in playlistCardQueries() {
            if !visibleContentElements(limitedElements(in: query, limit: 40)).isEmpty {
                return true
            }
        }
        return false
    }

    private func preferredQAPlaylistCardTarget() -> XCUIElement? {
        guard !isLegacyRun else { return nil }

        let preferredPredicates = [
            NSPredicate(format: "identifier BEGINSWITH[c] 'recommendedForYouSection-CarouselCard-Index'"),
            NSPredicate(format: "identifier BEGINSWITH[c] 'featuredPlaylistSection-CarouselCard-Index'"),
            NSPredicate(format: "identifier BEGINSWITH[c] 'moodsAndActivitiesSection-CarouselCard-Index'"),
            NSPredicate(format: "identifier BEGINSWITH[c] 'decadesSection-CarouselCard-Index'"),
        ]

        for predicate in preferredPredicates {
            let query = app.buttons.matching(predicate)
            let candidates = visibleContentElements(limitedElements(in: query, limit: 8))
            if let target = candidates.first(where: isValidPlaylistCardTarget(_:)) {
                return target
            }
        }

        return nil
    }

    private func firstPlaylistCardTarget() -> XCUIElement? {
        guard waitForPlaylistContentReady(timeout: isLegacyRun ? 12 : 20) else {
            return nil
        }
        if let preferredTarget = preferredQAPlaylistCardTarget() {
            return preferredTarget
        }
        for query in playlistCardQueries() {
            let visibleTargets = visibleContentElements(limitedElements(in: query, limit: 40))
            if let target = visibleTargets.first(where: isValidPlaylistCardTarget(_:)) {
                return target
            }
        }
        return nil
    }

    @discardableResult
    private func openFirstPlaylistCard() -> Bool {
        guard let target = firstPlaylistCardTarget() else { return false }
        target.forceTap()
        if waitForPlaylistDetail(timeout: isLegacyRun ? 8 : 6) {
            return true
        }
        if isLegacyRun {
            if app.buttons["ProfileHeader-backButton"].exists {
                app.buttons["ProfileHeader-backButton"].forceTap()
            } else if app.navigationBars.buttons.firstMatch.exists {
                app.navigationBars.buttons.firstMatch.forceTap()
            }
            _ = app.collectionViews.firstMatch.waitForExistence(timeout: 2)
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: 1)
        }
        return false
    }

    private func podcastEpisodeQueries() -> [XCUIElementQuery] {
        if isLegacyRun {
            let legacyPredicate = NSPredicate(format: "identifier CONTAINS[c] 'PodcastContentTabView' OR identifier CONTAINS[c] 'ContinueListening' OR identifier CONTAINS[c] 'EpisodeCard' OR identifier CONTAINS[c] 'CUIImageTitleSubtitleTileCell' OR identifier CONTAINS[c] 'CUICardListCell' OR identifier CONTAINS[c] 'CUIFeaturedCardListCell' OR identifier CONTAINS[c] 'podcast' OR identifier CONTAINS[c] 'episode' OR label CONTAINS[c] 'podcast' OR label CONTAINS[c] 'episode' OR label ==[c] 'Listen'")
            return [
                app.buttons.matching(legacyPredicate),
                app.otherElements.matching(legacyPredicate),
                app.collectionViews.firstMatch.descendants(matching: .button).matching(legacyPredicate),
                app.collectionViews.firstMatch.cells.matching(legacyPredicate),
                app.scrollViews["PodcastContentTabView-ScrollView"].descendants(matching: .button).matching(legacyPredicate),
            ]
        }

        let qaPredicate = NSPredicate(format: "identifier CONTAINS[c] 'EpisodeCard' OR identifier CONTAINS[c] 'PodcastContentTabView' OR identifier CONTAINS[c] 'ContinueListening' OR identifier CONTAINS[c] 'podcast' OR identifier CONTAINS[c] 'episode' OR label CONTAINS[c] 'episode' OR label ==[c] 'Listen' OR identifier CONTAINS[c] 'listen'")
        let qaScrollView = app.scrollViews["PodcastContentTabView-ScrollView"]
        return [
            qaScrollView.descendants(matching: .button).matching(qaPredicate),
            qaScrollView.descendants(matching: .other).matching(qaPredicate),
            app.buttons.matching(qaPredicate),
            app.otherElements.matching(qaPredicate),
        ]
    }

    @discardableResult
    private func waitForPodcastContentReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isContentLoadingVisible() {
                if !isLegacyRun, preferredQAPodcastEpisodeTarget() != nil {
                    return true
                }
                for query in podcastEpisodeQueries() {
                    if !visibleContentElements(limitedElements(in: query, limit: 40), preferLowerHalf: true).isEmpty {
                        return true
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        } while Date() < deadline

        for query in podcastEpisodeQueries() {
            if !visibleContentElements(limitedElements(in: query, limit: 40), preferLowerHalf: true).isEmpty {
                return true
            }
        }
        return false
    }

    private func preferredQAPodcastEpisodeTarget() -> XCUIElement? {
        guard !isLegacyRun else { return nil }

        let preferredPredicates = [
            NSPredicate(format: "identifier ==[c] 'PodcastContentTabView-ContinueListening-CardItem'"),
            NSPredicate(format: "identifier BEGINSWITH[c] 'recommendedPodcastsSection-CarouselCard-Index'"),
            NSPredicate(format: "identifier BEGINSWITH[c] 'popularPodcastsSection-CarouselCard-Index'"),
        ]

        for predicate in preferredPredicates {
            let query = app.buttons.matching(predicate)
            let candidates = visibleContentElements(limitedElements(in: query, limit: 8), preferLowerHalf: true)
                .filter { candidate in
                    let identifier = candidate.identifier.lowercased()
                    let label = candidate.label.lowercased()
                    return !identifier.contains("miniplayer") && !label.contains("mini player")
                }
            if let target = candidates.first {
                return target
            }
        }

        return nil
    }

    private func firstPodcastEpisodeTarget() -> XCUIElement? {
        guard waitForPodcastContentReady(timeout: isLegacyRun ? 12 : 20) else {
            return nil
        }
        func validPodcastTarget(_ element: XCUIElement) -> Bool {
            let identifier = element.identifier.lowercased()
            let label = element.label.lowercased()
            let value = (element.value as? String ?? "").lowercased()
            let strings = [identifier, label, value].joined(separator: " ")
            if identifier.contains("contentrow-indexrow") {
                return false
            }
            if identifier.contains("miniplayer") || label.contains("mini player") {
                return false
            }
            if strings.contains("tracklist")
                || strings.contains("track cell")
                || strings.contains("albumprofile")
                || strings.contains("song")
                || strings.contains("station")
                || strings.contains("search")
                || strings.contains("settings")
                || strings.contains("share")
                || strings.contains("overflow") {
                return false
            }
            if identifier.contains("tab") || label == "home" || label == "radio" || label == "podcasts" || label == "playlists" || label == "search" {
                return false
            }
            if isLegacyRun {
                return identifier.contains("cuicardlistcell")
                    || identifier.contains("cuiimagetitlesubtitletilecell")
                    || identifier.contains("cuifeaturedcardlistcell")
                    || identifier.contains("podcastcontenttabview")
                    || identifier.contains("continuelistening")
                    || label.contains("podcast")
                    || label.contains("episode")
                    || label == "listen"
            }
            return identifier.contains("episode")
                || identifier.contains("podcastcontenttabview")
                || identifier.contains("continuelistening")
                || identifier.contains("podcast")
                || label.contains("episode")
                || label == "listen"
        }

        if let preferredTarget = preferredQAPodcastEpisodeTarget(), validPodcastTarget(preferredTarget) {
            return preferredTarget
        }

        for query in podcastEpisodeQueries() {
            let candidates = visibleContentElements(limitedElements(in: query, limit: 40), preferLowerHalf: true)
                .filter(validPodcastTarget)
            if let target = candidates.first {
                return target
            }
        }
        return nil
    }

    @discardableResult
    private func openFirstPodcastEpisode() -> Bool {
        guard let target = firstPodcastEpisodeTarget() else {
            dumpAccessibilityTree("PodcastContentMissing")
            XCTFail("No podcast content found.")
            return false
        }
        target.forceTap()
        if waitForPodcastDetailLoaded(timeout: 6) {
            return true
        }
        if isInlineAPIErrorVisible() {
            dismissInlineAPIErrorIfPossible()
        }
        if app.buttons["ProfileHeader-backButton"].exists {
            app.buttons["ProfileHeader-backButton"].forceTap()
        } else {
            selectTab(label: "Podcasts", identifier: "podcastsTab")
        }
        dumpAccessibilityTree("PodcastContentMissing")
        XCTFail("No podcast content found.")
        return false
    }

    @discardableResult
    private func openFirstRadioStation() -> Bool {
        guard let target = firstRadioStationTarget() else { return false }
        target.forceTap()
        if waitForRadioDetail(timeout: isLegacyRun ? 10 : 8) {
            return true
        }
        if isInlineAPIErrorVisible() {
            dismissInlineAPIErrorIfPossible()
        }
        if app.buttons["ProfileHeader-backButton"].exists {
            app.buttons["ProfileHeader-backButton"].forceTap()
        } else {
            selectTab(label: "Radio", identifier: "radioTab")
        }
        return false
    }

    private func firstRadioStationTarget() -> XCUIElement? {
        let radioContainers = [
            app.collectionViews.firstMatch,
            app.scrollViews.firstMatch,
        ]
        for container in radioContainers {
            if container.waitForExistence(timeout: 6) {
                break
            }
        }

        _ = waitForRadioContentReady(timeout: 12)

        for query in radioStationQueries() {
            for target in visibleContentElements(query.allElementsBoundByIndex).filter(isValidRadioStationTarget) {
                return target
            }
        }
        return nil
    }

    private func radioStationQueries() -> [XCUIElementQuery] {
        if isLegacyRun {
            let legacyPredicate = NSPredicate(format: "identifier BEGINSWITH[c] 'recommendedLiveRadioSection-CarouselCard-Index' OR identifier CONTAINS[c] 'liveRadioSection' OR identifier CONTAINS[c] 'recommendedLiveRadioSection' OR identifier CONTAINS[c] 'radioSection' OR identifier CONTAINS[c] 'station' OR identifier CONTAINS[c] 'CUIWideImageTileCell' OR identifier CONTAINS[c] 'CUIImageTitleSubtitleTileCell'")
            return [
                app.buttons.matching(legacyPredicate),
                app.otherElements.matching(legacyPredicate),
                app.collectionViews.firstMatch.descendants(matching: .button).matching(legacyPredicate),
                app.collectionViews.firstMatch.cells.matching(legacyPredicate),
                app.scrollViews["homeRadioTabMainScrollView"].descendants(matching: .button).matching(legacyPredicate),
                app.scrollViews["homeRadioTabMainScrollView"].descendants(matching: .cell).matching(legacyPredicate),
            ]
        }

        return [
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'recommendedLiveRadioSection-CarouselCard-Index'")),
            app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'liveRadioSection' OR identifier CONTAINS[c] 'recommendedLiveRadioSection' OR identifier CONTAINS[c] 'radioSection' OR identifier CONTAINS[c] 'station'")),
            app.scrollViews["homeRadioTabMainScrollView"].descendants(matching: .button),
            app.scrollViews["homeRadioTabMainScrollView"].descendants(matching: .cell),
            app.collectionViews.firstMatch.descendants(matching: .button),
            app.collectionViews.firstMatch.cells,
            app.scrollViews.firstMatch.descendants(matching: .button),
            app.cells,
        ]
    }

    private func isValidRadioStationTarget(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        guard frame.width >= 80 && frame.height >= 44 else { return false }

        let identifier = element.identifier.lowercased()
        let label = element.label.lowercased()
        let value = (element.value as? String ?? "").lowercased()
        let strings = [identifier, label, value].joined(separator: " ")

        if strings.contains("tracklist")
            || strings.contains("track cell")
            || strings.contains("albumprofile")
            || strings.contains("open presets")
            || strings.contains("presets")
            || strings.contains("stop")
            || strings.contains("pause")
            || strings.contains("share")
            || strings.contains("overflow")
            || strings.contains("miniplayer")
            || strings.contains("search")
            || strings.contains("settings") {
            return false
        }

        if isLegacyRun {
            return identifier.contains("cuiwideimagetilecell")
                || identifier.contains("cuiimagetitlesubtitletilecell")
                || identifier.contains("liveradiosection")
                || identifier.contains("recommendedliveradiosection")
                || identifier.contains("radiosection")
                || identifier.contains("station")
        }

        return strings.contains("station") || identifier.contains("radiosection") || identifier.contains("liveradiosection")
    }

    private func isRadioContentLoading() -> Bool {
        let loadingIndicators = [
            app.activityIndicators.firstMatch,
            app.staticTexts["Loading"],
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Loading'")).firstMatch,
        ]
        return loadingIndicators.contains(where: { $0.exists })
    }

    @discardableResult
    private func waitForRadioContentReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isRadioContentLoading() {
                for query in radioStationQueries() {
                    if !visibleContentElements(query.allElementsBoundByIndex).isEmpty {
                        return true
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        } while Date() < deadline

        for query in radioStationQueries() {
            if !visibleContentElements(query.allElementsBoundByIndex).isEmpty {
                return true
            }
        }
        return false
    }

    private func currentInlineAPIErrorMessage() -> String? {
        let errorPredicate = NSPredicate(format: "label CONTAINS[c] 'API Error' OR label CONTAINS[c] '404' OR label CONTAINS[c] 'timeout'")
        let visibleText = app.staticTexts.matching(errorPredicate).allElementsBoundByIndex.first {
            $0.exists && !$0.label.isEmpty
        }
        return visibleText?.label
    }

    private func isInlineAPIErrorVisible() -> Bool {
        currentInlineAPIErrorMessage() != nil
    }

    private func dismissInlineAPIErrorIfPossible() {
        let closeCandidates = [
            app.buttons["Close"],
            app.buttons["Dismiss"],
            app.buttons["Done"],
            app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'close' OR identifier CONTAINS[c] 'dismiss'")).firstMatch,
        ]
        for candidate in closeCandidates where candidate.exists {
            candidate.forceTap()
            return
        }
    }

    private func waitForPlaylistDetail(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isInlineAPIErrorVisible() {
                return false
            }
            let hasLegacyBackButton =
                app.buttons["ProfileHeader-backButton"].exists ||
                app.buttons["Back-NavBar-Button"].exists
            let hasTrackRows =
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'ContentRow-IndexRow:'")).firstMatch.exists ||
                app.cells.matching(NSPredicate(format: "identifier CONTAINS[c] 'ContentRow-IndexRow'")).firstMatch.exists
            let hasProfileHeader = hasLegacyBackButton &&
                (
                    app.buttons["Shuffle Play"].exists ||
                    app.buttons["ProfileHeaderView-Play-Button"].exists ||
                    app.buttons["ProfileHeader-shareButton"].exists ||
                    app.buttons["ProfileHeader-overflowButton"].exists ||
                    app.buttons["Podcast-Share-NavBar-Button"].exists ||
                    app.buttons["More-NavBar-Button"].exists
                )
            let hasPlaybackSurface = hasVisibleMiniPlayerContainer() &&
                (
                    app.buttons["MiniPlayer-Play-Button"].exists ||
                    app.buttons["MiniPlayer-Pause-Button"].exists ||
                    app.buttons["MiniPlayer-Stop-Button"].exists ||
                    app.buttons["NowPlaying-Pause-Button"].exists ||
                    app.buttons["NowPlaying-Stop-Button"].exists
                )
            let hasExpandedNowPlaying = app.images["NowPlaying-IHRImageView-View"].exists &&
                (
                    app.buttons["NowPlaying-Play-Button"].exists ||
                    app.buttons["NowPlaying-Pause-Button"].exists ||
                    app.buttons["NowPlaying-Stop-Button"].exists ||
                    app.buttons["PlayerView-PlayButton-UIButton"].exists ||
                    app.buttons["NewPlayButton-Play-UIButton"].exists
                )
            let hasLegacyTracklistSurface = hasLegacyBackButton &&
                (
                    app.buttons["Now Playing"].exists ||
                    app.buttons["Tracklist"].exists ||
                    app.cells["Now Playing"].exists ||
                    app.cells["Tracklist"].exists ||
                    app.staticTexts["Now Playing"].exists ||
                    app.staticTexts["Tracklist"].exists ||
                    app.collectionViews["NewApp_Sliding_Collection_View_Tab_Header"].exists
                )
            let hasLegacyPlayerSurface = hasLegacyBackButton &&
                (
                    app.buttons["PlayerView-PlayButton-UIButton"].exists ||
                    app.buttons["NewPlayButton-Play-UIButton"].exists ||
                    app.buttons["Player-AddToPlaylistButton-UIButton"].exists ||
                    app.otherElements["PlayerView-ButtonContainer-UIView"].exists
                )
            if hasProfileHeader || hasPlaybackSurface || (hasExpandedNowPlaying && hasTrackRows) || hasLegacyTracklistSurface || hasLegacyPlayerSurface {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    private func albumDetailIndicators() -> [XCUIElement] {
        [
            app.buttons["ProfileHeader-backButton"],
            app.buttons["ProfileHeaderView-Play-Button"],
            app.buttons["Shuffle Play"],
            app.buttons["ProfileHeader-shareButton"],
            app.buttons["ProfileHeader-overflowButton"],
            miniPlayerContainerElement(),
            app.collectionViews.firstMatch,
            app.tables.firstMatch,
            app.staticTexts["Songs"],
            app.staticTexts["Tracks"],
            app.staticTexts["Album"],
        ]
    }

    private func visibleAlbumArtworkImage() -> XCUIElement? {
        let viewport = contentViewportBounds()
        let artworkPredicate = NSPredicate(format: "identifier CONTAINS[c] 'artwork' OR identifier CONTAINS[c] 'cover' OR identifier CONTAINS[c] 'album' OR label CONTAINS[c] 'cover' OR label CONTAINS[c] 'artwork'")
        let imageGroups = [
            app.images.matching(artworkPredicate).allElementsBoundByIndex,
            app.images.allElementsBoundByIndex,
        ]

        for group in imageGroups {
            let candidate = group.first { image in
                guard image.exists else { return false }
                let frame = image.frame
                guard !frame.isEmpty else { return false }
                guard frame.width >= 60 && frame.height >= 60 else { return false }
                guard frame.intersects(viewport) else { return false }
                return true
            }
            if let candidate {
                return candidate
            }
        }
        return nil
    }

    private func waitForAlbumArtworkVisible(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isContentLoadingVisible(), visibleAlbumArtworkImage() != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return visibleAlbumArtworkImage() != nil
    }

    private func searchResultArtworkImage(in container: XCUIElement) -> XCUIElement? {
        let viewport = contentViewportBounds()
        let artworkPredicate = NSPredicate(format: "identifier CONTAINS[c] 'artwork' OR identifier CONTAINS[c] 'cover' OR label CONTAINS[c] 'cover' OR label CONTAINS[c] 'artwork'")
        let imageQueries: [XCUIElementQuery] = [
            container.descendants(matching: .image).matching(artworkPredicate),
            container.images.matching(artworkPredicate),
            container.descendants(matching: .image),
            container.images,
        ]

        for query in imageQueries {
            for image in limitedElements(in: query, limit: 8) {
                guard image.exists else { continue }
                let frame = image.frame
                guard !frame.isEmpty else { continue }
                guard frame.width >= 40 && frame.height >= 40 else { continue }
                guard frame.intersects(viewport) else { continue }
                guard boundsContainsMidpoint(viewport, frame: frame) else { continue }
                return image
            }
        }
        return nil
    }

    private func searchResultAwaitingArtworkTarget(query: String) -> XCUIElement? {
        if isLegacyRun, let preferredLegacyTarget = preferredLegacyImageLoadingTarget(query: query), preferredLegacyTarget.exists {
            return preferredLegacyTarget
        }
        guard let target = firstSearchResultTarget(query: query), target.exists else {
            return nil
        }
        return target
    }

    private func waitForSearchResultAwaitingArtwork(query: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let target = searchResultAwaitingArtworkTarget(query: query) {
                return target
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return searchResultAwaitingArtworkTarget(query: query)
    }

    private func boundsContainsMidpoint(_ bounds: CGRect, frame: CGRect) -> Bool {
        bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func waitForArtworkVisible(in container: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isContentLoadingVisible(),
               (searchResultArtworkImage(in: container) != nil || (isLegacyRun && visibleMediaArtworkImage() != nil)) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return searchResultArtworkImage(in: container) != nil || (isLegacyRun && visibleMediaArtworkImage() != nil)
    }

    private func waitForMediaArtworkVisible(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !isContentLoadingVisible(), visibleMediaArtworkImage() != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return visibleMediaArtworkImage() != nil
    }

    private func waitForAlbumDetailLoaded(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isInlineAPIErrorVisible() {
                return false
            }
            let hasPrimaryChrome = app.buttons["ProfileHeader-backButton"].exists
                && (
                    app.buttons["ProfileHeaderView-Play-Button"].exists
                    || app.buttons["Shuffle Play"].exists
                    || app.buttons["ProfileHeader-shareButton"].exists
                    || app.buttons["ProfileHeader-overflowButton"].exists
                )
            let hasTrackSurface = app.collectionViews.firstMatch.exists || app.tables.firstMatch.exists
            if hasPrimaryChrome && (hasTrackSurface || waitForAlbumArtworkVisible(timeout: 0.6)) {
                return true
            }
            if albumDetailIndicators().contains(where: { $0.exists }) && waitForAlbumArtworkVisible(timeout: 0.4) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func assertAlbumDetailLoaded(context: String) {
        if waitForAlbumDetailLoaded(timeout: isLegacyRun ? 10 : 8) {
            return
        }
        dumpAccessibilityTree(context)
        XCTFail("Album detail did not load.")
    }

    private func assertAlbumArtworkVisible(context: String) {
        if waitForAlbumArtworkVisible(timeout: isLegacyRun ? 8 : 6) {
            return
        }
        dumpAccessibilityTree(context)
        XCTFail("Album artwork did not become visible.")
    }

    private func returnToAlbumResults() {
        if app.buttons["ProfileHeader-backButton"].exists {
            app.buttons["ProfileHeader-backButton"].forceTap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            return
        }
        if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.forceTap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            return
        }
        selectTab(label: "Search", identifier: "searchTab")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func waitForRadioDetail(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isInlineAPIErrorVisible() {
                return false
            }
            let hasLegacyBackButton =
                app.buttons["ProfileHeader-backButton"].exists ||
                app.buttons["Back-NavBar-Button"].exists
            let contentTabSwitcher = app.scrollViews["ContentTabSwitcher-ScrollView"]
            let hasLoadedProfile = app.buttons["ProfileHeader-backButton"].exists &&
                app.otherElements["ProfileHeaderView"].exists &&
                (contentTabSwitcher.frame.height > 10 || app.buttons["ProfileHeaderView-Play-Button"].exists)
            let hasPlaybackSurface = hasVisibleMiniPlayerContainer() &&
                (
                    app.buttons["MiniPlayer-Play-Button"].exists ||
                    app.buttons["MiniPlayer-Pause-Button"].exists ||
                    app.buttons["MiniPlayer-Stop-Button"].exists ||
                    app.buttons["NowPlaying-Pause-Button"].exists ||
                    app.buttons["NowPlaying-Stop-Button"].exists
                )
            let hasLegacyPlayerSurface = hasLegacyBackButton &&
                (
                    app.staticTexts["Now Playing"].exists ||
                    app.buttons["Now Playing"].exists ||
                    app.staticTexts["Tracklist"].exists ||
                    app.buttons["Tracklist"].exists ||
                    app.buttons["PlayerView-PlayButton-UIButton"].exists ||
                    app.buttons["NewPlayButton-Play-UIButton"].exists ||
                    app.otherElements["PlayerView-ButtonContainer-UIView"].exists
                )
            if hasLoadedProfile || hasPlaybackSurface || hasLegacyPlayerSurface {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    private func podcastDetailIndicators() -> [XCUIElement] {
        [
            app.collectionViews["PodcastProfileViewController-EpisodeCollectionView-UICollectionView"],
            app.buttons["Podcast-Share-NavBar-Button"],
            app.buttons["More-NavBar-Button"],
            app.buttons["NewPlayButton-Play-UIButton"],
            app.buttons["NowPlaying-Pause-Button"],
            app.buttons["MiniPlayer-Pause-Button"],
            miniPlayerContainerElement(),
            app.staticTexts["Episodes"],
            app.staticTexts["Podcast"],
            app.otherElements["PodcastProfileHeaderView"],
            app.otherElements["Now Playing"],
        ]
    }

    private func waitForPodcastDetailLoaded(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if podcastDetailIndicators().contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func assertPodcastDetailLoaded(context: String) {
        if waitForPodcastDetailLoaded(timeout: 8) {
            return
        }
        dumpAccessibilityTree(context)
        XCTFail("Podcast detail did not load.")
    }
    
    private func findEmailField(timeout: TimeInterval) -> XCUIElement {
        let direct = app.textFields[UI.emailFieldId]
        let legacy = app.textFields["Email Address"]
        let emailPredicate = NSPredicate(format: "label CONTAINS[c] 'email' OR placeholderValue CONTAINS[c] 'email' OR identifier CONTAINS[c] 'email'")
        let anyEmail = app.textFields.matching(emailPredicate).firstMatch
        let legacyId = app.textFields[UI.legacyEmailFieldId]
        let first = app.textFields.firstMatch

        if isLegacyRun {
            if legacyId.waitForExistence(timeout: 2) { return legacyId }
            if legacy.waitForExistence(timeout: 2) { return legacy }
            if anyEmail.waitForExistence(timeout: 2) { return anyEmail }
            if first.waitForExistence(timeout: 2) { return first }
            if direct.waitForExistence(timeout: timeout) { return direct }
        } else {
            if direct.waitForExistence(timeout: timeout) { return direct }
            if legacy.waitForExistence(timeout: 2) { return legacy }
            if anyEmail.waitForExistence(timeout: 2) { return anyEmail }
            #if PERF_APP_LEGACY
            if legacyId.waitForExistence(timeout: 2) { return legacyId }
            if first.waitForExistence(timeout: 2) { return first }
            #endif
        }
        
        XCTFail("Login Failed: Email field not found.")
        return direct
    }
    
    private func findPasswordField(timeout: TimeInterval) -> XCUIElement {
        let direct = app.secureTextFields[UI.passwordFieldId]
        let legacy = app.secureTextFields["Password"]
        let passwordPredicate = NSPredicate(format: "label CONTAINS[c] 'password' OR placeholderValue CONTAINS[c] 'password' OR identifier CONTAINS[c] 'password'")
        let passwordTextField = app.textFields.matching(passwordPredicate).firstMatch
        let passwordSecureField = app.secureTextFields.matching(passwordPredicate).firstMatch
        let legacyPlain = app.textFields["Password"]
        let legacyId = app.textFields["TextFieldView-Password-UITextField"]
        let first = app.secureTextFields.firstMatch

        if isLegacyRun {
            if legacyPlain.waitForExistence(timeout: 2) { return legacyPlain }
            if legacyId.waitForExistence(timeout: 2) { return legacyId }
            if passwordTextField.waitForExistence(timeout: 2) { return passwordTextField }
            if passwordSecureField.waitForExistence(timeout: 2) { return passwordSecureField }
            if legacy.waitForExistence(timeout: 2) { return legacy }
            if first.waitForExistence(timeout: 2) { return first }
            if direct.waitForExistence(timeout: timeout) { return direct }
        } else {
            if direct.waitForExistence(timeout: timeout) { return direct }
            if legacy.waitForExistence(timeout: 2) { return legacy }
            #if PERF_APP_LEGACY
            if legacyPlain.waitForExistence(timeout: 2) { return legacyPlain }
            if legacyId.waitForExistence(timeout: 2) { return legacyId }
            if passwordTextField.waitForExistence(timeout: 2) { return passwordTextField }
            if passwordSecureField.waitForExistence(timeout: 2) { return passwordSecureField }
            if first.waitForExistence(timeout: 2) { return first }
            #endif
        }
        
        XCTFail("Login Failed: Password field not found.")
        return direct
    }

    private func legacyEmailField() -> XCUIElement {
        [
            app.textFields[UI.legacyEmailFieldId],
            app.textFields["Email Address"],
            app.textFields.matching(NSPredicate(format: "identifier CONTAINS[c] 'email' OR label CONTAINS[c] 'email'")).firstMatch,
            app.textFields.firstMatch,
        ].first(where: { $0.exists }) ?? app.textFields[UI.legacyEmailFieldId]
    }

    private func legacyPasswordField(timeout: TimeInterval) -> XCUIElement {
        [
            app.textFields["Password"],
            app.textFields["TextFieldView-Password-UITextField"],
            app.secureTextFields["Password"],
            app.secureTextFields.matching(NSPredicate(format: "identifier CONTAINS[c] 'password' OR label CONTAINS[c] 'password'")).firstMatch,
            app.textFields.matching(NSPredicate(format: "identifier CONTAINS[c] 'password' OR label CONTAINS[c] 'password'")).firstMatch,
            app.secureTextFields.firstMatch,
        ].first(where: { $0.exists }) ?? findPasswordField(timeout: timeout)
    }

    private func legacyLoginSubmitButton() -> XCUIElement {
        [
            app.buttons[UI.loginSubmit],
            app.buttons["Log In"],
            app.buttons["Log in"],
            app.navigationBars.buttons["Log In"],
            app.navigationBars.buttons["Log in"],
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'log in' OR identifier CONTAINS[c] 'login'")).firstMatch,
            app.descendants(matching: .button).matching(NSPredicate(format: "label CONTAINS[c] 'log in' OR identifier CONTAINS[c] 'login'")).firstMatch,
        ].first(where: { $0.exists }) ?? app.buttons[UI.loginSubmit]
    }
    
    private func dismissKeyboardIfPresent() {
        guard app.keyboards.firstMatch.exists else { return }
        if app.toolbars.buttons["Done"].exists {
            app.toolbars.buttons["Done"].tap()
        } else {
            if app.navigationBars["Log In"].exists {
                app.navigationBars["Log In"].tap()
            } else if app.navigationBars.firstMatch.exists && app.navigationBars.firstMatch.isHittable {
                app.navigationBars.firstMatch.tap()
            } else {
                // Avoid using Return here because password forms often submit on Return.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func advanceLoginKeyboardToPassword() -> Bool {
        guard app.keyboards.firstMatch.exists else { return false }

        for label in ["Next", "next"] {
            let button = app.keyboards.buttons[label]
            if button.exists {
                button.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                return true
            }
        }

        return false
    }

    @discardableResult
    private func dismissAppErrorAlertIfPresent() -> Bool {
        let errorPredicate = NSPredicate(
            format: "label CONTAINS[c] 'iheart.ihrautherror' OR label CONTAINS[c] 'operation couldn' OR label CONTAINS[c] 'something went wrong'"
        )

        for container in [app.alerts.matching(errorPredicate).firstMatch, app.sheets.matching(errorPredicate).firstMatch] {
            guard container.exists else { continue }
            for label in ["OK", "Close", "Done", "Cancel"] {
                let button = container.buttons[label]
                if button.exists {
                    button.forceTap()
                    return true
                }
            }
            let dismissButton = container.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'ok' OR label CONTAINS[c] 'close' OR label CONTAINS[c] 'cancel' OR identifier CONTAINS[c] 'ok' OR identifier CONTAINS[c] 'close'")
            ).firstMatch
            if dismissButton.exists {
                dismissButton.forceTap()
                return true
            }
        }

        return false
    }

    private func currentAppErrorMessage() -> String? {
        let errorPredicate = NSPredicate(
            format: "label CONTAINS[c] 'iheart.ihrautherror' OR label CONTAINS[c] 'operation couldn' OR label CONTAINS[c] 'something went wrong'"
        )

        let alert = app.alerts.matching(errorPredicate).firstMatch
        if alert.exists, !alert.label.isEmpty {
            return alert.label
        }

        let text = app.staticTexts.matching(errorPredicate).firstMatch
        if text.exists, !text.label.isEmpty {
            return text.label
        }

        return nil
    }

    @discardableResult
    private func dismissUnexpectedAuthPromptIfPresent() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancelLabels = ["Cancel", "Close", "Done", "Not Now", "Maybe Later", "Don’t Allow", "Don't Allow", "OK"]
        let promptPredicate = NSPredicate(
            format: "label CONTAINS[c] 'google.com' OR label CONTAINS[c] 'wants to use' OR label CONTAINS[c] 'appleid.apple.com' OR label CONTAINS[c] 'account.apple.com' OR label CONTAINS[c] 'sign in with google'"
        )

        let dismissPromptInContainer: (XCUIElement) -> Bool = { container in
            guard container.exists else { return false }
            for label in cancelLabels {
                let button = container.buttons[label]
                if button.exists {
                    button.forceTap()
                    return true
                }
            }
            let closeCandidate = container.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'cancel' OR label CONTAINS[c] 'close' OR identifier CONTAINS[c] 'cancel' OR identifier CONTAINS[c] 'close'")
            ).firstMatch
            if closeCandidate.exists {
                closeCandidate.forceTap()
                return true
            }
            return false
        }

        for application in [app, springboard] {
            let matchingAlert = application.alerts.firstMatch
            let matchingSheet = application.sheets.firstMatch
            let matchingText = application.staticTexts.matching(promptPredicate).firstMatch

            if dismissPromptInContainer(matchingAlert) { return true }
            if dismissPromptInContainer(matchingSheet) { return true }

            let hasExternalPrompt: Bool
            if application == springboard {
                hasExternalPrompt = matchingText.exists || application.webViews.firstMatch.exists
            } else {
                hasExternalPrompt = application.webViews.firstMatch.exists || matchingText.exists
            }
            guard hasExternalPrompt else { continue }

            for label in cancelLabels {
                let button = application.buttons[label]
                if button.exists {
                    button.forceTap()
                    return true
                }
            }
            let fallbackCancel = application.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'cancel' OR label CONTAINS[c] 'close' OR identifier CONTAINS[c] 'cancel' OR identifier CONTAINS[c] 'close'")
            ).firstMatch
            if fallbackCancel.exists {
                fallbackCancel.forceTap()
                return true
            }
        }
        return false
    }

    private func clearInterferingPrompts(reason: String, timeout: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        var dismissedAnything = false
        repeat {
            let dismissedPrompt = dismissUnexpectedAuthPromptIfPresent()
            let dismissedAppError = dismissAppErrorAlertIfPresent()
            let dismissedAd = dismissAdsIfPresent(reason: reason)
            guard dismissedPrompt || dismissedAppError || dismissedAd else { break }
            dismissedAnything = true
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        } while Date() < deadline

        if dismissedAnything {
            app.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private func findWelcomeLoginCandidate() -> XCUIElement? {
        let exactLogin = NSPredicate(format: "label ==[c] %@", UI.loginText)
        let viewport = app.windows.firstMatch.exists && !app.windows.firstMatch.frame.isEmpty
            ? app.windows.firstMatch.frame
            : app.frame

        let candidates = app.descendants(matching: .any).matching(exactLogin).allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .sorted { lhs, rhs in
                let lhsScore = (lhs.isHittable ? 1 : 0, lhs.frame.maxY)
                let rhsScore = (rhs.isHittable ? 1 : 0, rhs.frame.maxY)
                return lhsScore > rhsScore
            }

        if let lowerCandidate = candidates.first(where: { $0.frame.midY > viewport.midY }) {
            return lowerCandidate
        }
        return candidates.first
    }

    private func tapElementCenter(_ element: XCUIElement) {
        let frame = element.frame
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    private func returnToRootIfNeeded() {
        if app.tabBars.buttons[UI.homeTab].exists {
            selectTab(label: UI.homeTab, identifier: "homeTab")
        }
    }

    @discardableResult
    private func tapFirstExisting(_ candidates: [XCUIElement], context: String, failIfMissing: Bool = true) -> Bool {
        for candidate in candidates {
            if candidate.waitForExistence(timeout: 3) {
                candidate.forceTap()
                return true
            }
        }
        if failIfMissing {
            dumpAccessibilityTree(context)
            XCTFail("No tappable element found for \(context).")
        }
        return false
    }

    private func playbackIndicators() -> [XCUIElement] {
        let genericIndicators = [
            app.buttons["MiniPlayer-Stop-Button"],
            app.buttons["NowPlaying-Stop-Button"],
            app.buttons["ProfileHeaderView-Stop-Button"],
            app.buttons["MiniPlayer-Pause-Button"],
            app.buttons["NowPlaying-Pause-Button"],
            app.buttons["ProfileHeaderView-Pause-Button"],
            app.staticTexts["Now Playing"],
            app.otherElements["ProfileHeaderView"],
            app.otherElements["MiniPlayerView"],
            app.buttons["PlayerView-PlayButton-UIButton"],
            app.otherElements["PlayerView-ButtonContainer-UIView"],
        ]
        let legacyIndicators = [
            app.buttons["NewPlayButton-Pause-UIButton"],
            app.buttons["NewPlayButton-Stop-UIButton"],
            app.buttons["NewPlayButton-Play-UIButton"],
            app.buttons["PlayerView-PlayButton-UIButton"],
            app.buttons["MiniPlayerView-PlayButton-UIButton"],
        ]
        return isLegacyRun ? legacyIndicators + genericIndicators : genericIndicators + legacyIndicators
    }

    private func playbackStartedIndicators() -> [XCUIElement] {
        let genericIndicators = [
            app.buttons["MiniPlayer-Stop-Button"],
            app.buttons["NowPlaying-Stop-Button"],
            app.buttons["ProfileHeaderView-Stop-Button"],
            app.buttons["MiniPlayer-Pause-Button"],
            app.buttons["NowPlaying-Pause-Button"],
            app.buttons["ProfileHeaderView-Pause-Button"],
        ]
        let legacyIndicators = [
            app.buttons["NewPlayButton-Pause-UIButton"],
            app.buttons["NewPlayButton-Stop-UIButton"],
            app.buttons["NowPlaying-Pause-Button"],
            app.buttons["NowPlaying-Stop-Button"],
            app.buttons.matching(NSPredicate(format: "identifier ==[c] 'MiniPlayerView-PlayButton-UIButton' AND (label CONTAINS[c] 'pause' OR label CONTAINS[c] 'stop')")).firstMatch,
            app.buttons.matching(NSPredicate(format: "identifier ==[c] 'PlayerView-PlayButton-UIButton' AND (label CONTAINS[c] 'pause' OR label CONTAINS[c] 'stop')")).firstMatch,
            app.buttons.matching(NSPredicate(format: "identifier ==[c] 'NewPlayButton-Play-UIButton' AND (label CONTAINS[c] 'pause' OR label CONTAINS[c] 'stop')")).firstMatch,
        ]
        return isLegacyRun ? legacyIndicators + genericIndicators : genericIndicators + legacyIndicators
    }

    private func playbackProgressIndicators() -> [XCUIElement] {
        let genericProgressPredicate = NSPredicate(
            format: "identifier CONTAINS[c] 'ProgressBar' OR label CONTAINS[c] 'Playback position' OR label CONTAINS[c] 'Miniplayer: Playback position'"
        )
        return [
            app.otherElements["MiniPlayerView-ProgressBar-UIView"],
            app.otherElements.matching(genericProgressPredicate).firstMatch,
            app.progressIndicators.matching(genericProgressPredicate).firstMatch,
            app.sliders.matching(genericProgressPredicate).firstMatch,
        ]
    }

    private func currentPlaybackProgressSnapshot() -> String? {
        for indicator in playbackProgressIndicators() where indicator.exists && !indicator.frame.isEmpty {
            let value = (indicator.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
            let label = indicator.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                return label
            }
        }
        return nil
    }

    private func visiblePlaybackEntryControlSummary() -> String? {
        let candidateGroups: [(String, [XCUIElement])] = [
            ("listen button", [
                preferredLegacyListenButton(),
                app.buttons["Listen"],
                app.buttons.matching(NSPredicate(format: "label ==[c] 'Listen' OR identifier CONTAINS[c] 'listen'")).firstMatch,
            ].compactMap { $0 }),
            ("play button", [
                preferredLegacyPlayButton(),
                preferredPlayButton(),
                preferredPlaylistPlayButton(),
                app.buttons["Play"],
                app.buttons["Shuffle Play"],
                app.buttons["NewPlayButton-Play-UIButton"],
                app.buttons["PlayerView-PlayButton-UIButton"],
                app.buttons["MiniPlayer-Play-Button"],
                app.buttons["NowPlaying-Play-Button"],
                app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'play' OR label ==[c] 'Play' OR label CONTAINS[c] 'Play'")).firstMatch,
            ].compactMap { $0 }),
        ]

        for (kind, candidates) in candidateGroups {
            if let candidate = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                let identifier = candidate.identifier.isEmpty ? "<no-id>" : candidate.identifier
                let label = candidate.label.isEmpty ? "<no-label>" : candidate.label
                return "\(kind) still visible (\(identifier) / \(label))"
            }
        }
        return nil
    }

    private func waitForAnyPlaybackIndicator(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if playbackIndicators().contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func waitForPlaybackStarted(timeout: TimeInterval, baselineProgressSnapshot: String? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if playbackStartedIndicators().contains(where: { $0.exists }) {
                return true
            }
            let currentProgress = currentPlaybackProgressSnapshot()
            if baselineProgressSnapshot == nil, currentProgress != nil {
                return true
            }
            if let currentProgress, let baselineProgressSnapshot, currentProgress != baselineProgressSnapshot {
                return true
            }
            if currentAppErrorMessage() != nil || currentInlineAPIErrorMessage() != nil {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func stopExistingPlaybackIfNeeded(reason: String) {
        let stopCandidates = [
            app.buttons["MiniPlayer-Stop-Button"],
            app.buttons["NowPlaying-Stop-Button"],
            app.buttons["ProfileHeaderView-Stop-Button"],
            app.buttons["MiniPlayer-Pause-Button"],
            app.buttons["NowPlaying-Pause-Button"],
            app.buttons["ProfileHeaderView-Pause-Button"],
            app.buttons.matching(NSPredicate(format: "identifier ==[c] 'MiniPlayerView-PlayButton-UIButton' AND label CONTAINS[c] 'pause'")).firstMatch,
            app.buttons.matching(NSPredicate(format: "identifier ==[c] 'PlayerView-PlayButton-UIButton' AND label CONTAINS[c] 'pause'")).firstMatch,
            app.buttons.matching(NSPredicate(format: "identifier ==[c] 'NewPlayButton-Play-UIButton' AND label CONTAINS[c] 'pause'")).firstMatch,
        ]

        guard let active = stopCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) else {
            return
        }

        active.forceTap()
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if !playbackStartedIndicators().contains(where: { $0.exists }) {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        dismissAdsIfPresent(reason: reason)
    }

    private func preferredPlayButton() -> XCUIElement? {
        let playPredicate = NSPredicate(format: "identifier CONTAINS[c] 'Play' OR label CONTAINS[c] 'Play'")
        let buttons = app.buttons.matching(playPredicate).allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        guard !buttons.isEmpty else { return nil }

        return buttons.sorted {
            if $0.frame.maxX != $1.frame.maxX { return $0.frame.maxX > $1.frame.maxX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX > $1.frame.minX
        }.first
    }

    private func preferredPlaylistPlayButton() -> XCUIElement? {
        let playlistPredicate = NSPredicate(format: "identifier CONTAINS[c] 'shuffle' OR identifier CONTAINS[c] 'play' OR label ==[c] 'Shuffle Play' OR label ==[c] 'Play' OR label CONTAINS[c] 'Play'")
        let playlistScopedQueries = [
            app.buttons.matching(playlistPredicate),
            app.otherElements.matching(playlistPredicate),
            app.descendants(matching: .button).matching(playlistPredicate),
        ]

        for query in playlistScopedQueries {
            for candidate in visibleContentElements(query.allElementsBoundByIndex) {
                let identifier = candidate.identifier.lowercased()
                let label = candidate.label.lowercased()
                if identifier.contains("mini") || label.contains("mini") {
                    continue
                }
                if identifier.contains("add") || label.contains("add to playlist") || label.contains("save to playlist") {
                    continue
                }
                if identifier.contains("tab") || label == "home" || label == "radio" || label == "podcasts" || label == "playlists" || label == "search" {
                    continue
                }
                if identifier.contains("carouselcard") || identifier.contains("gridcard") {
                    continue
                }
                if !(identifier.contains("play") || identifier.contains("shuffle") || label.contains("play")) {
                    continue
                }
                return candidate
            }
        }
        return nil
    }

    private func isValidPlaylistCardTarget(_ element: XCUIElement) -> Bool {
        let identifier = element.identifier.lowercased()
        let label = element.label.lowercased()
        let value = (element.value as? String ?? "").lowercased()
        let strings = [identifier, label, value].joined(separator: " ")

        if strings.contains("add to playlist")
            || strings.contains("save to playlist")
            || strings.contains("create playlist")
            || strings.contains("playlist settings")
            || strings.contains("more options")
            || strings.contains("overflow")
            || strings.contains("share")
            || strings.contains("follow") {
            return false
        }

        if isLegacyRun {
            if identifier.contains("cuifeaturedcardlistcell")
                || identifier.contains("cuicardlistcell")
                || identifier.contains("cuiimagetitlesubtitletilecell") {
                return true
            }

            if (strings.contains("playlist") || strings.contains("mix"))
                && (identifier.contains("card") || identifier.contains("cell")) {
                return true
            }
        }

        if identifier.contains("carouselcard")
            || identifier.contains("gridcard")
            || identifier.contains("featuredplaylistsection")
            || identifier.contains("moodsandactivitiessection")
            || identifier.contains("decadessection")
            || identifier.contains("playlistgenresgrid") {
            return true
        }

        return false
    }

    private func preferredLegacyImageLoadingTarget(query: String) -> XCUIElement? {
        let queryPredicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@", query, query, query)
        let legacyResultPredicate = NSPredicate(format: "identifier CONTAINS[c] 'CUIListCell' OR identifier CONTAINS[c] 'playlist' OR label CONTAINS[c] 'playlist' OR value CONTAINS[c] %@ OR label CONTAINS[c] %@", query, query)
        let queries = [
            app.collectionViews.firstMatch.descendants(matching: .button).matching(legacyResultPredicate),
            app.buttons.matching(legacyResultPredicate),
            app.collectionViews.firstMatch.cells.matching(queryPredicate),
            app.buttons.matching(queryPredicate),
        ]

        for query in queries {
            for candidate in visibleContentElements(query.allElementsBoundByIndex) {
                let strings = [candidate.identifier, candidate.label, candidate.value as? String ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                if strings.contains("playlist") || strings.contains("version") || strings.contains("taylor swift") {
                    return candidate
                }
            }
        }

        return nil
    }

    private func visibleMediaArtworkImage(minimumSize: CGFloat = 36) -> XCUIElement? {
        let viewport = contentViewportBounds()
        let candidates = app.images.allElementsBoundByIndex

        for image in candidates {
            guard image.exists else { continue }
            let frame = image.frame
            guard !frame.isEmpty else { continue }
            guard frame.width >= minimumSize && frame.height >= minimumSize else { continue }
            guard frame.intersects(viewport) else { continue }
            guard boundsContainsMidpoint(viewport, frame: frame) else { continue }

            let strings = [image.identifier, image.label, image.value as? String ?? ""]
                .joined(separator: " ")
                .lowercased()
            if strings.contains("tab_")
                || strings.contains("logo")
                || strings.contains("search")
                || strings.contains("settings")
                || strings.contains("notifications")
                || strings.contains("scroll bar") {
                continue
            }

            return image
        }

        return nil
    }

    private func startPlaybackIfNeeded(context: String) {
        if playbackStartedIndicators().contains(where: { $0.exists }) { return }

        var playCandidates: [XCUIElement] = []
        if isLegacyRun {
            if let listen = preferredLegacyListenButton() {
                playCandidates.append(listen)
            }
            if let play = preferredLegacyPlayButton() {
                playCandidates.append(play)
            }
            playCandidates.append(contentsOf: [
                app.buttons["Listen"],
                app.buttons.matching(NSPredicate(format: "label ==[c] 'Listen' OR identifier CONTAINS[c] 'listen'")).firstMatch,
                app.buttons["NewPlayButton-Play-UIButton"],
                app.buttons["SpotlightCell-Play-UIButton"],
                app.buttons["PlayerView-PlayButton-UIButton"],
                app.buttons["ProfileHeaderView-Play-Button"],
                app.buttons["NowPlaying-Play-Button"],
                app.buttons["MiniPlayer-Play-Button"],
                app.buttons["Play"],
                app.buttons["Shuffle Play"],
                app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'play' OR label ==[c] 'Play' OR label CONTAINS[c] 'Play'")).firstMatch,
                app.cells.buttons.firstMatch,
            ])
        } else {
            if context.localizedCaseInsensitiveContains("playlist"),
               let playlistPreferred = preferredPlaylistPlayButton() {
                playCandidates.append(playlistPreferred)
            }
            if let preferred = preferredPlayButton() {
                playCandidates.append(preferred)
            }
            playCandidates.append(contentsOf: [
                app.buttons["ProfileHeaderView-Play-Button"],
                app.buttons["NowPlaying-Play-Button"],
                app.buttons["MiniPlayer-Play-Button"],
                app.buttons["Play"],
                app.buttons["Shuffle Play"],
                app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'play' OR label ==[c] 'Play' OR label CONTAINS[c] 'Play'")).firstMatch,
            ])
        }
        _ = tapFirstExisting(playCandidates, context: context, failIfMissing: false)
    }

    private func assertPlaybackStarted(context: String) {
        let timeout: TimeInterval = isLegacyRun ? 16 : 10
        let baselineProgressSnapshot = currentPlaybackProgressSnapshot()
        startPlaybackIfNeeded(context: context)
        if waitForPlaybackStarted(timeout: timeout, baselineProgressSnapshot: baselineProgressSnapshot) {
            return
        }
        var failureParts: [String] = []
        if let appError = currentAppErrorMessage() {
            failureParts.append("App error visible: \(appError)")
        }
        if let inlineError = currentInlineAPIErrorMessage() {
            failureParts.append("Inline error visible: \(inlineError)")
        }
        if let progressSnapshot = currentPlaybackProgressSnapshot() {
            if let baselineProgressSnapshot, baselineProgressSnapshot == progressSnapshot {
                failureParts.append("Playback progress remained at '\(progressSnapshot)'")
            } else {
                failureParts.append("Playback surface visible with progress '\(progressSnapshot)'")
            }
        }
        if let controlSummary = visiblePlaybackEntryControlSummary() {
            failureParts.append(controlSummary)
        }
        dumpAccessibilityTree(context)
        if failureParts.isEmpty {
            XCTFail("Playback did not start.")
        } else {
            XCTFail("Playback did not start. " + failureParts.joined(separator: ". "))
        }
    }

    @discardableResult
    private func dismissAdsIfPresent(reason: String) -> Bool {
        // Common ad containers / banners
        let adPredicate = NSPredicate(format: "label CONTAINS[c] 'Advertisement' OR identifier CONTAINS[c] 'AdBanner' OR identifier CONTAINS[c] 'Ad' OR identifier CONTAINS[c] 'homeAdBanner' OR identifier CONTAINS[c] 'RadioTabView-AdBanner' OR label CONTAINS[c] 'Sponsored'")
        let adContainer = app.descendants(matching: .any).matching(adPredicate).firstMatch
        
        // Common close buttons
        let closePredicate = NSPredicate(format: "label IN {'Close','Dismiss','Done'} OR label CONTAINS[c] 'close' OR label == 'X' OR identifier CONTAINS[c] 'close' OR identifier CONTAINS[c] 'dismiss'")
        let closeButton = app.buttons.matching(closePredicate).firstMatch
        
        if closeButton.exists && closeButton.isHittable {
            closeButton.tap()
            return true
        }
        
        if adContainer.exists {
            // Try to close within ad container if possible
            let nestedClose = adContainer.descendants(matching: .button).matching(closePredicate).firstMatch
            if nestedClose.exists && nestedClose.isHittable {
                nestedClose.tap()
                return true
            }
        }
        return false
    }

    private func isAdPresent() -> Bool {
        let adPredicate = NSPredicate(format: "label CONTAINS[c] 'Advertisement' OR identifier CONTAINS[c] 'AdBanner' OR identifier CONTAINS[c] 'Ad' OR label CONTAINS[c] 'Sponsored' OR label CONTAINS[c] 'Learn More' OR label CONTAINS[c] 'will continue'")
        if app.descendants(matching: .any).matching(adPredicate).firstMatch.exists { return true }
        return false
    }

    private func bypassIfAdPresent(reason: String) -> Bool {
        guard isAdPresent() else { return false }

        let behavior = (ProcessInfo.processInfo.environment[Env.adBehavior] ?? "bypass").lowercased()
        if behavior == "fail" {
            XCTFail("Ad detected (\(reason)) and PERF_AD_BEHAVIOR=fail")
            return false
        }

        print("LOG: Ad detected (\(reason)). Marking test step as passed.")
        return true
    }
}

// MARK: - FORCE TAP EXTENSION
extension XCUIElement {
    private func perfTargetApplication() -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let bundleId = PerfTestConfig.resolveBundleId(from: env)
        return XCUIApplication(bundleIdentifier: bundleId)
    }

    func forceTap() {
        guard self.exists else { return }

        let frame = self.frame
        if !frame.isEmpty && frame.width > 1 && frame.height > 1 {
            let app = perfTargetApplication()
            let appFrame = app.frame
            if !appFrame.isEmpty && appFrame.intersects(frame) {
                let x = min(max(frame.midX, appFrame.minX + 1), appFrame.maxX - 1)
                let y = min(max(frame.midY, appFrame.minY + 1), appFrame.maxY - 1)
                let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                origin.withOffset(CGVector(dx: x, dy: y)).tap()
                return
            }
        }

        let coordinate: XCUICoordinate = self.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coordinate.tap()
    }
    
    func clearAndType(_ text: String) {
        self.forceTap()
        if let value = self.value as? String, !value.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            self.typeText(deleteString)
        }
        self.typeText(text)
    }
}
