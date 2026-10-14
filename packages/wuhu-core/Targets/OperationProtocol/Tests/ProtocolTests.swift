#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import OperationProtocol
import Testing

@Test func offsetsAreDecimalStringsBeyondJavaScriptPrecision() throws {
  let offset = Offset(rawValue: UInt64.max)
  #expect(String(decoding: try JSONEncoder().encode(offset), as: UTF8.self) == "\"18446744073709551615\"")
  #expect(try JSONDecoder().decode(Offset.self, from: JSONEncoder().encode(offset)) == offset)
  #expect(throws: (any Error).self) { try offset.advanced(by: 1) }
  for text in ["1", "\"-1\"", "\"1.2\"", "\"18446744073709551616\"", "\"\"", "\"١\""] {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Offset.self, from: Data(text.utf8)) }
  }
}

@Test func firstComputerSchemasDoNotImportPlatformEffects() throws {
  let kinds = [ComputerKindSchemas.exec, ComputerKindSchemas.read, ComputerKindSchemas.find, ComputerKindSchemas.grep]
  #expect(kinds.map(\.name) == ["exec.v1", "read.v1", "find.v1", "grep.v1"])
  for descriptor in kinds {
    #expect(try JSONDecoder().decode(KindDescriptor.self, from: JSONEncoder().encode(descriptor)) == descriptor)
  }
  #expect(ComputerKindSchemas.exec.inputChannels.map(\.name) == ["stdin"])
  #expect(ComputerKindSchemas.exec.outputChannels.map(\.name) == ["stdout", "stderr"])
}

@Test func runnerVerdictsRequireEvidenceAndNeverIncludeUnknown() throws {
  for text in ["{\"tag\":\"unknown\"}", "{\"tag\":\"completed\"}", "{\"tag\":\"failed\"}", "{\"tag\":\"stopped\"}"] {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Verdict.self, from: Data(text.utf8)) }
  }
  let verdict = Verdict(.completed, result: .null)
  #expect(try JSONDecoder().decode(Verdict.self, from: JSONEncoder().encode(verdict)) == verdict)
}
