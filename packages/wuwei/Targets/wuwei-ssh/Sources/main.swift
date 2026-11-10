#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
import SSHMachine
import Wuwei

/// Takes the reply to one call and shows it, through the output gate like any other output.
@Cell
struct Terminal: SSHCaller {
  static func message(_ reply: SSHReply, call: String) -> Message {
    .reply(call, reply)
  }

  mutating func reply(_ call: String, _ reply: SSHReply) {
    let screen = ctx.dependency(Screen.self)
    ctx.emit { screen.show(call, reply) }
  }
}

struct Screen: Sendable {
  let show: @Sendable (_ call: String, _ reply: SSHReply) -> Void
}

let usage = """
usage: wuwei-ssh [--store PATH] run HOST COMMAND...   run a command at most once
       wuwei-ssh [--store PATH] cat HOST PATH         read a file, retried until it succeeds or times out
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var store = (ProcessInfo.processInfo.environment["HOME"] ?? ".") + "/.wuwei-ssh/store.sqlite"
if arguments.first == "--store", arguments.count > 1 {
  store = arguments[1]
  arguments.removeFirst(2)
}

guard arguments.count >= 3, ["run", "cat"].contains(arguments[0]) else {
  print(usage)
  exit(64)
}

let host = arguments[1]
let command = arguments[0] == "run" ? arguments[2...].joined(separator: " ") : "cat -- '\(arguments[2].replacing("'", with: "'\\''"))'"

try FileManager.default.createDirectory(atPath: String(store[..<(store.lastIndex(of: "/") ?? store.startIndex)]), withIntermediateDirectories: true)
let sockets = "/tmp/wuwei-ssh-\(getuid())"
try FileManager.default.createDirectory(atPath: sockets, withIntermediateDirectories: true)

let (replies, shown) = AsyncStream<(call: String, reply: SSHReply)>.makeStream()
var dependencies = Dependencies()
dependencies.register(SSHClient.openSSH(socketDirectory: sockets))
dependencies.register(Screen { shown.yield(($0, $1)) })
let worker = try Worker(
  id: "cli-\(UUID().uuidString.prefix(8))",
  storage: .layered(FileDatabase(path: store)),
  scheduler: LiveScheduler(),
  registrations: [.cell(Terminal.self), .job(SSHHost.self), .job(SSHCall<Terminal>.self)],
  dependencies: dependencies,
)
worker.start()

let call = UUID().uuidString
try worker.create(
  SSHCall<Terminal>.ID(call),
  params: .init(host: host, command: command, retrySafe: arguments[0] == "cat", timeout: .seconds(30), replyTo: Terminal.ID(call)),
)
var status: Int32 = 1
for await shown in replies where shown.call == call {
  switch shown.reply {
  case let .output(output):
    print(output.stdout, terminator: "")
    _ = Array(output.stderr.utf8).withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
    status = output.status
  case let .unreachable(reason):
    print("not run: \(reason)")
  case let .unknown(reason):
    print("outcome unknown, it may have run: \(reason)")
  }
  break
}

await worker.drain()
exit(status)
