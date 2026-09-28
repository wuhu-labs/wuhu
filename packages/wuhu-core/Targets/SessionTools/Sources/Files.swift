import Foundation
import struct MachineContract.Base64Data
import struct MachineContract.MachineEntry
import struct MachineContract.MachineID
import enum MachineContract.VFSDefaults
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceContract.ImageMedia
import SpaceCore
import SpaceFS
import SystemFiles

extension ToolExecutor {
  func read(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: ReadArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let address = try await resolve(arguments.path, as: session)
    if let mimeType = ImageMedia.mimeType(ofPath: address.rendered) {
      guard arguments.lines == nil else {
        throw ToolProblem("lines applies to text files; \(address.rendered) is an image")
      }
      let (revision, data) = try await readImage(address)
      let actual = ImageMedia.mimeType(ofBytes: data)
      guard actual == mimeType else {
        throw ToolProblem(
          "\(address.rendered) is named as \(mimeType) but its bytes are \(actual ?? "no image format read takes"); rename or convert it",
        )
      }
      let pixels = ImageMedia.pixelSize(ofBytes: data)
      try await deliverContext(session, callID, touching: address.folder, state: state)
      return .read(.init(
        path: address.rendered,
        revision: revision,
        content: "image \(mimeType), \(pixels.map { "\($0.width)x\($0.height) px, " } ?? "")\(data.count) bytes; delivered as an attached image",
        image: .init(mimeType: mimeType, source: .blob(try await space.storeImage(data)), byteCount: data.count, pixels: pixels),
      ))
    }
    let (revision, content) = try await readFile(address)
    let page = try readPage(content, lines: arguments.lines, path: address.rendered)
    try await deliverContext(session, callID, touching: address.folder, state: state)
    return .read(.init(path: address.rendered, revision: revision, content: page))
  }

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

  func write(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: WriteArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let address = try await resolve(arguments.path, as: session)
    try refuseSystem(address)
    if let recorded = try await store.receipt(session, toolCallID: callID) { return recorded }
    let logged = try loggedRevision(address, state: state)
    switch address {
    case let .space(path, group, _):
      return try await recordedSpaceWrite(
        session, callID,
        path: path,
        in: group,
        content: arguments.content,
        logged: logged,
        address: address,
        payload: { .write(.init(path: address.rendered, revision: .journal($0))) },
      )
    case let .machine(machine, path):
      try await guardMachineFile(machine, path: path, address: address, logged: logged)
      let revision = try await machineWrite(machine, path: path, bytes: Array(arguments.content.utf8))
      let payload = ToolResultPayload.write(.init(path: address.rendered, revision: revision))
      try await deliverContext(session, callID, touching: address.folder, state: state)
      try await store.recordReceipt(session, toolCallID: callID, payload: payload)
      return payload
    case .system:
      throw systemReadOnly(address)
    }
  }

  func edit(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: EditArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let address = try await resolve(arguments.path, as: session)
    try refuseSystem(address)
    if let recorded = try await store.receipt(session, toolCallID: callID) { return recorded }
    guard let logged = try loggedRevision(address, state: state) else {
      throw ToolProblem("you have not read \(address.rendered); read it before editing")
    }
    let (current, content) = try await readFile(address)
    guard current == logged else { throw staleProblem(address) }
    let edited = try apply(arguments.edits, to: content, path: address.rendered)
    switch address {
    case let .space(path, group, _):
      return try await recordedSpaceWrite(
        session, callID,
        path: path,
        in: group,
        content: edited,
        logged: logged,
        address: address,
        payload: { .edit(.init(path: address.rendered, revision: .journal($0))) },
      )
    case let .machine(machine, path):
      let revision = try await machineWrite(machine, path: path, bytes: Array(edited.utf8))
      let payload = ToolResultPayload.edit(.init(path: address.rendered, revision: revision))
      try await deliverContext(session, callID, touching: address.folder, state: state)
      try await store.recordReceipt(session, toolCallID: callID, payload: payload)
      return payload
    case .system:
      throw systemReadOnly(address)
    }
  }

  // MARK: - The fileAccessLog guard

  private func loggedRevision(
    _ address: Address,
    state: ToolExecutionState,
  ) throws(ToolProblem) -> FileRevision? {
    guard let logged = state.fileAccessLog[address.rendered] else { return nil }
    switch (address, logged) {
    case (.space, .journal), (.machine, .mtime), (.system, .journal):
      return logged
    case (.space, .mtime), (.machine, .journal), (.system, .mtime):
      throw ToolProblem("internal: logged revision kind does not match the backend of \(address.rendered)")
    }
  }

