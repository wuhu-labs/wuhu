import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import JSONValue
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private func providers(_ harness: SessionHarness) async throws -> [ProviderDescriptor] {
  try JSONValueDecoder().decode(
    ProvidersOutput.self,
    from: try await json(try await harness.get("/v1/providers")),
  ).providers
}

private let codexAndClaudeModels = """
{
  "chatgpt": {
    "dialect": "codex",
    "baseURL": "https://chatgpt.com/backend-api/codex",
    "models": {"gpt": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "claude": {
    "dialect": "claude",
    "baseURL": "https://api.anthropic.com",
    "models": {"opus": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "testing": {
    "dialect": "anthropic",
    "baseURL": "http://localhost:1",
    "models": {"test-model": {"maxInput": 1000, "maxOutput": 100, "efforts": ["low"], "defaultEffort": "low"}}
  }
}
"""

@Suite struct ProviderUsageTests {
  @Test func everyProviderListsItsModelsAndNoUsageUntilObserved() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      #expect(try await providers(harness) == [ProviderDescriptor(
        id: "testing",
        dialect: "anthropic",
        models: [ProviderModel(id: "test-model", effortLevels: ["low", "high"], defaultEffort: "high")],
        usage: nil,
      )])
    }
  }

  @Test func observedUsageRidesTheProviderListing() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let at = Date(timeIntervalSince1970: 1_800_000_000)
      harness.runtime.usage.record(
        "testing", plan: "pro",
        windows: [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_800_100_000)], at: at,
      )
      #expect(try await providers(harness).first?.usage == ProviderUsage(
        plan: "pro",
        windows: [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_800_100_000)],
        observedAt: 1_800_000_000,
      ))
    }
  }

  // Codex sends both header families even on a plan with one window; the
  // empty family is zero minutes long.
  @Test func codexResponseHeadersBecomeWindowsNamedByLength() {
    #expect(codexUsage(headers: [
      "x-codex-plan-type": "pro",
      "x-codex-primary-used-percent": "9",
      "x-codex-primary-window-minutes": "10080",
      "x-codex-primary-reset-at": "1790728625",
      "x-codex-secondary-used-percent": "0",
      "x-codex-secondary-window-minutes": "0",
    ]) == [UsageWindow(name: "seven_day", usedPercent: 9, resetsAt: 1_790_728_625)])
    #expect(codexUsage(headers: [
      "x-codex-primary-used-percent": "12.5",
      "x-codex-primary-window-minutes": "300",
      "x-codex-primary-reset-at": "1800000300",
      "x-codex-secondary-used-percent": "34",
      "x-codex-secondary-window-minutes": "10080",
      "x-codex-secondary-reset-at": "1800600000",
    ]) == [
      UsageWindow(name: "five_hour", usedPercent: 12.5, resetsAt: 1_800_000_300),
      UsageWindow(name: "seven_day", usedPercent: 34, resetsAt: 1_800_600_000),
    ])
    #expect(codexUsage(headers: ["content-type": "text/event-stream"]).isEmpty)
  }

  @Test func codexSocketQuotaUsesItsOwnSchemaAndRejectsMalformedWindows() throws {
    let valid = try #require(JSONValue.parse(#"{"type":"codex.rate_limits","plan_type":"pro","rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"reset_at":1800000300},"secondary":{"used_percent":34,"window_minutes":10080,"reset_at":1800600000}}}"#))
    let result = codexSocketUsage(valid)
    #expect(result.plan == "pro")
    #expect(result.windows == [UsageWindow(name: "five_hour", usedPercent: 12.5, resetsAt: 1_800_000_300), UsageWindow(name: "seven_day", usedPercent: 34, resetsAt: 1_800_600_000)])
    for text in [#"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":300,"reset_at":1800000300}}}"#, #"{"rate_limits":{"primary":{"used_percent":12,"window_minutes":0,"reset_at":1800000300}}}"#, #"{"rate_limits":{"primary":{"used_percent":101,"window_minutes":300,"reset_at":1800000300}}}"#, #"{"rate_limits":{"primary":{"used_percent":12,"window_minutes":300}}}"#] {
      #expect(codexSocketUsage(try #require(JSONValue.parse(text))).windows.isEmpty)
    }
  }

  @Test func theCodexUsageReadBecomesWindows() throws {
    let payload = try #require(JSONValue.parse("""
    {"plan_type":"pro","rate_limit":{"allowed":true,"primary_window":{"used_percent":61,"limit_window_seconds":604800,
    "reset_after_seconds":135000,"reset_at":1790314546},"secondary_window":null}}
    """))
    let (plan, windows) = codexUsage(payload: payload)
    #expect(plan == "pro")
    #expect(windows == [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_790_314_546)])
  }

  @Test func windowsMergeByNameAndAPlanSurvivesAReportWithoutOne() {
    let board = UsageBoard()
    let early = Date(timeIntervalSince1970: 100)
    board.record("claude", plan: "max", windows: [
      UsageWindow(name: "five_hour", usedPercent: 10, resetsAt: 1),
      UsageWindow(name: "seven_day", usedPercent: 50, resetsAt: 2),
    ], at: early)
    board.record("claude", plan: nil, windows: [UsageWindow(name: "five_hour", usedPercent: 12, resetsAt: 1)], at: early + 60)
    #expect(board.usage("claude") == ProviderUsage(
      plan: "max",
      windows: [
        UsageWindow(name: "five_hour", usedPercent: 12, resetsAt: 1),
        UsageWindow(name: "seven_day", usedPercent: 50, resetsAt: 2),
      ],
      observedAt: 160,
    ))
    board.record("claude", plan: nil, windows: [], at: early + 120)
    #expect(board.usage("claude")?.observedAt == 160, "an empty report observes nothing")
  }

  @Test func aRefreshIsClaimedOnlyAfterTheIntervalSinceTheLastObservationOrAttempt() {
    let board = UsageBoard()
    let start = Date(timeIntervalSince1970: 10000)
    #expect(board.claimRefresh("codex", now: start, interval: 900))
    #expect(!board.claimRefresh("codex", now: start + 60, interval: 900), "a failed attempt is not retried at once")
    #expect(board.usage("codex") == nil, "an attempt observes nothing")
    board.record("codex", plan: nil, windows: [UsageWindow(name: "seven_day", usedPercent: 1, resetsAt: nil)], at: start + 800)
    #expect(!board.claimRefresh("codex", now: start + 1000, interval: 900))
    #expect(board.claimRefresh("codex", now: start + 1700, interval: 900))
  }

  @Test func theRefresherReadsOnlyCodexWhenStale() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/models.json", Data(codexAndClaudeModels.utf8), ifMatch: nil)
      let board = UsageBoard()
      let resolved = Mutex<[String]>([])
      let seen = Mutex<[URLRequestSummary]>([])
      let refresher = UsageRefresher(board: board, space: space, credentials: CredentialResolver { provider in
        resolved.withLock { $0.append(provider) }
        #expect(provider == "chatgpt", "Claude must not be probed")
        return provider == "chatgpt" ? .chatGPT(accessToken: "jwt", accountID: "acct-42") : nil
      })
      await withDependencies {
        $0.fetch = FetchClient { request in
          seen.withLock {
            $0.append(URLRequestSummary(
              url: request.url.absoluteString,
              account: request.headers.sensitiveValues["chatgpt-account-id"],
              authorization: request.headers.sensitiveValues["authorization"],
            ))
          }
          return Response(status: .ok, body: .string(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":1790314546},"secondary_window":null}}"#))
        }
      } operation: {
        await refresher.refreshStale()
        await refresher.refreshStale()
      }
      #expect(seen.withLock { $0 } == [URLRequestSummary(url: "https://chatgpt.com/backend-api/wham/usage", account: "acct-42", authorization: "Bearer jwt")])
      #expect(resolved.withLock { $0 } == ["chatgpt"], "the second fresh pass reads no credentials and Claude is never probed")
      #expect(board.usage("chatgpt")?.plan == "pro")
      #expect(board.usage("chatgpt")?.windows == [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_790_314_546)])
      #expect(board.usage("claude") == nil)
      #expect(board.usage("testing") == nil)
    }
  }
}

private struct URLRequestSummary: Equatable, Sendable {
  let url: String
  let account: String?
  let authorization: String?
}
