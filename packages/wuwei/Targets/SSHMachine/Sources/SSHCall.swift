import Wuwei

/// Someone who runs commands through ``SSHCall`` and takes the replies as its own messages.
public protocol SSHCaller: Addressable {
  static func message(_ reply: SSHReply, call: String) -> Message
}

/// One command, from the caller's request to exactly one reply. A command that is not `retrySafe` is sent to the host once, ever; if no answer comes before the deadline, the reply is ``SSHReply/unknown(_:)``. A retry-safe one is sent again after a failover or a broken connection, until the deadline.
@Job
public struct SSHCall<Caller: SSHCaller> {
  public static var kind: String {
    "SSHCall.\(Caller.kind)"
  }

  public static var schema: [String] {
    ["CREATE TABLE call (deadline INTEGER NOT NULL, sent INTEGER NOT NULL DEFAULT 0)"]
  }

  public struct Params: Codable, Sendable {
    let host: String
    let command: String
    let retrySafe: Bool
    let timeout: Duration
    let replyTo: Caller.ID

    public init(host: String, command: String, retrySafe: Bool, timeout: Duration, replyTo: Caller.ID) {
      self.host = host
      self.command = command
      self.retrySafe = retrySafe
      self.timeout = timeout
      self.replyTo = replyTo
    }
  }

  public typealias Message = SSHReply

  public static func create(ctx: inout JobContext<Self>) throws {
    try ctx.db.execute("INSERT INTO call (deadline) VALUES (?)", .integer((ctx.now + ctx.params.timeout).milliseconds))
  }

  public mutating func start() async throws -> Outcome {
    let call = db.rows("SELECT deadline, sent FROM call")[0]
    let deadline = Instant(milliseconds: call["deadline"].integer!)
    if ctx.params.retrySafe || call["sent"].integer == 0 {
      try db.execute("UPDATE call SET sent = 1")
      send()
    }
    while true {
      let reply = try await ctx.receive(within: deadline - ctx.now) ?? .unknown("no reply within \(ctx.params.timeout)")
      if case .unknown = reply, ctx.params.retrySafe, ctx.now < deadline {
        send()
        continue
      }
      return .done(sending: Caller.message(reply, call: id.key), to: ctx.params.replyTo.recipient)
    }
  }

  private mutating func send() {
    let host = SSHHost.ID(ctx.params.host)
    ctx.create(host, params: ctx.params.host)
    ctx.send(SSHHost.Message(command: ctx.params.command, replyTo: id.recipient), to: host)
  }
}
