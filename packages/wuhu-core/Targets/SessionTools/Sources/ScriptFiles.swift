import func MainHub.systemModulePath
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import QuickJSKit
import SpaceClient
import SpaceCore
import SpaceFS
import SpaceTools
import SystemFiles

// The file half of `wuhu:space`, over main's API as the session; the bytes of
// `wuhu://system/` are this binary's own, read in place.
struct ScriptFiles: Sendable {
  let client: SpaceClient
  let execution: ScriptExecution

  func install(in engine: JSEngine) {
    engine.define("__wuhu_space_file", promising: { arguments in
      await spaceAnswer {
        let name = string(arguments, 0)
        guard case let .object(fields)? = arguments[safe: 1], case let .object(options)? = arguments[safe: 2] else {
          throw ToolRunError.failed(code: .invalidArgument, message: "file arguments and options must be objects", hint: nil)
        }
        let allowed: Set<String> = switch name {
        case "readBytes", "readText": ["rev"]
        case "writeBytes", "writeText", "checkout": ["ifMatch"]
        case "list": ["rev", "hidden"]
        case "history": ["after", "limit"]
        case "move": ["replace"]
        case "stat": []
        default: throw ToolRunError.failed(code: .invalidArgument, message: "unknown file operation", hint: nil)
        }
        guard Set(options.keys).isSubset(of: allowed) else {
          throw ToolRunError.failed(code: .invalidArgument, message: "unsupported options for \(name)", hint: nil)
        }
        for key in name == "move" ? ["from", "to"] : ["path"] {
          try scriptSpaceAddress(fields[key]?.stringValue ?? "")
        }
        let path = fields["path"]?.stringValue ?? ""
        var input = fields
        for (key, value) in options { input[key] = value }
        let output: JSONValue
        var reserved = 0
        defer { execution.buffers.withLock { $0.unclaim(reserved) } }
        switch name {
        case "readBytes", "readText":
          let revision: Int?
          switch options["rev"] {
          case let .integer(value)? where value >= 0: revision = value
          case nil: revision = nil
          default: throw ToolRunError.failed(code: .invalidArgument, message: "rev must be non-negative", hint: nil)
          }
          try claimFileBuffer(execution.limits.fileResultBytes, in: execution)
          defer { execution.buffers.withLock { $0.unclaim(execution.limits.fileResultBytes) } }
          let token: String
          let rev: Int?
          let data: Data
          if let system = systemModulePath(path) {
            guard revision == nil else {
              throw ToolRunError.failed(code: .unsupported, message: "wuhu://system/ has no revisions: \(path)", hint: nil)
            }
            let read = try await SystemFiles.vfs.read(system)
            (token, rev, data) = (Wire.string(read.0), nil, read.1)
          } else {
            let read = try await client.file(path, rev: revision, limit: 16 << 20)
            (token, rev, data) = (read.token, read.rev, read.data)
          }
          let value: String
          if name == "readText" {
            guard let text = String(validating: data, as: UTF8.self) else {
              throw ToolRunError.failed(code: .unsupported, message: "file is not UTF-8 text", hint: "Use readBytes.")
            }
            value = text
          } else { value = data.base64EncodedString() }
          output = .object(["token": .string(token), "rev": rev.map(JSONValue.integer) ?? .null, name == "readText" ? "content" : "data": .string(value)])
        case "writeBytes", "writeText":
          let token: String?
          switch options["ifMatch"] {
          case .null?: token = nil
          case let .string(value)? where !value.isEmpty: token = value
          default: throw ToolRunError.failed(code: .invalidArgument, message: "ifMatch is required: null to create, a token to replace", hint: nil)
          }
          let data: Data
          if name == "writeText", case let .string(text)? = fields["content"] { data = Data(text.utf8) }
          else if name == "writeBytes", let text = fields["data"]?.stringValue, let bytes = Data(base64Encoded: text) { data = bytes }
          else { throw ToolRunError.failed(code: .invalidArgument, message: "invalid file content", hint: nil) }
          guard data.count <= 16 << 20 else { throw overBudget(.fileResult, budget: execution.limits.bufferBytes) }
          try execution.buffers.withLock { try $0.claim(data.count, for: .fileResult) }
          defer { execution.buffers.withLock { $0.unclaim(data.count) } }
          output = try await client.putFileBytes(path, data, ifMatch: token, createOnly: token == nil)
        case "checkout":
          let token: String?
          switch options["ifMatch"] {
          case .null?: token = nil
          case let .string(value)? where !value.isEmpty: token = value
          default: throw ToolRunError.failed(code: .invalidArgument, message: "ifMatch is required: null to restore a missing path, a token to replace", hint: nil)
          }
          guard case let .integer(rev)? = fields["rev"], rev >= 0 else {
            throw ToolRunError.failed(code: .invalidArgument, message: "rev must be non-negative", hint: nil)
          }
          output = try await client.tool("checkout", .object([
            "path": .string(path), "rev": .integer(rev), "ifMatch": token.map(JSONValue.string) ?? .null, "createOnly": .bool(token == nil),
          ]))
        case "list":
          switch options["rev"] {
          case let .integer(value)? where value >= 0: break
          case nil: break
          default: throw ToolRunError.failed(code: .invalidArgument, message: "rev must be non-negative", hint: nil)
          }
          switch options["hidden"] {
          case .bool?, nil: break
          default: throw ToolRunError.failed(code: .invalidArgument, message: "hidden must be a boolean", hint: nil)
          }
          try claimFileBuffer(execution.limits.fileResultBytes, in: execution)
          reserved = execution.limits.fileResultBytes
          input["limit"] = .integer(execution.limits.listingEntries)
          input["byteLimit"] = .integer(execution.limits.fileResultBytes)
          output = try await client.tool("ls", .object(input))
        default:
          output = try await client.tool(name == "move" ? "mv" : name, .object(input))
        }
        let bytes = try fileResultSize(output, limit: execution.limits.fileResultBytes)
        if reserved > 0 {
          execution.buffers.withLock { $0.unclaim(reserved - bytes) }
        } else { try claimFileBuffer(bytes, in: execution) }
        reserved = bytes
        return output
      }
    })
  }
}

