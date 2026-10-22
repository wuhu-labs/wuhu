import func MainHub.groupModulePath
import func MainHub.resolveScriptModule
import struct MainHub.ScriptError
import let MainHub.scriptModuleBytes
import func MainHub.scriptModuleFailure
import let MainHub.scriptModuleScheme
import func MainHub.systemModulePath
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import QuickJSKit
import SpaceClient
import struct SpaceContract.GroupDetail
import struct SpaceContract.GroupID
import struct SpaceContract.GroupSummary
import SpaceCore
import SpaceTools
import SystemFiles

let scriptModuleLimit = 256

/// `GET /v1/context` as a script's bindings read it.
struct ScriptContext: Decodable, Sendable {
  let session: String?
  let group: String
  let rev: Int
}

/// The space as one execution's modules see it: every space module is as of
/// `revision`, from the acting group or one it reads.
struct ScriptModuleSnapshot: Sendable {
  let revision: Int
  let acting: GroupID
  let readable: Set<GroupID>

  static func load(_ client: SpaceClient) async throws -> ScriptModuleSnapshot {
    let context: ScriptContext = try await client.api(.get, "/v1/context")
    let groups: [GroupSummary] = try await client.api(.get, "/v1/groups")
    return ScriptModuleSnapshot(
      revision: context.rev, acting: GroupID(rawValue: context.group),
      readable: Set(groups.filter { $0.readable == true }.map { GroupID(rawValue: $0.id) }),
    )
  }
}

/// `wuhu:/<path>` reads the acting group's files and `wuhu://<group>.localspace/<path>`
/// another group's, which it must read; `wuhu://system/` is this binary's own.
func scriptModules(client: SpaceClient, snapshot: ScriptModuleSnapshot, typedErrors: Bool = false) -> JSEngine.ModuleLoader {
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
        } else {
          let group: GroupID
          if let (named, _) = groupModulePath(name) {
            shown = name
            if snapshot.readable.contains(named) {
              group = named
            } else {
              do {
                let detail: GroupDetail = try await client.api(.get, "/v1/group/\(named.rawValue)")
                group = GroupID(rawValue: detail.id)
              } catch let error as SpaceClient.ToolFailure where error.error.code == .notFound || error.error.code == .forbidden {
                throw SpaceError.notFound(shown)
              } catch let error as SpaceClient.TransportFailure where error.status == 404 || error.status == 403 {
                throw SpaceError.notFound(shown)
              }
            }
          } else {
            shown = String(name.dropFirst(scriptModuleScheme.count))
            group = snapshot.acting
          }
          guard snapshot.readable.contains(group), snapshot.revision != 0 else { throw SpaceError.notFound(shown) }
          do {
            data = try await client.file(shown, rev: snapshot.revision, limit: scriptModuleBytes).data
          } catch let failure as SpaceClient.ToolFailure {
            guard failure.error.code == .byteLimitExceeded else {
              throw ScriptError(typedErrors ? "\(failure.error.code.rawValue): \(failure.error.message)" : failure.error.message)
            }
            throw ScriptError("\(shown) is larger than \(scriptModuleBytes >> 20) MiB")
          }
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
