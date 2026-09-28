import struct Foundation.Data
import SpaceContract
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
  func readBytes(_ address: String) async throws(ToolRunError) -> FileBytes {
    do {
      let target = try resolve(address)
      let (token, data) = try await target.backend.read(target.path)
      return FileBytes(token: Wire.string(token), rev: try rev(token, target), data: data)
    } catch {
      throw Wire.failure(error)
    }
  }

  func writeBytes(_ address: String, _ data: Data, ifMatch: String?) async throws(ToolRunError) -> FileVersion {
    do {
      let target = try resolve(address)
      let token = try await target.backend.write(target.path, data, ifMatch: ifMatch.map(Wire.token))
      return FileVersion(token: Wire.string(token), rev: try rev(token, target))
    } catch {
      throw Wire.failure(error)
    }
  }
}

private extension SpaceToolContext {
  func rev(_ token: VersionToken, _ target: Target) throws -> Int? {
    target.isSpace ? try Wire.rev(token) : nil
  }
}
