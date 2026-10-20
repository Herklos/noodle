import XCTest
@testable import NoodleCore

final class SubscriptionUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Codex

    /// The shape of codex app-server's GetAccountRateLimitsResponse (`codex app-server generate-json-schema`).
    func testCodexReadPrefersTheCodexBucketAndKeepsBothWindows() throws {
        let result: [String: Any] = [
            "rateLimits": ["limitId": "other", "primary": ["usedPercent": 99, "windowDurationMins": 60, "resetsAt": 1_800_000_600]],
            "rateLimitsByLimitId": ["codex": [
                "limitId": "codex", "planType": "plus",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_008_040],
                "secondary": ["usedPercent": 7, "windowDurationMins": 10_080, "resetsAt": 1_800_400_000],
                "credits": ["hasCredits": false, "unlimited": false]
            ]]
        ]
        let usage = try XCTUnwrap(SubscriptionUsage.codexRead(result, at: now))
        XCTAssertEqual(usage.updatedAt, now)
        XCTAssertEqual(usage.windows, [
            SubscriptionUsageWindow(id: "primary", minutes: 300, usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_800_008_040)),
            SubscriptionUsageWindow(id: "secondary", minutes: 10_080, usedPercent: 7, resetsAt: Date(timeIntervalSince1970: 1_800_400_000))
        ])
    }

    func testCodexReadFallsBackToTheSingleBucketAndSkipsWindowsWithoutAShare() throws {
        let result: [String: Any] = ["rateLimits": [
            "primary": ["usedPercent": 3, "windowDurationMins": 300, "resetsAt": NSNull()],
            "secondary": ["windowDurationMins": 10_080, "resetsAt": 1_800_400_000]
        ]]
        let usage = try XCTUnwrap(SubscriptionUsage.codexRead(result, at: now))
        XCTAssertEqual(usage.windows, [SubscriptionUsageWindow(id: "primary", minutes: 300, usedPercent: 3, resetsAt: nil)])
        XCTAssertNil(SubscriptionUsage.codexRead(["rateLimits": ["primary": NSNull(), "secondary": NSNull()]], at: now))
        XCTAssertNil(SubscriptionUsage.codexRead([:], at: now))
    }

    func testCodexUpdatesForOtherBucketsAreIgnored() {
        func update(_ limitID: Any) -> [String: Any] {
            ["method": "account/rateLimits/updated", "params": ["rateLimits": [
                "limitId": limitID, "primary": ["usedPercent": 50, "windowDurationMins": 300, "resetsAt": 1_800_001_000]]]]
        }
        XCTAssertTrue(SubscriptionUsage.isReport(update("codex"), provider: .codex))
        XCTAssertEqual(SubscriptionUsage.reading(update("codex"), provider: .codex, previous: nil, at: now)?.windows.first?.usedPercent, 50)
        XCTAssertEqual(SubscriptionUsage.reading(update(NSNull()), provider: .codex, previous: nil, at: now)?.windows.count, 1)
        XCTAssertNil(SubscriptionUsage.reading(update("codex_other_model"), provider: .codex, previous: nil, at: now))
        XCTAssertNil(SubscriptionUsage.reading(["method": "thread/tokenUsage/updated", "params": [:]], provider: .codex, previous: nil, at: now))
    }

    // MARK: - Claude Code

    /// The shape of Claude Code's stream-json `rate_limit_event`.
    func testClaudeEventsMergeEachReportedWindow() throws {
        let session: [String: Any] = ["type": "rate_limit_event", "session_id": "s", "uuid": "u", "rate_limit_info": [
            "status": "allowed", "rateLimitType": "five_hour", "utilization": 0.25, "resetsAt": 1_800_003_600, "isUsingOverage": false]]
        let first = try XCTUnwrap(SubscriptionUsage.reading(session, provider: .claudeCode, previous: nil, at: now))
        XCTAssertEqual(first.windows, [SubscriptionUsageWindow(id: "five_hour", minutes: 300, usedPercent: 25,
                                                               resetsAt: Date(timeIntervalSince1970: 1_800_003_600))])

        let weekly: [String: Any] = ["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed_warning", "rateLimitType": "seven_day_opus", "utilization": 0.8, "resetsAt": 1_800_300_000]]
        let later = now.addingTimeInterval(60)
        let second = try XCTUnwrap(SubscriptionUsage.reading(weekly, provider: .claudeCode, previous: first, at: later))
        XCTAssertEqual(second.updatedAt, later)
        XCTAssertEqual(second.windows.map(\.id), ["five_hour", "seven_day_opus"])
        XCTAssertEqual(second.windows.last?.model, "Opus")
        XCTAssertEqual(try XCTUnwrap(second.windows.last?.usedPercent), 80, accuracy: 0.001)
    }

    func testClaudeUnifiedWindowsCarryBothWindows() throws {
        let event: [String: Any] = ["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed", "rateLimitType": "five_hour", "utilization": 0.5, "resetsAt": 1_800_003_600,
            "unifiedWindows": ["five_hour": ["utilization": 0.5, "resetsAt": 1_800_003_600],
                               "seven_day": ["utilization": 0.125, "resetsAt": 1_800_200_000],
                               "seven_day_overage_included": ["utilization": 0.9, "resetsAt": 1_800_200_000]]]]
        let usage = try XCTUnwrap(SubscriptionUsage.reading(event, provider: .claudeCode, previous: nil, at: now))
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [50, 12.5])
    }

    func testClaudeEventWithoutUtilizationKeepsTheLastShareOnlyForTheSameWindow() throws {
        let resets = Date(timeIntervalSince1970: 1_800_003_600)
        let previous = SubscriptionUsage(windows: [SubscriptionUsageWindow(id: "five_hour", minutes: 300, usedPercent: 60, resetsAt: resets)],
                                         updatedAt: now)
        func event(_ reset: Int) -> [String: Any] {
            ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "resetsAt": reset]]
        }
        XCTAssertEqual(SubscriptionUsage.reading(event(1_800_003_600), provider: .claudeCode, previous: previous, at: now)?
            .windows.first?.usedPercent, 60)
        let next = try XCTUnwrap(SubscriptionUsage.reading(event(1_800_021_600), provider: .claudeCode, previous: previous, at: now))
        XCTAssertNil(next.windows.first?.usedPercent)
        XCTAssertEqual(next.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_021_600))
    }

    func testClaudeMessagesWithoutAKnownWindowChangeNothing() {
        for message: [String: Any] in [
            ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed"]],
            ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "rateLimitType": "overage", "utilization": 0.1]],
            ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "rateLimitType": "five_hour", "utilization": true]],
            ["type": "result", "rate_limit_info": ["rateLimitType": "five_hour", "utilization": 0.1]]
        ] {
            XCTAssertNil(SubscriptionUsage.reading(message, provider: .claudeCode, previous: nil, at: now))
        }
        XCTAssertFalse(SubscriptionUsage.isReport(["type": "result"], provider: .claudeCode))
    }

    /// The other harnesses report no plan limits, so nothing is ever made up for them.
    func testOtherHarnessesHaveNoReadings() {
        let message: [String: Any] = ["type": "rate_limit_event", "method": "account/rateLimits/updated",
                                      "rate_limit_info": ["rateLimitType": "five_hour", "utilization": 0.1],
                                      "params": ["rateLimits": ["primary": ["usedPercent": 1]]]]
        for provider in HarnessProvider.allCases where provider != .codex && provider != .claudeCode {
            XCTAssertFalse(SubscriptionUsage.isReport(message, provider: provider))
            XCTAssertNil(SubscriptionUsage.reading(message, provider: provider, previous: nil, at: now))
        }
    }

    // MARK: - Settings text

    func testWindowsThatHaveResetAreNoLongerShown() {
        let usage = SubscriptionUsage(windows: [
            SubscriptionUsageWindow(id: "secondary", minutes: 10_080, usedPercent: 10, resetsAt: now.addingTimeInterval(86_400)),
            SubscriptionUsageWindow(id: "primary", minutes: 300, usedPercent: 90, resetsAt: now.addingTimeInterval(-1)),
            SubscriptionUsageWindow(id: "other", minutes: nil, usedPercent: 5, resetsAt: nil)
        ], updatedAt: now)
        XCTAssertEqual(usage.windows.map(\.id), ["primary", "secondary", "other"])
        XCTAssertEqual(usage.current(at: now).map(\.id), ["secondary", "other"])
    }

    func testTitles() {
        func title(_ minutes: Int?, _ model: String? = nil) -> String {
            SubscriptionUsageFormat.title(SubscriptionUsageWindow(id: "w", minutes: minutes, model: model, usedPercent: nil, resetsAt: nil))
        }
        XCTAssertEqual(title(300), "5-hour limit")
        XCTAssertEqual(title(10_080), "Weekly limit")
        XCTAssertEqual(title(10_080, "Opus"), "Weekly limit · Opus")
        XCTAssertEqual(title(1_440), "Daily limit")
        XCTAssertEqual(title(43_200), "30-day limit")
        XCTAssertEqual(title(90), "90-minute limit")
        XCTAssertEqual(title(nil), "Limit")
    }

    func testShareAndResetText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        func detail(_ percent: Double?, in seconds: TimeInterval?) -> String {
            SubscriptionUsageFormat.detail(SubscriptionUsageWindow(id: "w", minutes: 300, usedPercent: percent,
                resetsAt: seconds.map(now.addingTimeInterval)), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(detail(41.6, in: 2 * 3_600 + 14 * 60), "42% used · Resets in 2 h 14 min")
        XCTAssertEqual(detail(0, in: 3 * 3_600), "0% used · Resets in 3 h")
        XCTAssertEqual(detail(100, in: 20), "100% used · Resets in 1 min")
        XCTAssertEqual(detail(12, in: 59 * 60), "12% used · Resets in 59 min")
        // 2027-01-15 08:00 UTC is a Friday; three days on is Monday at 08:00.
        XCTAssertEqual(detail(5, in: 3 * 86_400), "5% used · Resets Mon 08:00")
        XCTAssertEqual(detail(nil, in: 600), "Not available · Resets in 10 min")
        XCTAssertEqual(detail(nil, in: nil), "Not available")
        XCTAssertEqual(detail(7, in: -60), "7% used")
    }

    func testBarFractionIsClampedAndAbsentWhenNotReported() {
        func fraction(_ percent: Double?) -> Double? {
            SubscriptionUsageFormat.fraction(SubscriptionUsageWindow(id: "w", minutes: nil, usedPercent: percent, resetsAt: nil))
        }
        XCTAssertEqual(fraction(42), 0.42)
        XCTAssertEqual(fraction(130), 1)
        XCTAssertEqual(fraction(-3), 0)
        XCTAssertNil(fraction(nil))
    }
}

