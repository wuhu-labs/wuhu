@testable import Machines
import MachinesTesting
@testable import SpaceCore
import Wuwei
import WuweiQueries

func watchSpaceTables(_ tables: [String], in space: Space) async -> (changes: AsyncStream<Void>, cancel: @Sendable () -> Void) {
  let (changes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let cancel = await space.observations.regions(tables, wake)
  wake.yield(())
  return (changes, cancel)
}

func testFileOperations(in space: Space) async throws -> [(machine: String, row: MachineFileOperation)] {
  let machines = try await space.machineFamily.machines()
  return space.worker.read { reader in
    machines.flatMap { machine in
      reader.cell(MachineCell.ID(machine.id.rawValue)).fileOperationsForTest().map { (machine.id.rawValue, $0) }
    }
  }
}

extension MachineCell {
  func fileOperationsForTest() -> [MachineFileOperation] { db.rows(MachineFileOperation.all) }
}

func waitForMachineDescription(_ cell: MachineCell.ID, in space: Space) async throws {
  let watch = await watchSpaceTables(["machine_presence"], in: space)
  defer { watch.cancel() }
  for await _ in watch.changes {
    if space.worker.cell(cell).db.rows(MachinePresence.all).first?.state == "attached" { return }
  }
  try Task.checkCancellation()
  throw CancellationError()
}
