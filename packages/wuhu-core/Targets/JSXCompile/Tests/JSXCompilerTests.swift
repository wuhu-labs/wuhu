import JSXCompile
import Testing

struct JSXCompilerTests {
  @Test func aCompileHasAStepBudget() async throws {
    let compiler = JSXCompiler(stepBudget: 500)
    #expect(try await compiler.javaScript("export default () => <Figure value={1} />", file: "/a.widget.jsx").contains("h(Figure"))
    let huge = (0 ..< 20000).map { "export const v\($0) = <List rows={[{ label: '\($0)' }]} />" }.joined(separator: "\n")
    let failure = await #expect(throws: JSXCompiler.Failure.self) { try await compiler.javaScript(huge, file: "/huge.widget.jsx") }
    #expect(failure?.message == "/huge.widget.jsx: too long to compile")
    #expect(try await compiler.javaScript("export default () => <Figure value={2} />", file: "/b.widget.jsx").contains("value: 2"))
  }

  @Test func aSyntaxErrorNamesTheFileLineAndColumn() async throws {
    let failure = await #expect(throws: JSXCompiler.Failure.self) {
      try await JSXCompiler().javaScript("export default () => <Sidebar name=>", file: "/bad.sidebar.jsx")
    }
    let message = try #require(failure?.message)
    #expect(message.hasPrefix("/bad.sidebar.jsx: "))
    #expect(message.contains("(1:"))
  }
}
