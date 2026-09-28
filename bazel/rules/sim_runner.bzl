"""Simulator test runner for rules_apple `*_unit_test` bundles.

The runner itself is tools/sim/runner.ts; this rule wraps it for one lane.
"""

load("@build_bazel_rules_apple//apple:providers.bzl", "apple_provider")

SIMULATOR_PLATFORM_DIRS = {
    "ios": "iPhoneSimulator.platform",
    "tvos": "AppleTVSimulator.platform",
    "visionos": "XRSimulator.platform",
}

def _wuhu_sim_test_runner_impl(ctx):
    runner = [f for f in ctx.files._sources if f.basename == "runner.ts"][0]
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.test_runner_template,
        substitutions = {
            "%(lane)s": ctx.attr.lane,
            "%(platform_dir)s": SIMULATOR_PLATFORM_DIRS[ctx.attr.lane],
            "%(deno)s": ctx.file._deno.short_path,
            "%(runner)s": runner.short_path,
        },
    )
    return [
        apple_provider.make_apple_test_runner_info(
            test_runner_template = ctx.outputs.test_runner_template,
            execution_requirements = {
                "no-sandbox": "",
                "requires-darwin": "",
            },
            execution_environment = {
                "XCODE_VERSION_OVERRIDE": str(
                    ctx.attr._xcode_config[apple_common.XcodeVersionConfig].xcode_version(),
                ),
            },
        ),
        DefaultInfo(
            runfiles = ctx.runfiles(files = ctx.files._sources + [ctx.file._deno]),
        ),
    ]

wuhu_sim_test_runner = rule(
    implementation = _wuhu_sim_test_runner_impl,
    attrs = {
        "lane": attr.string(mandatory = True, values = SIMULATOR_PLATFORM_DIRS.keys()),
        "_sources": attr.label(default = Label("//tools:sim_runner_sources")),
        "_deno": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = Label("//bazel/rules:deno"),
        ),
        "_template": attr.label(
            default = Label("//bazel/rules:sim_test_runner.template.sh"),
            allow_single_file = True,
        ),
        "_xcode_config": attr.label(
            default = configuration_field(
                fragment = "apple",
                name = "xcode_config_label",
            ),
        ),
    },
    outputs = {"test_runner_template": "%{name}.sh"},
    fragments = ["apple"],
)
