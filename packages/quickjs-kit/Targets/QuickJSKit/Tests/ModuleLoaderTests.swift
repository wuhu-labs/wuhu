import JSONValue
import QuickJSKit
import Synchronization
import Testing

private struct Unknown: Error, CustomStringConvertible {
  let description: String
}

private final class Library: Sendable {
  private let files: [String: String]
  private let reads = Mutex<[String]>([])
  private let reports = Mutex<[JSONValue]>([])

  init(_ files: [String: String]) { self.files = files }

  var read: [String] { reads.withLock { $0 } }
  var reported: [JSONValue] { reports.withLock { $0 } }

  func loader(maxModules: Int = 16) -> JSEngine.ModuleLoader {
    JSEngine.ModuleLoader(
      maxModules: maxModules,
      resolve: { specifier, _ in
        guard specifier.hasPrefix("lib:") else { throw Unknown(description: "unknown module '\(specifier)'") }
        return specifier
      },
      source: { name in
        self.reads.withLock { $0.append(name) }
        guard let source = self.files[name] else { throw Unknown(description: "no such module") }
        return source
      },
    )
  }

  func engine() -> JSEngine {
    let engine = JSEngine()
    engine.define("report") { arguments in
      self.reports.withLock { $0.append(arguments.first ?? .null) }
      return .null
    }
    return engine
  }
}

private func message(of run: () async throws -> Void) async -> String? {
  do {
    try await run()
    return nil
  } catch let JSError.exception(message, _) {
    return message
  } catch {
    return "\(error)"
  }
}

@Suite(.timeLimit(.minutes(1))) struct ModuleLoaderTests {
  @Test func importsTheWholeGraphAndEvaluatesEachModuleOnce() async throws {
    let library = Library([
      "lib:a": "import { b } from 'lib:b'\nreport('a')\nexport const a = b + 1",
      "lib:b": "report('b')\nexport const b = 1",
    ])
    let engine = library.engine()
    try await engine.run(
      module: "import { a } from 'lib:a'\nimport { b } from 'lib:b'\nreport(a + b)",
      name: "script",
      loader: library.loader(),
    )
    #expect(library.reported == [.string("b"), .string("a"), .integer(3)])
    #expect(library.read.sorted() == ["lib:a", "lib:b"])
  }

  @Test func cyclesFollowModuleSemantics() async throws {
    let library = Library([
      "lib:even": "import { odd } from 'lib:odd'\nexport const even = (n) => n === 0 || odd(n - 1)",
      "lib:odd": "import { even } from 'lib:even'\nexport const odd = (n) => n !== 0 && even(n - 1)",
    ])
    let engine = library.engine()
    try await engine.run(module: "import { even } from 'lib:even'\nreport(even(10))", loader: library.loader())
    #expect(library.reported == [.bool(true)])
  }

  @Test func importedModulesShareTheRealmAndImportMeta() async throws {
    let library = Library(["lib:a": "report(import.meta.session)\nglobalThis.seen = 'a'"])
    let engine = library.engine()
    try await engine.run(
      module: "import 'lib:a'\nreport(globalThis.seen)",
      meta: ["session": .string("s1")],
      loader: library.loader(),
    )
    #expect(library.reported == [.string("s1"), .string("a")])
  }

  @Test func definedModulesBypassTheLoader() async throws {
    let library = Library(["lib:a": "import { twice } from 'host:math'\nexport const four = twice(2)"])
    let engine = library.engine()
    try engine.defineModule("host:math", source: "export const twice = (x) => x * 2")
    try await engine.run(module: "import { four } from 'lib:a'\nreport(four)", loader: library.loader())
    #expect(library.reported == [.integer(4)])
    #expect(library.read == ["lib:a"])
  }

  @Test func failuresNameTheImportChain() async throws {
    let library = Library([
      "lib:a": "import 'lib:b'",
      "lib:b": "import 'lib:gone'",
      "lib:c": "import 'fs'",
      "lib:d": "export const = 1",
    ])
    let loader = library.loader()
    #expect(
      await message { try await library.engine().run(module: "import 'lib:a'", name: "script", loader: loader) }
        == "script → lib:a → lib:b → lib:gone: no such module",
    )
    #expect(
      await message { try await library.engine().run(module: "import 'lib:c'", name: "script", loader: loader) }
        == "script → lib:c: unknown module 'fs'",
    )
    let syntax = await message { try await library.engine().run(module: "import 'lib:d'", name: "script", loader: loader) }
    #expect(syntax?.hasPrefix("script → lib:d: SyntaxError: ") == true)
  }

  @Test func refusesAGraphLargerThanTheLimit() async throws {
    let library = Library([
      "lib:1": "import 'lib:2'",
      "lib:2": "import 'lib:3'",
      "lib:3": "",
    ])
    let refused = await message {
      try await library.engine().run(module: "import 'lib:1'", name: "script", loader: library.loader(maxModules: 2))
    }
    #expect(refused == "script → lib:1 → lib:2 → lib:3: the import graph has more than 2 modules")
    #expect(!library.read.contains("lib:3"))
  }

  @Test func refusesDynamicImport() async throws {
    let library = Library(["lib:a": "export const a = 1"])
    let engine = library.engine()
    try await engine.run(
      module: "try { await import('lib:a') } catch (error) { report(error.message) }",
      loader: library.loader(),
    )
    #expect(library.reported == [.string("import() is not supported; import 'lib:a' statically")])
    #expect(library.read.isEmpty)
  }
}
