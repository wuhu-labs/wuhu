#if canImport(FoundationEssentials)
  import struct FoundationEssentials.Data
#else
  import struct Foundation.Data
#endif
import SpaceContract
import SpaceCore
import struct SpaceFS.VersionToken

public struct FileBytes: Sendable {
  public let token: String
  public let rev: Int?
  public let data: Data
  public init(token: String, rev: Int?, data: Data) { self.token = token; self.rev = rev; self.data = data }
}

public struct FileVersion: Sendable {
  public let token: String
  public let rev: Int?
  public init(token: String, rev: Int?) { self.token = token; self.rev = rev }
}

public extension SpaceToolContext {
  func readBytes(_ address: String, rev: Int? = nil, byteLimit: Int? = nil) async throws(ToolRunError) -> FileBytes {
    do {
      let target = try await resolve(address, rev: rev)
      let (token, data) = try await read(target, upTo: byteLimit) { _ in
        .failed(code: .byteLimitExceeded, message: "file exceeds byte limit", hint: "Read a smaller file.")
      }
      return FileBytes(token: Wire.string(token), rev: try revision(token, target), data: data)
    } catch {
      throw Wire.failure(error)
    }
  }

  /// `target` whole, or `tooLarge(size)` past `limit` bytes: a machine file
  /// through the seam's own bound, so the server never holds more than it; a
  /// space or system file by its stat, then its bytes.
  internal func read(_ target: Target, upTo limit: Int?, tooLarge: (Int) -> ToolRunError) async throws -> (VersionToken, Data) {
    guard let limit else { return try await target.backend.read(target.path) }
    if let machine = target.machine, let machines {
      do {
        let (token, bytes) = try await machines.fileBytes(machine, target.path, limit: limit)
        return (Wire.token(token), Data(bytes))
      } catch let over as MachineSeam.OverLimit {
        throw tooLarge(over.size)
      }
    }
    let size = try await target.backend.stat(target.path).size
    guard size <= limit else { throw tooLarge(size) }
    let (token, data) = try await target.backend.read(target.path)
    guard data.count <= limit else { throw tooLarge(data.count) }
    return (token, data)
  }

  func writeBytes(_ address: String, _ data: Data, ifMatch: String?, createOnly: Bool = false) async throws(ToolRunError) -> FileVersion {
    do {
      let target = try await resolve(address)
      if target.isSpace, address.contains("@") {
        throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(address)", hint: "Historical views are read-only.")
      }
      let token: VersionToken
      if let group = target.group {
        let path = try spacePath(target.path)
        try await SpaceView.requireReadable(group, by: principal.group, actor: principal.actor, path: path.rawValue, in: space)
        try await refuseWrite(path, in: group)
        token = try await space.writeFile(path, data: data, in: group, acting: principal.group, attribution: attribution, ifMatch: ifMatch.map(Wire.token), createOnly: createOnly)
      } else {
        // A machine agent has no create-only write: the check is a stat
        // before it, with the window that leaves. (The system backend
        // refuses every write itself.)
        if createOnly, target.machine != nil {
          let exists: Bool
          do {
            _ = try await target.backend.stat(target.path)
            exists = true
          } catch ToolRunError.failed(code: .notFound, message: _, hint: _, token: _) {
            exists = false
          }
          if exists { throw SpaceError.alreadyExists(address) }
        }
        token = try await target.backend.write(target.path, data, ifMatch: ifMatch.map(Wire.token))
      }
      return FileVersion(token: Wire.string(token), rev: try revision(token, target))
    } catch let SpaceError.alreadyExists(path) where createOnly {
      throw .failed(code: .conflict, message: "already exists: \(path)", hint: "Choose another path; create-only operations never replace an existing entry.")
    } catch SpaceError.versionMismatch {
      let target = try? await resolve(address)
      let current: VersionToken?
      if let target { current = try? await target.backend.stat(target.path).token }
      else { current = nil }
      throw .failed(code: .conflict, message: "version mismatch: \(address)", hint: Wire.staleHint, token: current.map(Wire.string))
    } catch {
      throw Wire.failure(error)
    }
  }
}

private extension SpaceToolContext {
  func revision(_ token: VersionToken, _ target: Target) throws -> Int? {
    target.isSpace ? try Wire.rev(token) : nil
  }
}
