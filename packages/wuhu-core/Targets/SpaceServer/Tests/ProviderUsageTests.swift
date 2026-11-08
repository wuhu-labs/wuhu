import struct Credentials.CredentialResolver
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import enum ProviderCapabilities.PlanUsage
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

private let usageModels = """
{
  "gateway": {
    "dialect": "responses",
    "baseURL": "http://gateway.test/v1", "usage": "gateway",
    "models": {"opus": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "broken": {
    "dialect": "responses", "auth": "oidc",
    "baseURL": "http://broken.test/v1", "usage": "gateway",
    "models": {"opus": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "plain": {
    "dialect": "responses",
    "baseURL": "http://plain.test/v1",
    "models": {"gpt": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "chatgpt": {
    "dialect": "codex",
    "baseURL": "https://chatgpt.com/backend-api/codex",
    "models": {"gpt": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "claude": {
    "dialect": "anthropic",
    "baseURL": "https://api.anthropic.com",
    "models": {"opus": {"maxInput": 1000, "maxOutput": 100, "efforts": ["high"], "defaultEffort": "high"}}
  },
  "testing": {
    "dialect": "anthropic",
    "baseURL": "http://localhost:1", "opaqueReplay": "affine",
    "models": {"test-model": {"maxInput": 1000, "maxOutput": 100, "efforts": ["low"], "defaultEffort": "low"}}
  }
}
"""

private let week = 7 * 86400.0

