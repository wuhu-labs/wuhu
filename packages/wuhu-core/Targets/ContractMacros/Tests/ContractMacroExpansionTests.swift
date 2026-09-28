import ContractMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ContractMacroExpansionTests: XCTestCase {
  private let macros = ["Contract": ContractMacro.self]

  func testCustomDiscriminatorCollisionDiagnoses() {
    assertMacroExpansion(
      """
      @Contract(discriminator: "view")
      enum Bad {
          case put(view: String)
      }
      """,
      expandedSource: """
      enum Bad {
          case put(view: String)
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract reserves the key 'view' for the union discriminator; case 'put' has an associated value labeled 'view', which would collide. Rename the associated value.",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testDiscriminatorOnStructDiagnoses() {
    assertMacroExpansion(
      """
      @Contract(discriminator: "view")
      struct Bad {
          let sql: String
      }
      """,
      expandedSource: """
      struct Bad {
          let sql: String
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract takes a discriminator only on an enum with associated values (a discriminated union)",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testQualifiedStringRawTypeAccepted() {
    assertMacroExpansion(
      """
      @Contract
      enum Kind: Swift.String {
          case a
      }
      """,
      expandedSource: """
      enum Kind: Swift.String {
          case a

          static var jsonSchema: JSONValue {
              .object(["type": .string("string"), "enum": .array([.string("a")])])
          }
      }
      """,
      macros: macros,
    )
  }

  func testUnlabeledAssociatedValueDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      enum Bad {
          case write(String)
      }
      """,
      expandedSource: """
      enum Bad {
          case write(String)
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract requires a label on every associated value; case 'write' has an unlabeled (or `_`-suppressed) one. Internally-tagged unions flatten associated values beside the discriminator by field name, so each needs a label — there is no _0 synthesis.",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testWildcardSuppressedLabelDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      enum Bad {
          case foo(_ value: Int)
      }
      """,
      expandedSource: """
      enum Bad {
          case foo(_ value: Int)
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract requires a label on every associated value; case 'foo' has an unlabeled (or `_`-suppressed) one. Internally-tagged unions flatten associated values beside the discriminator by field name, so each needs a label — there is no _0 synthesis.",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testDiscriminatorCollisionDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      enum Bad {
          case put(kind: String)
      }
      """,
      expandedSource: """
      enum Bad {
          case put(kind: String)
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract reserves the key 'kind' for the union discriminator; case 'put' has an associated value labeled 'kind', which would collide. Rename the associated value.",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testNonLiteralRawValueDiagnoses() {
    assertMacroExpansion(
      #"""
      @Contract
      enum Bad: String {
          case a = "x\(1)"
      }
      """#,
      expandedSource: #"""
      enum Bad: String {
          case a = "x\(1)"
      }
      """#,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract needs a plain string-literal raw value to derive the wire value; case 'a' has a non-literal raw value",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testPlainEnumNeedsRawOrAssociatedDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      enum Plain {
          case a
          case b
      }
      """,
      expandedSource: """
      enum Plain {
          case a
          case b
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract enum 'Plain' needs either a String raw type — spelled `String` or `Swift.String`, not through a typealias the macro cannot resolve — or at least one case with labeled associated values (a discriminated union)",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testAppliedToClassDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      class Bad {
          let name: String = ""
      }
      """,
      expandedSource: """
      class Bad {
          let name: String = ""
      }
      """,
      diagnostics: [
        DiagnosticSpec(message: "@Contract can only be applied to a struct or enum", line: 1, column: 1),
      ],
      macros: macros,
    )
  }

  func testAccessModifierPropagates() {
    assertMacroExpansion(
      """
      @Contract
      public struct Sample {
          public let name: String
      }
      """,
      expandedSource: """
      public struct Sample {
          public let name: String

          public static var jsonSchema: JSONValue {
              .object(["type": .string("object"), "properties": .object(["name": .object(["type": .string("string")])]), "required": .array([.string("name")]), "additionalProperties": .bool(false)])
          }

          public init(name: String) {
              self.name = name
          }
      }
      """,
      macros: macros,
    )
  }

  func testAccessModifierPropagatesToEnum() {
    assertMacroExpansion(
      """
      @Contract
      public enum Kind: String {
          case a
      }
      """,
      expandedSource: """
      public enum Kind: String {
          case a

          public static var jsonSchema: JSONValue {
              .object(["type": .string("string"), "enum": .array([.string("a")])])
          }
      }
      """,
      macros: macros,
    )
  }

  func testTuplePatternDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      struct Sample {
          let (width, height): (Int, Int)
      }
      """,
      expandedSource: """
      struct Sample {
          let (width, height): (Int, Int)
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract does not support tuple-pattern property '(width, height)'; declare each property on its own binding",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testUnsupportedLeafTypeDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      struct Sample {
          let id: UUID
      }
      """,
      expandedSource: """
      struct Sample {
          let id: UUID
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract does not support the type of 'id': UUID. Supported: String, Int, Double, Bool, JSONValue, their optionals and arrays, and nested @Contract types",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testFloatSuggestsDouble() {
    assertMacroExpansion(
      """
      @Contract
      struct Sample {
          let ratio: Float
      }
      """,
      expandedSource: """
      struct Sample {
          let ratio: Float
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract does not support the type of 'ratio': Float. Supported: String, Int, Double, Bool, JSONValue, their optionals and arrays, and nested @Contract types (use Double instead of Float)",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }

  func testPropertyWrapperDiagnoses() {
    assertMacroExpansion(
      """
      @Contract
      struct Sample {
          @Clamped var n: Int
      }
      """,
      expandedSource: """
      struct Sample {
          @Clamped var n: Int
      }
      """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Contract cannot derive a wire schema for property 'n' because it carries an attribute (e.g. a property wrapper), whose encoded form is not knowable from the declaration",
          line: 1,
          column: 1,
        ),
      ],
      macros: macros,
    )
  }
}
