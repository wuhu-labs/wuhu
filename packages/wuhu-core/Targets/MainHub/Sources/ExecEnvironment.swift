import struct MachineContract.StringMap

public struct ExecEnvironment: Equatable, Sendable {
  public var env: StringMap?
  public var secrets: StringMap?
}

public func execEnvironment(env: [String: String], secrets: [String: String]) throws -> ExecEnvironment {
  for name in env.keys.sorted() where !isEnvironmentName(name) {
    throw ToolProblem("exec: '\(name)' is not a usable environment variable name")
  }
  for name in secrets.keys.sorted() where !isEnvironmentName(name) {
    throw ToolProblem("exec: '\(name)' is not a usable environment variable name")
  }
  let both = Set(env.keys).intersection(secrets.keys).sorted()
  if let clash = both.first {
    throw ToolProblem("exec: '\(clash)' is set by both env and secrets; pick one")
  }
  return ExecEnvironment(
    env: env.isEmpty ? nil : StringMap(env),
    secrets: secrets.isEmpty ? nil : StringMap(secrets),
  )
}

private func isEnvironmentName(_ name: String) -> Bool {
  var utf8 = name.utf8.makeIterator()
  guard let first = utf8.next(), first == UInt8(ascii: "_") || isASCIILetter(first) else { return false }
  while let byte = utf8.next() {
    guard byte == UInt8(ascii: "_") || isASCIILetter(byte) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    else { return false }
  }
  return true
}

private func isASCIILetter(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
}
