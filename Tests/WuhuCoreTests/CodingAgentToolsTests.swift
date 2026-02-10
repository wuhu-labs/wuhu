import Foundation
import Testing
import WuhuCore

struct CodingAgentToolsTests {
  private func tools(cwd: String) -> [String: AnyAgentTool] {
    Dictionary(uniqueKeysWithValues: WuhuTools.codingAgentTools(cwd: cwd).map { ($0.tool.name, $0) })
  }

  private func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  private func makeTempDir(prefix: String) throws -> String {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    return dir.path
  }

  @Test func readToolReadsFileWithinLimits() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read")
    let file = (dir as NSString).appendingPathComponent("test.txt")
    let content = "Hello, world!\nLine 2\nLine 3"
    try content.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t1", args: .object(["path": .string(file)]))

    #expect(textOutput(result) == content)
  }

  @Test func readToolNonexistentFileThrows() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-missing")
    let file = (dir as NSString).appendingPathComponent("missing.txt")
    let t = try #require(tools(cwd: dir)["read"])

    await #expect(throws: Error.self) {
      _ = try await t.execute(toolCallId: "t2", args: .object(["path": .string(file)]))
    }
  }

  @Test func readToolTruncatesByLineLimit() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-lines")
    let file = (dir as NSString).appendingPathComponent("large.txt")
    let lines = (1 ... 2500).map { "Line \($0)" }.joined(separator: "\n")
    try lines.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t3", args: .object(["path": .string(file)]))
    let out = textOutput(result)

    #expect(out.contains("Line 1"))
    #expect(out.contains("Line 2000"))
    #expect(!out.contains("Line 2001"))
    #expect(out.contains("Use offset=2001"))
  }

  @Test func readToolTruncatesByByteLimit() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-bytes")
    let file = (dir as NSString).appendingPathComponent("large-bytes.txt")
    let lines = (1 ... 500).map { "Line \($0): " + String(repeating: "x", count: 200) }.joined(separator: "\n")
    try lines.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t4", args: .object(["path": .string(file)]))
    let out = textOutput(result)

    #expect(out.contains("Line 1:"))
    #expect(out.contains("limit"))
    #expect(out.contains("Use offset="))
  }

  @Test func readToolOffset() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-offset")
    let file = (dir as NSString).appendingPathComponent("offset.txt")
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    try lines.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t5", args: .object(["path": .string(file), "offset": .number(51)]))
    let out = textOutput(result)

    #expect(!out.contains("Line 50"))
    #expect(out.contains("Line 51"))
    #expect(out.contains("Line 100"))
    #expect(!out.contains("Use offset="))
  }

  @Test func readToolLimitAddsContinueNotice() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-limit")
    let file = (dir as NSString).appendingPathComponent("limit.txt")
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    try lines.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t6", args: .object(["path": .string(file), "limit": .number(10)]))
    let out = textOutput(result)

    #expect(out.contains("Line 1"))
    #expect(out.contains("Line 10"))
    #expect(!out.contains("Line 11"))
    #expect(out.contains("90 more lines"))
    #expect(out.contains("Use offset=11"))
  }

  @Test func readToolOffsetAndLimit() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-offset-limit")
    let file = (dir as NSString).appendingPathComponent("offset-limit.txt")
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    try lines.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(
      toolCallId: "t7",
      args: .object(["path": .string(file), "offset": .number(41), "limit": .number(20)]),
    )
    let out = textOutput(result)

    #expect(!out.contains("Line 40"))
    #expect(out.contains("Line 41"))
    #expect(out.contains("Line 60"))
    #expect(!out.contains("Line 61"))
    #expect(out.contains("40 more lines"))
    #expect(out.contains("Use offset=61"))
  }

  @Test func readToolOffsetBeyondLengthThrows() async throws {
    let dir = try makeTempDir(prefix: "wuhu-read-oob")
    let file = (dir as NSString).appendingPathComponent("short.txt")
    try "Line 1\nLine 2\nLine 3".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    await #expect(throws: Error.self) {
      _ = try await t.execute(toolCallId: "t8", args: .object(["path": .string(file), "offset": .number(100)]))
    }
  }

  @Test func writeToolWritesAndCreatesParents() async throws {
    let dir = try makeTempDir(prefix: "wuhu-write")
    let t = try #require(tools(cwd: dir)["write"])

    let rel = "nested/dir/file.txt"
    let result = try await t.execute(toolCallId: "w1", args: .object(["path": .string(rel), "content": .string("hello")]))
    #expect(textOutput(result).contains("Successfully wrote"))

    let abs = (dir as NSString).appendingPathComponent(rel)
    let written = try String(contentsOfFile: abs, encoding: .utf8)
    #expect(written == "hello")
  }

  @Test func editToolReplacesText() async throws {
    let dir = try makeTempDir(prefix: "wuhu-edit")
    let file = (dir as NSString).appendingPathComponent("edit.txt")
    try "Hello, world!".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["edit"])
    _ = try await t.execute(toolCallId: "e1", args: .object([
      "path": .string(file),
      "oldText": .string("Hello, world!"),
      "newText": .string("Hi"),
    ]))

    let updated = try String(contentsOfFile: file, encoding: .utf8)
    #expect(updated == "Hi")
  }

  @Test func editToolFailsIfNotFound() async throws {
    let dir = try makeTempDir(prefix: "wuhu-edit-missing-text")
    let file = (dir as NSString).appendingPathComponent("edit.txt")
    try "Hello, world!".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["edit"])
    await #expect(throws: Error.self) {
      _ = try await t.execute(toolCallId: "e2", args: .object([
        "path": .string(file),
        "oldText": .string("nope"),
        "newText": .string("x"),
      ]))
    }
  }

  @Test func editToolFailsIfMultipleOccurrences() async throws {
    let dir = try makeTempDir(prefix: "wuhu-edit-dups")
    let file = (dir as NSString).appendingPathComponent("dups.txt")
    try "foo foo foo".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["edit"])
    await #expect(throws: Error.self) {
      _ = try await t.execute(toolCallId: "e3", args: .object([
        "path": .string(file),
        "oldText": .string("foo"),
        "newText": .string("bar"),
      ]))
    }
  }

  @Test func editToolFuzzyTrailingWhitespace() async throws {
    let dir = try makeTempDir(prefix: "wuhu-edit-fuzzy-ws")
    let file = (dir as NSString).appendingPathComponent("trailing.txt")
    try "line one   \nline two  \nline three\n".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["edit"])
    _ = try await t.execute(toolCallId: "ef1", args: .object([
      "path": .string(file),
      "oldText": .string("line one\nline two\n"),
      "newText": .string("replaced\n"),
    ]))

    let updated = try String(contentsOfFile: file, encoding: .utf8)
    #expect(updated == "replaced\nline three\n")
  }

  @Test func editToolPreservesCRLFAndBOM() async throws {
    let dir = try makeTempDir(prefix: "wuhu-edit-crlf-bom")
    let file = (dir as NSString).appendingPathComponent("bom.txt")
    try "\u{FEFF}first\r\nsecond\r\nthird\r\n".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["edit"])
    _ = try await t.execute(toolCallId: "ef2", args: .object([
      "path": .string(file),
      "oldText": .string("second\n"),
      "newText": .string("REPLACED\n"),
    ]))

    let updatedData = try Data(contentsOf: URL(fileURLWithPath: file))
    let updated = String(decoding: updatedData, as: UTF8.self)
    #expect(updated == "\u{FEFF}first\r\nREPLACED\r\nthird\r\n")
  }

  @Test func bashToolExecutesCommand() async throws {
    let dir = try makeTempDir(prefix: "wuhu-bash")
    let t = try #require(tools(cwd: dir)["bash"])
    let result = try await t.execute(toolCallId: "b1", args: .object(["command": .string("echo 'test output'")]))
    #expect(textOutput(result).contains("test output"))
  }

  @Test func bashToolTimeoutThrows() async throws {
    let dir = try makeTempDir(prefix: "wuhu-bash-timeout")
    let t = try #require(tools(cwd: dir)["bash"])

    await #expect(throws: Error.self) {
      _ = try await t.execute(toolCallId: "b2", args: .object(["command": .string("sleep 5"), "timeout": .number(1)]))
    }
  }

  @Test func grepToolSearchesSingleFileWithContextAndLimit() async throws {
    let dir = try makeTempDir(prefix: "wuhu-grep")
    let file = (dir as NSString).appendingPathComponent("context.txt")
    let content = ["before", "match one", "after", "middle", "match two", "after two"].joined(separator: "\n")
    try content.write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["grep"])
    let result = try await t.execute(toolCallId: "g1", args: .object([
      "pattern": .string("match"),
      "path": .string(file),
      "limit": .number(1),
      "context": .number(1),
    ]))
    let out = textOutput(result)

    #expect(out.contains("context.txt-1- before"))
    #expect(out.contains("context.txt:2: match one"))
    #expect(out.contains("context.txt-3- after"))
    #expect(out.contains("matches limit reached"))
    #expect(!out.contains("match two"))
  }

  @Test func findToolIncludesHiddenAndRespectsGitignore() async throws {
    let dir = try makeTempDir(prefix: "wuhu-find")
    let secretDir = (dir as NSString).appendingPathComponent(".secret")
    try FileManager.default.createDirectory(atPath: secretDir, withIntermediateDirectories: true, attributes: nil)
    try "hidden".write(toFile: (secretDir as NSString).appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
    try "visible".write(toFile: (dir as NSString).appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

    try "ignored.txt\n".write(toFile: (dir as NSString).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "ignored".write(toFile: (dir as NSString).appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["find"])
    let result = try await t.execute(toolCallId: "f1", args: .object([
      "pattern": .string("**/*.txt"),
      "path": .string(dir),
    ]))
    let out = textOutput(result).split(separator: "\n").map { String($0) }

    #expect(out.contains("visible.txt"))
    #expect(out.contains(".secret/hidden.txt"))
    #expect(!out.contains("ignored.txt"))
  }

  @Test func lsToolListsDotfilesAndDirectories() async throws {
    let dir = try makeTempDir(prefix: "wuhu-ls")
    try "secret".write(toFile: (dir as NSString).appendingPathComponent(".hidden-file"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      atPath: (dir as NSString).appendingPathComponent(".hidden-dir"),
      withIntermediateDirectories: true,
      attributes: nil,
    )

    let t = try #require(tools(cwd: dir)["ls"])
    let result = try await t.execute(toolCallId: "l1", args: .object(["path": .string(dir)]))
    let out = textOutput(result)

    #expect(out.contains(".hidden-file"))
    #expect(out.contains(".hidden-dir/"))
  }

  @Test func swiftToolRunsSnippet() async throws {
    let dir = try makeTempDir(prefix: "wuhu-swift-tool")
    let t = try #require(tools(cwd: dir)["swift"])

    let code = """
    import Foundation
    print("hi")
    """

    let result = try await t.execute(toolCallId: "s1", args: .object([
      "code": .string(code),
      "timeout": .number(10),
    ]))

    #expect(textOutput(result).trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
  }
}
