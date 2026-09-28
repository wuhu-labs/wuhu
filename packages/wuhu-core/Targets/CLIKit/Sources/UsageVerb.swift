import Dependencies
import Foundation
import JSONValue
import struct SpaceContract.ProviderDescriptor
import struct SpaceContract.ProvidersOutput

extension Executor {
  mutating func usage(json: Bool) async throws {
    let space = try self.wallet.pinnedSpace()
    let output: ProvidersOutput = try await self.authenticated(space).api(.get, "/v1/providers")
    guard !json else {
      await self.runner.stdout(prettyJSON(try JSONValueEncoder().encode(output)) + "\n")
      return
    }
    @Dependency(\.date) var date
    let reported = output.providers.compactMap { renderedUsage($0, now: date.now) }
    guard !reported.isEmpty else {
      await self.runner.stdout("no plan usage observed yet; only codex and claude providers report it\n")
      return
    }
    await self.runner.stdout(reported.joined(separator: "\n") + "\n")
  }
}

private func renderedUsage(_ provider: ProviderDescriptor, now: Date) -> String? {
  guard let usage = provider.usage else { return nil }
  let age = Int(now.timeIntervalSince1970 - usage.observedAt) / 60
  var text = provider.id + (usage.plan.map { " (\($0))" } ?? "") + " · observed \(age)m ago\n"
  for window in usage.windows {
    let percent = window.usedPercent.map { String(format: "%.0f%%", $0) } ?? "?"
    let resets = window.resetsAt.map {
      " resets " + isoFormatted(Date(timeIntervalSince1970: $0), in: .current)
    } ?? ""
    text += "  \(window.name) \(percent)\(resets)\n"
  }
  return text
}
