import Credentials
import Dependencies
import ExecutionOwner
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SessionTools
import SpaceCore
import Testing

@Suite struct HubBindingContractTests {
  @Test func preservesVerifiedCredentialAndOIDCIdentity() async throws {
    let space = try Space.inMemory()
    let expected = CredentialBinding(credential: .apiKey("fixture-key"), identityEpoch: "authoritative-epoch")
    let audience = URL(string: "https://provider.example")!
    let session = SessionID("forwarding-session")
    let execution: any Main = Hub(
      space: space, credentials: .bound { provider in
        #expect(provider == "fixture")
        return expected
      }, inferenceToken: { requested, caller in
        #expect(requested == audience && caller == session)
        return "fixture-token"
      }, inferenceBindingIdentity: { requested, caller in
        #expect(requested == audience && caller == session)
        return "stable-owner-identity"
      },
    )
    let owner: any Main = execution
    let forwarded = try #require(try await owner.providerCredentialBinding("fixture"))
    #expect(forwarded.credential == expected.credential)
    #expect(forwarded.identityEpoch == expected.identityEpoch)
    #expect(forwarded.permitsOpaqueReplay == expected.permitsOpaqueReplay)
    #expect(try await owner.providerCredentialBinding("fixture")?.credential == expected.credential)
    #expect(try await owner.inferenceToken(audience: audience, session: session) == "fixture-token")
    #expect(try await owner.inferenceBindingIdentity(audience: audience, session: session) == "stable-owner-identity")
    let unavailable: any Main = Hub(space: space)
    #expect(try await unavailable.inferenceBindingIdentity(audience: audience, session: session) == nil)
  }

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
    let committed = try await owner.append(id, .portableHandoff(expectedGeneration: hydration.generation, source: source, transcript: projected, transition: nil)).value(Transcript.self)
    #expect(committed == projected)
    #expect(try await owner.hydrate(id).generation == hydration.generation + 1)
    #expect(try await owner.hydrate(id).transcript == .kernel(projected))
  }
}
