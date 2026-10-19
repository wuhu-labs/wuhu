import struct Credentials.CredentialBinding
import struct Credentials.CredentialResolver
import Fetch
import Foundation
import JSONValue
import class MainHub.Hub
@testable import SessionTools
import Testing

private let completionModels = #"{"offline":{"dialect":"anthropic","baseURL":"https://offline.test", "opaqueReplay": "affine","models":{"small":{"maxInput":8192,"maxOutput":512,"efforts":["low"],"defaultEffort":"low"}}}}"#
private let completionSSE = #"""
event: message_start
data: {"message":{"model":"served-small","usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":2}}}

event: content_block_start
data: {"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"delta":{"type":"text_delta","text":"{\"relevant\":true}"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {}

"""#

@Suite struct ScriptCompletionTests {
  @Test func modelGroupsAreTypedUnsupportedTargetsWithoutCredentialsOrProviderIO() async throws {
    let fetch = FetchClient { _ in Issue.record("group completion must not call a provider"); return Response(status: .internalServerError) }
    let credentials = CredentialResolver { _ in Issue.record("group completion must not resolve credentials"); return nil }
    try await withRig(fetch: fetch, credentials: credentials) { rig in
      let groups: JSONValue = [
        "work": ["kind": "group", "defaultEffort": "low", "members": [["id": "first", "provider": "offline", "model": "small"]], "policy": ["type": "select", "member": "first"]],
      ]
      try await rig.write("/models.json", completionModels)
      try await rig.write("/model-groups.json", groups.jsonString())
      let codes = try await rig.evaluate(#"import {complete} from 'wuhu:ai'; const codes=[]; for(const model of ['work','work/small']) {try {await complete('hello',{model})}catch(e){codes.push(e.code)}} result(codes)"#)
      #expect(codes == .array([.string("unsupportedTarget"), .string("unsupportedTarget")]))
    }
  }

  @Test func modelErrorsAreTypedAndNeverFallBack() async throws {
    let calls = Box<[String]>([])
    let credentials = CredentialResolver { id in calls.withLock { $0.append(id) }; return nil }
    let fetch = FetchClient { _ in Issue.record("Invalid completion must not call a provider"); return Response(status: .internalServerError) }
    try await withRig(fetch: fetch, credentials: credentials) { rig in
      let source = #"""
      import { complete, CompletionError } from 'wuhu:ai'
      const codes = []
      for (const invoke of [
        () => complete('hello'),
        () => complete('hello', {}),
        () => complete('hello', {model:'offline/small'}),
      ]) {
        try { await invoke() } catch (e) { codes.push([e instanceof CompletionError, e.name, e.code]) }
      }
      result(codes)
      """#
      #expect(try await rig.evaluate(source) == .array([
        .array([.bool(true), .string("CompletionError"), .string("missingModel")]),
        .array([.bool(true), .string("CompletionError"), .string("missingModel")]),
        .array([.bool(true), .string("CompletionError"), .string("providerNotConfigured")]),
      ]))
      try await rig.write("/models.json", completionModels)
      let errors = try await rig.evaluate(#"""
      import { complete } from 'wuhu:ai'
      const codes = []
      for (const model of ['absent/small', 'offline/absent', 'offline', 'offline/small']) {
        try { await complete('hello', {model}) } catch (e) { codes.push(e.code) }
      }
      result(codes)
      """#)
      #expect(errors == .array([.string("unknownModel"), .string("unknownModel"), .string("unknownModel"), .string("providerNotConfigured")]))
      #expect(calls.value == ["offline"])
      let token = try await rig.space.fs(.shared).read("/models.json").0
      _ = try await rig.space.fs(.shared).write("/models.json", Data("broken".utf8), ifMatch: token)
      #expect(try await rig.evaluate(#"import { complete } from 'wuhu:ai'; try { await complete('hello', {model:'offline/small'}) } catch(e) { result(e.code) }"#) == .string("providerNotConfigured"))
    }
  }

  @Test func promptsMessagesSchemasAndUsageUseTheCallingSession() async throws {
    let bodies = Box<[JSONValue]>([])
    let fetch = FetchClient { request in
      #expect(request.url.absoluteString == "https://offline.test/v1/messages")
      let bytes = try await request.body?.data() ?? Data()
      bodies.withLock { $0.append(JSONValue.parse(String(decoding: bytes, as: UTF8.self)) ?? .null) }
      return Response(status: .ok, body: .bytes(Data(completionSSE.utf8), contentType: "text/event-stream"))
    }
    try await withRig(fetch: fetch, credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") }, group: .init(rawValue: "completion-home")) { rig in
      try await rig.write("/models.json", completionModels)
      #expect(try await rig.evaluate(#"""
      import { complete } from 'wuhu:ai'
      const first = await complete('Judge relevance', {model:'offline/small'})
      const second = await complete([
        {role:'system',content:'Return JSON'},
        {role:'user',content:'Release today?'},
        {role:'assistant',content:'Maybe'},
        {role:'user',content:'Decide'},
      ], {model:'offline/small',schema:{type:'object',properties:{relevant:{type:'boolean'}},required:['relevant'],additionalProperties:false}})
      result([first,second])
      """#) == .array([.string(#"{"relevant":true}"#), .string(#"{"relevant":true}"#)]))
      #expect(bodies.value.count == 2)
      for body in bodies.value {
        #expect(body.object?["tools"] == nil)
        #expect(body.object?["tool_choice"] == nil)
        #expect(body.object?["model"] == .string("small"))
        #expect(body.object?["max_tokens"] == .integer(512))
      }
      #expect(bodies.value[0].object?["output_config"]?.object?["format"] == nil)
      #expect(bodies.value[1].object?["output_config"]?.object?["effort"] == .string("low"))
      #expect(bodies.value[1].object?["output_config"]?.object?["format"]?.object?["schema"]?.object?["required"] == .array([.string("relevant")]))
      #expect(bodies.value[1].object?["system"] == .string("Return JSON"))
      let records = try #require(try await rig.evaluate(#"import {query} from 'wuhu:space'; result(await query('SELECT * FROM "wuhu://*.localspace/inferences"'))"#).array)
      #expect(records.count == 2)
      for record in records {
        #expect(record.object?["session"]?.stringValue == rig.session.rawValue)
        #expect(record.object?["grp"]?.stringValue == "completion-home")
        #expect(record.object?["provider"]?.stringValue == "offline")
        #expect(record.object?["model"]?.stringValue == "small")
        #expect(record.object?["served_model"]?.stringValue == "served-small")
        #expect(record.object?["outcome"]?.stringValue == "ok")
        #expect(record.object?["input"]?.intValue == 10)
        #expect(record.object?["cache_read"]?.intValue == 4)
        #expect(record.object?["cache_write"]?.intValue == 2)
        #expect(record.object?["output"]?.intValue == 5)
      }
    }
  }

  @Test func failuresAreRecordedOnceAndNotRetried() async throws {
    let calls = Box(0)
    let fetch = FetchClient { _ in
      calls.withLock { $0 += 1 }
      return Response(status: .serviceUnavailable, body: .string("Provider failed"))
    }
    try await withRig(fetch: fetch, credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") }) { rig in
      try await rig.write("/models.json", completionModels)
      #expect(try await rig.evaluate(#"import { complete } from 'wuhu:ai'; try { await complete('hello',{model:'offline/small'}) } catch(e) { result([e.name,e.code]) }"#) == .array([.string("CompletionError"), .string("inferenceFailed")]))
      #expect(calls.value == 1)
      let record = try await rig.evaluate(#"import {query} from 'wuhu:space'; result((await query('SELECT * FROM inferences'))[0])"#)
      #expect(record.object?["session"]?.stringValue == rig.session.rawValue)
      #expect(record.object?["outcome"]?.stringValue == "httpError")
    }
  }

  @Test func invalidMessagesSchemasAndToolOptionsAreRefusedBeforeInference() async throws {
    try await withRig { rig in
      let result = try await rig.evaluate(#"""
      import { complete } from 'wuhu:ai'
      const codes = []
      for (const [input,options] of [
        ['',{model:'offline/small'}],
        [[],{model:'offline/small'}],
        [[{role:'tool',content:'tool output'}],{model:'offline/small'}],
        [[{role:'user',content:'hello'},{role:'system',content:'late'}],{model:'offline/small'}],
        ['hello',{model:'offline/small',schema:'not a schema'}],
        ['hello',{model:'offline/small',tools:[]}],
      ]) {
        try { await complete(input,options) } catch(e) { codes.push(e.code) }
      }
      result(codes)
      """#)
      #expect(result == .array(Array(repeating: .string("invalidArgument"), count: 6)))
    }
  }

  @Test func oidcSigningFailureReachesJavaScriptWithProviderAndWithoutSecrets() async throws {
    struct SigningFailure: Error, CustomStringConvertible {
      var description: String { "private-signing-material" }
    }
    let fetch = FetchClient { _ in
      Issue.record("signing failure must not reach a provider")
      return Response(status: .internalServerError)
    }
    try await withRig(fetch: fetch) { rig in
      let models = completionModels.replacingOccurrences(of: "\"dialect\":\"anthropic\"", with: "\"dialect\":\"anthropic\",\"auth\":\"oidc\"")
      let tools = ToolExecutor(owner: Hub(space: rig.space), completionCatalog: {
        .init(document: try .init(json: Data(models.utf8)), credentials: .init { _ in
          Issue.record("OIDC must not resolve a stored credential")
          return nil
        }, oidcToken: { _, _ in throw SigningFailure() })
      })
      try await rig.write("/signing-handler.js", #"""
      import {complete, CompletionError} from 'wuhu:ai'
      export default async () => {
        try { await complete('hello', {model:'offline/small'}) }
        catch (error) { return {typed:error instanceof CompletionError,name:error.name,code:error.code,provider:error.provider,message:error.message} }
        throw new Error('expected signing failure')
      }
      """#)
      let result = try await rig.scripts.runHandler(path: "/signing-handler.js", session: rig.session, stateJSON: "null", tools: tools)
      #expect(JSONValue.parse(result.stateJSON) == .object([
        "typed": .bool(true), "name": .string("CompletionError"), "code": .string("oidcSigningFailed"), "provider": .string("offline"),
        "message": .string("OIDC signing failed for provider offline; no fallback was attempted."),
      ]))
      #expect(!result.stateJSON.contains("private-signing-material"))
    }
  }

  @Test func configuredOIDCAndMetricsSeamsKeepCallerIdentity() async throws {
    let seen = Box<[String]>([])
    let fetch = FetchClient { request in
      #expect(request.headers.sensitiveValues["authorization"] == "Bearer fixture-token")
      return Response(status: .ok, body: .bytes(Data(completionSSE.utf8), contentType: "text/event-stream"))
    }
    try await withRig(fetch: fetch) { rig in
      let models = completionModels.replacingOccurrences(of: "\"dialect\":\"anthropic\"", with: "\"dialect\":\"anthropic\",\"auth\":\"oidc\"")
      let tools = ToolExecutor(owner: Hub(space: rig.space, completionMetrics: .init { metric in
        seen.withLock { $0.append(metric.session.rawValue) }
        #expect(metric.provider == "offline")
        #expect(metric.usage?.uncachedInputTokens == 10)
        #expect(metric.outcome.rawValue == "ok")
      }), completionCatalog: {
        .init(document: try .init(json: Data(models.utf8)), credentials: .init { _ in
          Issue.record("OIDC must not use stored credentials")
          return nil
        }, oidcToken: { _, caller in
          #expect(caller == rig.session)
          return "fixture-token"
        }, oidcBindingIdentity: { _, _ in "completion-oidc-fixture" })
      })
      let request = try CompletionRequest(input: .string("hello"), options: .object(["model": .string("offline/small")]))
      #expect(try await tools.complete(rig.session, request) == #"{"relevant":true}"#)
      #expect(seen.value == [rig.session.rawValue])
      #expect(try await rig.evaluate(#"import {query} from 'wuhu:space'; result((await query('SELECT COUNT(*) AS n FROM inferences'))[0].n)"#) == .integer(0))
    }
  }

  @Test func unsupportedSchemaAndInvalidProviderConfigurationNeverCallProviders() async throws {
    let fetch = FetchClient { _ in Issue.record("Invalid configuration must not reach a provider"); return Response(status: .internalServerError) }
    try await withRig(fetch: fetch, credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") }) { rig in
      try await rig.write("/models.json", completionModels.replacingOccurrences(of: "offline", with: "deepseek"))
      #expect(try await rig.evaluate(#"import { complete } from 'wuhu:ai'; try { await complete('hello',{model:'deepseek/small',schema:{type:'object'}}) } catch(e) { result(e.code) }"#) == .string("unsupportedSchema"))
      let token = try await rig.space.fs(.shared).read("/models.json").0
      let malformed = completionModels.replacingOccurrences(of: "https://offline.test", with: "file:///private")
      _ = try await rig.space.fs(.shared).write("/models.json", Data(malformed.utf8), ifMatch: token)
      #expect(try await rig.evaluate(#"import { complete } from 'wuhu:ai'; try { await complete('hello',{model:'offline/small'}) } catch(e) { result(e.code) }"#) == .string("providerNotConfigured"))
    }
  }

  @Test func malformedStructuredOutputIsRecordedAsFailure() async throws {
    let invalid = completionSSE.replacingOccurrences(of: #"{\"relevant\":true}"#, with: "not JSON")
    let fetch = FetchClient { _ in Response(status: .ok, body: .bytes(Data(invalid.utf8), contentType: "text/event-stream")) }
    try await withRig(fetch: fetch, credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") }) { rig in
      try await rig.write("/models.json", completionModels)
      #expect(try await rig.evaluate(#"import {complete} from 'wuhu:ai'; try { await complete('hello',{model:'offline/small',schema:{type:'object'}}) } catch(e) { result(e.code) }"#) == .string("inferenceFailed"))
      let record = try await rig.evaluate(#"import {query} from 'wuhu:space'; result((await query('SELECT * FROM inferences'))[0])"#)
      #expect(record.object?["outcome"] == .string("httpError"))
      #expect(record.object?["error"] == .string("malformedModelMessage"))
      #expect(record.object?["output"] == .integer(5))
    }
  }

  @Test func cancelledProviderAttemptIsRecorded() async throws {
    let fetch = FetchClient { _ in throw CancellationError() }
    try await withRig(fetch: fetch) { rig in
      try await rig.write("/models.json", completionModels)
      let tools = ToolExecutor(owner: Hub(space: rig.space, credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") }), credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") })
      let request = try CompletionRequest(input: .string("hello"), options: .object(["model": .string("offline/small")]))
      await #expect(throws: CancellationError.self) { try await tools.complete(rig.session, request) }
      let record = try await rig.evaluate(#"import {query} from 'wuhu:space'; result((await query('SELECT * FROM inferences'))[0])"#)
      #expect(record.object?["outcome"] == .string("cancelled"))
      #expect(record.object?["session"] == .string(rig.session.rawValue))
    }
  }

  @Test func handlersUseTheSameCompletionBindingAndCallingSession() async throws {
    let fetch = FetchClient { request in
      #expect(request.url.absoluteString == "https://offline.test/v1/messages")
      return Response(status: .ok, body: .bytes(Data(completionSSE.utf8), contentType: "text/event-stream"))
    }
    try await withRig(fetch: fetch) { rig in
      try await rig.write("/models.json", completionModels)
      try await rig.write("/complete-handler.js", #"""
      import {complete} from 'wuhu:ai'
      import {context} from 'wuhu:space'
      export default async ({state,wake}) => {
        const text = await complete('Release today?', {model:'offline/small',schema:{type:'object',properties:{relevant:{type:'boolean'}},required:['relevant'],additionalProperties:false}})
        if (JSON.parse(text).relevant) wake('Release question')
        return {session:(await context()).session,text,cursor:(state?.cursor ?? 0)+1}
      }
      """#)
      let tools = ToolExecutor(owner: Hub(space: rig.space, credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") }), credentials: .bound { _ in CredentialBinding(credential: .apiKey("fixture"), identityEpoch: "completion-fixture") })
      let result = try await rig.scripts.runHandler(path: "/complete-handler.js", session: rig.session, stateJSON: #"{"cursor":4}"#, tools: tools)
      let state = try #require(JSONValue.parse(result.stateJSON)?.object)
      #expect(state["session"] == .string(rig.session.rawValue))
      #expect(state["text"] == .string(#"{"relevant":true}"#))
      #expect(state["cursor"] == .integer(5))
      #expect(result.wakes == ["Release question"])
      let record = try await rig.evaluate(#"import {query} from 'wuhu:space'; result((await query('SELECT * FROM inferences'))[0])"#)
      #expect(record.object?["session"] == .string(rig.session.rawValue))
      #expect(record.object?["model"] == .string("small"))
      #expect(record.object?["output"] == .integer(5))
    }
  }
}

extension ScriptCompletionTests {
  @Test func noneOnlyAnthropicCompletionEmitsNoThinkingWithoutReplayScope() async throws {
    let requests = Box<[JSONValue]>([])
    let fetch = FetchClient { request in
      let data = try await request.body?.data() ?? Data()
      requests.withLock { $0.append(JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null) }
      return Response(status: .ok, body: .bytes(Data(completionSSE.utf8), contentType: "text/event-stream"))
    }
    try await withRig(fetch: fetch, credentials: .init { _ in .apiKey("fixture") }) { rig in
      let models = completionModels.replacingOccurrences(of: "\"affine\"", with: "\"none\"")
        .replacingOccurrences(of: "\"low\"", with: "\"none\"")
      try await rig.write("/models.json", models)
      let output = try await rig.evaluate(#"import {complete} from 'wuhu:ai'; result([await complete('hello', {model:'offline/small'})])"#)
      #expect(output == .array([.string(#"{"relevant":true}"#)]))
    }
    let body = try #require(requests.value.first?.object)
    #expect(body["thinking"] == nil)
    #expect(body["output_config"] == nil)
  }
}
