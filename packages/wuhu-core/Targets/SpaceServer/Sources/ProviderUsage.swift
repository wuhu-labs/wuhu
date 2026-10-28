import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.ModelsDocument
import struct InferenceKit.ProviderCatalog
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
  private let onRecord: (@Sendable (String, String?, [UsageWindow], Date) -> Void)?

  /// `onRecord` hears every report too: a worker in its own process passes
  /// them on to main's board.
  init(onRecord: (@Sendable (String, String?, [UsageWindow], Date) -> Void)? = nil) {
    self.onRecord = onRecord
  }

  func record(_ provider: String, plan: String?, windows: [UsageWindow], at date: Date) {
    guard !windows.isEmpty else { return }
    onRecord?(provider, plan, windows, date)
    entries.withLock { entries in
      guard (entries[provider]?.usage.observedAt ?? -.infinity) <= date.timeIntervalSince1970 else { return }
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

  func snapshot() -> [String: ProviderUsage] { entries.withLock { $0.mapValues(\.usage) } }

  func merge(_ snapshot: [String: ProviderUsage]) {
    for (id, usage) in snapshot {
      record(id, plan: usage.plan, windows: usage.windows, at: Date(timeIntervalSince1970: usage.observedAt))
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
}

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
    return UsageWindow(name: minutes.map(usageWindowName(minutes:)) ?? fallback, usedPercent: usedPercent, resetsAt: resetsAt, windowMinutes: minutes)
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
      windowMinutes: seconds.map { $0 / 60 },
    )
  }
  return (payload.object?["plan_type"]?.stringValue, windows)
}

struct UsageRefresher: Sendable {
  static let interval: TimeInterval = 15 * 60
  static let tick: Duration = .seconds(60)

  let board: UsageBoard
  let space: Space
  let credentials: CredentialResolver

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
    let invalid = ProviderCatalog(document: document, credentials: .unavailable).providerErrors
    await withTaskGroup { reads in
      for (id, provider) in document.providers where invalid[id] == nil {
        let read: (@Sendable () async -> Void)? = switch (provider.dialect, provider.usage) {
        case (.codex, _): { await refreshCodex(id, provider: provider) }
        case (.responses, .gateway?): { await refreshGateway(id, provider: provider) }
        case (.anthropic, _), (.responses, nil): nil
        }
        guard let read, board.claimRefresh(id, now: date.now, interval: Self.interval) else { continue }
        reads.addTask(operation: read)
      }
    }
  }

  private func refreshCodex(_ id: String, provider: ModelsDocument.Provider) async {
    guard let (accessToken, accountID) = await credential(id, { if case let .chatGPT(token, account) = $0 { (token, account) } else { nil } }) else { return }
    let root = provider.baseURL.lastPathComponent == "codex" ? provider.baseURL.deletingLastPathComponent() : provider.baseURL
    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(accessToken)")
    headers.setSensitive("chatgpt-account-id", accountID)
    headers.set("originator", provider.originator ?? "wuhu")
    // Cloudflare refuses the backend without a User-Agent.
    headers.set("user-agent", "wuhu-usage/1")
    await read(id, Request(url: root.appendingPathComponent("wham/usage"), headers: headers), parse: codexUsage(payload:))
  }

  // The Claude gateway's saved `rate_limits`, the shape its WebSocket reports.
  private func refreshGateway(_ id: String, provider: ModelsDocument.Provider) async {
    guard let key = await credential(id, { if case let .apiKey(key) = $0 { key } else { nil } }) else { return }
    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(key)")
    await read(id, Request(url: provider.baseURL.appendingPathComponent("usage"), headers: headers), parse: codexSocketUsage)
  }

  private enum CredentialProblem: String {
    case unreadable, wrongKind
  }

  private func credential<Value>(_ id: String, _ extract: (ProviderCredential) -> Value?) async -> Value? {
    let problem: CredentialProblem
    do {
      // A provider without a login is the ordinary unconfigured state, not worth a line every interval.
      guard let credential = try await credentials.resolve(id) else { return nil }
      if let value = extract(credential) { return value }
      problem = .wrongKind
    } catch {
      problem = .unreadable
    }
    Logger(label: "wuhu.usage").notice("usage read skipped", metadata: ["provider": "\(id)", "credential": "\(problem.rawValue)"])
    return nil
  }

  private func read(_ id: String, _ request: Request, parse: (JSONValue) -> (plan: String?, windows: [UsageWindow])) async {
    @Dependency(\.fetch) var fetch
    @Dependency(\.date) var date
    do {
      let response = try await fetch(request)
      guard response.status.code == 200 else {
        Logger(label: "wuhu.usage").notice("usage read failed", metadata: ["provider": "\(id)", "status": "\(response.status.code)"])
        return
      }
      let (plan, windows) = parse(try await response.body.json(JSONValue.self))
      board.record(id, plan: plan, windows: windows, at: date.now)
    } catch {
      Logger(label: "wuhu.usage").notice("usage read failed", metadata: ["provider": "\(id)", "error": "\(error)"])
    }
  }
}

func codexSocketUsage(_ payload: JSONValue) -> (plan: String?, windows: [UsageWindow]) {
  let rates = payload.object?["rate_limits"]?.object
  var windows: [String: UsageWindow] = [:]
  func record(_ name: String, _ value: JSONValue) {
    guard let window = value.object, let minutes = window["window_minutes"]?.intValue, minutes > 0,
          let used = window["used_percent"]?.doubleValue, used.isFinite, (0 ... 100).contains(used),
          let reset = window["reset_at"]?.doubleValue, reset.isFinite, reset >= 0 else { return }
    windows[name] = UsageWindow(name: name, usedPercent: used, resetsAt: reset, windowMinutes: minutes)
  }
  for key in ["primary", "secondary"] {
    if let value = rates?[key], let minutes = value.object?["window_minutes"]?.intValue {
      record(usageWindowName(minutes: minutes), value)
    }
  }
  for (name, value) in rates?["windows"]?.object ?? [:] { record(name, value) }
  return (payload.object?["plan_type"]?.stringValue, windows.values.sorted { $0.name < $1.name })
}