  func refuseSystem(_ address: Address) throws(ToolProblem) {
    if case .system = address { throw systemReadOnly(address) }
  }

  func systemReadOnly(_ address: Address) -> ToolProblem {
    ToolProblem(
      "\(address.rendered) is read-only: wuhu://system/ ships with the server; a skill with the same name in the space or your home replaces a system one",
    )
  }

  private func staleProblem(_ address: Address) -> ToolProblem {
    ToolProblem("\(address.rendered) changed since you read it; re-read it and retry")
  }

  private func recordedSpaceWrite(
    _ session: SessionID,
    _ callID: ToolCallID,
    path: String,
    in group: GroupID,
    content: String,
    logged: FileRevision?,
    address: Address,
    payload: @escaping @Sendable (Int64) -> ToolResultPayload,
  ) async throws -> ToolResultPayload {
    let ifMatchRev: Int64? = switch logged {
    case let .journal(rev): rev
    case .mtime, nil: nil
    }
    do {
      let recorded = try await store.recordedSpaceWrite(
        session,
        toolCallID: callID,
        path: path,
        in: group,
        content: Data(content.utf8),
        ifMatchRev: ifMatchRev,
        payload: payload,
      )
      return recorded.payload
    } catch let error as SpaceError {
      guard case .versionMismatch = error else { throw error }
      if logged == nil {
        throw ToolProblem("\(address.rendered) already exists; read it at its current revision before overwriting")
      }
      throw staleProblem(address)
    }
  }

  private func guardMachineFile(
    _ machine: MachineID,
    path: String,
    address: Address,
    logged: FileRevision?,
  ) async throws {
    let current = try await machineStat(machine, path: path)
    switch (logged, current) {
    case (nil, nil):
      break
    case (nil, .some):
      throw ToolProblem("\(address.rendered) already exists; read it at its current version before overwriting")
    case (.some, nil):
      throw staleProblem(address)
    case let (.mtime(read)?, entry?):
      guard Date(timeIntervalSince1970: entry.mtime) == read else { throw staleProblem(address) }
    case (.journal?, _):
      throw ToolProblem("internal: journal revision logged for machine path \(address.rendered)")
    }
  }

  // MARK: - Backends

  func readFile(_ address: Address) async throws -> (FileRevision, String) {
    let (revision, data) = try await readRaw(address)
    return (revision, try text(data, path: address.rendered))
  }

  private func readImage(_ address: Address) async throws -> (FileRevision, Data) {
    let tooLarge = { (size: Int) in
      ToolProblem("\(address.rendered) is \(size) bytes; read takes images up to \(ImageMedia.maxReadBytes) bytes")
    }
    guard case let .machine(machine, path) = address else {
      let (revision, data) = try await readRaw(address)
      guard data.count <= ImageMedia.maxReadBytes else { throw tooLarge(data.count) }
      return (revision, data)
    }
    guard let entry = try await machineStat(machine, path: path), entry.kind != .directory else {
      throw ToolProblem("\(address.rendered) is not a file on that machine")
    }
    guard entry.size <= ImageMedia.maxReadBytes else { throw tooLarge(entry.size) }
    guard let mtime = Double(entry.token) else {
      throw ToolProblem("machine minted a non-mtime token for \(path)")
    }
    let bytes = try await machineFile(machine, path: path, entry: entry, reference: address.rendered)
    return (.mtime(Date(timeIntervalSince1970: mtime)), Data(bytes))
  }

  func readRaw(_ address: Address) async throws -> (FileRevision, Data) {
    switch address {
    case let .space(path, group, _):
      let (token, data) = try await space.fs(group).read(path)
      guard let rev = spaceRev(token) else {
        throw ToolProblem("space fs minted a non-revision token for \(path)")
      }
      return (.journal(rev), data)
    case let .machine(machine, path):
      switch try await machineVFS(machine, .read(path: path)) {
      case let .file(token, data):
        guard let mtime = Double(token) else {
          throw ToolProblem("machine minted a non-mtime token for \(path)")
        }
        return (.mtime(Date(timeIntervalSince1970: mtime)), Data(data.bytes))
      case let .error(error):
        throw ToolProblem(error.message)
      default:
        throw ToolProblem("machine returned an unexpected read result for \(path)")
      }
    case let .system(path):
      // The binary's files have no revision; journal 0 keeps the access log
      // well-formed, and nothing writes there to check it against.
      return (.journal(0), try await SystemFiles.vfs.read(path).1)
    }
  }

