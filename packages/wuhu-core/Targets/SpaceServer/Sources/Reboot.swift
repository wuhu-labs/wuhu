#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import NIOCore

/// Main rebooting in place: the same process `execve`s this binary again,
/// keeping its two listening sockets open across it, so connections wait in
/// their backlog instead of being refused, and its worker processes stay its
/// children. What main holds only in memory crosses in a handover file.
public struct Reboot: Sendable {
  static let listenersVariable = "WUHU_LISTEN_FDS"
  static let handoverVariable = "WUHU_HANDOVER"

  let listeners: Listeners
  let handover: URL

  /// Becomes this binary again, with the same arguments; returns only when
  /// `execve` fails, with its error.
  public func exec() -> Int32 {
    listeners.inheritable()
    var environment = ProcessInfo.processInfo.environment
    environment[Self.listenersVariable] = "\(listeners.api),\(listeners.workers)"
    environment[Self.handoverVariable] = handover.path
    let argv = CommandLine.arguments.map { strdup($0) } + [nil]
    let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(currentExecutable(), argv, env)
    let failure = errno
    (argv + env).forEach { free($0) }
    listeners.closedOnExec()
    return failure
  }

  /// What the main before this one handed down, read once: the variables are
  /// cleared so no child sees them.
  static func inherited() -> (listeners: Listeners, handover: URL)? {
    let environment = ProcessInfo.processInfo.environment
    defer {
      unsetenv(listenersVariable)
      unsetenv(handoverVariable)
    }
    guard let fds = environment[listenersVariable]?.split(separator: ","), fds.count == 2,
          let api = CInt(fds[0]), let workers = CInt(fds[1]), let path = environment[handoverVariable]
    else { return nil }
    let listeners = Listeners(api: api, workers: workers)
    listeners.closedOnExec()
    return (listeners, URL(fileURLWithPath: path))
  }
}

/// Main's two listening sockets, held for the life of the process: the API's
/// TCP socket and the workers' Unix socket. A server serving one gets its
/// own duplicate; closing that leaves the socket listening.
struct Listeners: Sendable {
  let api: CInt
  let workers: CInt

  static func open(host: String, port: Int, workerSocket: String) throws -> Listeners {
    let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
    let api = try listening(address, family: address.protocol.rawValue)
    do {
      // A socket left by a main that is gone; a live main holds main.lock.
      unlink(workerSocket)
      let workers = try listening(SocketAddress(unixDomainSocketPath: workerSocket), family: AF_UNIX)
      guard chmod(workerSocket, 0o600) == 0 else { throw ListenerError(step: "chmod \(workerSocket)", code: errno) }
      return Listeners(api: api, workers: workers)
    } catch {
      close(api)
      throw error
    }
  }

  /// A duplicate of `socket` for a server to own, closed on `execve`.
  func lend(_ socket: CInt) throws -> CInt {
    let lent = fcntl(socket, F_DUPFD_CLOEXEC, 0)
    guard lent >= 0 else { throw ListenerError(step: "dup", code: errno) }
    return lent
  }

  func inheritable() {
    for fd in [api, workers] { _ = fcntl(fd, F_SETFD, 0) }
  }

  func closedOnExec() {
    for fd in [api, workers] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
  }

  private static func listening(_ address: SocketAddress, family: CInt) throws -> CInt {
    #if os(Linux)
      let fd = socket(family, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    #else
      let fd = socket(family, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { throw ListenerError(step: "socket", code: errno) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var one: CInt = 1
    if family != AF_UNIX { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<CInt>.size)) }
    let bound = address.withSockAddr { bind(fd, $0, socklen_t($1)) }
    guard bound == 0, listen(fd, 1024) == 0 else {
      let failure = ListenerError(step: "listen on \(address)", code: errno)
      close(fd)
      throw failure
    }
    return fd
  }
}

struct ListenerError: Error, CustomStringConvertible {
  let step: String
  let code: Int32
  var description: String { "\(step): \(String(cString: strerror(code)))" }
}

/// `<folder>/main.lock`, held for as long as a main serves the folder: a
/// second main started on it stops at once. `execve` lets go of it, and the
/// main that comes up takes it again.
enum MainLock {
  static func acquire(folder: URL) throws {
    let path = folder.appendingPathComponent("main.lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ListenerError(step: "open \(path)", code: errno) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw MainAlreadyRunning(folder: folder.path)
    }
    // Held until the process ends or execs.
  }
}

public struct MainAlreadyRunning: Error, CustomStringConvertible {
  public let folder: String
  public var description: String { "another main serves \(folder): it holds main.lock" }
}

/// What main holds in memory and the main it becomes takes over: the tokens
/// it issued, how many workers it has minted, its worker processes, and the
/// wakes parked sessions asked for.
struct Handover: Codable, Sendable {
  var tokens: ExecTokens.Table
  var minted: Int
  var workers: [ProcessWorkers.Child]
  /// Session id → when its wake is due, seconds since 1970.
  var wakes: [String: Double]

  func write(to url: URL) throws {
    let data = try JSONEncoder().encode(self)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ListenerError(step: "open \(url.path)", code: errno) }
    defer { close(fd) }
    let written = data.withUnsafeBytes { systemWrite(fd, $0.baseAddress, $0.count) }
    guard written == data.count else { throw ListenerError(step: "write \(url.path)", code: errno) }
  }

  /// Reads the handover and removes it: its tokens are good only once.
  static func take(from url: URL) throws -> Handover {
    defer { unlink(url.path) }
    return try JSONDecoder().decode(Handover.self, from: Data(contentsOf: url))
  }
}

private func systemWrite(_ fd: CInt, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
  write(fd, bytes, count)
}

/// The binary this process runs, to run it again.
func currentExecutable() -> String {
  #if os(Linux)
    return "/proc/self/exe"
  #else
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
    return String(cString: buffer)
  #endif
}
