#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct MachineContract.MachineID
import enum MainHub.Address
import enum MainHub.Addressing
import struct MainHub.ToolProblem
import SessionDomain
import SpaceClient
import struct SpaceContract.EditOutput
import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize
import struct SpaceContract.ReadOutput
import struct SpaceContract.WriteOutput

// The agent's file tools, run in the worker over main's API. The fold's
// fileAccessLog is the guard: a read records the version token main answered,
// a write or edit sends it back as `ifMatch`, and main knows nothing else of
// the loop. Main answers a repeated write or edit (same tool call id) with its
// first response, so a retry after a crash never fails as stale.
extension ToolExecutor {
  func read(_ session: SessionID, _ arguments: ReadArguments) async throws -> ToolResultPayload {
    let address = try address(arguments.path)
    if case .system = address {} else if ImageMedia.mimeType(ofPath: address.rendered) != nil, arguments.lines != nil {
      throw ToolProblem("lines applies to text files; \(address.rendered) is an image")
    }
    let main = try await client(session)
    let output: ReadOutput = try await main.tool("read", .object(["path": .string(address.rendered), "image": .bool(true)]))
    let revision = try revision(output.token, at: address)
    // Main checked an image's bytes and stored them; the transcript keeps the hash.
    if let image = output.image {
      let pixels: PixelSize? = if let width = image.width, let height = image.height { PixelSize(width: width, height: height) } else { nil }
      return .read(.init(
        path: address.rendered,
        revision: revision,
        content: output.content,
        image: .init(mimeType: image.mimeType, source: .blob(image.blob), byteCount: image.byteCount, pixels: pixels),
      ))
    }
    let page = try readPage(output.content, lines: arguments.lines, path: address.rendered)
    return .read(.init(path: address.rendered, revision: revision, content: page))
  }

  func write(_ session: SessionID, _ call: String, _ arguments: WriteArguments, state: ToolExecutionState) async throws -> ToolResultPayload {
    let address = try address(arguments.path)
    try Addressing.refuseSystem(address)
    let logged = try loggedRevision(address, state: state)
    // Without a read there is no version to match: the write may only create.
    let guarded: (field: String, value: JSONValue) = logged.map { ("ifMatch", .string(token($0))) } ?? ("createOnly", .bool(true))
    let input: JSONValue = .object(["path": .string(address.rendered), "content": .string(arguments.content), guarded.field: guarded.value])
    let main = try await client(session, toolCall: call)
    let output: WriteOutput = try await versioned(address, logged: logged) { try await main.tool("write", input) }
    return .write(.init(path: address.rendered, revision: try revision(output.token, at: address)))
  }

  func edit(_ session: SessionID, _ call: String, _ arguments: EditArguments, state: ToolExecutionState) async throws -> ToolResultPayload {
    let address = try address(arguments.path)
    try Addressing.refuseSystem(address)
    guard let logged = try loggedRevision(address, state: state) else {
      throw ToolProblem("you have not read \(address.rendered); read it before editing")
    }
    guard !arguments.edits.isEmpty else { throw ToolProblem("edit needs at least one {old, new} pair") }
    let input: JSONValue = .object([
      "path": .string(address.rendered),
      "edits": .array(arguments.edits.map { .object(["old": .string($0.old), "new": .string($0.new)]) }),
      "ifMatch": .string(token(logged)),
    ])
    let main = try await client(session, toolCall: call)
    let output: EditOutput = try await versioned(address, logged: logged) { try await main.tool("edit", input) }
    return .edit(.init(path: address.rendered, revision: try revision(output.token, at: address)))
  }

  // A machine name the roster knows was swapped for its id before the call
  // reached here; a host that is neither names no machine.
  private func address(_ raw: String) throws -> Address {
    if let host = Addressing.machineHost(raw), !host.isEmpty, !MachineID.isValid(host) {
      throw ToolProblem("unknown machine: \(host)")
    }
    return try Addressing.parse(raw)
  }

  // MARK: - Versions

