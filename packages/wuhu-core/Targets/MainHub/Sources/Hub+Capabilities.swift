#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct InferenceKit.AudioClip
import enum InferenceKit.AudioMediaType
import struct InferenceKit.CapabilityClient
import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import struct InferenceKit.InferenceMetric
import struct InferenceKit.Transcription
import SessionDomain
import SpaceCore
import struct SpaceTools.MachineSeam

extension Hub {
  nonisolated public func capabilityDocument(_ path: String) async throws -> Data? {
    do { return try await space.fs(.shared).read(path).1 }
    catch SpaceError.notFound { return nil }
  }

  nonisolated public func recordCompletion(_ metric: InferenceMetric) async throws {
    if let completionMetrics { await completionMetrics.record(metric) }
    else {
      try await space.recordInference(InferenceRecord(
        id: UUID().uuidString.lowercased(),
        session: metric.session,
        at: metric.timestamp,
        provider: metric.provider,
        model: metric.model,
        servedModel: metric.servedModel,
        effort: metric.effort,
        input: metric.usage?.uncachedInputTokens,
        cacheRead: metric.usage?.cacheReadTokens,
        cacheWrite: metric.usage?.cacheWriteTokens,
        output: metric.usage?.outputTokens,
        reasoning: metric.usage?.reasoningTokens,
        outcome: metric.outcome.rawValue,
        error: metric.errorKind,
        durationMs: metric.durationMs,
        ttftMs: metric.ttftMs,
      ))
    }
  }

  nonisolated public func capabilityInput(_ raw: String, as session: SessionID, limit: Int) async throws -> Data {
    try await MachineSeam.$caller.withValue(session) { try await capabilityBytes(raw, as: session, limit: limit) }
  }

  nonisolated private func capabilityBytes(_ raw: String, as session: SessionID, limit: Int) async throws -> Data {
    let address = try await resolve(raw, as: session)
    switch address {
    case let .machine(machine, path):
      guard let entry = try await machineStat(machine, path: path) else { throw CapabilityError(.invalidArgument, "Input file does not exist.") }
      guard entry.size <= limit else { throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.") }
      return try await Data(machineFile(machine, path: path, entry: entry, reference: address.rendered))
    case let .space(path, group, _):
      let entry = try await space.fs(group).stat(path)
      guard entry.size <= limit else { throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.") }
      let bytes = try await readRaw(address).1
      guard bytes.count <= limit else { throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.") }
      return bytes
    case .system: throw CapabilityError(.invalidArgument, "Capability inputs must be private space or authorized machine files.")
    }
  }
}
