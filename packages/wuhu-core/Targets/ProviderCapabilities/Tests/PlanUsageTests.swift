import JSONValue
import ProviderCapabilities
import struct SpaceContract.UsageWindow
import Testing

struct PlanUsageTests {
  // Codex sends both header families even on a plan with one window; the
  // empty family is zero minutes long.
  @Test func codexResponseHeadersBecomeWindowsNamedByLength() {
    #expect(PlanUsage.codex(headers: [
      "x-codex-plan-type": "pro",
      "x-codex-primary-used-percent": "9",
      "x-codex-primary-window-minutes": "10080",
      "x-codex-primary-reset-at": "1790728625",
      "x-codex-secondary-used-percent": "0",
      "x-codex-secondary-window-minutes": "0",
    ]) == [UsageWindow(name: "seven_day", usedPercent: 9, resetsAt: 1_790_728_625, windowMinutes: 10080)])
    #expect(PlanUsage.codex(headers: [
      "x-codex-primary-used-percent": "12.5",
      "x-codex-primary-window-minutes": "300",
      "x-codex-primary-reset-at": "1800000300",
      "x-codex-secondary-used-percent": "34",
      "x-codex-secondary-window-minutes": "10080",
      "x-codex-secondary-reset-at": "1800600000",
    ]) == [
      UsageWindow(name: "five_hour", usedPercent: 12.5, resetsAt: 1_800_000_300, windowMinutes: 300),
      UsageWindow(name: "seven_day", usedPercent: 34, resetsAt: 1_800_600_000, windowMinutes: 10080),
    ])
    #expect(PlanUsage.codex(headers: ["content-type": "text/event-stream"]).isEmpty)
  }

  @Test func codexSocketQuotaUsesItsOwnSchemaAndRejectsMalformedWindows() throws {
    let valid = try #require(JSONValue.parse(#"{"type":"codex.rate_limits","plan_type":"pro","rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"reset_at":1800000300},"secondary":{"used_percent":34,"window_minutes":10080,"reset_at":1800600000}}}"#))
    let result = PlanUsage.codexSocket(valid)
    #expect(result.plan == "pro")
    #expect(result.windows == [UsageWindow(name: "five_hour", usedPercent: 12.5, resetsAt: 1_800_000_300, windowMinutes: 300), UsageWindow(name: "seven_day", usedPercent: 34, resetsAt: 1_800_600_000, windowMinutes: 10080)])
    for text in [#"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":300,"reset_at":1800000300}}}"#, #"{"rate_limits":{"primary":{"used_percent":12,"window_minutes":0,"reset_at":1800000300}}}"#, #"{"rate_limits":{"primary":{"used_percent":101,"window_minutes":300,"reset_at":1800000300}}}"#, #"{"rate_limits":{"primary":{"used_percent":12,"window_minutes":300}}}"#] {
      #expect(PlanUsage.codexSocket(try #require(JSONValue.parse(text))).windows.isEmpty)
    }
  }

  @Test func aGatewayWindowNeverReportedHasNoReset() throws {
    let unreported = try #require(JSONValue.parse(#"{"rate_limits":{"windows":{"seven_day":{"used_percent":0,"window_minutes":10080,"reset_at":0}}}}"#))
    #expect(PlanUsage.codexSocket(unreported).windows == [UsageWindow(name: "seven_day", usedPercent: 0, resetsAt: nil, windowMinutes: 10080)])
  }

  @Test func theCodexUsageReadBecomesWindows() throws {
    let payload = try #require(JSONValue.parse("""
    {"plan_type":"pro","rate_limit":{"allowed":true,"primary_window":{"used_percent":61,"limit_window_seconds":604800,
    "reset_after_seconds":135000,"reset_at":1790314546},"secondary_window":null}}
    """))
    let (plan, windows) = PlanUsage.codex(payload: payload)
    #expect(plan == "pro")
    #expect(windows == [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_790_314_546, windowMinutes: 10080)])
  }
}
