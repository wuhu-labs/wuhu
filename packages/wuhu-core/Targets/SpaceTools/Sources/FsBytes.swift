import struct Foundation.Data
import SpaceContract
import SpaceCore
import struct SpaceFS.VersionToken

public struct FileBytes: Sendable {
  public let token: String
  public let rev: Int?
  public let data: Data
}

public struct FileVersion: Sendable {
  public let token: String
  public let rev: Int?
}

public extension SpaceToolContext {
  func readBytes(_ address: String, rev: Int? = nil, byteLimit: Int? = nil) async throws(ToolRunError) -> FileBytes {
    do {
      let target = try resolve(address, rev: rev)
      if let byteLimit, try await target.backend.stat(target.path).size > byteLimit {
        throw ToolRunError.failed(code: .invalidArgument, message: "file exceeds byte limit", hint: "Read a smaller file.")
      }
      let (token, data) = try await target.backend.read(target.path)
      if let byteLimit, data.count > byteLimit {
        throw ToolRunError.failed(code: .invalidArgument, message: "file exceeds byte limit", hint: "Read a smaller file.")
      }
      return FileBytes(token: Wire.string(token), rev: try revision(token, target), data: data)
    } catch {
      throw Wire.failure(error)
    }
  }

  func writeBytes(_ address: String, _ data: Data, ifMatch: String?, createOnly: Bool = false) async throws(ToolRunError) -> FileVersion {
    do {
      let target = try resolve(address)
      if target.isSpace, address.contains("@") {
        throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(address)", hint: "Historical views are read-only.")
      }
      let token: VersionToken
      if let group = target.group {
        let path = try spacePath(target.path)
        try await SpaceView.requireReadable(group, by: principal.group, actor: principal.actor, path: path.rawValue, in: space)
        try await refuseWrite(path, in: group)
        token = try await space.writeFile(path, data: data, in: group, acting: principal.group, ifMatch: ifMatch.map(Wire.token), createOnly: createOnly)
      } else {
        token = try await target.backend.write(target.path, data, ifMatch: ifMatch.map(Wire.token))
      }
      return FileVersion(token: Wire.string(token), rev: try revision(token, target))
    } catch let SpaceError.alreadyExists(path) where createOnly {
      throw .failed(code: .conflict, message: "already exists: \(path)", hint: "Choose another path; create-only operations never replace an existing entry.")
    } catch SpaceError.versionMismatch {
      let target = try? resolve(address)
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
