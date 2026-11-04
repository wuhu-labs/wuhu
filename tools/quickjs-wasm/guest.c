#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#define IMPORT(name) __attribute__((import_module("wuhu"), import_name(#name)))

IMPORT(receive) void host_receive(char *buffer);
IMPORT(send) void host_send(const char *bytes, size_t length);
IMPORT(send_body) void host_send_body(const char *bytes, size_t length, const uint8_t *body, size_t body_length);
IMPORT(expired) int host_expired(void);

struct source {
  struct source *next;
  const char *name;
  const char *text;
  size_t length;
};

static JSRuntime *runtime;
static JSContext *context;
static int entries;
static struct source *sources;
static int discovering;
static int missing;
static int sealed;
static JSValue hooks;

static int interrupt(JSRuntime *rt, void *opaque) { return host_expired(); }

static JSValue send(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv) {
  size_t length;
  const char *bytes = JS_ToCStringLen(ctx, &length, argv[0]);
  if (!bytes) return JS_EXCEPTION;
  if (argc > 1) {
    size_t body_length;
    uint8_t *body = JS_GetArrayBuffer(ctx, &body_length, argv[1]);
    if (!body) {
      JS_FreeCString(ctx, bytes);
      return JS_EXCEPTION;
    }
    host_send_body(bytes, length, body, body_length);
  } else {
    host_send(bytes, length);
  }
  JS_FreeCString(ctx, bytes);
  return JS_UNDEFINED;
}

static JSValue decode(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv) {
  size_t length;
  uint8_t *bytes = JS_GetArrayBuffer(ctx, &length, argv[0]);
  if (!bytes) return JS_EXCEPTION;
  return JS_NewStringLen(ctx, (const char *)bytes, length);
}

static JSValue encode(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv) {
  size_t length;
  const char *text = JS_ToCStringLen(ctx, &length, argv[0]);
  if (!text) return JS_EXCEPTION;
  JSValue buffer = JS_NewArrayBufferCopy(ctx, (const uint8_t *)text, length);
  JS_FreeCString(ctx, text);
  return buffer;
}

/// The prelude's one call: `{receive, fail, main, kernel, meta}` stay in C, off the global object, and
/// `kernel` reaches only `wuhu:host`, as its `import.meta.kernel`.
static JSValue seal(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv) {
  if (sealed) return JS_ThrowTypeError(ctx, "the prelude is sealed");
  hooks = JS_DupValue(ctx, argv[0]);
  sealed = 1;
  return JS_UNDEFINED;
}

static void release(JSRuntime *rt, void *opaque, void *ptr) { free(opaque); }

static JSValue hook(const char *name) { return sealed ? JS_GetPropertyStr(context, hooks, name) : JS_UNDEFINED; }

/// `wuhu:/<path>` names a space module; `./` and `../` resolve against the importing module's folder.
/// Any other `wuhu:<name>` is a built-in module, which loads only if the host handed it over;
/// `wuhu:host`, the host calls behind them, only into another built-in module.
static char *normalize(JSContext *ctx, const char *base, const char *name, void *opaque) {
  const char *path;
  size_t folder = 0;
  if (!strcmp(name, "wuhu:host") && strncmp(base, "wuhu:", 5)) {
    JS_ThrowReferenceError(ctx, "module 'wuhu:host' is internal to the built-in modules");
    return NULL;
  }
  if (!strncmp(name, "wuhu:", 5) && name[5] != '/' && name[5]) return js_strdup(ctx, name);
  if (!strncmp(name, "wuhu:/", 6) && name[6] != '/') {
    path = name + 5;
  } else if (!strncmp(name, "./", 2) || !strncmp(name, "../", 3)) {
    if (base[0] != '/') {
      JS_ThrowReferenceError(ctx, "relative import '%s' works only inside a space module", name);
      return NULL;
    }
    folder = strrchr(base, '/') - base;
    path = name;
  } else {
    JS_ThrowReferenceError(ctx, "unknown module '%s'; import wuhu:/<path> or a relative path", name);
    return NULL;
  }
  size_t capacity = folder + strlen(path) + 2;
  char *out = js_malloc(ctx, capacity);
  if (!out) return NULL;
  memcpy(out, base, folder);
  size_t length = folder;
  for (const char *piece = path; *piece;) {
    const char *end = strchr(piece, '/');
    size_t size = end ? (size_t)(end - piece) : strlen(piece);
    if (size == 2 && !strncmp(piece, "..", 2)) {
      if (length == 0) {
        js_free(ctx, out);
        JS_ThrowReferenceError(ctx, "import '%s' leaves the space", name);
        return NULL;
      }
      while (out[--length] != '/') {}
    } else if (size && !(size == 1 && piece[0] == '.')) {
      out[length++] = '/';
      memcpy(out + length, piece, size);
      length += size;
    }
    piece += size + (end != NULL);
  }
  if (length == 0) {
    js_free(ctx, out);
    JS_ThrowReferenceError(ctx, "import '%s' names no module", name);
    return NULL;
  }
  out[length] = 0;
  return out;
}

