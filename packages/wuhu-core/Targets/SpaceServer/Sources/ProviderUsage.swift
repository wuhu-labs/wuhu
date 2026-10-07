import ClaudeStream
import struct Credentials.CredentialResolver
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.ModelsDocument
import JSONValue
import Logging
import struct SpaceContract.ProviderUsage
import struct SpaceContract.UsageWindow
import SpaceCore
import Synchronization

// Plan usage per provider, as last observed. Inference feeds it for free; the
// refresher fills the gaps. A report names only the windows it saw, so windows
// merge by name and a partial report never erases the rest.
final class UsageBoard: Sendable {
  private struct Entry {
    var usage: ProviderUsage
    var attemptedAt: Date?
  }

  private let entries = Mutex<[String: Entry]>([:])

  func record(_ provider: String, plan: String?, windows: [UsageWindow], at date: Date) {
    guard !windows.isEmpty else { return }
    entries.withLock { entries in
      var merged = entries[provider]?.usage.windows ?? []
      for window in windows {
        if let held = merged.firstIndex(where: { $0.name == window.name }) {
          merged[held] = window
        } else {
          merged.append(window)
        }
      }
      let usage = ProviderUsage(
        plan: plan ?? entries[provider]?.usage.plan,
        windows: merged,
        observedAt: date.timeIntervalSince1970,
      )
      entries[provider] = Entry(usage: usage, attemptedAt: entries[provider]?.attemptedAt)
    }
  }

  func usage(_ provider: String) -> ProviderUsage? {
    entries.withLock { $0[provider]?.usage }.flatMap { $0.windows.isEmpty ? nil : $0 }
  }

  // Claims a refresh when the provider has been neither observed nor tried
  // within the interval, so a failing source is retried at that pace too.
  func claimRefresh(_ provider: String, now: Date, interval: TimeInterval) -> Bool {
    entries.withLock { entries in
      let observed = entries[provider].map { Date(timeIntervalSince1970: $0.usage.observedAt) }
      let attempted = entries[provider]?.attemptedAt
      let latest = [observed, attempted].compactMap(\.self).max()
      guard latest.map({ now.timeIntervalSince($0) >= interval }) ?? true else { return false }
      if var entry = entries[provider] {
        entry.attemptedAt = now
        entries[provider] = entry
      } else {
        entries[provider] = Entry(usage: ProviderUsage(plan: nil, windows: [], observedAt: 0), attemptedAt: now)
      }
      return true
    }
  }

  // Gives back a claim whose refresh could not run, so the next tick tries again.
  func releaseClaim(_ provider: String, claimedAt: Date) {
    entries.withLock { entries in
      guard entries[provider]?.attemptedAt == claimedAt else { return }
      entries[provider]?.attemptedAt = nil
    }
  }
}

// A probe needs the installed binary; until it is there, nothing was tried.
enum ClaudeUsageProbe: Sendable {
  case notInstalled
  case probed(ClaudeStreamFrame.RateLimit?)
}

// The cheapest model Claude Code accepts; a probe turn is one word long.
let claudeUsageProbeModel = "claude-haiku-4-5"

// A window is named for its length, so Codex and Claude windows of the same
// length read alike.
func usageWindowName(minutes: Int) -> String {
  switch minutes {
  case 300: "five_hour"
  case 10080: "seven_day"
  default: "\(minutes)_minute"
  }
}

// A plan with one window still sends the other family, zero minutes long.
func codexUsage(headers: [String: String]) -> [UsageWindow] {
  [("x-codex-primary", "primary"), ("x-codex-secondary", "secondary")].compactMap { prefix, fallback in
    let usedPercent = headers["\(prefix)-used-percent"].flatMap(Double.init)
    let resetsAt = headers["\(prefix)-reset-at"].flatMap(Double.init)
    let minutes = headers["\(prefix)-window-minutes"].flatMap(Int.init)
    guard usedPercent != nil || resetsAt != nil, minutes != 0 else { return nil }
    return UsageWindow(name: minutes.map(usageWindowName(minutes:)) ?? fallback, usedPercent: usedPercent, resetsAt: resetsAt)
  }
}

