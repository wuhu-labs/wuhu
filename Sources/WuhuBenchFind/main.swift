import Dispatch
import Foundation
import PiAgent
import PiAI
import WuhuCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private struct Options: Sendable {
  var root: String = FileManager.default.currentDirectoryPath
  var pattern: String = "Sources/PiAI/Providers/*.swift"
  var toolPath: String? = "."
  var toolLimit: Int = 1000

  var iterations: Int = 5
  var warmup: Int = 1

  var cliFindPath: String = "/usr/bin/find"
  var cliPruneDefaults: Bool = true
  var includeGitIgnored: Bool = false
  var printFirstLines: Int = 0
}

@main
struct WuhuBenchFindMain {
  static func main() async throws {
    var options = try parseOptions(CommandLine.arguments.dropFirst())

    options.root = resolve(options.root)
    if let toolPath = options.toolPath {
      options.toolPath = toolPath
    }

    print("root: \(options.root)")
    print("pattern: \(options.pattern)")
    print("tool.path: \(options.toolPath ?? "(nil)")")
    print("tool.limit: \(options.toolLimit)")
    print("iterations: \(options.iterations) warmup: \(options.warmup)")
    print("cli.find: \(options.cliFindPath) pruneDefaults: \(options.cliPruneDefaults)")
    print("includeGitIgnored: \(options.includeGitIgnored)")
    print("")

    if options.warmup > 0 {
      print("warming up…")
      for _ in 0 ..< options.warmup {
        _ = try await runWuhuFind(options: options)
        _ = try runCLIFind(options: options)
      }
      print("")
    }

    var wuhuTimes: [Double] = []
    var cliTimes: [Double] = []
    var wuhuCount = 0
    var cliCount = 0

    for i in 1 ... options.iterations {
      let wuhuStart = nowNs()
      let wuhu = try await runWuhuFind(options: options)
      let wuhuMs = elapsedMs(startNs: wuhuStart)

      let cliStart = nowNs()
      let cli = try runCLIFind(options: options)
      let cliMs = elapsedMs(startNs: cliStart)

      wuhuTimes.append(wuhuMs)
      cliTimes.append(cliMs)
      wuhuCount = wuhu.count
      cliCount = cli.count

      print("iter \(i): wuhu=\(fmt(wuhuMs))ms (\(wuhu.count) results)  cli=\(fmt(cliMs))ms (\(cli.count) results)")
    }

    print("")
    print("wuhu: min=\(fmt(wuhuTimes.min() ?? 0))ms  median=\(fmt(median(wuhuTimes)))ms  max=\(fmt(wuhuTimes.max() ?? 0))ms  results=\(wuhuCount)")
    print("cli:  min=\(fmt(cliTimes.min() ?? 0))ms  median=\(fmt(median(cliTimes)))ms  max=\(fmt(cliTimes.max() ?? 0))ms  results=\(cliCount)")
  }
}

private func parseOptions(_ args: ArraySlice<String>) throws -> Options {
  var options = Options()
  var it = args.makeIterator()

  func nextValue(_ flag: String) throws -> String {
    guard let v = it.next() else {
      throw PiAIError.unsupported("Missing value for \(flag)")
    }
    return v
  }

  while let arg = it.next() {
    switch arg {
    case "--root":
      options.root = try nextValue(arg)
    case "--pattern":
      options.pattern = try nextValue(arg)
    case "--tool-path":
      options.toolPath = try nextValue(arg)
    case "--tool-limit":
      options.toolLimit = try Int(nextValue(arg)) ?? options.toolLimit
    case "--iterations":
      options.iterations = try Int(nextValue(arg)) ?? options.iterations
    case "--warmup":
      options.warmup = try Int(nextValue(arg)) ?? options.warmup
    case "--cli-find":
      options.cliFindPath = try nextValue(arg)
    case "--cli-prune-defaults":
      options.cliPruneDefaults = true
    case "--no-cli-prune-defaults":
      options.cliPruneDefaults = false
    case "--include-git-ignored":
      options.includeGitIgnored = true
    case "--print-first-lines":
      options.printFirstLines = try Int(nextValue(arg)) ?? options.printFirstLines
    case "-h", "--help":
      printHelpAndExit()
    default:
      throw PiAIError.unsupported("Unknown argument: \(arg)")
    }
  }

  options.iterations = max(1, options.iterations)
  options.warmup = max(0, options.warmup)
  options.toolLimit = max(1, options.toolLimit)
  options.printFirstLines = max(0, options.printFirstLines)

  return options
}

