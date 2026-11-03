#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif
import Crypto
import JSONValue
import OrderedCollections
import QuickJSKit
import Synchronization

/// Sidebar and widget scripts are JSX with no build step: `GET /v1/f/<path>?as=js`
/// serves a `.jsx` file compiled to plain JS by the bundled transform
/// (packages/jsx-compile), once per file name and source.
public actor JSXCompiler {
  public struct Failure: Error {
    public let message: String
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

  public init(stepBudget: Int = 100_000) {
    self.stepBudget = stepBudget
  }

  // Keyed by the source's digest, never a version token: one process serves many groups and
  // spaces, whose revisions and paths collide.
  public func javaScript(_ source: String, file: String) throws(Failure) -> String {
    let key = file + "\n" + SHA256.hash(data: Array(source.utf8)).map { String($0, radix: 16) }.joined(separator: ".")
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
    let budget = stepBudget
    let work = Work {
      Result { try self.engine.withLock { engine in
        let loaded = engine ?? Self.loaded(stepBudget: budget)
        engine = loaded
        return try loaded.evaluate(call, name: "compile")
      } }
    }
    work.joined(stackBytes: Self.threadStackBytes)
    return try work.result.withLock { $0! }.get()
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

/// One compile, run on a thread of its own: a raw pthread, since Foundation's `Thread` would
/// pull full Foundation into the server.
private final class Work: Sendable {
  let body: @Sendable () -> Result<JSONValue, any Error>
  let result = Mutex<Result<JSONValue, any Error>?>(nil)

  init(_ body: @escaping @Sendable () -> Result<JSONValue, any Error>) {
    self.body = body
  }

  /// Runs on a fresh thread of `stackBytes` and waits for it.
  func joined(stackBytes: Int) {
    var attributes = pthread_attr_t()
    precondition(pthread_attr_init(&attributes) == 0)
    defer { pthread_attr_destroy(&attributes) }
    precondition(pthread_attr_setstacksize(&attributes, stackBytes) == 0)
    let context = Unmanaged.passRetained(self).toOpaque()
    #if canImport(Darwin)
      var thread: pthread_t?
      precondition(pthread_create(&thread, &attributes, { context in
        Unmanaged<Work>.fromOpaque(context).takeRetainedValue().run()
        return nil
      }, context) == 0)
      precondition(pthread_join(thread!, nil) == 0)
    #else
      var thread = pthread_t()
      precondition(pthread_create(&thread, &attributes, { context in
        Unmanaged<Work>.fromOpaque(context!).takeRetainedValue().run()
        return nil
      }, context) == 0)
      precondition(pthread_join(thread, nil) == 0)
    #endif
  }

  private func run() {
    let value = body()
    result.withLock { $0 = value }
  }
}
