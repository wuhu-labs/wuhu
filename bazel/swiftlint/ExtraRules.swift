import Foundation
import SwiftLintCore
import SwiftSyntax

public func extraRules() -> [any Rule.Type] {
  [TestableImportOutsideTestsRule.self]
}

struct TestableImportOutsideTestsRule: SwiftSyntaxRule {
  var configuration = SeverityConfiguration<Self>(.error)

  static let description = RuleDescription(
    identifier: "testable_import_outside_tests",
    name: "Testable Import Outside Tests",
    description: "`@testable import` belongs only in test sources, under a directory whose name ends in `Tests`",
    kind: .lint,
  )

  func makeVisitor(file: SwiftLintFile) -> ViolationsSyntaxVisitor<ConfigurationType> {
    Visitor(configuration: configuration, file: file)
  }

  func preprocess(file: SwiftLintFile) -> SourceFileSyntax? {
    let inTests = file.path?.pathComponents.contains { $0.hasSuffix("Tests") } ?? false
    return inTests ? nil : file.syntaxTree
  }

  private final class Visitor: ViolationsSyntaxVisitor<ConfigurationType> {
    override func visitPost(_ node: ImportDeclSyntax) {
      let testable = node.attributes.contains {
        $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "testable"
      }
      if testable {
        violations.append(node.positionAfterSkippingLeadingTrivia)
      }
    }
  }
}