/// Opening Settings checks each Codex login; for a signed-in one the same short
/// app-server connection asks for its plan limits.
final class CodexUsageReadTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// `limits` is the reply to account/rateLimits/read; requests are logged so the test sees what was asked.
    private func fakeCodex(signedIn: Bool = true, limits: String) throws -> URL {
        let executable = root.appendingPathComponent("fake-codex")
        let log = root.appendingPathComponent("requests.log")
        let account = signedIn ? #"{"type":"chatgpt"}"# : "null"
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\n' "$line" >> '\#(log.path)'
          case "$line" in
            *rateLimits*read*) printf '%s\n' '\#(limits)' ;;
            *account*read*) printf '%s\n' '{"id":2,"result":{"account":\#(account),"requiresOpenaiAuth":true}}' ;;
            *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func requests() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
            .split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    @MainActor func testSignedInCheckReadsPlanLimits() async throws {
        let executable = try fakeCodex(limits: #"{"id":5,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1800008040},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1800400000}}}}"#)
        let provider = CodexSetupProvider(codexHome: root)
        var readings: [SubscriptionUsage] = []
        provider.onUsage = { readings.append($0) }
        let status = try await provider.status(for: HarnessInstallation(provider: .codex, executablePath: executable.path))
        XCTAssertEqual(status, .authenticated)
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.windows.map(\.usedPercent), [42, 7])
        XCTAssertEqual(readings.first?.windows.map(\.minutes), [300, 10_080])
        // Older Codex takes no parameters for this request.
        let read = try XCTUnwrap(try requests().first { $0["method"] as? String == "account/rateLimits/read" })
        XCTAssertNil(read["params"])
    }

    @MainActor func testUnreadablePlanLimitsLeaveTheSignInStatus() async throws {
        let executable = try fakeCodex(limits: #"{"id":5,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}"#)
        let provider = CodexSetupProvider(codexHome: root)
        var readings: [SubscriptionUsage] = []
        provider.onUsage = { readings.append($0) }
        let status = try await provider.status(for: HarnessInstallation(provider: .codex, executablePath: executable.path))
        XCTAssertEqual(status, .authenticated)
        XCTAssertTrue(readings.isEmpty)
    }

    @MainActor func testSignedOutOrUnaskedChecksDoNotReadPlanLimits() async throws {
        let limits = #"{"id":5,"result":{"rateLimits":{"primary":{"usedPercent":1}}}}"#
        let signedOut = try fakeCodex(signedIn: false, limits: limits)
        let provider = CodexSetupProvider(codexHome: root)
        var readings: [SubscriptionUsage] = []
        provider.onUsage = { readings.append($0) }
        let status = try await provider.status(for: HarnessInstallation(provider: .codex, executablePath: signedOut.path))
        XCTAssertEqual(status, .unauthenticated)
        XCTAssertFalse(try requests().contains { $0["method"] as? String == "account/rateLimits/read" })

        try FileManager.default.removeItem(at: root.appendingPathComponent("requests.log"))
        let signedIn = try fakeCodex(limits: limits)
        let quiet = CodexSetupProvider(codexHome: root)
        let quietStatus = try await quiet.status(for: HarnessInstallation(provider: .codex, executablePath: signedIn.path))
        XCTAssertEqual(quietStatus, .authenticated)
        XCTAssertFalse(try requests().contains { $0["method"] as? String == "account/rateLimits/read" })
        XCTAssertTrue(readings.isEmpty)
    }
}
