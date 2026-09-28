import Foundation
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS

public struct SessionTemplate: Hashable, Sendable {
  public static let root: String = "/templates"
  public static let manifest: String = "template.json"

  public let name: String
  /// The group whose `/templates` holds it.
  public let group: GroupID
  public let kind: SessionKind?
  public let description: String?
  public let params: SessionCreationParams

  public var path: String { "\(Self.root)/\(name)" }

  static func isValidName(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || ($0.isASCII && $0.isNumber) || $0 == "-" }
  }

  init(name: String, group: GroupID, manifest: Data) throws {
    guard let json = JSONValue.parse(String(decoding: manifest, as: UTF8.self)), var fields = json.object else {
      throw ExecutorSpecError("template \(name): \(Self.manifest) is not a JSON object")
    }
    var kind: SessionKind?
    if let value = fields.removeValue(forKey: "kind") {
      guard let raw = value.stringValue, let parsed = SessionKind(rawValue: raw) else {
        throw ExecutorSpecError("template \(name): kind must be agent or task")
      }
      kind = parsed
    }
    var description: String?
    if let value = fields.removeValue(forKey: "description") {
      guard let text = value.stringValue else {
        throw ExecutorSpecError("template \(name): description must be a string")
      }
      description = text
    }
    let params: SessionCreationParams
    do {
      params = try SessionCreationParams(templateFields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) }))
    } catch let error as ExecutorSpecError {
      throw ExecutorSpecError("template \(name): \(error.message)")
    }
    self.name = name
    self.group = group
    self.kind = kind
    self.description = description
    self.params = params
  }
}

extension Space {
  /// A name is a template in `group`'s `/templates`; another group's is named
  /// `wuhu://<g>.localspace/templates/<name>`, and `group` must read `g`.
  public func sessionTemplate(named reference: String, in group: GroupID) async throws -> SessionTemplate {
    var (name, owner) = (reference, group)
    if reference.lowercased().hasPrefix("wuhu://") {
      let host = reference.dropFirst("wuhu://".count).prefix { $0 != "/" }
      let path = reference.dropFirst("wuhu://".count + host.count)
      guard let named = try? FSResolver.group(ofHost: host), path.hasPrefix(SessionTemplate.root + "/") else {
        throw ExecutorSpecError("not a template: \(reference); name one in /templates or wuhu://<group>.localspace/templates/<name>")
      }
      name = String(path.dropFirst(SessionTemplate.root.count + 1))
      if name.hasSuffix("/") { name.removeLast() }
      owner = GroupID(rawValue: named)
    }
    guard SessionTemplate.isValidName(name) else {
      throw ExecutorSpecError("not a template name: \(name)")
    }
    let path = "\(SessionTemplate.root)/\(name)/\(SessionTemplate.manifest)"
    let manifest: Data
    do {
      if owner != group {
        guard try await reads(group).contains(owner) else { throw SpaceError.notFound(path) }
      }
      (_, manifest) = try await fs(owner).read(path)
    } catch {
      throw ExecutorSpecError("unknown template: \(reference) (\(owner == group ? path : FSResolver.address(path, inGroup: owner.rawValue)))")
    }
    return try SessionTemplate(name: name, group: owner, manifest: manifest)
  }

  public func sessionTemplates(in group: GroupID) async throws -> [SessionTemplate] {
    let fs = fs(group)
    var templates: [SessionTemplate] = []
    for entry in try await fs.entriesIfPresent(SessionTemplate.root) where entry.kind == .directory {
      guard SessionTemplate.isValidName(entry.name),
            let manifest = try await fs.dataIfPresent("\(SessionTemplate.root)/\(entry.name)/\(SessionTemplate.manifest)")
      else { continue }
      templates.append(try SessionTemplate(name: entry.name, group: group, manifest: manifest))
    }
    return templates
  }

  // Everything in the template directory but the manifest lands in the
  // session's home, same relative paths; only files are cloned.
  public func applySessionTemplate(_ template: SessionTemplate, to session: SessionID) async throws {
    if let templateCloneFault { throw TemplateCloneFault(reason: templateCloneFault) }
    let fs = fs(template.group)
    let homeGroup = try await principal(of: session).group
    let homeFS = self.fs(homeGroup, acting: homeGroup)
    let home = SessionHome.path(of: session)
    var pending = [""]
    while let relative = pending.popLast() {
      for entry in try await fs.entriesIfPresent(template.path + relative) {
        let child = relative + "/" + entry.name
        switch entry.kind {
        case .directory:
          pending.append(child)
        case .file where child != "/" + SessionTemplate.manifest:
          let (_, data) = try await fs.read(template.path + child)
          _ = try await homeFS.write(home + child, data, ifMatch: nil)
        case .file, .table, .symlink:
          continue
        }
      }
    }
    // The clone lands after the session row, so the prompt revision stamped
    // at creation predates it; the cloned home belongs in the first prompt.
    try await sessions.advancePromptRevision(session)
  }
}

extension SpaceVFS {
  func dataIfPresent(_ path: String) async throws -> Data? {
    do {
      return try await read(path).1
    } catch SpaceError.notFound, SpaceError.notAFile {
      return nil
    }
  }
}

// The failure a test injects into every template clone, so the path where a
// session exists but its home never got the template's files can be driven.
public struct TemplateCloneFault: Error, CustomStringConvertible {
  public var reason: String
  public var description: String { reason }
}

extension Space {
  // Test seam: every later clone fails with reason until it is set to nil.
  // Nothing in the server sets it.
  @_spi(Testing) public func failTemplateClones(_ reason: String?) {
    templateCloneFault = reason
  }
}
