import CQuickJS
import JSONValue
import OrderedCollections

let jsUndefined = JSValue(u: JSValueUnion(int32: 0), tag: Int64(JS_TAG_UNDEFINED))
let jsNull = JSValue(u: JSValueUnion(int32: 0), tag: Int64(JS_TAG_NULL))
let jsException = JSValue(u: JSValueUnion(int32: 0), tag: Int64(JS_TAG_EXCEPTION))

private let maximumDepth = 128

func tag(of value: JSValue) -> Int { Int(value.tag) }

func isException(_ value: JSValue) -> Bool { tag(of: value) == JS_TAG_EXCEPTION }

func string(_ value: JSValue, in ctx: OpaquePointer) -> String? {
  var length = 0
  guard let bytes = JS_ToCStringLen(ctx, &length, value) else { return nil }
  defer { JS_FreeCString(ctx, bytes) }
  return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
}

func toJSON(_ value: JSValue, in ctx: OpaquePointer, depth: Int = 0) throws -> JSONValue {
  if depth > maximumDepth {
    throw JSError.unsupportedValue("value nests deeper than \(maximumDepth) levels")
  }
  switch tag(of: value) {
  case JS_TAG_NULL, JS_TAG_UNDEFINED, JS_TAG_UNINITIALIZED:
    return .null
  case JS_TAG_BOOL:
    return .bool(value.u.int32 != 0)
  case JS_TAG_INT:
    return .integer(Int(value.u.int32))
  case JS_TAG_FLOAT64:
    return .number(value.u.float64)
  case JS_TAG_STRING, JS_TAG_STRING_ROPE:
    guard let text = string(value, in: ctx) else { throw pendingException(in: ctx) }
    return .string(text)
  case JS_TAG_OBJECT:
    return try toJSONObject(value, in: ctx, depth: depth)
  case JS_TAG_SYMBOL:
    throw JSError.unsupportedValue("symbol")
  case JS_TAG_BIG_INT, JS_TAG_SHORT_BIG_INT:
    throw JSError.unsupportedValue("bigint")
  case JS_TAG_EXCEPTION:
    throw pendingException(in: ctx)
  default:
    throw JSError.unsupportedValue("tag \(tag(of: value))")
  }
}

private func toJSONObject(
  _ value: JSValue,
  in ctx: OpaquePointer,
  depth: Int,
) throws -> JSONValue {
  if JS_IsFunction(ctx, value) { throw JSError.unsupportedValue("function") }
  if JS_PromiseState(ctx, value) != JS_PROMISE_NOT_A_PROMISE {
    throw JSError.unsupportedValue("promise")
  }
  if JS_IsArray(value) {
    var count: Int64 = 0
    guard JS_GetLength(ctx, value, &count) == 0 else { throw pendingException(in: ctx) }
    var elements: [JSONValue] = []
    elements.reserveCapacity(Int(count))
    for index in 0 ..< count {
      let element = JS_GetPropertyUint32(ctx, value, UInt32(index))
      defer { JS_FreeValue(ctx, element) }
      elements.append(try toJSON(element, in: ctx, depth: depth + 1))
    }
    return .array(elements)
  }
  var table: UnsafeMutablePointer<JSPropertyEnum>?
  var count: UInt32 = 0
  guard JS_GetOwnPropertyNames(
    ctx, &table, &count, value, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY,
  ) == 0
  else { throw pendingException(in: ctx) }
  defer { JS_FreePropertyEnum(ctx, table, count) }
  var members: OrderedDictionary<String, JSONValue> = [:]
  for index in 0 ..< Int(count) {
    let atom = table![index].atom
    guard let key = JS_AtomToCString(ctx, atom) else { throw pendingException(in: ctx) }
    defer { JS_FreeCString(ctx, key) }
    let member = JS_GetProperty(ctx, value, atom)
    defer { JS_FreeValue(ctx, member) }
    members[String(cString: key)] = try toJSON(member, in: ctx, depth: depth + 1)
  }
  return .object(members)
}

func toJS(_ value: JSONValue, in ctx: OpaquePointer) throws -> JSValue {
  switch value {
  case .null:
    return jsNull
  case .bool(let flag):
    return JS_NewBool(ctx, flag)
  case .integer(let number):
    return JS_NewInt64(ctx, Int64(number))
  case .number(let number):
    return JS_NewFloat64(ctx, number)
  case .string(let text):
    var bytes = text.utf8CString
    let result = bytes.withUnsafeMutableBufferPointer {
      JS_NewStringLen(ctx, $0.baseAddress, $0.count - 1)
    }
    if isException(result) { throw pendingException(in: ctx) }
    return result
  case .array(let elements):
    let array = JS_NewArray(ctx)
    if isException(array) { throw pendingException(in: ctx) }
    for (index, element) in elements.enumerated() {
      let converted: JSValue
      do { converted = try toJS(element, in: ctx) } catch {
        JS_FreeValue(ctx, array)
        throw error
      }
      guard JS_SetPropertyUint32(ctx, array, UInt32(index), converted) >= 0 else {
        JS_FreeValue(ctx, array)
        throw pendingException(in: ctx)
      }
    }
    return array
  case .object(let members):
    let object = JS_NewObject(ctx)
    if isException(object) { throw pendingException(in: ctx) }
    for (key, member) in members {
      let converted: JSValue
      do { converted = try toJS(member, in: ctx) } catch {
        JS_FreeValue(ctx, object)
        throw error
      }
      let stored = key.withCString { JS_SetPropertyStr(ctx, object, $0, converted) }
      guard stored >= 0 else {
        JS_FreeValue(ctx, object)
        throw pendingException(in: ctx)
      }
    }
    return object
  }
}

func pendingException(in ctx: OpaquePointer) -> JSError {
  let thrown = JS_GetException(ctx)
  defer { JS_FreeValue(ctx, thrown) }
  return exception(thrown, in: ctx)
}

func exception(_ thrown: JSValue, in ctx: OpaquePointer) -> JSError {
  let message = string(thrown, in: ctx) ?? "unknown error"
  guard tag(of: thrown) == JS_TAG_OBJECT else { return .exception(message: message, stack: nil) }
  let stackValue = JS_GetPropertyStr(ctx, thrown, "stack")
  defer { JS_FreeValue(ctx, stackValue) }
  let stack = tag(of: stackValue) == JS_TAG_STRING ? string(stackValue, in: ctx) : nil
  return .exception(message: message, stack: stack)
}

func throwError(_ message: String, in ctx: OpaquePointer) -> JSValue {
  let error = JS_NewError(ctx)
  if isException(error) { return error }
  var bytes = message.utf8CString
  let text = bytes.withUnsafeMutableBufferPointer {
    JS_NewStringLen(ctx, $0.baseAddress, $0.count - 1)
  }
  _ = "message".withCString { JS_SetPropertyStr(ctx, error, $0, text) }
  return JS_Throw(ctx, error)
}
