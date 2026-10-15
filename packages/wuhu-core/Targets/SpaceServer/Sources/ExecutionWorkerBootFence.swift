#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import Synchronization

final class ExecutionWorkerCredentialFence: Sendable {
  private let fingerprints = Mutex<Set<SHA256.Digest>>([])

  func revoke(_ credentials: ExecutionWorkerManifest.Credentials) {
    let values = [credentials.current, credentials.successor].compactMap { $0 }.map { SHA256.hash(data: Data($0.utf8)) }
    fingerprints.withLock { $0.formUnion(values) }
  }

  func admits(_ token: String) -> Bool {
    let fingerprint = SHA256.hash(data: Data(token.utf8))
    return fingerprints.withLock { !$0.contains(fingerprint) }
  }
}

import struct SessionDomain.SessionID

struct ExecutionWorkerBootFence {
  enum Inventory: Sendable {
    case missing
    case unsafeStorage(String)
    case directories([String])
  }

  enum Read: Sendable {
    case missing, missingManifest, corrupt, foreignVersion, foreignSpace, unsafeStorage
    case manifest(ExecutionWorkerManifest)
  }

  enum Process: Sendable {
    case absent, differentBirth, unverified, matching
  }

  enum Termination: Sendable {
    case exited, staleCredentialExited, acknowledgedWithoutPIDHandle, unconfirmed
    case unsafeProcessIdentity, pidHandleUnavailable, didNotExit
  }

  enum Outcome: String, Sendable {
    case missing, missingManifest, corrupt, foreignVersion, foreignSpace, unsafeStorage
    case absent, differentBirth, unverified, terminated, acknowledgedWithoutPIDHandle, unconfirmed
    case staleCredentialTerminated, unsafeProcessIdentity, pidHandleUnavailable, didNotExit
    case cleanupFailed
  }

  struct Effects: Sendable {
    var inventory: @Sendable () async -> Inventory
    var read: @Sendable (String) async -> Read
    var process: @Sendable (ExecutionWorkerManifest) -> Process
    var terminate: @Sendable (ExecutionWorkerManifest, String) async -> Termination
    var cleanup: @Sendable (String) async throws -> Void
    var report: @Sendable (Outcome) -> Void
  }

  struct UnresolvedWorker: Sendable {
    let processID: Int32?
    let birthDiagnostic: String?
    let directory: String
    let reason: Outcome

    init(directory: String, reason: Outcome) {
      processID = nil
      birthDiagnostic = nil
      self.directory = directory
      self.reason = reason
    }

    init(manifest: ExecutionWorkerManifest, directory: String, reason: Outcome) {
      processID = manifest.processID
      self.directory = directory
      self.reason = reason
      let parts = manifest.birth.split(separator: ":", omittingEmptySubsequences: false)
      let containsCredential = [manifest.credentials.current, manifest.credentials.successor].compactMap { $0 }.contains { manifest.birth.contains($0) }
      if !containsCredential,
         (parts.count == 3 && parts[0] == "linux") || (parts.count == 4 && parts[0] == "darwin"),
         UUID(uuidString: String(parts[1])) != nil,
         parts.dropFirst(2).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } })
      {
        birthDiagnostic = manifest.birth
      } else {
        birthDiagnostic = "unverified-fingerprint:" + SHA256.hash(data: Data(manifest.birth.utf8)).prefix(8).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
      }
    }
  }

  struct Result: Sendable {
    var counts: [Outcome: Int] = [:]
    var blockedSessions: Set<SessionID> = []
    var unresolved: Set<UUID> = []
    var unresolvedWorkers: [UnresolvedWorker] = []
    let credentials: ExecutionWorkerCredentialFence
  }

  static func reconcile(effects: Effects, credentials: ExecutionWorkerCredentialFence = .init()) async -> Result {
    var result = Result(credentials: credentials)
    func count(_ outcome: Outcome) {
      result.counts[outcome, default: 0] += 1
      effects.report(outcome)
    }
    func unresolved(_ manifest: ExecutionWorkerManifest, directory: String, reason: Outcome) {
      result.unresolved.insert(manifest.incarnation)
      result.unresolvedWorkers.append(.init(manifest: manifest, directory: directory, reason: reason))
      count(reason)
    }
    func uninspected(_ directory: String, reason: Outcome) {
      result.unresolvedWorkers.append(.init(directory: directory, reason: reason))
      count(reason)
    }
    let directories: [String]
    switch await effects.inventory() {
    case .missing: count(.missing); return result
    case let .unsafeStorage(directory): uninspected(directory, reason: .unsafeStorage); return result
    case let .directories(values): directories = values
    }
    for directory in directories {
      let manifest: ExecutionWorkerManifest
      switch await effects.read(directory) {
      case .missing: count(.missing); continue
      case .missingManifest: uninspected(directory, reason: .missingManifest); continue
      case .corrupt: uninspected(directory, reason: .corrupt); continue
      case .foreignVersion: uninspected(directory, reason: .foreignVersion); continue
      case .foreignSpace: uninspected(directory, reason: .foreignSpace); continue
      case .unsafeStorage: uninspected(directory, reason: .unsafeStorage); continue
      case let .manifest(value): manifest = value
      }
      credentials.revoke(manifest.credentials)
      let outcome: Outcome
      switch effects.process(manifest) {
      case .absent: outcome = .absent
      case .differentBirth: outcome = .differentBirth
      case .unverified:
        unresolved(manifest, directory: directory, reason: .unverified)
        continue
      case .matching:
        switch await effects.terminate(manifest, directory) {
        case .exited: outcome = .terminated
        case .staleCredentialExited: outcome = .staleCredentialTerminated
        case .acknowledgedWithoutPIDHandle: outcome = .acknowledgedWithoutPIDHandle
        case .unconfirmed:
          unresolved(manifest, directory: directory, reason: .unconfirmed)
          continue
        case .unsafeProcessIdentity:
          unresolved(manifest, directory: directory, reason: .unsafeProcessIdentity)
          continue
        case .pidHandleUnavailable:
          unresolved(manifest, directory: directory, reason: .pidHandleUnavailable)
          continue
        case .didNotExit:
          unresolved(manifest, directory: directory, reason: .didNotExit)
          continue
        }
      }
      count(outcome)
      do { try await effects.cleanup(directory) }
      catch { count(.cleanupFailed) }
    }
    return result
  }
}
