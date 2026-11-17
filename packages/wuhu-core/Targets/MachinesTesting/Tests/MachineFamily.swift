import struct Credentials.SpaceSecretStores
import struct MachineContract.MachineID
import Machines
import MachinesContract
import SpaceCore
import Synchronization

/// The machine family on a test space: the cells and clients the family needs, registered on the space's worker so a
/// space opened bare hosts the machine kinds too.
extension Space {
  public nonisolated var machineFamily: Machines {
    machines(credentials: nil, secrets: nil)
  }

  /// The same space with the machine cells and clients registered on its worker.
  @discardableResult
  public nonisolated func registeringMachines() -> Space {
    machineFamily.register()
    return self
  }

  public nonisolated func machines(credentials: ExecCredentials?, secrets: SpaceSecretStores?) -> Machines {
    let machines = Machines(
      worker: worker, tenancy: tenancy, groups: groupClients, notes: groupNotes,
      sessions: { try? await self.sessions.record($0).summary }, credentials: credentials, secrets: secrets,
    )
    // A family reached before the worker starts hosts its kinds; one reached after can only read, and registering then
    // is a crash in Wuwei.
    if !worker.isStarted { machines.register() }
    return machines
  }
}

extension Machines {
  /// The family with the exec credentials and secret stores a hub needs, registered on the space's worker.
  public static func forTesting(_ space: Space, credentials: ExecCredentials? = nil, secrets: SpaceSecretStores? = nil) -> Machines {
    space.machines(credentials: credentials, secrets: secrets)
  }
}

public func machineHub(
  _ space: Space, credentials: ExecCredentials? = nil, secrets: SpaceSecretStores? = nil,
  revocationGate: @escaping @Sendable (MachineID) async -> Void = { _ in },
) -> MachineHub {
  MachineHub(machines: .forTesting(space, credentials: credentials, secrets: secrets), revocationGate: revocationGate)
}

extension MachineV2Upgrades {
  /// The policy read from a test space's settings group, as the server wires it.
  public convenience init(space: Space, serverVersion: String) {
    self.init(
      worker: space.worker,
      settings: { try? await space.fs(.settings).read(MachineUpgradeFile.path).1 },
      serverVersion: serverVersion,
    )
  }
}

/// Holds a test's client until the test opens it, and waits for that: a fetch that must not answer yet.
public final class Gate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let opened = Mutex(false)

  public init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  public var isOpen: Bool { opened.withLock { $0 } }

  public func open() {
    opened.withLock { $0 = true }
    continuation.finish()
  }

  public func wait() async {
    for await _ in stream {}
  }
}