private func printHelpAndExit() -> Never {
  print(
    """
    Usage: wuhu-bench-find [options]

      --root PATH                 Root directory (default: cwd)
      --pattern GLOB              Wuhu find glob pattern (default: Sources/PiAI/Providers/*.swift)
      --tool-path PATH            Wuhu find 'path' argument (default: .)
      --tool-limit N              Wuhu find 'limit' argument (default: 1000)

      --iterations N              Measured iterations (default: 5)
      --warmup N                  Warmup iterations (default: 1)

      --cli-find PATH             Path to CLI find (default: /usr/bin/find)
      --cli-prune-defaults        Prune big dirs for CLI find (default)
      --no-cli-prune-defaults     Do not prune big dirs for CLI find

      --include-git-ignored       Run Wuhu find without .gitignore filtering (best-effort)
      --print-first-lines N       Print first N lines of each output (default: 0)
    """,
  )
  exit(0)
}

private func runWuhuFind(options: Options) async throws -> [String] {
  let tools = WuhuTools.codingAgentTools(cwd: options.root)
  guard let tool = tools.first(where: { $0.tool.name == "find" }) else {
    throw PiAIError.unsupported("find tool not found")
  }

  var args: [String: JSONValue] = [
    "pattern": .string(options.pattern),
    "limit": .number(Double(options.toolLimit)),
  ]
  if let toolPath = options.toolPath {
    args["path"] = .string(toolPath)
  }

  if options.includeGitIgnored {
    // Best-effort: the current tool does not expose an "includeIgnored" option.
    // Running with `--tool-path` pointing directly at an ignored directory remains supported.
  }

  let result = try await tool.execute(toolCallId: "bench_find", args: .object(args))
  let text = result.content.compactMap { block -> String? in
    if case let .text(part) = block { return part.text }
    return nil
  }.joined(separator: "\n")

  if options.printFirstLines > 0 {
    print("\n--- wuhu output (first \(options.printFirstLines) lines) ---")
    print(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(options.printFirstLines).joined(separator: "\n"))
    print("--- end ---\n")
  }

  return text
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map { String($0) }
}

private func runCLIFind(options: Options) throws -> [String] {
  let root = options.root
  let glob = options.pattern

  var args: [String] = [root, "-type", "f"]
  if options.cliPruneDefaults {
    args += [
      "(",
      "-name", ".git", "-o",
      "-name", ".build", "-o",
      "-name", ".swiftpm", "-o",
      "-name", "DerivedData", "-o",
      "-name", "node_modules",
      ")",
      "-prune",
      "-o",
    ]
  }

  if let name = cliNamePatternIfPossible(fromWuhuGlob: glob) {
    args += ["-name", name]
  } else if !glob.contains("/") {
    args += ["-name", glob]
  } else {
    // Try to approximate Wuhu's relative glob matching using find's -path.
    // Note: this is not a perfect equivalent for `**` semantics.
    args += ["-path", "*/\(glob)"]
  }

  args += ["-print"]

  let output = try runProcess(executable: options.cliFindPath, args: args)

  if options.printFirstLines > 0 {
    print("\n--- cli output (first \(options.printFirstLines) lines) ---")
    print(output.split(separator: "\n", omittingEmptySubsequences: false).prefix(options.printFirstLines).joined(separator: "\n"))
    print("--- end ---\n")
  }

  return output
    .split(separator: "\n", omittingEmptySubsequences: true)
    .map { String($0) }
}

private func cliNamePatternIfPossible(fromWuhuGlob glob: String) -> String? {
  // Map common "**/NAME" patterns to `find -name NAME` for a closer apples-to-apples benchmark.
  // Examples:
  // - "**/*.swift" -> "*.swift"
  // - "Sources/**/Package.swift" -> "Package.swift" (if caller sets --root Sources)
  let normalized = glob.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalized.isEmpty else { return nil }

  if normalized.hasPrefix("**/") {
    let rest = String(normalized.dropFirst(3))
    if !rest.contains("/") { return rest }
  }

  if let range = normalized.range(of: "/**/") {
    let rest = String(normalized[range.upperBound...])
    if !rest.contains("/") { return rest }
  }

  return nil
}

private func runProcess(executable: String, args: [String]) throws -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: executable)
  p.arguments = args

  let out = Pipe()
  let err = Pipe()
  p.standardOutput = out
  p.standardError = err

  try p.run()
  p.waitUntilExit()

  let outData = out.fileHandleForReading.readDataToEndOfFile()
  let errData = err.fileHandleForReading.readDataToEndOfFile()

  if p.terminationStatus != 0 {
    let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    throw PiAIError.unsupported("CLI find failed (\(p.terminationStatus)): \(stderr)")
  }

  return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func resolve(_ path: String) -> String {
  let expanded = (path as NSString).expandingTildeInPath
  if expanded.hasPrefix("/") { return expanded }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).path
}

private func nowNs() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds
}

private func elapsedMs(startNs: UInt64) -> Double {
  let end = DispatchTime.now().uptimeNanoseconds
  return Double(end - startNs) / 1_000_000.0
}

private func median(_ xs: [Double]) -> Double {
  guard !xs.isEmpty else { return 0 }
  let s = xs.sorted()
  if s.count % 2 == 1 { return s[s.count / 2] }
  return (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

private func fmt(_ v: Double) -> String {
  String(format: "%.1f", v)
}
