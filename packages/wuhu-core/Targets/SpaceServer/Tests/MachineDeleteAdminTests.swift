#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import Fetch
import MachinesTesting
import Serve
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import Testing

/// The machine delete route under the group's admin rules: the world it needs is the group route suite's.
@Suite(.deterministicDependencies) struct MachineDeleteAdminTests {
  @Test func onlyAHumanAdminMayDelete() async throws {
    try await withSessionDeps {
      let w = try await GroupAdminRoutesTests().world()
      let machine = try await w.harness.space.machineFamily.addMachineV2(name: "box", group: w.group).machine
      let endpoint = "/v1/machine/" + machine.id.rawValue
      let other = try await w.harness.enrolledBearer()
      func request(_ bearer: String) -> Request {
        var request = Request(url: URL(string: "https://space.test" + endpoint)!, method: .delete)
        request.headers[.authorization] = "Bearer " + bearer
        request.headers["wuhu-group"] = w.group.rawValue
        return request
      }
      #expect(try await w.harness.api(request(other.bearer)).status == .forbidden)
      let session = try await w.harness.store.createSession(group: w.group, title: "Admin", kind: .agent, createdBy: "person", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      let exec = try await w.harness.space.machineFamily.reserveExec(machine: machine.id, caller: session.rawValue)
      let bearer = try await w.tokens.credential(session: session, exec: exec.id, timeout: nil, now: Date()).token
      #expect(try await w.harness.api(request(bearer)).status == .forbidden)
      #expect(try await w.harness.space.machineFamily.machine(machine.id) != nil)
      var fromShared = request(w.bearer)
      fromShared.headers["wuhu-group"] = GroupID.shared.rawValue
      #expect(try await w.harness.api(fromShared).status == .ok)
      #expect(try await w.harness.space.machineFamily.machine(machine.id) == nil)
      #expect(try await w.harness.api(request(w.bearer)).status == .notFound)
    }
  }
}
