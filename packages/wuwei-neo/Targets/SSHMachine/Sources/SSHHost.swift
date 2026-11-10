import WuweiNeo

/// Holds one host's SSH connection and runs the commands mailed to it, one at a time. Taking a request deletes its mail row, and the output gate makes that durable before the command leaves, so no command runs twice. After a minute without requests it closes the connection and hibernates.
@Job
public struct SSHHost {
  public typealias Params = String

  public struct Message: Codable, Sendable {
    let command: String
    let replyTo: Recipient<SSHReply>
  }

  public final class State {
    var connection: SSHConnection?
  }

  public static func hydrate(ctx _: inout JobContext<Self>) throws -> State {
    State()
  }

  public mutating func start() async throws -> Outcome {
    while let request = try await ctx.receive(within: .seconds(60)) {
      ctx.send(await run(request.command), to: request.replyTo)
    }
    if let connection = state.connection {
      try await ctx.effect { await connection.close() }
    }
    return .hibernate
  }

  private func run(_ command: String) async -> SSHReply {
    if state.connection == nil {
      do {
        let client = ctx.dependency(SSHClient.self)
        let host = ctx.params
        state.connection = try await ctx.effect { try await client.connect(host) }
      } catch {
        return .unreachable("\(error)")
      }
    }
    let connection = state.connection!
    do {
      return try await .output(ctx.effect { try await connection.run(command) })
    } catch {
      state.connection = nil
      return .unknown("\(error)")
    }
  }
}
