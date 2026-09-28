import struct FetchSSE.SSEEvent
import struct SpaceClient.ObserveRequest
import struct SpaceClient.SpaceClient

extension Executor {
  mutating func observe(_ command: ObserveCommand, space: String) async throws {
    let events = try await self.authenticated(space).observe(command.request)
    if command.once {
      try await self.observeOnce(command, space: space, events: events)
      return
    }
    for try await event in events {
      await self.runner.stdout(event.data + "\n")
    }
  }

  private mutating func observeOnce(
    _ command: ObserveCommand,
    space: String,
    events: AsyncThrowingStream<SSEEvent, Error>,
  ) async throws {
    switch command.request.mode {
    case .glob:
      for try await event in events {
        await self.runner.stdout(event.data + "\n")
        return
      }
    case .sql:
      let previousHash = self.wallet.readObservationHash(space: space, mode: command.request.mode)
      for try await event in events {
        let hash = SHA256.hex(event.data)
        if hash == previousHash { continue }
        try self.wallet.writeObservationHash(hash, space: space, mode: command.request.mode)
        await self.runner.stdout(event.data + "\n")
        return
      }
    }
    throw CLIError(message: "observe ended without a new event")
  }
}
