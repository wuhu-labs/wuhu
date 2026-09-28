import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ContractPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [ContractMacro.self]
}
