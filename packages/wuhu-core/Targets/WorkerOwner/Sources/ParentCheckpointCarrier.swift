#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct ParentCheckpointCarrierError: Error, Equatable, Sendable {
  enum Code: Equatable, Sendable { case unprovenCredentialFreedom, io, shortRead, oversized, invalidFrame, closeFailed }
  let code: Code
}

final class ParentCheckpointCarrier: Sendable {
  let descriptor: Int32
  private static let header = Data("WUHUCP01".utf8)

  private init(descriptor: Int32) { self.descriptor = descriptor }
  deinit { _ = close(descriptor) }

  static func export(_ checkpoint: ParentExecCheckpoint) throws -> ParentCheckpointCarrier {
    try requireCredentialFree(checkpoint)
    let payload = try checkpoint.encode()
    let carrier = try empty()
    var length = UInt64(payload.count).bigEndian
    var frame = header
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    try frame.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = pwrite(carrier.descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written, off_t(written))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw failure(.io) }
        written += count
      }
    }
    return carrier
  }

  static func take(_ descriptor: Int32, expecting identity: ParentExecCheckpoint.Identity) throws -> ParentExecCheckpoint {
    try take(descriptor, expecting: identity, closeDescriptor: { close($0) })
  }

  static func take(_ descriptor: Int32, expecting identity: ParentExecCheckpoint.Identity, closeDescriptor: (Int32) -> Int32) throws -> ParentExecCheckpoint {
    var ownsDescriptor = true
    defer { if ownsDescriptor { _ = close(descriptor) } }
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw failure(.io) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 0 else { throw failure(.invalidFrame) }
    let prefix = try read(descriptor, count: 16, offset: 0)
    guard prefix.prefix(8) == header else { throw failure(.invalidFrame) }
    let length = prefix.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard length <= ParentExecCheckpoint.maximumBytes else { throw failure(.oversized) }
    guard info.st_size >= 16 + Int64(length) else { throw failure(.shortRead) }
    guard info.st_size == 16 + Int64(length) else { throw failure(.invalidFrame) }
    let checkpoint = try ParentExecCheckpoint.decode(read(descriptor, count: Int(length), offset: 16), expecting: identity)
    try requireCredentialFree(checkpoint)
    // A close attempt relinquishes ownership even on EINTR, which therefore counts as closed. Its number may be reused at once by another thread, so close's result is the only evidence.
    ownsDescriptor = false
    guard closeDescriptor(descriptor) == 0 || errno == EINTR else { throw failure(.closeFailed) }
    return checkpoint
  }

  static func empty() throws -> ParentCheckpointCarrier {
    let path = "/tmp/wuhu-checkpoint-\(UUID().uuidString)"
    let descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw failure(.io) }
    guard unlink(path) == 0 else { _ = close(descriptor); throw failure(.io) }
    return ParentCheckpointCarrier(descriptor: descriptor)
  }

  private static func read(_ descriptor: Int32, count: Int, offset: Int) throws -> Data {
    var bytes = Data(count: count)
    try bytes.withUnsafeMutableBytes { buffer in
      var received = 0
      while received < count {
        let next = pread(descriptor, buffer.baseAddress!.advanced(by: received), count - received, off_t(offset + received))
        if next < 0, errno == EINTR { continue }
        guard next >= 0 else { throw failure(.io) }
        guard next > 0 else { throw failure(.shortRead) }
        received += next
      }
    }
    return bytes
  }

  private static func requireCredentialFree(_ checkpoint: ParentExecCheckpoint) throws {
    // Opaque payloads, fault text, tracing baggage and reader values cannot prove credential freedom.
    guard checkpoint.execution.readers.isEmpty,
          (checkpoint.execution.attempts ?? []).allSatisfy({ credentialFreeSessionID($0.session.rawValue) }) else { throw failure(.unprovenCredentialFreedom) }
    for entry in checkpoint.execution.receipts.clients.flatMap(\.entries) {
      let call = entry.call
      guard call.operation == "runtime.schedule-warming", call.traceContext == nil,
            let request = try? ownerDecode(WarmingRequest.self, call.payload),
            UUID(uuidString: request.session.rawValue)?.uuidString == request.session.rawValue,
            call.payload == (try? ownerEncode(request)), entry.reply.error == nil,
            entry.reply.result == .object(["value": .bool(true)])
      else { throw failure(.unprovenCredentialFreedom) }
    }
  }

  private static func credentialFreeSessionID(_ value: String) -> Bool {
    if UUID(uuidString: value)?.uuidString == value { return true }
    let words = value.split(separator: "-", omittingEmptySubsequences: false)
    return (3 ... 8).contains(words.count) && words.allSatisfy { word in
      (1 ... 16).contains(word.utf8.count) && word.utf8.allSatisfy { (97 ... 122).contains($0) }
    }
  }

  private static func failure(_ code: ParentCheckpointCarrierError.Code) -> ParentCheckpointCarrierError { .init(code: code) }
}
