import Loro
import WmdDocument

/// The Loro layout of a `.canvas` board, for a client that edits the Loro doc directly.
public enum CanvasSchema {
  public enum Key {
    public static let tree = "tree"
    public static let connectors = "connectors"
    public static let id = "id"
    public static let kind = "kind"
    public static let x = "x"
    public static let y = "y"
    public static let w = "w"
    public static let h = "h"
    public static let color = "color"
    public static let text = WmdSchema.Key.text
    public static let path = "path"
    public static let from = "from"
    public static let to = "to"
    public static let fromSide = "fromSide"
    public static let toSide = "toSide"
    public static let style = "style"
    public static let offset = "offset"
    public static let arrow = "arrow"
    public static let label = "label"
  }

  /// Every doc of a board needs it: `.wmd`'s mark expansion, and the tree's sibling order.
  public static func configure(_ doc: LoroDoc) {
    WmdSchema.configure(doc)
    doc.getTree(id: Key.tree).enableFractionalIndex(jitter: 0)
  }

  /// loro-crdt stores a JS number as a double, and a hand-made doc may hold an integer.
  static func number(_ value: LoroValue?) -> Double? {
    switch value {
    case let .double(number)? where number.isFinite: number
    case let .i64(number)?: Double(number)
    default: nil
    }
  }

  static func string(_ value: LoroValue?) -> String? {
    if case let .string(string)? = value { string } else { nil }
  }
}

public enum CanvasKind: String, CaseIterable, Hashable, Sendable {
  case sticky
  case text
  case rect
  case ellipse
  case diamond
  case section
  case file

  public var defaultSize: CanvasSize {
    switch self {
    case .sticky: CanvasSize(w: 160, h: 160)
    case .text: CanvasSize(w: 240, h: 40)
    case .rect: CanvasSize(w: 200, h: 100)
    case .ellipse, .diamond: CanvasSize(w: 160, h: 120)
    case .section: CanvasSize(w: 600, h: 400)
    case .file: CanvasSize(w: 240, h: 160)
    }
  }

  /// What a new item gets when nothing names its colour; free text and file cards have none.
  public var defaultColor: CanvasColor? {
    switch self {
    case .sticky: .yellow
    case .rect, .ellipse, .diamond: .blue
    case .section: .gray
    case .text, .file: nil
    }
  }

  public var isColored: Bool { self != .text }
}

public enum CanvasColor: String, CaseIterable, Hashable, Sendable {
  case yellow
  case pink
  case green
  case blue
  case purple
  case gray
}

public enum CanvasSide: String, CaseIterable, Hashable, Sendable {
  case top
  case right
  case bottom
  case left
}

public enum ConnectorStyle: String, CaseIterable, Hashable, Sendable {
  case straight
  case elbow
}

public enum ConnectorArrow: String, CaseIterable, Hashable, Sendable {
  case none
  case end
  case both
}

public struct CanvasSize: Hashable, Sendable {
  public var w: Double
  public var h: Double

  public init(w: Double, h: Double) {
    self.w = w
    self.h = h
  }
}

public struct CanvasRect: Hashable, Sendable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }

  func intersects(_ other: CanvasRect) -> Bool {
    self.x < other.x + other.w && other.x < self.x + self.w && self.y < other.y + other.h && other.y < self.y + self.h
  }
}
