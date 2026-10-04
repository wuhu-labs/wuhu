#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import QuickJSKit
import struct SpaceContract.GroupID
import SpaceCore
import SpaceFS
import SpaceTools
import SystemFiles

let scriptModuleLimit = 256
let scriptModuleBytes = 1 << 20
private let scheme = "wuhu:"

/// `wuhu:/<path>` reads the acting group's files and `wuhu://<group>.localspace/<path>`
/// another group's, which it must read; every space module is as of `rev`.
func scriptModules(in space: Space, at rev: Rev, acting: GroupID, readable: Set<GroupID>) -> JSEngine.ModuleLoader {
  JSEngine.ModuleLoader(
    maxModules: scriptModuleLimit,
    resolve: resolveScriptModule,
    source: { name in
      // A system module reads from the binary; a space module from the space
      // as of the moment the script started.
      let (fs, path, shown): (any SpaceVFS, String, String)
      if let system = systemModulePath(name) {
        (fs, path, shown) = (SystemFiles.vfs, system, name)
      } else if let (group, inGroup) = groupModulePath(name) {
        guard readable.contains(group) else { throw ScriptError(message(of: SpaceError.notFound(name))) }
        (fs, path, shown) = (await space.fs(group, at: rev), inGroup, name)
      } else {
        let plain = String(name.dropFirst(scheme.count))
        (fs, path, shown) = (await space.fs(acting, at: rev), plain, plain)
      }
      let data: Data
      do {
        guard try await fs.stat(path).size <= scriptModuleBytes else {
          throw ScriptError("\(shown) is larger than \(scriptModuleBytes >> 20) MiB")
        }
        data = try await fs.read(path).1
      } catch let error as ScriptError {
        throw error
      } catch {
        throw ScriptError(message(of: error))
      }
      guard let text = String(validating: data, as: UTF8.self) else {
        throw ScriptError("\(shown) is not UTF-8 text")
      }
      return text
    },
  )
}

// `wuhu://system/<path>` names a module built into the binary; the check runs
// before the `wuhu:/` one, which the system prefix also matches.
private func systemModulePath(_ name: String) -> String? {
  let prefix = SystemFiles.origin + "/"
  guard name.lowercased().hasPrefix(prefix) else { return nil }
  return "/" + name.dropFirst(prefix.count)
}

// `wuhu://<group>.localspace/<path>`: another group's file. The name stays in
// that form, so a relative import from it stays in its group.
private func groupModulePath(_ name: String) -> (GroupID, String)? {
  guard name.lowercased().hasPrefix("wuhu://") else { return nil }
  let rest = name.dropFirst("wuhu://".count)
  let host = rest.prefix { $0 != "/" }
  guard let group = try? FSResolver.group(ofHost: host) else { return nil }
  let path = rest.dropFirst(host.count)
  return (GroupID(rawValue: group), path.isEmpty ? "/" : String(path))
}

private let moduleForms = "wuhu:/<path> (this group), wuhu://<group>.localspace/<path> (another group) or wuhu://system/<path>"

@Sendable func resolveScriptModule(_ specifier: String, from referrer: String) throws -> String {
  do {
    if let path = systemModulePath(specifier) {
      return SystemFiles.address(try SpacePath(validating: path).rawValue)
    }
    if specifier.lowercased().hasPrefix("wuhu://") {
      let host = specifier.dropFirst("wuhu://".count).prefix { $0 != "/" }
      guard let group = try? FSResolver.group(ofHost: host), let (_, path) = groupModulePath(specifier) else {
        throw ScriptError("unknown module '\(specifier)'; import \(moduleForms)")
      }
      return FSResolver.address((try SpacePath(validating: path)).rawValue, inGroup: group)
    }
    if specifier.hasPrefix(scheme + "/") {
      return scheme + (try SpacePath(validating: String(specifier.dropFirst(scheme.count)))).rawValue
    }
    guard specifier.hasPrefix("./") || specifier.hasPrefix("../") else {
      throw ScriptError(
        "unknown module '\(specifier)'; import wuhu:space, wuhu:secret, wuhu:ai, wuhu:web_search, wuhu:machine, wuhu:session, \(moduleForms)",
      )
    }
    // A relative import stays where its referrer lives: in its group, or in
    // the system files.
    let system = systemModulePath(referrer)
    let group = groupModulePath(referrer)
    guard system != nil || group != nil || referrer.hasPrefix(scheme + "/") else {
      throw ScriptError("relative import '\(specifier)' works only inside a space or system module; import \(moduleForms)")
    }
    var components = try SpacePath(validating: system ?? group?.1 ?? String(referrer.dropFirst(scheme.count))).parent.components
    for piece in specifier.split(separator: "/", omittingEmptySubsequences: false) {
      switch piece {
      case ".":
        continue
      case "..":
        guard !components.isEmpty else {
          throw ScriptError("'\(specifier)' climbs above the \(system == nil ? "space" : "system") root")
        }
        components.removeLast()
      default:
        components.append(String(piece))
      }
    }
    let resolved = try SpacePath(components: components).rawValue
    if system != nil { return SystemFiles.address(resolved) }
    if let (group, _) = group { return FSResolver.address(resolved, inGroup: group.rawValue) }
    return scheme + resolved
  } catch let error as SpacePathError {
    throw ScriptError("'\(specifier)' is not a valid path: \(message(of: error))")
  }
}

private func message(of error: any Error) -> String {
  guard case let .failed(_, message, _, _) = Wire.failure(error) else { return "\(error)" }
  return message
}