  /// The logged version of `address`, which must be of the address's kind.
  private func loggedRevision(_ address: Address, state: ToolExecutionState) throws(ToolProblem) -> FileRevision? {
    guard let logged = state.fileAccessLog[address.rendered] else { return nil }
    switch (address, logged) {
    case (.space, .journal), (.machine, .mtime), (.machine, .machine), (.system, .journal):
      return logged
    case (.space, .mtime), (.space, .machine), (.machine, .journal), (.system, .mtime), (.system, .machine):
      throw ToolProblem("internal: logged revision kind does not match the backend of \(address.rendered)")
    }
  }

  // Main's version token for `address`: a space file's journal revision, a
  // machine file's mtime or the opaque token its agent minted; the binary's
  // files have no revision, and journal 0 keeps the access log well-formed.
  private func revision(_ token: String, at address: Address) throws(ToolProblem) -> FileRevision {
    switch address {
    case .space:
      guard let rev = Int64(token) else { throw ToolProblem("main minted a non-revision token for \(address.rendered)") }
      return .journal(rev)
    case .machine:
      if let mtime = Double(token), mtime.isFinite { return .mtime(Date(timeIntervalSince1970: mtime)) }
      return .machine(token)
    case .system:
      return .journal(0)
    }
  }

  private func token(_ revision: FileRevision) -> String {
    switch revision {
    case let .journal(rev): String(rev)
    case let .mtime(date): String(date.timeIntervalSince1970)
    case let .machine(token): token
    }
  }

  // A version conflict is told by the fold, not by main: without a logged read
  // the file was not there to be replaced; with one, it moved since.
  private func versioned<Output>(_ address: Address, logged: FileRevision?, _ run: () async throws -> Output) async throws -> Output {
    do {
      return try await run()
    } catch let failure as SpaceClient.ToolFailure where failure.error.code == .conflict {
      guard logged != nil else {
        throw ToolProblem("\(address.rendered) already exists; read it at its current revision before overwriting")
      }
      throw ToolProblem("\(address.rendered) changed since you read it; re-read it and retry")
    }
  }

  // MARK: - Paging

  private func readPage(_ content: String, lines: String?, path: String) throws(ToolProblem) -> String {
    var requested: ClosedRange<Int>?
    if let lines { requested = try readLineRange(lines) }
    let sliced: String
    let first: Int
    if let requested {
      let all = content.split(separator: "\n", omittingEmptySubsequences: false)
      guard requested.lowerBound <= all.count else {
        throw ToolProblem("lines \(rendered(requested)) is beyond the end of \(path) (\(all.count) lines)")
      }
      sliced = all[(requested.lowerBound - 1) ... min(requested.upperBound, all.count) - 1].joined(separator: "\n")
      first = requested.lowerBound
    } else {
      sliced = content
      first = 1
    }
    let clamp = ToolOutput.head(sliced)
    guard clamp.clamped else { return clamp.text }
    guard let shown = clamp.shownLines else {
      return clamp.text + "\n\n[line \(first) is \(clamp.totalBytes) bytes; showing its head. Slice long lines with exec instead.]"
    }
    let last = first + shown.upperBound - 1
    let extent = requested == nil ? " of \(clamp.totalLines)" : ""
    return clamp.text
      + "\n\n[showing lines \(first)-\(last)\(extent); pass lines: \"\(last + 1)-\" to continue]"
  }
}

// "A-B" reads a closed range; "A-" reads to the end of the file.
private func readLineRange(_ spec: String) throws(ToolProblem) -> ClosedRange<Int> {
  let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
  guard parts.count == 2, let lower = Int(parts[0]), lower >= 1 else {
    throw ToolProblem("lines must be \"A-B\" or \"A-\" with 1 <= A <= B, got \"\(spec)\"")
  }
  guard !parts[1].isEmpty else { return lower ... Int.max }
  guard let upper = Int(parts[1]), upper >= lower else {
    throw ToolProblem("lines must be \"A-B\" or \"A-\" with 1 <= A <= B, got \"\(spec)\"")
  }
  return lower ... upper
}

private func rendered(_ range: ClosedRange<Int>) -> String {
  range.upperBound == Int.max ? "\(range.lowerBound)-" : "\(range.lowerBound)-\(range.upperBound)"
}