static void request(JSContext *ctx, const char *name) {
  JSValue string = JS_NewString(ctx, name);
  JSValue json = JS_JSONStringify(ctx, string, JS_UNDEFINED, JS_UNDEFINED);
  size_t length;
  const char *quoted = JS_ToCStringLen(ctx, &length, json);
  char *frame = malloc(length + 10);
  if (!quoted || !frame) abort();
  memcpy(frame, "{\"load\":", 8);
  memcpy(frame + 8, quoted, length);
  frame[length + 8] = '}';
  host_send(frame, length + 9);
  free(frame);
  JS_FreeCString(ctx, quoted);
  JS_FreeValue(ctx, json);
  JS_FreeValue(ctx, string);
  missing++;
}

/// While discovering, a module the host has not handed over yet compiles as an empty stub and is requested.
static JSModuleDef *load(JSContext *ctx, const char *name, void *opaque) {
  struct source *source = sources;
  while (source && strcmp(source->name, name)) source = source->next;
  static const char stub[] = "export {}";
  if (!source && name[0] != '/') {
    JS_ThrowReferenceError(ctx, "module '%s' is not available yet", name);
    return NULL;
  }
  if (!source) {
    if (!discovering) {
      JS_ThrowReferenceError(ctx, "module '%s' was not loaded", name);
      return NULL;
    }
    request(ctx, name);
  }
  JSValue compiled = source ? JS_Eval(ctx, source->text, source->length, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY)
                            : JS_Eval(ctx, stub, sizeof stub - 1, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(compiled)) return NULL;
  JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
  JS_FreeValue(ctx, compiled);
  if (ctx == context && !strcmp(name, "wuhu:host")) {
    JSValue meta = JS_GetImportMeta(ctx, module);
    int set = JS_SetPropertyStr(ctx, meta, "kernel", hook("kernel"));
    JS_FreeValue(ctx, meta);
    if (set < 0) return NULL;
  }
  return module;
}

/// Compiles the main module in a throwaway context; returns how many modules it requested.
static int discover(const char *bytes, size_t length) {
  JSContext *scratch = JS_NewContext(runtime);
  discovering = 1;
  missing = 0;
  JSValue compiled = JS_Eval(scratch, bytes, length, "main", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(compiled)) JS_FreeValue(scratch, JS_GetException(scratch));
  JS_FreeValue(scratch, compiled);
  discovering = 0;
  JS_FreeContext(scratch);
  return missing;
}

static void boot(void) {
  runtime = JS_NewRuntime();
  JS_SetMaxStackSize(runtime, 768 << 10);
  JS_SetInterruptHandler(runtime, interrupt, NULL);
  JS_SetModuleLoaderFunc(runtime, normalize, load, NULL);
  context = JS_NewContext(runtime);
  JSValue object = JS_GetGlobalObject(context);
  JS_SetPropertyStr(context, object, "__wuhu_send", JS_NewCFunction(context, send, "__wuhu_send", 2));
  JS_SetPropertyStr(context, object, "__wuhu_decode", JS_NewCFunction(context, decode, "__wuhu_decode", 1));
  JS_SetPropertyStr(context, object, "__wuhu_encode", JS_NewCFunction(context, encode, "__wuhu_encode", 1));
  JS_SetPropertyStr(context, object, "__wuhu_seal", JS_NewCFunction(context, seal, "__wuhu_seal", 1));
  JS_FreeValue(context, object);
}

