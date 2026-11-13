import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Wuwei

public struct SessionRestart: Hashable, Sendable, Codable {
  public var generation: Int
  public var executor: SessionExecutor

  public init(generation: Int, executor: SessionExecutor) {
    self.generation = generation
    self.executor = executor
  }
}

public struct GenerationState: Hashable, Sendable {
  public var generation: Int
  public var note: String?

  public init(generation: Int, note: String?) {
    self.generation = generation
    self.note = note
  }
}

extension SessionStore {
  /// The executor a restart onto `executor` stores: a model group is stored as the model it was placed on.
  public static func restartExecutor(_ executor: SessionExecutor, route: SessionModelRoute?) throws -> SessionExecutor {
    try Sessions.concreteExecutor(executor, route: route)
  }

  public func generation(_ id: SessionID) async throws -> Int {
    return try spaceCell.sessionGeneration(id)
  }

  public func generationState(_ id: SessionID) async throws -> GenerationState {
    return try spaceCell.sessionGenerationState(id)
  }
}

extension Sessions {
  static func generationState(_ key: String, in db: Database) throws -> GenerationState {
    let generation = try runtime(key, in: db).generation
    if try record(key, in: db).executor.isRetired { return GenerationState(generation: Int(generation), note: nil) }
    return GenerationState(generation: Int(generation), note: try lineText(key, generation: generation, lineKey: "head:note", in: db)?.text)
  }
}
