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
import Testing
import class WorkerProtocol.WorkerListener
import struct WorkerProtocol.WorkerProtocolError

enum ListenerScenario: String, CaseIterable {
  case readinessFailure, queuedExport, serve, replacementShutdown, descriptorIdentity, pathIdentity, replacedPath, wrongPath
  case regularFile, datagram, notListening, unsafeDirectory, unsafeSocket, symlink
}

@Suite(.enabled(if: !carrierFixtureRequested), .serialized, .timeLimit(.minutes(2))) struct ListenerAdoptionTests {
  @Test func execServesInheritedListenerWithoutRebinding() async throws {
    try await Task.detached { try exerciseListener(.serve) }.value
  }

  @Test(arguments: ListenerScenario.allCases.filter { $0 != .serve && $0 != .queuedExport && $0 != .readinessFailure }) func execValidatesAndOwnsListener(scenario: ListenerScenario) async throws {
    try await Task.detached { try exerciseListener(scenario) }.value
  }
}

private func exerciseListener(_ scenario: ListenerScenario) throws {
  let directory = "/tmp/listener-" + UUID().uuidString
  try #require(mkdir(directory, 0o700) == 0)
  let path = directory + "/owner.sock"
  defer { _ = unlink(path); _ = unlink(directory + "/old.sock"); _ = unlink(directory + "/regular"); _ = rmdir(directory) }
  let source = try rawListener(path: path, datagram: scenario == .datagram, listening: scenario != .notListening)
  defer { _ = close(source) }
  var fdState = stat(), pathState = stat()
  try #require(fstat(source, &fdState) == 0)
  try #require(lstat(path, &pathState) == 0)
  var descriptor = source
  if scenario == .regularFile {
    descriptor = open(directory + "/regular", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    try #require(descriptor >= 0)
    try #require(fstat(descriptor, &fdState) == 0)
  }
  defer { if descriptor != source { _ = close(descriptor) } }
  if scenario == .replacedPath {
    try #require(unlink(path) == 0)
    let replacement = try rawListener(path: path)
    try #require(close(replacement) == 0)
  }
  if scenario == .symlink {
    try #require(rename(path, directory + "/old.sock") == 0)
    try #require(symlink(directory + "/old.sock", path) == 0)
  }
  if scenario == .unsafeDirectory { try #require(chmod(directory, 0o755) == 0) }
  if scenario == .unsafeSocket { try #require(chmod(path, 0o666) == 0) }
  let metadata = [
    "PATH": scenario == .wrongPath ? directory + "/other.sock" : path,
    "SCENARIO": scenario.rawValue,
    "FD_DEVICE": String(UInt64(truncatingIfNeeded: fdState.st_dev)),
    "FD_INODE": String(UInt64(truncatingIfNeeded: fdState.st_ino) + (scenario == .descriptorIdentity ? 1 : 0)),
    "PATH_DEVICE": String(UInt64(truncatingIfNeeded: pathState.st_dev)),
    "PATH_INODE": String(UInt64(truncatingIfNeeded: pathState.st_ino) + (scenario == .pathIdentity ? 1 : 0)),
  ]
  try #require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
  try #require(try spawnCarrierTest(mode: "listener", descriptor: descriptor, mapping: true, listenerEnvironment: metadata) == 0)
  try #require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
}

func runListenerAdoptionFixture(descriptor: Int32) async throws {
  let environment = ProcessInfo.processInfo.environment
  let path = try #require(environment["WUHU_LISTENER_TEST_PATH"])
  let scenario = try #require(environment["WUHU_LISTENER_TEST_SCENARIO"].flatMap(ListenerScenario.init(rawValue:)))
  func number(_ key: String) throws -> UInt64 { try #require(environment["WUHU_LISTENER_TEST_" + key].flatMap(UInt64.init)) }
  let identity = try WorkerListener.InheritedIdentity(descriptorDevice: number("FD_DEVICE"), descriptorInode: number("FD_INODE"), pathDevice: number("PATH_DEVICE"), pathInode: number("PATH_INODE"))
  let file = try DescriptorFile(of: descriptor)
  var before = stat()
  let existed = lstat(path, &before) == 0
  if scenario == .queuedExport {
    try await runQueuedExportFixture(descriptor: descriptor, path: path, identity: identity)
    return
  }
  if scenario == .readinessFailure {
    let listener = try await WorkerListener.adopt(descriptor, socket: path, expecting: identity) { _ in .text("uncommitted-successor") }
    let wrong = WorkerListener.InheritedIdentity(descriptorDevice: identity.descriptorDevice, descriptorInode: identity.descriptorInode + 1, pathDevice: identity.pathDevice, pathInode: identity.pathInode)
    await #expect(throws: WorkerProtocolError.self) { try await listener.commitHandoff(.init(socket: path, identity: wrong)) }
    try await listener.pauseAccepting()
    await #expect(throws: WorkerProtocolError.self) { try await listener.exportListener() }
    try await listener.resumeAccepting()
    let proof: Result<String, any Error>
    do { proof = .success(try await Task.detached { try requestListener(path: path) }.value) }
    catch { proof = .failure(error) }
    await listener.shutdown()
    try #require(try proof.get().hasSuffix("uncommitted-successor"))
    var after = stat()
    try #require(lstat(path, &after) == 0 && after.st_dev == before.st_dev && after.st_ino == before.st_ino)
    return
  }
  if scenario != .serve, scenario != .replacementShutdown {
    do {
      let listener = try await WorkerListener.adopt(descriptor, socket: path, expecting: identity) { _ in
        Issue.record("Refused descriptor served a request")
        return .text("unexpected")
      }
      await listener.shutdown()
      Issue.record("Invalid listener was adopted")
    } catch let error as WorkerProtocolError {
      try #require(error.code == .invalidConfiguration)
    }
    try #require(released(descriptor, from: file))
    var after = stat()
    try #require((lstat(path, &after) == 0) == existed)
    if existed { try #require(after.st_ino == before.st_ino && after.st_dev == before.st_dev && after.st_mode == before.st_mode) }
    try #require(try spawnCarrierTest(mode: "absent", descriptor: descriptor, file: file) == 0)
    return
  }
  let listener = try await WorkerListener.adopt(descriptor, socket: path, expecting: identity) { _ in .text("adopted-listener") }
  try await listener.commitHandoff(.init(socket: path, identity: identity))
  let result: Result<Void, any Error>
  var replacement: Int32 = -1
  do {
    try #require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    var after = stat()
    try #require(lstat(path, &after) == 0 && after.st_ino == before.st_ino && after.st_dev == before.st_dev)
    try #require(try await Task.detached { try requestListener(path: path) }.value.hasSuffix("adopted-listener"))
    try #require(try spawnCarrierTest(mode: "absent", descriptor: descriptor, file: file) == 0)
    if scenario == .replacementShutdown {
      try #require(unlink(path) == 0)
      replacement = try rawListener(path: path)
    }
    result = .success(())
  } catch { result = .failure(error) }
  await listener.shutdown()
  await listener.shutdown()
  try result.get()
  try #require(released(descriptor, from: file))
  var final = stat()
  if replacement >= 0 {
    defer { _ = close(replacement); _ = unlink(path) }
    try #require(lstat(path, &final) == 0)
    try #require(final.st_ino != before.st_ino || final.st_dev != before.st_dev)
  } else {
    try #require(lstat(path, &final) == -1 && errno == ENOENT)
  }
}

func rawListener(path: String, datagram: Bool = false, listening: Bool = true) throws -> Int32 {
  #if os(Linux)
    let type = Int32(datagram ? SOCK_DGRAM.rawValue : SOCK_STREAM.rawValue)
  #else
    let type = datagram ? SOCK_DGRAM : SOCK_STREAM
  #endif
  let descriptor = socket(AF_UNIX, type, 0)
  try #require(descriptor >= 0)
  do {
    try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
    var address = try unixAddress(path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(bound == 0)
    try #require(chmod(path, 0o600) == 0)
    if !datagram, listening { try #require(listen(descriptor, 16) == 0) }
    return descriptor
  } catch { _ = close(descriptor); throw error }
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  #if !os(Linux)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  #endif
  try path.utf8CString.withUnsafeBytes { pathBytes in
    try withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      try #require(pathBytes.count <= bytes.count)
      bytes.copyBytes(from: pathBytes)
    }
  }
  return address
}

func requestListener(path: String) throws -> String {
  let descriptor = try sendListenerRequest(path: path)
  defer { _ = close(descriptor) }
  return try readListenerResponse(descriptor)
}

func sendListenerRequest(path: String, route: String = "/", method: String = "GET", body: String = "", headers: String = "") throws -> Int32 {
  #if os(Linux)
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
  #else
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  #endif
  try #require(descriptor >= 0)
  var succeeded = false
  defer { if !succeeded { _ = close(descriptor) } }
  try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
  var timeout = timeval(tv_sec: 10, tv_usec: 0)
  try #require(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
  try #require(setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
  var address = try unixAddress(path)
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  try #require(connected == 0)
  let request = Array("\(method) \(route) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
  try #require(request.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == request.count)
  succeeded = true
  return descriptor
}

func readListenerResponse(_ descriptor: Int32) throws -> String {
  var response: [UInt8] = []
  var bytes = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    try #require(count >= 0)
    if count == 0 { break }
    response.append(contentsOf: bytes.prefix(count))
    try #require(response.count < 16384)
  }
  let text = String(decoding: response, as: UTF8.self)
  try #require(text.hasPrefix("HTTP/1.1 200"))
  return text
}
