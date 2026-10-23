import Dispatch
import Foundation
import JSONValue
import OrderedCollections
import QuickJSKit
import Synchronization

/// Sidebar and widget scripts are JSX with no build step: `GET /v1/f/<path>?as=js`
/// serves a `.jsx` file compiled to plain JS by the bundled transform
/// (packages/jsx-compile), once per file version.
actor JSXCompiler {
  struct Failure: Error {
    let message: String
  }

  // Only ever touched under its lock, from the compile thread.
  private let engine = Mutex<JSEngine?>(nil)

  // The transform's parser recurses deeply even for small files, so a compile
  // runs on its own thread with a stack well past what QuickJS may use.
  private static let stackBytes = 16 << 20
  private static let threadStackBytes = 64 << 20

  // About a billion bytecode steps: past it a file fails rather than hold
  // every other compile behind it.
  private let stepBudget: Int

  private var compiled: OrderedDictionary<String, Result<String, Failure>> = [:]
  private static let kept = 256

  init(stepBudget: Int = 100_000) {
    self.stepBudget = stepBudget
  }

  /// `version` is the file's version token: a file compiles once per version.
  func javaScript(_ source: String, file: String, version: String) throws(Failure) -> String {
    let key = file + "\n" + version
    if let hit = compiled[key] { return try hit.get() }
    let result: Result<String, Failure>
    do {
      let call = "compileJSX(\(JSONValue.string(source).jsonString()), \(JSONValue.string(file).jsonString()))"
      guard case let .string(code) = try onLargeStack(call) else {
        preconditionFailure("compileJSX returns a string")
      }
      result = .success(code)
    } catch let JSError.exception(message, _, _) {
      result = .failure(Failure(message: "\(file): \(message)"))
    } catch JSError.terminated {
      result = .failure(Failure(message: "\(file): too long to compile"))
    } catch {
      result = .failure(Failure(message: "\(file): \(error)"))
    }
    compiled[key] = result
    if compiled.count > Self.kept { compiled.removeFirst() }
    return try result.get()
  }

  private func onLargeStack(_ call: String) throws -> JSONValue {
    let result = Mutex<Result<JSONValue, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    let budget = stepBudget
    let thread = Thread {
      let value = Result { try self.engine.withLock { engine in
        let loaded = engine ?? Self.loaded(stepBudget: budget)
        engine = loaded
        return try loaded.evaluate(call, name: "compile")
      } }
      result.withLock { $0 = value }
      done.signal()
    }
    thread.stackSize = Self.threadStackBytes
    thread.start()
    done.wait()
    return try result.withLock { $0! }.get()
  }

  // The bundle loads on the compile thread too.
  private static func loaded(stepBudget: Int) -> JSEngine {
    let engine = JSEngine(limits: .init(memoryBytes: 256 << 20, stackBytes: stackBytes, stepBudget: stepBudget))
    guard let file = EmbeddedJSXCompiler.files.first(where: { $0.path == ["compile.js"] }) else {
      preconditionFailure("the JSX transform bundle has no compile.js")
    }
    // A bundle that does not load is a build defect, not a request failure.
    try! engine.execute(String(decoding: EmbeddedJSXCompiler.bytes(for: file), as: UTF8.self), name: "compile.js")
    return engine
  }
}
