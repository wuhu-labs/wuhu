import ControlledTime
import Dependencies
import DeterministicDependencies
import Foundation
import MachineContract
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineReleaseRolloverTests {
  @Test func inFlightLookupRollsOverToOneResolutionRow() async throws {
    try await rolling { old, new, time in
      let first = ReleaseHost(["1.2.3": both], mode: .hold)
      try install(old, first)
      old.worker.start()
      await first.lookedUp(2)
      try await assertRow(old, requested: true, lookedUp: false)

      let second = ReleaseHost(["1.2.3": both])
      try install(new, second)
      new.worker.start()
      #expect(second.count == 0)
      await old.stopWorker()
      try await time.wake("the successor scans after release", after: 1)
      try await releaseSettled(new, "1.2.3")
      #expect(first.count == 2)
      #expect(second.count == 2)
      try await assertRow(new, requested: false, lookedUp: true)
      let answer = await MachineV2Upgrades(space: new, serverVersion: "1.2.3").announcement(for: MachineID(rawValue: "mc_abcdefgh"))
      #expect(answer == ready("1.2.3"))
    }
  }

  @Test func publishedRowSurvivesRolloverWithoutAnotherLookup() async throws {
    try await rolling { old, new, time in
      let first = ReleaseHost(["1.2.3": both])
      try install(old, first)
      old.worker.start()
      try await releaseSettled(old, "1.2.3")
      let second = ReleaseHost(mode: .fail)
      try install(new, second)
      new.worker.start()
      await old.stopWorker()
      try await time.wake("the successor scans after release", after: 1)
      try await releaseSettled(new, "1.2.3")
      #expect(first.count == 2)
      #expect(second.count == 0)
      try await assertRow(new, requested: false, lookedUp: true)
      let answer = await MachineV2Upgrades(space: new, serverVersion: "1.2.3").announcement(for: MachineID(rawValue: "mc_abcdefgh"))
      #expect(answer == ready("1.2.3"))
    }
  }

  private func install(_ space: Space, _ host: ReleaseHost) throws {
    try registerMachineReleases(space: space, version: "1.2.3", client: MachineReleaseClient(base: URL(string: "https://wuhu.ai")!, fetch: host.fetch, clock: host.clock))
  }

  private func assertRow(_ space: Space, requested: Bool, lookedUp: Bool) async throws {
    try RawDatabase.open(space.databasePath) { db in
      let rows = try db.rows("SELECT owner, version, requested, looked_up_at FROM machine_release_resolutions")
      #expect(rows.count == 1)
      let row = try #require(rows.first)
      let owner: String = row["owner"]
      let version: String = row["version"]
      let storedRequested: Bool = row["requested"]
      let lookedUpAt: Int64? = row["looked_up_at"]
      #expect(owner == "releases")
      #expect(version == "1.2.3")
      #expect(storedRequested == requested)
      #expect((lookedUpAt != nil) == lookedUp)
    }
  }

  private func rolling(_ body: (Space, Space, TimeControl) async throws -> Void) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let folder = try ScratchFolder("machine-release-rollover")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      do {
        try await body(old, new, time)
      } catch {
        try await old.close()
        try await new.close()
        throw error
      }
      try await old.close()
      try await new.close()
    }
  }
}