  func machineWrite(_ machine: MachineID, path: String, bytes: [UInt8]) async throws -> FileRevision {
    if let parent = parent(of: path), parent != "/" {
      switch try await machineVFS(machine, .mkdir(path: parent)) {
      case .ok, .error:
        break
      default:
        throw ToolProblem("machine returned an unexpected mkdir result for \(parent)")
      }
    }
    switch try await machineVFS(machine, .write(path: path, data: Base64Data(bytes), ifMatch: nil)) {
    case let .written(token):
      guard let mtime = Double(token) else {
        throw ToolProblem("machine minted a non-mtime token for \(path)")
      }
      return .mtime(Date(timeIntervalSince1970: mtime))
    case let .error(error):
      throw ToolProblem(error.message)
    default:
      throw ToolProblem("machine returned an unexpected write result for \(path)")
    }
  }

  func machineStat(_ machine: MachineID, path: String) async throws -> MachineEntry? {
    switch try await machineVFS(machine, .stat(path: path)) {
    case let .entry(entry):
      return entry
    case let .error(error):
      guard error.code == .notFound else { throw ToolProblem(error.message) }
      return nil
    default:
      throw ToolProblem("machine returned an unexpected stat result for \(path)")
    }
  }

  // An agent built before ranged reads ignores the range and refuses a file
  // over one frame as tooLarge, which is how it is told apart.
  func machineFile(_ machine: MachineID, path: String, entry: MachineEntry, reference: String) async throws -> [UInt8] {
    guard entry.size > VFSDefaults.maxReadBytes else {
      return try await [UInt8](readRaw(.machine(machine, path)).1)
    }
    let changed = ToolProblem("\(reference) changed while it was being read; send it again")
    var bytes: [UInt8] = []
    bytes.reserveCapacity(entry.size)
    while bytes.count < entry.size {
      let length = min(VFSDefaults.maxReadBytes, entry.size - bytes.count)
      switch try await machineVFS(machine, .read(path: path, offset: bytes.count, length: length)) {
      case let .file(token, data):
        guard token == entry.token, data.bytes.count == length else { throw changed }
        bytes += data.bytes
      case let .error(error) where error.code == .tooLarge:
        throw ToolProblem(
          "\(reference) is \(entry.size) bytes and the machine agent there reads at most \(VFSDefaults.maxReadBytes) bytes of a file; upgrade the machine agent to attach files over 8 MiB",
        )
      case let .error(error):
        throw ToolProblem(error.message)
      default:
        throw ToolProblem("machine returned an unexpected read result for \(path)")
      }
    }
    // An agent built before ranged reads answers every range with the whole
    // file, and does so only once the file fits one frame. A file that shrank
    // to exactly one frame while keeping its mtime passes every check above;
    // only its size after the read tells.
    guard bytes.count == entry.size, let after = try await machineStat(machine, path: path),
          after.size == entry.size, after.token == entry.token else { throw changed }
    return bytes
  }

  func machineVFS(_ machine: MachineID, _ op: VFSOp) async throws -> VFSResult {
    guard let machines else {
      throw ToolProblem("no machine backend is available on this server")
    }
    return try await machines.vfs(machine, op)
  }

  private func apply(_ edits: [EditArguments.Edit], to content: String, path: String) throws(ToolProblem) -> String {
    guard !edits.isEmpty else { throw ToolProblem("edit needs at least one {old, new} pair") }
    var content = content
    for (index, edit) in edits.enumerated() {
      let position = "edit \(index + 1) of \(edits.count)"
      switch TextEdit.apply(content: content, old: edit.old, new: edit.new) {
      case let .success(edited):
        content = edited
      case .failure(.notFound):
        throw ToolProblem("\(position): old text not found in \(path); re-read the file and retry")
      case let .failure(.notUnique(count)):
        throw ToolProblem("\(position): old text matches \(count) times in \(path); widen old with surrounding context until it is unique")
      case .failure(.noChange):
        throw ToolProblem("\(position): old and new are identical")
      }
    }
    return content
  }
}

// A lossy decode of one screenshot once wedged a session beyond what
// compaction could fold: binary bytes never enter the transcript.
private func text(_ data: Data, path: String) throws(ToolProblem) -> String {
  guard let decoded = String(bytes: data, encoding: .utf8) else {
    throw ToolProblem("\(path) is not UTF-8 text (\(data.count) bytes); read and edit handle text files only")
  }
  return decoded
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

func spaceRev(_ token: VersionToken) -> Int64? {
  Int64(String(decoding: token.bytes, as: UTF8.self))
}
