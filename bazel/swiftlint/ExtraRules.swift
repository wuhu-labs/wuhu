import Foundation
import SwiftLintCore
import SwiftSyntax

public func extraRules() -> [any Rule.Type] {
  [TestableImportOutsideTestsRule.self, NoUncheckedSendableRule.self, NoObservableObjectRule.self]
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

struct NoUncheckedSendableRule: SwiftSyntaxRule {
  var configuration = SeverityConfiguration<Self>(.error)

  static let description = RuleDescription(
    identifier: "no_unchecked_sendable",
    name: "No Unchecked Sendable",
    description: "Use checked Sendable conformance instead of @unchecked Sendable",
    kind: .lint,
    nonTriggeringExamples: [
      Example(code: "struct Value: Sendable {}"),
      Example(code: "// @unchecked Sendable\nstruct Value {}"),
      Example(code: "let text = \"@unchecked Sendable\""),
    ],
    triggeringExamples: [
      Example(code: "class Value: ↓@unchecked Sendable {}"),
      Example(code: "extension Value: ↓@unchecked Swift.Sendable {}"),
    ],
  )

  func preprocess(file: SwiftLintFile) -> SourceFileSyntax? {
    file.path?.pathComponents.contains("Sources") == true ? file.syntaxTree : nil
  }

  func makeVisitor(file: SwiftLintFile) -> ViolationsSyntaxVisitor<ConfigurationType> {
    Visitor(configuration: configuration, file: file)
  }

  private final class Visitor: ViolationsSyntaxVisitor<ConfigurationType> {
    override func visitPost(_ node: InheritedTypeSyntax) {
      guard let type = node.type.as(AttributedTypeSyntax.self),
            ["Sendable", "Swift.Sendable"].contains(type.baseType.trimmedDescription)
      else { return }
      for attribute in type.attributes {
        if let attribute = attribute.as(AttributeSyntax.self),
           attribute.attributeName.trimmedDescription == "unchecked"
        {
          violations.append(attribute.positionAfterSkippingLeadingTrivia)
        }
      }
    }
  }
}

struct NoObservableObjectRule: SwiftSyntaxRule {
  var configuration = SeverityConfiguration<Self>(.error)

  static let description = RuleDescription(
    identifier: "no_observable_object",
    name: "No Observable Object",
    description: "Prefer Swift Observation and TCA stores over ObservableObject, @ObservedObject and @Published",
    kind: .lint,
    nonTriggeringExamples: [
      Example(code: "@Observable class Model {}"),
      Example(code: "let text = \"ObservableObject @Published @ObservedObject\""),
      Example(code: "// class Model: ObservableObject {}"),
    ],
    triggeringExamples: [
      Example(code: "class Model: ↓ObservableObject {}"),
      Example(code: "extension Model: ↓Combine.ObservableObject {}"),
      Example(code: "class Model: ↓@MainActor ObservableObject {}"),
      Example(code: "extension Model: ↓@retroactive Combine.ObservableObject {}"),
      Example(code: "↓@Published var value = 0"),
      Example(code: "↓@ObservedObject var model: Model"),
      Example(code: "↓@Combine.Published var value = 0"),
    ],
  )

  func preprocess(file: SwiftLintFile) -> SourceFileSyntax? {
    file.path?.pathComponents.contains("Sources") == true ? file.syntaxTree : nil
  }

  func makeVisitor(file: SwiftLintFile) -> ViolationsSyntaxVisitor<ConfigurationType> {
    Visitor(configuration: configuration, file: file)
  }

  private final class Visitor: ViolationsSyntaxVisitor<ConfigurationType> {
    override func visitPost(_ node: InheritedTypeSyntax) {
      let type = node.type.as(AttributedTypeSyntax.self)?.baseType ?? node.type
      if ["ObservableObject", "Combine.ObservableObject"].contains(type.trimmedDescription) {
        violations.append(node.positionAfterSkippingLeadingTrivia)
      }
    }

    override func visitPost(_ node: AttributeSyntax) {
      if ["Published", "ObservedObject", "Combine.Published", "SwiftUI.ObservedObject"].contains(node.attributeName.trimmedDescription) {
        violations.append(node.positionAfterSkippingLeadingTrivia)
      }
    }
  }
}
