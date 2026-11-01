import Loro

/// The Loro layout of a `.wmd` document, for a client that edits the Loro doc directly.
public enum WmdSchema {
  public enum Key {
    static let frontmatter = "frontmatter"
    public static let blocks = "blocks"
    public static let kind = "kind"
    public static let level = "level"
    public static let style = "style"
    public static let text = "text"
    static let view = "view"
    public static let config = "config"
    static let sql = "sql"
    public static let bold = "bold"
    public static let italic = "italic"
    public static let link = "link"
  }

  public enum ListStyle: String, Hashable, Sendable {
    case unordered
    case ordered
    case todo
    case done
  }

  public enum Kind: Hashable, Sendable {
    case heading(Int)
    case paragraph
    case code
    case list(level: Int, style: ListStyle)
    case view(view: String, sql: String)

    /// nil for a block outside the schema, which every reader skips and no writer repairs.
    public init?(_ map: LoroMap) {
      guard case let .string(kind)? = map.get(key: Key.kind)?.asValue() else { return nil }
      switch kind {
      case "h1", "h2", "h3": self = .heading(Int(String(kind.dropFirst()))!)
      case "paragraph": self = .paragraph
      case "code": self = .code
      case "list":
        guard let level = WmdSchema.listLevel(map.get(key: Key.level)?.asValue()),
              case let .string(raw)? = map.get(key: Key.style)?.asValue(), let style = ListStyle(rawValue: raw) else { return nil }
        self = .list(level: level, style: style)
      case "view":
        guard case let .string(view)? = map.get(key: Key.view)?.asValue(),
              case let .string(sql)? = map.get(key: Key.sql)?.asValue() else { return nil }
        self = .view(view: view, sql: sql)
      default: return nil
      }
    }

    public var name: String {
      switch self {
      case let .heading(level): "h\(level)"
      case .paragraph: "paragraph"
      case .code: "code"
      case .list: "list"
      case .view: "view"
      }
    }
  }

  public static func configure(_ doc: LoroDoc) {
    let styles = StyleConfigMap()
    styles.insert(key: Key.bold, value: StyleConfig(expand: .after))
    styles.insert(key: Key.italic, value: StyleConfig(expand: .after))
    styles.insert(key: Key.link, value: StyleConfig(expand: .none))
    doc.configTextStyle(textStyle: styles)
  }

  /// loro-crdt stores a JS number as a double, so a level the web wrote arrives as one.
  public static func listLevel(_ value: LoroValue?) -> Int? {
    switch value {
    case let .i64(level)? where level >= 0: Int(level)
    case let .double(level)? where level >= 0 && level == level.rounded() && level < 64: Int(level)
    default: nil
    }
  }
}
