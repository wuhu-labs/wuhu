import JSONValue
import QuickJSKit
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import SpaceFS
import SpaceTools

// move and remove run the same space tools as `wuhu mv` and `wuhu rm`, under the
// write tool's home rule: a script writes into another session's home no more
// than its session could.
struct ScriptFiles: Sendable {
  let space: Space
  let session: SessionID

  func install(in engine: JSEngine) {
    engine.define("__wuhu_move", promising: { arguments in
      let principal = try await space.principal(of: session)
      let from = try writable(text(arguments, 0), as: principal)
      let to = try writable(text(arguments, 1), as: principal)
      let replace = arguments.count > 2 && arguments[2] == JSONValue.bool(true)
      return try await run("mv", replace ? ["from": .string(from), "to": .string(to), "replace": .bool(true)] : ["from": .string(from), "to": .string(to)], as: principal)
    })
    engine.define("__wuhu_remove", promising: { arguments in
      let principal = try await space.principal(of: session)
      let path = try writable(text(arguments, 0), as: principal)
      return try await run("rm", ["path": .string(path)], as: principal)
    })
  }

  private func writable(_ raw: String, as principal: Principal) throws -> String {
    do {
      return try scriptWritable(raw, by: session, as: principal)
    } catch {
      throw ScriptError(renderedFailure(Wire.failure(error)))
    }
  }

  private func run(_ name: String, _ input: JSONValue, as principal: Principal) async throws -> JSONValue {
    let tool = SpaceToolbox.all.first { $0.name == name }!
    do {
      return try await tool.run(SpaceToolContext(space: space, principal: principal), input: input)
    } catch {
      throw ScriptError(renderedFailure(error))
    }
  }
}

// Only a space path passes, hostless or `wuhu://<group>.localspace/…`, so no
// other address form (`machines://…`, `@rev`) reaches the tool around the
// home rule.
func scriptWritable(_ raw: String, by session: SessionID, as principal: Principal) throws(ToolRunError) -> String {
  var plain = raw
  var group = principal.group
  if raw.lowercased().hasPrefix("wuhu://") {
    let host = raw.dropFirst("wuhu://".count).prefix { $0 != "/" }
    if let named = try? FSResolver.group(ofHost: host) {
      plain = String(raw.dropFirst("wuhu://".count + host.count))
      group = GroupID(rawValue: named)
    }
  }
  let path: SpacePath
  do {
    path = try SpacePath(validating: plain)
  } catch {
    throw .failed(
      code: .invalidPath, message: "wuhu:space takes a path in this group or wuhu://<group>.localspace/<path>: \(raw)", hint: nil,
    )
  }
  do {
    try SessionHome.refuseForeignWrite(to: path, in: group, by: session, home: principal.group)
  } catch {
    throw Wire.failure(error)
  }
  return plain == raw ? path.rawValue : raw
}

private func text(_ arguments: [JSONValue], _ index: Int) -> String {
  guard arguments.indices.contains(index), case let .string(text) = arguments[index] else { return "" }
  return text
}

let spaceFilesModule = #"""

const moveEntry = __wuhu_move
const removeEntry = __wuhu_remove

export async function move(from, to, options = {}) {
  return await moveEntry(String(from), String(to), options?.replace === true)
}

export async function remove(path) {
  return await removeEntry(String(path))
}
"""#
