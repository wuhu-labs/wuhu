import func MainHub.groupModulePath
import protocol MainHub.Main
import func MainHub.resolveScriptModule
import struct MainHub.ScriptError
import let MainHub.scriptModuleBytes
import func MainHub.scriptModuleFailure
import let MainHub.scriptModuleScheme
import struct MainHub.ScriptModuleSnapshot
import func MainHub.systemModulePath
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

/// `wuhu:/<path>` reads the acting group's files and `wuhu://<group>.localspace/<path>`
/// another group's, which it must read; every space module is as of `rev`.
func scriptModules(owner: any Main, snapshot: ScriptModuleSnapshot, typedErrors: Bool = false) -> JSEngine.ModuleLoader {
  JSEngine.ModuleLoader(
    maxModules: scriptModuleLimit,
    resolve: resolveScriptModule,
    source: { name in
      let data: Data
      let shown: String
      do {
        if let path = systemModulePath(name) {
          shown = name
          guard try await SystemFiles.vfs.stat(path).size <= scriptModuleBytes else { throw ScriptError("\(shown) is larger than \(scriptModuleBytes >> 20) MiB") }
          data = try await SystemFiles.vfs.read(path).1
        } else if let (group, path) = groupModulePath(name) {
          shown = name
          guard snapshot.readable.contains(group) else { throw ScriptError(scriptModuleFailure(of: SpaceError.notFound(name), typed: typedErrors)) }
          data = try await owner.moduleBytes(path: path, shown: shown, group: group, snapshot: snapshot)
        } else {
          shown = String(name.dropFirst(scriptModuleScheme.count))
          data = try await owner.moduleBytes(path: shown, shown: shown, group: snapshot.acting, snapshot: snapshot)
        }
      } catch let error as ScriptError { throw error }
      catch { throw ScriptError(scriptModuleFailure(of: error, typed: typedErrors)) }
      guard let text = String(validating: data, as: UTF8.self) else {
        throw ScriptError("\(shown) is not UTF-8 text")
      }
      return text
    },
  )
}