static void fail(void) {
  JSValue exception = JS_GetException(context);
  JSValue report = hook("fail");
  if (JS_IsFunction(context, report)) {
    JS_FreeValue(context, JS_Call(context, report, JS_UNDEFINED, 1, &exception));
  } else {
    static const char frame[] = "{\"failed\":\"the guest failed before its prelude\"}";
    host_send(frame, sizeof frame - 1);
  }
  JS_FreeValue(context, report);
  JS_FreeValue(context, exception);
}

static void settle(JSValue value) {
  if (JS_IsException(value)) {
    fail();
    return;
  }
  JS_FreeValue(context, value);
  JSContext *job;
  int status;
  while ((status = JS_ExecutePendingJob(runtime, &job)) != 0) {
    if (status < 0) fail();
  }
}

static JSValue evaluate(const char *bytes, size_t length) {
  JSValue compiled = JS_Eval(context, bytes, length, "main", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
  if (JS_IsException(compiled)) return compiled;
  JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
  JSValue meta = JS_GetImportMeta(context, module);
  JSValue join = hook("meta");
  JSValue joined = JS_IsFunction(context, join) ? JS_Call(context, join, JS_UNDEFINED, 1, &meta) : JS_UNDEFINED;
  JS_FreeValue(context, join);
  JS_FreeValue(context, meta);
  if (JS_IsException(joined)) {
    JS_FreeValue(context, compiled);
    return joined;
  }
  JS_FreeValue(context, joined);
  JSValue promise = JS_EvalFunction(context, compiled);
  if (JS_IsException(promise)) return promise;
  JSValue arguments[2] = {promise, JS_GetModuleNamespace(context, module)};
  JSValue value = arguments[1];
  if (!JS_IsException(value)) {
    JSValue run = hook("main");
    value = JS_Call(context, run, JS_UNDEFINED, 2, arguments);
    JS_FreeValue(context, run);
    JS_FreeValue(context, arguments[1]);
  }
  JS_FreeValue(context, promise);
  return value;
}

/// Takes `length` bytes the host hands over through `receive`: kind 0 a script, 1 the main module
/// (its evaluation promise and namespace go to the `main` hook, once every module it imports was
/// handed over), 2 a frame for the `receive` hook, 3 a module as its name, a NUL and its source,
/// 4 a frame, a NUL and bytes, which `receive` takes as the frame and an ArrayBuffer over the bytes.
/// Returns how many entries this guest has taken, this one included.
__attribute__((export_name("wuhu_enter"))) int wuhu_enter(int kind, size_t length) {
  if (!runtime) boot();
  char *bytes = malloc(length + 1);
  if (!bytes) abort();
  host_receive(bytes);
  bytes[length] = 0;
  if (kind == 3) {
    struct source *source = malloc(sizeof *source);
    if (!source) abort();
    size_t name = strlen(bytes);
    *source = (struct source){sources, bytes, bytes + name + 1, length - name - 1};
    sources = source;
    return ++entries;
  }
  if (kind == 1 && discover(bytes, length)) {
    free(bytes);
    return ++entries;
  }
  JSValue value;
  if (kind == 2 || kind == 4) {
    JSValue receive = hook("receive");
    size_t head = kind == 4 ? strlen(bytes) : length;
    JSValue arguments[2] = {JS_NewStringLen(context, bytes, head), JS_UNDEFINED};
    if (kind == 4) {
      arguments[1] = JS_NewArrayBuffer(context, (uint8_t *)bytes + head + 1, length - head - 1, release, bytes, false);
      bytes = NULL;
    }
    value = JS_Call(context, receive, JS_UNDEFINED, 2, arguments);
    JS_FreeValue(context, arguments[0]);
    JS_FreeValue(context, arguments[1]);
    JS_FreeValue(context, receive);
  } else if (kind == 1) {
    value = evaluate(bytes, length);
  } else {
    value = JS_Eval(context, bytes, length, "prelude", JS_EVAL_TYPE_GLOBAL);
  }
  free(bytes);
  settle(value);
  return ++entries;
}

__attribute__((export_name("wuhu_entries"))) int wuhu_entries(void) { return entries; }
