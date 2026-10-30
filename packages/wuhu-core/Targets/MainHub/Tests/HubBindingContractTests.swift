import Dependencies
import DeterministicDependencies
import ExecutionOwner
import protocol MainHub.Main
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MainHub
import SessionDomain
import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct HubBindingContractTests {
  @Test func commitsConditionalPortableHandoff() async throws {
    let space = try Space.inMemory()
    let id = try await space.sessions.createSession(group: .shared, title: "tool owner handoff", kind: .agent, createdBy: "fixture", model: .init(provider: "fixture", model: "model", effort: "high"))
    let owner: any Main = Hub(space: space)
    let hydration = try await owner.hydrate(id)
    guard case let .kernel(source) = hydration.transcript else { Issue.record("expected kernel transcript"); return }
    let projected = try withDependencies {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      try source.portableHandoff(binding: .init(identity: "forwarded-binding", epoch: "forwarded-route"), budget: .init(maxInput: 10000, maxOutput: 1000), runningWork: [])
    }
    let committed = try await owner.append(id, .portableHandoff(expectedGeneration: hydration.generation, source: source, transcript: projected)).value(Transcript.self)
    #expect(committed == projected)
    #expect(try await owner.hydrate(id).generation == hydration.generation + 1)
    #expect(try await owner.hydrate(id).transcript == .kernel(projected))
  }
}
