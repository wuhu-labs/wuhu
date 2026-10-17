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
  let kinds = [ComputerKindSchemas.exec, ComputerKindSchemas.read, ComputerKindSchemas.search]
  #expect(kinds.map(\.name) == ["exec.v1", "read.v1", "search.v1"])
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

@Test func availabilityAndSummaryAreOptionalAndRoundTrip() throws {
  let states: [KindAvailability] = [.available, .unavailable(reason: "edition"), .needsConsent, .needsPermission(permission: "calendar", state: "notDetermined")]
  for state in states { #expect(try JSONDecoder().decode(KindAvailability.self, from: JSONEncoder().encode(state)) == state) }
  #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(states[3])) == ["state": "needsPermission", "permission": "calendar", "permissionState": "notDetermined"])
  #expect(throws: (any Error).self) { try JSONDecoder().decode(KindAvailability.self, from: Data(#"{"state":"maybe"}"#.utf8)) }
  let old = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read])
  guard case let .object(wire) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(old)), case let .array(kinds) = wire["kinds"], case let .object(kind) = kinds.first else { Issue.record("description shape"); return }
  #expect(wire["availability"] == nil); #expect(kind["summary"] == nil)
  let gated = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [KindDescriptor("battery.v1", inputSchema: [:], resultSchema: [:], summary: "Battery level")], availability: ["exec.v1": .unavailable(reason: "edition")])
  let decoded = try JSONDecoder().decode(MachineDescription.self, from: JSONEncoder().encode(gated))
  #expect(decoded.availability == ["exec.v1": .unavailable(reason: "edition")]); #expect(decoded.kinds.first?.summary == "Battery level")
}

@Test func refusalsAreTypedWithWhatThePersonMustDo() {
  #expect(KindAvailability.available.refusal(kind: "x.v1") == nil)
  let edition = KindAvailability.unavailable(reason: "edition").refusal(kind: "exec.v1")
  #expect(edition?.code == .kindUnavailable); #expect(edition?.statusCode == 409); #expect(edition?.details == ["kind": "exec.v1", "reason": "edition"])
  #expect(KindAvailability.needsConsent.refusal(kind: "x.v1")?.details == ["kind": "x.v1", "reason": "needsConsent"])
  let permission = KindAvailability.needsPermission(permission: "healthkit", state: "denied").refusal(kind: "x.v1")
  #expect(permission?.code == .permissionDenied); #expect(permission?.statusCode == 403); #expect(permission?.details == ["kind": "x.v1", "permission": "healthkit", "state": "denied"])
  #expect(OperationError(.deviceLocked).statusCode == 503)
}

@Test func errorCodesAreAnOpenSetOnTheWire() throws {
  // Every code this build defines keeps its plain-string wire form.
  for code in OperationError.Code.known {
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(code)) == .string(code.rawValue))
    #expect(try JSONDecoder().decode(OperationError.Code.self, from: JSONEncoder().encode(code)) == code)
  }
  // A newer peer's code decodes as itself, not as a broken envelope.
  let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(#"{"error":{"code":"quotaPaused","message":"later","details":{"retryMs":5}}}"#.utf8))
  #expect(envelope.error.code.rawValue == "quotaPaused"); #expect(!envelope.error.code.isKnown)
  #expect(envelope.error.statusCode == 400); #expect(envelope.error.details == ["retryMs": 5])
  #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(envelope)) == ["error": ["code": "quotaPaused", "message": "later", "details": ["retryMs": 5]]])
  #expect(OperationError.Code.kindUnavailable.isKnown); #expect("\(OperationError.Code.kindUnavailable)" == "kindUnavailable")
  #expect(throws: (any Error).self) { try JSONDecoder().decode(OperationError.Code.self, from: Data("17".utf8)) }
}

@Test func revocationStopReasonsNameWhatChanged() {
  #expect(KindAvailability.available.stopReason == nil)
  #expect(KindAvailability.needsConsent.stopReason == "consentRevoked")
  #expect(KindAvailability.needsPermission(permission: "calendar", state: "denied").stopReason == "permissionRevoked")
  #expect(KindAvailability.unavailable(reason: "disabled").stopReason == "kindUnavailable")
}

@Test func startCallerIsOptionalDisplayMetadataOutsideTheInvocationIdentity() throws {
  let caller = StartRequest.Caller(session: "quick-breeze-badge", title: "Backend coder", group: "shared")
  let attributed = StartRequest(kind: "read.v1", input: ["path": "/a"], caller: caller)
  let wire = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(attributed))
  #expect(wire.object?["caller"] == ["session": "quick-breeze-badge", "title": "Backend coder", "group": "shared"])
  #expect(try JSONDecoder().decode(StartRequest.self, from: JSONEncoder().encode(attributed)) == attributed)
  // An old server's start has no caller key and decodes; a start without one never sends the key.
  let plain = try JSONDecoder().decode(StartRequest.self, from: Data(#"{"kind":"read.v1","input":{"path":"/a"}}"#.utf8))
  #expect(plain.caller == nil)
  #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(plain)).object?["caller"] == nil)
  // A renamed session replaying the same start is the same invocation.
  let renamed = StartRequest(kind: "read.v1", input: ["path": "/a"], caller: .init(session: "quick-breeze-badge", title: "Renamed", group: "shared"))
  #expect(try attributed.canonicalData() == plain.canonicalData())
  #expect(try attributed.canonicalData() == renamed.canonicalData())
  #expect(try attributed.canonicalData() != StartRequest(kind: "read.v1", input: ["path": "/b"], caller: caller).canonicalData())
}
