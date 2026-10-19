import struct SpaceContract.GroupID
import SpaceFS
import SpaceTools
import SystemFiles

public let scriptModuleBytes = 1 << 20
public let scriptModuleScheme = "wuhu:"

// `wuhu://system/<path>` names a module built into the binary; the check runs
// before the `wuhu:/` one, which the system prefix also matches.
public func systemModulePath(_ name: String) -> String? {
  let prefix = SystemFiles.origin + "/"
  guard name.lowercased().hasPrefix(prefix) else { return nil }
  return "/" + name.dropFirst(prefix.count)
}

// `wuhu://<group>.localspace/<path>`: another group's file. The name stays in
// that form, so a relative import from it stays in its group.
public func groupModulePath(_ name: String) -> (GroupID, String)? {
  guard name.lowercased().hasPrefix("wuhu://") else { return nil }
  let rest = name.dropFirst("wuhu://".count)
  let host = rest.prefix { $0 != "/" }
  guard let group = try? FSResolver.group(ofHost: host) else { return nil }
  let path = rest.dropFirst(host.count)
  return (GroupID(rawValue: group), path.isEmpty ? "/" : String(path))
}

private let moduleForms = "wuhu:/<path> (this group), wuhu://<group>.localspace/<path> (another group) or wuhu://system/<path>"

@Sendable public func resolveScriptModule(_ specifier: String, from referrer: String) throws -> String {
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
    if specifier.hasPrefix(scriptModuleScheme + "/") {
      return scriptModuleScheme + (try SpacePath(validating: String(specifier.dropFirst(scriptModuleScheme.count)))).rawValue
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
    guard system != nil || group != nil || referrer.hasPrefix(scriptModuleScheme + "/") else {
      throw ScriptError("relative import '\(specifier)' works only inside a space or system module; import \(moduleForms)")
    }
    var components = try SpacePath(validating: system ?? group?.1 ?? String(referrer.dropFirst(scriptModuleScheme.count))).parent.components
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
    return scriptModuleScheme + resolved
  } catch let error as SpacePathError {
    throw ScriptError("'\(specifier)' is not a valid path: \(scriptModuleFailure(of: error))")
  }
}

public func scriptModuleFailure(of error: any Error, typed: Bool = false) -> String {
  guard case let .failed(code, message, _, _) = Wire.failure(error) else { return "\(error)" }
  return typed ? "\(code.rawValue): \(message)" : message
}
