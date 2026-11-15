"""Portal ensures produce cacheable provisioning artifacts, never installed-file lookups."""

def _ensure_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    args = ["run", "--frozen", "-A", "tools/signing/ensure.ts", ctx.attr.command]
    if ctx.attr.command == "profile":
        args += [ctx.file.manifest.path, ctx.attr.target, ctx.attr.variant, ctx.file.devices.path]
    args += [out.path]
    ctx.actions.run(
        executable = ctx.file._deno,
        arguments = args,
        inputs = depset(ctx.files.srcs + ctx.files.manifest + ctx.files.devices),
        tools = [ctx.file._deno],
        outputs = [out],
        use_default_shell_env = True,
        execution_requirements = {"no-sandbox": "1", "requires-network": "1"},
        mnemonic = "EnsureAppleProfile" if ctx.attr.command == "profile" else "EnsureAppleDevices",
        progress_message = "Ensuring Apple signing inputs for %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

apple_signing_ensure = rule(
    implementation = _ensure_impl,
    exec_compatible_with = ["@platforms//os:macos"],
    attrs = {
        "command": attr.string(mandatory = True, values = ["devices", "profile"]),
        "out": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "manifest": attr.label(allow_single_file = True),
        "devices": attr.label(allow_single_file = True),
        "target": attr.string(),
        "variant": attr.string(),
        "_deno": attr.label(default = Label("//bazel/rules:deno"), allow_single_file = True, cfg = "exec"),
    },
)