@Suite(.deterministicDependencies) struct ProviderUsageTests {
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
      let listed = try await withDependencies { $0.date = .constant(at) } operation: { try await providers(harness) }
      #expect(listed.first?.usage == ProviderUsage(
        plan: "pro",
        windows: [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_800_100_000)],
        observedAt: 1_800_000_000,
      ))
    }
  }

  @Test func namedSocketWindowsRetainTheirNamesAndDurationsThroughTheBoard() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let event = try #require(JSONValue.parse(#"{"rate_limits":{"primary":{"used_percent":12,"window_minutes":300,"reset_at":1800000300},"windows":{"five_hour":{"used_percent":15,"window_minutes":300,"reset_at":1800000300},"model_week":{"used_percent":100,"window_minutes":10080,"reset_at":1800600000}}}}"#))
      let parsed = PlanUsage.codexSocket(event)
      #expect(parsed.windows.map(\.name) == ["five_hour", "model_week"])
      #expect(parsed.windows.map(\.windowMinutes) == [300, 10080])
      #expect(parsed.windows.first?.usedPercent == 15)
      let at = Date(timeIntervalSince1970: 1_800_000_000)
      harness.runtime.usage.record("testing", plan: parsed.plan, windows: parsed.windows, at: at)
      let listed = try await withDependencies { $0.date = .constant(at) } operation: { try await providers(harness) }
      #expect(listed.first?.usage?.windows == parsed.windows)
      for malformed in [#"{"rate_limits":{"windows":{"model_week":{"used_percent":12,"window_minutes":0,"reset_at":1}}}}"#, #"{"rate_limits":{"windows":{"model_week":{"used_percent":101,"window_minutes":10080,"reset_at":1}}}}"#] {
        #expect(PlanUsage.codexSocket(try #require(JSONValue.parse(malformed))).windows.isEmpty)
      }
    }
  }

  @Test func windowsMergeByNameAndAPlanSurvivesAReportWithoutOne() {
    let board = UsageBoard()
    let early = Date(timeIntervalSince1970: 100)
    board.record("claude", plan: "max", windows: [
      UsageWindow(name: "five_hour", usedPercent: 10, resetsAt: 18100),
      UsageWindow(name: "seven_day", usedPercent: 50, resetsAt: 604_900),
    ], at: early)
    board.record("claude", plan: nil, windows: [UsageWindow(name: "five_hour", usedPercent: 12, resetsAt: 18100)], at: early + 60)
    #expect(board.usage("claude", at: early + 60) == ProviderUsage(
      plan: "max",
      windows: [
        UsageWindow(name: "five_hour", usedPercent: 12, resetsAt: 18100),
        UsageWindow(name: "seven_day", usedPercent: 50, resetsAt: 604_900),
      ],
      observedAt: 160,
    ))
    board.record("claude", plan: nil, windows: [], at: early + 120)
    #expect(board.usage("claude", at: early + 120)?.observedAt == 160, "an empty report observes nothing")
  }

  @Test func aPassedResetReadsAsUnusedAndOnlyAFixedWindowKnowsTheNextOne() {
    let board = UsageBoard()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    board.record("gateway", plan: nil, windows: [
      UsageWindow(name: "five_hour", usedPercent: 100, resetsAt: 1_700_000_060, windowMinutes: 300),
      UsageWindow(name: "seven_day", usedPercent: 40, resetsAt: 1_700_000_000 - 2 * week - 10),
      UsageWindow(name: "primary", usedPercent: 12, resetsAt: nil),
    ], at: now - 3600)
    let unchanged = [
      UsageWindow(name: "seven_day", usedPercent: 0, resetsAt: 1_700_000_000 + week - 10),
      UsageWindow(name: "primary", usedPercent: 12, resetsAt: nil),
    ]
    #expect(board.usage("gateway", at: now)?.windows == [UsageWindow(name: "five_hour", usedPercent: 100, resetsAt: 1_700_000_060, windowMinutes: 300)] + unchanged, "a weekly reset rolls on by whole weeks")
    #expect(board.usage("gateway", at: now + 60) == ProviderUsage(plan: nil, windows: [UsageWindow(name: "five_hour", usedPercent: 0, resetsAt: nil, windowMinutes: 300)] + unchanged, observedAt: 1_699_996_400), "the reading is fresh once its reset passes, without a new poll")
  }

  @Test func aFixedWindowReportedWithoutAResetKeepsTheKnownOneAndATimedReportReplacesIt() {
    let board = UsageBoard()
    let reset = 1_700_000_000.0
    board.record("gateway", plan: nil, windows: [UsageWindow(name: "seven_day", usedPercent: 90, resetsAt: reset)], at: Date(timeIntervalSince1970: reset - 60))
    let nextWeek = Date(timeIntervalSince1970: reset + week + 3600)
    board.record("gateway", plan: nil, windows: [
      UsageWindow(name: "seven_day", usedPercent: 5, resetsAt: nil),
      UsageWindow(name: "five_hour", usedPercent: 5, resetsAt: nil),
    ], at: nextWeek)
    #expect(board.usage("gateway", at: nextWeek)?.windows == [
      UsageWindow(name: "seven_day", usedPercent: 5, resetsAt: reset + 2 * week),
      UsageWindow(name: "five_hour", usedPercent: 5, resetsAt: nil),
    ], "the usage counts toward the week the report fell in")
    board.record("gateway", plan: nil, windows: [UsageWindow(name: "seven_day", usedPercent: 6, resetsAt: reset + 2 * week + 7200)], at: nextWeek + 60)
    #expect(board.usage("gateway", at: nextWeek + 60)?.windows.first == UsageWindow(name: "seven_day", usedPercent: 6, resetsAt: reset + 2 * week + 7200))
  }

  @Test func aFixedResetOutlivesARestartWhileTheGatewayReportsNone() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      _ = try await space.fs(.settings).write("/models.json", Data(usageModels.utf8), ifMatch: nil)
      let credentials = CredentialResolver { $0 == "gateway" ? .apiKey("gateway-key") : nil }
      let reset = 1_790_500_000.0
      let report = Mutex(#"{"rate_limits":{"windows":{"seven_day":{"used_percent":40,"window_minutes":10080,"reset_at":1790500000}}}}"#)
      let now = Mutex(Date(timeIntervalSince1970: reset - 3600))
      await withDependencies {
        $0.date = DateGenerator { now.withLock { $0 } }
        $0.fetch = FetchClient { request in
          #expect(request.url.absoluteString == "http://gateway.test/v1/usage")
          return Response(status: .ok, body: .string(report.withLock { $0 }))
        }
      } operation: {
        await UsageRefresher(board: UsageBoard(), space: space, credentials: credentials).tick()
        report.withLock { $0 = #"{"rate_limits":{"windows":{"seven_day":{"used_percent":0,"window_minutes":10080,"reset_at":0}}}}"# }
        let later = now.withLock { $0 = Date(timeIntervalSince1970: reset + week + 3600); return $0 }
        let restarted = UsageBoard()
        await UsageRefresher(board: restarted, space: space, credentials: credentials).tick()
        #expect(restarted.usage("gateway", at: later)?.windows == [UsageWindow(name: "seven_day", usedPercent: 0, resetsAt: reset + 2 * week, windowMinutes: 10080)])
      }
    }
  }

  @Test func aRefreshIsClaimedOnlyAfterTheIntervalSinceTheLastObservationOrAttempt() {
    let board = UsageBoard()
    let start = Date(timeIntervalSince1970: 10000)
    #expect(board.claimRefresh("codex", now: start, interval: 900))
    #expect(!board.claimRefresh("codex", now: start + 60, interval: 900), "a failed attempt is not retried at once")
    #expect(board.usage("codex", at: start + 60) == nil, "an attempt observes nothing")
    board.record("codex", plan: nil, windows: [UsageWindow(name: "seven_day", usedPercent: 1, resetsAt: nil)], at: start + 800)
    #expect(!board.claimRefresh("codex", now: start + 1000, interval: 900))
    #expect(board.claimRefresh("codex", now: start + 1700, interval: 900))
  }

  @Test func theRefresherReadsCodexAndDeclaredGatewaysWhenStale() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      _ = try await space.fs(.settings).write("/models.json", Data(usageModels.utf8), ifMatch: nil)
      let board = UsageBoard()
      let resolved = Mutex<[String]>([])
      let seen = Mutex<[URLRequestSummary]>([])
      let refresher = UsageRefresher(board: board, space: space, credentials: CredentialResolver { provider in
        resolved.withLock { $0.append(provider) }
        return switch provider {
        case "chatgpt": .chatGPT(accessToken: "jwt", accountID: "acct-42")
        case "gateway", "broken": .apiKey("gateway-key")
        default: nil
        }
      })
      let bodies = [
        "https://chatgpt.com/backend-api/wham/usage": #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":1790314546},"secondary_window":null}}"#,
        "http://gateway.test/v1/usage": #"{"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":30,"window_minutes":300,"reset_at":1790000000},"windows":{"five_hour":{"used_percent":30,"window_minutes":300,"reset_at":1790000000},"seven_day_overage_included":{"used_percent":0,"window_minutes":10080,"reset_at":1790500000}}}}"#,
      ]
      let at = Date(timeIntervalSince1970: 1_789_000_000)
      await withDependencies {
        $0.date = .constant(at)
        $0.fetch = FetchClient { request in
          seen.withLock {
            $0.append(URLRequestSummary(
              url: request.url.absoluteString,
              account: request.headers.sensitiveValues["chatgpt-account-id"],
              authorization: request.headers.sensitiveValues["authorization"],
            ))
          }
          return Response(status: .ok, body: .string(try #require(bodies[request.url.absoluteString])))
        }
      } operation: {
        await refresher.tick()
        await refresher.tick()
      }
      #expect(seen.withLock { $0 }.sorted { $0.url < $1.url } == [
        URLRequestSummary(url: "http://gateway.test/v1/usage", account: nil, authorization: "Bearer gateway-key"),
        URLRequestSummary(url: "https://chatgpt.com/backend-api/wham/usage", account: "acct-42", authorization: "Bearer jwt"),
      ])
      #expect(resolved.withLock { $0 }.sorted() == ["chatgpt", "gateway"], "the second fresh pass reads no credentials, and only Codex and the valid gateway are read")
      #expect(board.usage("chatgpt", at: at)?.plan == "pro")
      #expect(board.usage("chatgpt", at: at)?.windows == [UsageWindow(name: "seven_day", usedPercent: 61, resetsAt: 1_790_314_546, windowMinutes: 10080)])
      #expect(board.usage("gateway", at: at)?.windows == [
        UsageWindow(name: "five_hour", usedPercent: 30, resetsAt: 1_790_000_000, windowMinutes: 300),
        UsageWindow(name: "seven_day_overage_included", usedPercent: 0, resetsAt: 1_790_500_000, windowMinutes: 10080),
      ])
      for provider in ["broken", "plain", "claude", "testing"] {
        #expect(board.usage(provider, at: at) == nil)
      }
    }
  }
}

private struct URLRequestSummary: Equatable, Sendable {
  let url: String
  let account: String?
  let authorization: String?
}
