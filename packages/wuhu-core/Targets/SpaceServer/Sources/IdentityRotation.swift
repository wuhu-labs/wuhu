#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies

struct IdentityKeySchedule: Codable, Equatable, Sendable {
  var currentKey: Data
  var rotatedAt: Date
  var nextKey: Data?
  var overlapBeganAt: Date?
  var switchedAt: Date?

  var signingWithNext: Bool { switchedAt != nil }

  var signingKey: Data { signingWithNext ? nextKey! : currentKey }

  func validate() throws {
    _ = try ServerIdentity(rawKey: currentKey)
    if let nextKey {
      let next = try ServerIdentity(rawKey: nextKey)
      guard next.kid != (try ServerIdentity(rawKey: currentKey)).kid,
            !signingWithNext || overlapBeganAt != nil
      else { throw IdentityError.keyUnavailable }
    } else if overlapBeganAt != nil || signingWithNext { throw IdentityError.keyUnavailable }
  }
}

extension IdentityController {
  func rotate() async throws {
    guard !mutationInProgress else { throw IdentityError.mutationInProgress }
    mutationInProgress = true
    defer { mutationInProgress = false }
    guard settings.keySchedule!.nextKey == nil else { throw IdentityError.mutationInProgress }
    try await beginRotation()
    try await advanceRotation()
  }

  func maintain() async throws {
    guard !mutationInProgress else { return }
    mutationInProgress = true
    defer { mutationInProgress = false }
    @Dependency(\.date) var date
    if settings.keySchedule!.nextKey == nil, date.now.timeIntervalSince(settings.keySchedule!.rotatedAt) >= 90 * 86400 {
      try await beginRotation()
    }
    try await advanceRotation()
  }

  func run() async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled {
      do {
        try await maintain()
        try await clock.sleep(for: .seconds(60))
      } catch is CancellationError { return }
      catch {
        do { try await clock.sleep(for: .seconds(60)) }
        catch { return }
      }
    }
  }

  private func beginRotation() async throws {
    var next = settings
    next.keySchedule!.nextKey = try ServerIdentity.generate().rawKey
    try await commit(next)
  }

  private func advanceRotation() async throws {
    @Dependency(\.date) var date
    let publishesDirectory = settings.usesDirectory || settings.directoryID != nil
    if let schedule = settings.keySchedule, schedule.nextKey != nil {
      if schedule.overlapBeganAt == nil {
        if publishesDirectory { try await publishCurrent() }
        var next = settings
        next.keySchedule!.overlapBeganAt = date.now
        try await commit(next)
      }
      let elapsed = date.now.timeIntervalSince(settings.keySchedule!.overlapBeganAt!)
      if publishesDirectory, !directoryConfirmed { try await publishCurrent() }
      if elapsed >= 86400, !settings.keySchedule!.signingWithNext {
        var next = settings
        next.keySchedule!.switchedAt = date.now
        try await commit(next)
      }
      if elapsed >= 2 * 86400, date.now.timeIntervalSince(settings.keySchedule!.switchedAt!) >= 86400 {
        if publishesDirectory { try await publishCurrent(keys: identity.jwks) }
        var next = settings
        next.keySchedule = .init(currentKey: identity.rawKey, rotatedAt: date.now)
        try await commit(next)
      }
    } else if publishesDirectory, !directoryConfirmed { try await publishCurrent() }
  }
}