// The ChatGPT backend's own usage read, the one Codex's /status makes.
func codexUsage(payload: JSONValue) -> (plan: String?, windows: [UsageWindow]) {
  let limit = payload.object?["rate_limit"]?.object
  let windows = ["primary_window", "secondary_window"].compactMap { key -> UsageWindow? in
    guard let window = limit?[key]?.object else { return nil }
    let seconds = window["limit_window_seconds"]?.intValue
    return UsageWindow(
      name: seconds.map { usageWindowName(minutes: $0 / 60) } ?? key,
      usedPercent: window["used_percent"]?.doubleValue,
      resetsAt: window["reset_at"]?.doubleValue,
    )
  }
  return (payload.object?["plan_type"]?.stringValue, windows)
}

// Claude Code reports utilization as a fraction; the wire speaks percent.
func claudeUsage(_ rateLimit: ClaudeStreamFrame.RateLimit) -> [UsageWindow] {
  if !rateLimit.windows.isEmpty {
    return rateLimit.windows.map {
      UsageWindow(name: $0.name, usedPercent: $0.utilization * 100, resetsAt: $0.resetsAt)
    }
  }
  guard let name = rateLimit.type, rateLimit.utilization != nil || rateLimit.resetsAt != nil else { return [] }
  return [UsageWindow(name: name, usedPercent: rateLimit.utilization.map { $0 * 100 }, resetsAt: rateLimit.resetsAt)]
}

struct UsageRefresher: Sendable {
  static let interval: TimeInterval = 15 * 60
  static let tick: Duration = .seconds(60)

  let board: UsageBoard
  let space: Space
  let credentials: CredentialResolver
  let probeClaude: @Sendable (String) async -> ClaudeUsageProbe

  func run() async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled {
      await refreshStale()
      guard (try? await clock.sleep(for: Self.tick)) != nil else { return }
    }
  }

  func refreshStale() async {
    @Dependency(\.date) var date
    guard let document = await modelsDocument(space: space) else { return }
    for (id, provider) in document.providers.sorted(by: { $0.key < $1.key }) {
      switch provider.dialect {
      case .codex:
        guard board.claimRefresh(id, now: date.now, interval: Self.interval) else { continue }
        await refreshCodex(id, provider: provider)
      case .claude:
        let claimedAt = date.now
        guard board.claimRefresh(id, now: claimedAt, interval: Self.interval) else { continue }
        switch await probeClaude(id) {
        case .notInstalled:
          board.releaseClaim(id, claimedAt: claimedAt)
        case let .probed(rateLimit?):
          board.record(id, plan: nil, windows: claudeUsage(rateLimit), at: date.now)
        case .probed(nil):
          break
        }
      case .anthropic, .responses:
        continue
      }
    }
  }

  private func refreshCodex(_ id: String, provider: ModelsDocument.Provider) async {
    @Dependency(\.fetch) var fetch
    @Dependency(\.date) var date
    guard case let .chatGPT(accessToken, accountID)? = try? await credentials.resolve(id) else { return }
    let root = provider.baseURL.lastPathComponent == "codex" ? provider.baseURL.deletingLastPathComponent() : provider.baseURL
    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(accessToken)")
    headers.setSensitive("chatgpt-account-id", accountID)
    headers.set("originator", provider.originator ?? "wuhu")
    // Cloudflare refuses the backend without a User-Agent.
    headers.set("user-agent", "wuhu-usage/1")
    do {
      let response = try await fetch(Request(url: root.appendingPathComponent("wham/usage"), headers: headers))
      guard response.status.code == 200 else {
        Logger(label: "wuhu.usage").notice("codex usage read failed", metadata: ["provider": "\(id)", "status": "\(response.status.code)"])
        return
      }
      let (plan, windows) = codexUsage(payload: try await response.body.json(JSONValue.self))
      board.record(id, plan: plan, windows: windows, at: date.now)
    } catch {
      Logger(label: "wuhu.usage").notice("codex usage read failed", metadata: ["provider": "\(id)", "error": "\(error)"])
    }
  }
}

func codexSocketUsage(_ payload: JSONValue) -> (plan: String?, windows: [UsageWindow]) {
  let rates = payload.object?["rate_limits"]?.object
  let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
    guard let window = rates?[key]?.object, let minutes = window["window_minutes"]?.intValue, minutes > 0,
          let used = window["used_percent"]?.doubleValue, used.isFinite, (0 ... 100).contains(used),
          let reset = window["reset_at"]?.doubleValue, reset.isFinite, reset >= 0 else { return nil }
    return UsageWindow(name: usageWindowName(minutes: minutes), usedPercent: used, resetsAt: reset)
  }
  return (payload.object?["plan_type"]?.stringValue, windows)
}