func fileResultSize(_ value: JSONValue, limit: Int) throws -> Int {
  var size = 0
  func add(_ bytes: Int) throws {
    guard bytes <= limit - size else {
      throw ToolRunError.failed(code: .byteLimitExceeded, message: "file result exceeds serialized byte limit", hint: "Read a smaller file or directory.")
    }
    size += bytes
  }
  func string(_ value: String) throws {
    try add(2)
    for byte in value.utf8 {
      let bytes = switch byte {
      case 8, 9, 10, 12, 13, 34, 92: 2
      case 0 ..< 32: 6
      default: 1
      }
      try add(bytes)
    }
  }
  func walk(_ value: JSONValue) throws {
    switch value {
    case .null: try add(4)
    case let .bool(value): try add(value ? 4 : 5)
    case let .integer(value): try add(String(value).utf8.count)
    case let .number(value): try add(value.description.utf8.count)
    case let .string(value): try string(value)
    case let .array(values):
      try add(2 + max(0, values.count - 1))
      for value in values { try walk(value) }
    case let .object(values):
      try add(2 + max(0, values.count - 1))
      for (key, value) in values { try string(key); try add(1); try walk(value) }
    }
  }
  try walk(value)
  return size
}

private func claimFileBuffer(_ bytes: Int, in execution: ScriptExecution) throws {
  do { try execution.buffers.withLock { try $0.claim(bytes, for: .fileResult) } }
  catch {
    throw ToolRunError.failed(code: .invalidArgument, message: "file operation exceeds the script's available buffer", hint: "Consume unread response bodies or machine output, or let other in-flight operations finish before retrying.")
  }
}

func scriptSpaceAddress(_ raw: String) throws {
  var path = raw
  if raw.hasPrefix("machines://") {
    throw ToolRunError.failed(code: .invalidPath, message: "wuhu:space takes a path in this group or wuhu://<group>.localspace/<path>: \(raw)", hint: nil)
  }
  if raw.hasPrefix("wuhu://") {
    let host = raw.dropFirst("wuhu://".count).prefix { $0 != "/" }
    guard host == "system" || (try? FSResolver.group(ofHost: host)) != nil else {
      throw ToolRunError.failed(code: .invalidPath, message: "invalid space address", hint: nil)
    }
    path = String(raw.dropFirst("wuhu://".count + host.count))
  }
  guard (try? SpacePath(validating: path)) != nil else {
    throw ToolRunError.failed(code: .invalidPath, message: "expected an absolute space path", hint: nil)
  }
}

let spaceFilesModule = #"""

const hostFile = __wuhu_space_file
const fileCall = (name, input, options) => call(() => hostFile(name, input, options))
export const readText = (path, options = {}) => fileCall("readText", {path}, options)
export async function readBytes(path, options = {}) {
  const value = await fileCall("readBytes", {path}, options)
  const raw = atob(value.data)
  value.data = Uint8Array.from(raw, c => c.charCodeAt(0))
  return value
}
export const writeText = (path, content, options = {}) => fileCall("writeText", {path, content}, options)
export function writeBytes(path, data, options = {}) {
  if (data instanceof ArrayBuffer) data = new Uint8Array(data)
  else if (ArrayBuffer.isView(data)) data = new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  else throw new TypeError("data must be an ArrayBuffer or typed array")
  let text = ""
  for (let i = 0; i < data.length; i += 0x8000) text += String.fromCharCode(...data.subarray(i, i + 0x8000))
  return fileCall("writeBytes", {path, data:btoa(text)}, options)
}
export const stat = (path, options = {}) => fileCall("stat", {path}, options)
export const list = (path, options = {}) => fileCall("list", {path}, options)
export const history = (path, options = {}) => fileCall("history", {path}, options)
export const checkout = (path, rev, options = {}) => fileCall("checkout", {path, rev}, options)
export const move = (from, to, options = {}) => fileCall("move", {from, to}, options)

"""#
