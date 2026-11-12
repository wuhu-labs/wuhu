import struct Foundation.Data
import JSONValue
import MachineContract
import SpaceContract
import SpaceCore

/// The most a copy lands in the space: it is held whole before one write.
let copySpaceBytes = 64 << 20

extension SpaceToolbox {
  static let copy = SpaceTool("copy", schema: CopyInput.jsonSchema) { (context, input: CopyInput) in
    let from = try await context.resolve(input.from)
    let to = try await context.resolve(input.to)
    guard from.machine != nil || to.machine != nil, let machines = context.machines else {
      throw ToolRunError.failed(code: .unsupported, message: "copy moves a file onto or off a machine: \(input.from) -> \(input.to)", hint: "between space paths, read and write")
    }
    if to.system { throw SpaceError.systemReadOnly(input.to) }
    let replace = input.overwrite == true
    var restarted = false
    while true {
      do {
        let source: CopySource
        if let machine = from.machine {
          source = .machine(machine, path: from.path)
        } else {
          let (_, data) = try await context.read(from, upTo: copySpaceBytes) { size in
            .failed(code: .byteLimitExceeded, message: "\(input.from) is \(size) bytes; copy takes at most \(copySpaceBytes) bytes from the space", hint: nil)
          }
          source = .bytes([UInt8](data))
        }
        if let machine = to.machine {
          let receipt = try await machines.copy(source, .machine(machine, path: to.path, replace: replace))
          guard case let .machine(token) = receipt.landing else { throw ToolRunError.failed(code: .internal, message: "copy landed off its target", hint: nil) }
          return output(receipt, token: token)
        }
        guard input.to.firstIndex(of: "@") == nil, let group = to.group else {
          throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(input.to)", hint: "Historical views are read-only.")
        }
        let path = try context.spacePath(to.path)
        try await SpaceView.requireReadable(group, by: context.principal.group, actor: context.principal.actor, path: path.rawValue, in: context.space)
        try await context.refuseWrite(path, in: group)
        if !replace, (try? await to.backend.stat(to.path)) != nil { throw CopyRefusal.targetExists }
        let receipt = try await machines.copy(source, .caller(limit: copySpaceBytes))
        try Task.checkCancellation()
        guard case let .caller(bytes) = receipt.landing else { throw ToolRunError.failed(code: .internal, message: "copy landed off its target", hint: nil) }
        let token = try await context.space.writeFile(
          path, data: Data(bytes), in: group, acting: context.principal.group, attribution: context.attribution, ifMatch: nil, createOnly: !replace,
        )
        return output(receipt, token: Wire.string(token))
      } catch let loss as MachineFileFailure {
        switch loss {
        case .rangeLost where !replace, .outcomeUnknown where !replace:
          throw MachineFileFailure.outcomeUnknown
        case .rangeLost where !restarted, .outcomeUnknown where !restarted:
          restarted = true
          continue
        default:
          throw loss
        }
      } catch let refusal as CopyRefusal {
        throw failure(refusal, input)
      } catch SpaceError.alreadyExists(_) {
        throw failure(.targetExists, input)
      }
    }
  }
}

private func output(_ receipt: CopyReceipt, token: String) -> JSONValue {
  Wire.object([("bytes", .integer(receipt.bytes)), ("sha256", .string(receipt.sha256)), ("token", .string(token))])
}

private func failure(_ refusal: CopyRefusal, _ input: CopyInput) -> ToolRunError {
  let (from, to) = (input.from, input.to)
  return switch refusal {
  case .missing(.source): .failed(code: .notFound, message: "not found: \(from)", hint: nil)
  case .missing(.target): .failed(code: .notFound, message: "no folder for \(to)", hint: "create its folder first")
  case let .io(end, errno): .failed(code: .unavailable, message: "\(end == .source ? from : to): errno \(errno)", hint: nil)
  case .sourceNotAFile: .failed(code: .invalidArgument, message: "not a file: \(from)", hint: "copy takes one file; for a folder, tar it, copy the archive and untar it")
  case .sourceChanged: .failed(code: .sourceChanged, message: "\(from) changed during the copy", hint: "copy again")
  case let .sourceTooLarge(size, limit): .failed(code: .byteLimitExceeded, message: "\(from) is \(size) bytes; a space file takes at most \(limit) from a copy", hint: nil)
  case .targetExists: .failed(code: .exists, message: "already exists: \(to)", hint: "pass overwrite: true to replace it")
  case let .unsupported(machine): .failed(code: .unsupported, message: "the agent on \(machine.rawValue) predates copy", hint: "update the machine's agent")
  }
}
