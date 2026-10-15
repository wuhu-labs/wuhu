#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.ProviderUsage
import struct SpaceContract.UsageWindow
import Synchronization
import struct WorkerOwner.RemoteExecutionOwner

final class WorkerUsageMirror: Sendable {
  let board = UsageBoard()
  private let failure = Mutex<(any Error)?>(nil)
  private let owner: RemoteExecutionOwner
  init(owner: RemoteExecutionOwner) { self.owner = owner }
  func synchronize() async throws {
    if let error = failure.withLock({ $0 }) { throw error }
    board.merge(try await owner.runtimeUsage())
  }

  func record(_ provider: String, plan: String?, windows: [UsageWindow], at date: Date) async {
    guard !windows.isEmpty else { return }
    board.record(provider, plan: plan, windows: windows, at: date)
    do { try await owner.recordRuntimeUsage(provider, usage: ProviderUsage(plan: plan, windows: windows, observedAt: date.timeIntervalSince1970)) }
    catch { failure.withLock { if $0 == nil { $0 = error } } }
  }
}
