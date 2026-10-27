import JSONValue
import SpaceClient
import struct SpaceContract.ObserverInput
import struct SpaceContract.ObserverOutput
import struct SpaceContract.ObserversOutput

extension Executor {
  mutating func groupObservers(_ group: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let listed: ObserversOutput = try await self.authenticated(space).api(.get, "/v1/group/\(group)/observers")
    await self.runner.stdout(listed.observers.map(observerLine).map { $0 + "\n" }.joined())
  }

  mutating func groupObserverCreate(_ group: String, _ input: ObserverInput) async throws {
    let space = try self.wallet.pinnedSpace()
    let body = try JSONValueEncoder().encode(input)
    let armed: ObserverOutput = try await self.authenticated(space).api(.post, "/v1/group/\(group)/observers", body: body)
    await self.runner.stdout(observerLine(armed) + "\n")
  }

  mutating func groupObserverCancel(_ group: String, name: String) async throws {
    let space = try self.wallet.pinnedSpace()
    let ended: ObserverOutput = try await self.authenticated(space).api(.delete, "/v1/group/\(group)/observers/\(name)")
    await self.runner.stdout("cancelled \(observerLine(ended))\n")
  }
}

// name, kind, status, handler, then the schedule and why it paused.
private func observerLine(_ observer: ObserverOutput) -> String {
  var fields = [observer.name, observer.id, observer.status.rawValue, observer.handler, "\(observer.sessionsPerHour)/h"]
  if let sql = observer.sql { fields.append("sql=\(sql)") }
  if let cron = observer.cron { fields.append("cron=\(cron)") }
  if let fireAt = observer.fireAt { fields.append("at=\(formatTimestamp(fireAt))") }
  if let error = observer.lastError { fields.append("error=\(error)") }
  return fields.joined(separator: "\t")
}
