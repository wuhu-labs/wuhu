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

  /// A window whose reset has passed, or is 0, reads as used 0 with no reset
  /// time, so a reading taken before its reset is fresh after it without a new poll.
  func usage(_ provider: String, at now: Date) -> ProviderUsage? {
    guard let usage = entries.withLock({ $0[provider]?.usage }), !usage.windows.isEmpty else { return nil }
    let windows = usage.windows.map { window in
      guard let reset = window.resetsAt, reset <= now.timeIntervalSince1970 else { return window }
      return UsageWindow(name: window.name, usedPercent: 0, resetsAt: nil, windowMinutes: window.windowMinutes)
    }
    return ProviderUsage(plan: usage.plan, windows: windows, observedAt: usage.observedAt)
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
