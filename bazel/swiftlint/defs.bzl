"""`swiftlint_test`: lints Swift sources with the pinned SwiftLint (MODULE.bazel.template) and the root `.swiftlint.yml`, without compiling them."""

def _swiftlint_test_impl(ctx):
    files = ctx.actions.declare_file(ctx.label.name + ".files")
    ctx.actions.write(files, "".join([src.short_path + "\n" for src in ctx.files.srcs]))
    runner = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = runner,
        substitutions = {
            "@@CONFIG@@": ctx.file._config.short_path,
            "@@EXPECTED@@": " ".join(ctx.attr.expected_violations),
            "@@FILES@@": files.short_path,
            "@@SWIFTLINT@@": ctx.executable._swiftlint.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = ctx.files.srcs + [files, ctx.file._config])
    runfiles = runfiles.merge(ctx.attr._swiftlint[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

swiftlint_test = rule(
    implementation = _swiftlint_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".swift"]),
        # Rule identifiers that must fire: the test then passes only when lint fails with each of them.
        "expected_violations": attr.string_list(),
        "_config": attr.label(default = "//:.swiftlint.yml", allow_single_file = True),
        "_runner": attr.label(default = ":swiftlint_test.sh.tpl", allow_single_file = True),
        "_swiftlint": attr.label(default = "@swiftlint//:swiftlint", executable = True, cfg = "exec"),
    },
)
