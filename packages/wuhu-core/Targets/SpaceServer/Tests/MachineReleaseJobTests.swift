import ControlledTime
import Fetch
import Foundation
import Scratch
@testable import SpaceServer
import Testing
import Wuwei

@Suite struct MachineReleaseJobTests {
  @Test(arguments: [UInt64(1), 2, 3, 4, 5])
  func completeAnswersAreFinal(_ seed: UInt64) throws {
    let f = try ReleaseSimulation(seed: seed, host: ReleaseHost(["1.2.3": both]))
    f.worker.send(.resolve("1.2.3"), to: MachineReleaseJob.singleton)
    f.run()
    #expect(f.answer == .published(ready("1.2.3").artifacts))
    f.simulation.run(for: .seconds(600))
    f.worker.send(.resolve("1.2.3"), to: MachineReleaseJob.singleton)
    f.run()
    #expect(f.host.count == 2)
    f.stop()
  }

  @Test(arguments: ["partial", "unpublished", "unreachable"])
  func nonfinalReleaseRetriesOnlyOnHelloAfterSixtySeconds(_ outcome: String) throws {
    let host = ReleaseHost(outcome == "partial" ? ["1.2.3": ["macos-arm64"]] : [:], mode: outcome == "unreachable" ? .fail : .serve)
    let f = try ReleaseSimulation(host: host)
    f.worker.send(.resolve("1.2.3"), to: MachineReleaseJob.singleton)
    f.run()
    let expected: MachineReleaseClient.Resolution = switch outcome {
    case "partial": .published(ready("1.2.3").artifacts.filter { $0.platform == "macos-arm64" })
    case "unpublished": .unpublished
    default: .unreachable
    }
    #expect(f.answer == expected)
    #expect(host.count == 2)
    f.simulation.run(for: .seconds(59))
    f.worker.send(.resolve("1.2.3"), to: MachineReleaseJob.singleton)
    f.run()
    #expect(host.count == 2)
    f.simulation.run(for: .seconds(1))
    #expect(host.count == 2)
    host.published.withLock { $0 = ["1.2.3": both] }
    host.mode.withLock { $0 = .serve }
    f.worker.send(.resolve("1.2.3"), to: MachineReleaseJob.singleton)
    f.run()
    #expect(host.count == 4)
    #expect(f.answer == .published(ready("1.2.3").artifacts))
    f.stop()
  }
}

private struct ReleaseSimulation {
  let simulation: Simulation
  let process: SimulatedProcess
  let folder: ScratchFolder
  let worker: Worker
  let host: ReleaseHost

  init(seed: UInt64 = 1, host: ReleaseHost) throws {
    simulation = Simulation(seed: seed)
    process = simulation.spawn()
    folder = try ScratchFolder("release-simulation")
    let database = try FileDatabase(path: folder.url.appending(path: "release.sqlite").path, synchronous: false)
    worker = Worker(id: "release", storage: .shared(database), scheduler: process, registrations: [.job(MachineReleaseJob.self)])
    self.host = host
    worker.provide(MachineReleaseClient(base: URL(string: "https://wuhu.ai")!, fetch: host.fetch, clock: host.clock))
    try worker.create(MachineReleaseJob.singleton, params: .init())
    worker.start()
  }

  var answer: MachineReleaseClient.Resolution? { worker.job(MachineReleaseJob.singleton).resolution(for: "1.2.3") }
  func run() { simulation.run(for: .zero) }
  func stop() {
    Task(executorPreference: process) {
      await worker.quiesce()
      worker.release()
    }
    run()
  }
}
