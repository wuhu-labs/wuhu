import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.ProviderCatalog
import JSONValue
import Logging
import struct ModelProviders.ModelsDocument
import enum ProviderCapabilities.PlanUsage
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

  private struct State {
    var entries: [String: Entry] = [:]
    var fixedResets: [UsageWindowKey: Double] = [:]
  }

  private let state = Mutex(State())
  private let onRecord: (@Sendable (String, String?, [UsageWindow], Date) -> Void)?

  /// `onRecord` hears every report too: a worker in its own process passes
  /// them on to main's board.
  init(onRecord: (@Sendable (String, String?, [UsageWindow], Date) -> Void)? = nil) {
    self.onRecord = onRecord
  }

  /// A fixed window reported without a reset keeps the last one known, rolled forward to the report.
  func record(_ provider: String, plan: String?, windows: [UsageWindow], at date: Date) {
    guard !windows.isEmpty else { return }
    onRecord?(provider, plan, windows, date)
    state.withLock { state in
      guard (state.entries[provider]?.usage.observedAt ?? -.infinity) <= date.timeIntervalSince1970 else { return }
      var merged = state.entries[provider]?.usage.windows ?? []
      for var window in windows {
        if case .fixedWeekly = UsageWindowKind(window.name) {
          let key = UsageWindowKey(provider: provider, window: window.name)
          if let reset = window.resetsAt {
            state.fixedResets[key] = reset
          } else if let known = state.fixedResets[key] {
            window = window.resetting(at: UsageWindowKind.fixedWeekly.reset(following: known, after: date.timeIntervalSince1970))
          }
        }
        if let held = merged.firstIndex(where: { $0.name == window.name }) {
          merged[held] = window
        } else {
          merged.append(window)
        }
      }
      let usage = ProviderUsage(
        plan: plan ?? state.entries[provider]?.usage.plan,
        windows: merged,
        observedAt: date.timeIntervalSince1970,
      )
      state.entries[provider] = Entry(usage: usage, attemptedAt: state.entries[provider]?.attemptedAt)
    }
  }

  /// A window whose reset has passed reads as used 0, so a reading taken before
  /// its reset is fresh after it without a new poll. A rolling window's next
  /// reset is unknown until observed; a fixed one's is a whole number of periods on.
  func usage(_ provider: String, at now: Date) -> ProviderUsage? {
    guard let usage = state.withLock({ $0.entries[provider]?.usage }), !usage.windows.isEmpty else { return nil }
    let windows = usage.windows.map { window in
      guard let reset = window.resetsAt, reset <= now.timeIntervalSince1970 else { return window }
      return UsageWindow(name: window.name, usedPercent: 0, resetsAt: UsageWindowKind(window.name).reset(following: reset, after: now.timeIntervalSince1970), windowMinutes: window.windowMinutes)
    }
    return ProviderUsage(plan: usage.plan, windows: windows, observedAt: usage.observedAt)
  }

  /// The last reset reported of each fixed window.
  var fixedResets: [UsageWindowKey: Double] {
    state.withLock(\.fixedResets)
  }

  /// Takes resets kept from before a restart, for the fixed windows no report has timed since.
  func remember(_ resets: [UsageWindowKey: Double]) {
    state.withLock { state in
      for (key, reset) in resets where state.fixedResets[key] == nil {
        state.fixedResets[key] = reset
        guard var entry = state.entries[key.provider],
              let held = entry.usage.windows.firstIndex(where: { $0.name == key.window && $0.resetsAt == nil }) else { continue }
        var windows = entry.usage.windows
        windows[held] = windows[held].resetting(at: UsageWindowKind.fixedWeekly.reset(following: reset, after: entry.usage.observedAt))
        entry.usage = ProviderUsage(plan: entry.usage.plan, windows: windows, observedAt: entry.usage.observedAt)
        state.entries[key.provider] = entry
      }
    }
  }

  // Claims a refresh when the provider has been neither observed nor tried
  // within the interval, so a failing source is retried at that pace too.
  func claimRefresh(_ provider: String, now: Date, interval: TimeInterval) -> Bool {
    state.withLock { state in
      let observed = state.entries[provider].map { Date(timeIntervalSince1970: $0.usage.observedAt) }
      let attempted = state.entries[provider]?.attemptedAt
      let latest = [observed, attempted].compactMap(\.self).max()
      guard latest.map({ now.timeIntervalSince($0) >= interval }) ?? true else { return false }
      if var entry = state.entries[provider] {
        entry.attemptedAt = now
        state.entries[provider] = entry
      } else {
        state.entries[provider] = Entry(usage: ProviderUsage(plan: nil, windows: [], observedAt: 0), attemptedAt: now)
      }
      return true
    }
  }
}

/// How a plan window's reset moves once it passes.
enum UsageWindowKind {
  /// Starts at the first request after a reset, so the next reset is unknown until observed.
  case rolling
  /// Resets on a fixed weekly schedule.
  case fixedWeekly

  private static let week: Double = 7 * 24 * 3600

  init(_ name: String) {
    self = name.hasPrefix("seven_day") ? .fixedWeekly : .rolling
  }

  /// The first reset after `now` that one at `reset` implies.
  func reset(following reset: Double, after now: Double) -> Double? {
    guard reset <= now else { return reset }
    return switch self {
    case .rolling: nil
    case .fixedWeekly: reset + (((now - reset) / Self.week).rounded(.down) + 1) * Self.week
    }
  }
}

private extension UsageWindow {
  func resetting(at reset: Double?) -> UsageWindow {
    UsageWindow(name: name, usedPercent: usedPercent, resetsAt: reset, windowMinutes: windowMinutes)
  }
}

struct UsageRefresher: Sendable {
  static let interval: TimeInterval = 15 * 60
  static let pace: Duration = .seconds(60)

  let board: UsageBoard
  let space: Space
  let credentials: CredentialResolver

  func run() async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled {
      await tick()
      guard (try? await clock.sleep(for: Self.pace)) != nil else { return }
    }
  }

  /// Reads the stale providers, and keeps the board's fixed resets in the
  /// space across restarts: kept ones fill what the board lacks, and the
  /// board's new ones are kept.
  func tick() async {
    do {
      let kept = try await space.usageWindowResets()
      board.remember(kept)
      await refreshStale()
      let learned = board.fixedResets.filter { kept[$0.key] != $0.value }
      if !learned.isEmpty { try await space.saveUsageWindowResets(learned) }
    } catch {
      Logger(label: "wuhu.usage").error("usage resets not kept", metadata: ["error": "\(error)"])
    }
  }

  private func refreshStale() async {
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
    await read(id, Request(url: root.appendingPathComponent("wham/usage"), headers: headers), parse: PlanUsage.codex(payload:))
  }

  // The Claude gateway's saved `rate_limits`, the shape its WebSocket reports.
  private func refreshGateway(_ id: String, provider: ModelsDocument.Provider) async {
    guard let key = await credential(id, { if case let .apiKey(key) = $0 { key } else { nil } }) else { return }
    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(key)")
    await read(id, Request(url: provider.baseURL.appendingPathComponent("usage"), headers: headers), parse: PlanUsage.codexSocket)
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
