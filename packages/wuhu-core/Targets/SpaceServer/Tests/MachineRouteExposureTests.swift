#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ControlledTime
import DeterministicDependencies
import Fetch
import enum JSONValue.JSONValue
import class MainHub.Hub
@testable import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies(clock: VirtualClock())) struct MachineRouteExposureTests {
  @Test(arguments: [false, true])
  func bindMainDoesNotRegisterListenerMachineEnrollment(explicitGroup: Bool) async throws {
    let space = try makeMachineSpace()
    var input: [String: JSONValue] = ["name": "must_not_enroll"]
    if explicitGroup {
      let person = try await space.addAccount(kind: .human, name: "group-owner")
      let group = try await space.ensurePersonalGroup(account: person.id)
      input["group"] = .string(group.rawValue)
    }
    let connection = MainConnection()
    let tokens = try await testTokens(space: space)
    SessionRuntime.bindMain(owner: Hub(space: space), tokens: tokens, connection: connection)
    let response = try await connection.fetch(Request(
      url: URL(string: "http://space/v1/machine-v2")!,
      method: .post,
      body: try .json(input),
    ))
    #expect(response.status == .notFound)
    #expect(try await space.resolveMachine("must_not_enroll") == nil)
    try await space.close()
  }
}
