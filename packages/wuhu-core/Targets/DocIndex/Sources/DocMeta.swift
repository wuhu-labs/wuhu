import struct SpaceFS.SpacePath

public struct DocMeta: Equatable, Sendable {
  public var title: String
  public var kind: String?
  public var status: String?
  public var customAttrs: [Attr]
  /// Links into the document's own group.
  public var links: [SpacePath]
  /// `wuhu://<group>.localspace/<path>` links, into a named group.
  public var groupLinks: [GroupLink]

  public init(
    title: String,
    kind: String?,
    status: String?,
    customAttrs: [Attr],
    links: [SpacePath],
    groupLinks: [GroupLink] = [],
  ) {
    self.title = title
    self.kind = kind
    self.status = status
    self.customAttrs = customAttrs
    self.links = links
    self.groupLinks = groupLinks
  }

  public struct GroupLink: Hashable, Sendable {
    public var group: String
    public var path: SpacePath

    public init(group: String, path: SpacePath) {
      self.group = group
      self.path = path
    }
  }

  public struct Attr: Equatable, Sendable {
    public var name: String
    public var value: AttrValue

    public init(name: String, value: AttrValue) {
      self.name = name
      self.value = value
    }
  }

  // Every payload is canonical JSON text: `.scalar` is one YAML scalar, each
  // `.array` element is one element's canonical JSON (a scalar or a nested
  // structure), and `.jsonObject` is a whole mapping with sorted keys.
  public enum AttrValue: Equatable, Sendable {
    case scalar(String)
    case array([String])
    case jsonObject(String)
  }
}
