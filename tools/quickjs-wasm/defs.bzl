# The emscripten link must not see host --linkopt flags (the static Swift
# runtime list of --config=linux-static-runtime), which wasm_cc_binary's own
# transition keeps.
def _without_host_linkopts_impl(_settings, _attr):
    return {"//command_line_option:linkopt": []}

_without_host_linkopts = transition(
    implementation = _without_host_linkopts_impl,
    inputs = [],
    outputs = ["//command_line_option:linkopt"],
)

def _wasm_files_impl(ctx):
    return [DefaultInfo(files = ctx.attr.binary[0][DefaultInfo].files)]

wasm_files = rule(
    implementation = _wasm_files_impl,
    attrs = {
        "binary": attr.label(mandatory = True, cfg = _without_host_linkopts),
        "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    },
)
