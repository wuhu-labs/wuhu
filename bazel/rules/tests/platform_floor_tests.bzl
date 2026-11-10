"""A package floor raises the lane's `-target` and nothing else: never lowers it, never reaches exec tools."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("//bazel/rules:rules.bzl", "raised_target", "wuhu_platform_floor", "wuhu_platforms")

_FLOORS = {"ios": "18.4", "macos": "26.0", "tvos": "26.0", "visionos": "26.0", "watchos": "11.0"}

def _raised_target_test_impl(ctx):
    env = unittest.begin(ctx)
    for triple, expected in [
        ("arm64-apple-macosx15.4", "arm64-apple-macosx26.0"),
        ("arm64-apple-ios17.0-simulator", "arm64-apple-ios18.4-simulator"),
        ("arm64-apple-ios17.0", "arm64-apple-ios18.4"),
        ("arm64-apple-tvos18.4-simulator", "arm64-apple-tvos26.0-simulator"),
        ("arm64-apple-xros1.0-simulator", "arm64-apple-xros26.0-simulator"),
        ("arm64_32-apple-watchos10.0", "arm64_32-apple-watchos11.0"),
        ("arm64-apple-macosx26", None),
        ("arm64-apple-macosx26.0.1", None),
        ("arm64-apple-ios26.0-simulator", None),
        ("x86_64-unknown-linux-gnu", None),
    ]:
        asserts.equals(env, expected, raised_target(triple, _FLOORS), triple)
    asserts.equals(env, None, raised_target("arm64-apple-macosx15.4", {"ios": "26.0"}))
    return unittest.end(env)

_raised_target_test = unittest.make(_raised_target_test_impl)

_TripleInfo = provider(fields = ["triple", "exec_triple"])

def _triple_probe_impl(ctx):
    return [_TripleInfo(
        triple = find_cc_toolchain(ctx).target_gnu_system_name,
        exec_triple = ctx.attr.exec_probe[_TripleInfo].triple if ctx.attr.exec_probe else None,
    )]

_triple_probe = rule(
    implementation = _triple_probe_impl,
    attrs = {
        "exec_probe": attr.label(cfg = "exec", providers = [_TripleInfo]),
        "_cc_toolchain": attr.label(default = "@rules_cc//cc:current_cc_toolchain"),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

_MAC_LANE = {"//command_line_option:macos_minimum_os": "15.4"}

def _mac_floor_test_impl(ctx):
    env = analysistest.begin(ctx)
    writes = [action for action in analysistest.target_actions(env) if action.mnemonic == "FileWrite"]
    asserts.equals(env, 1, len(writes))
    asserts.equals(env, "-target\narm64-apple-macosx26.0\n", writes[0].content)
    return analysistest.end(env)

_mac_floor_test = analysistest.make(_mac_floor_test_impl, config_settings = _MAC_LANE)

def _exec_minimum_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[_TripleInfo]
    asserts.equals(env, "arm64-apple-macosx15.4", info.triple)
    asserts.equals(env, "arm64-apple-macosx26.0", info.exec_triple)
    return analysistest.end(env)

_exec_minimum_test = analysistest.make(_exec_minimum_test_impl, config_settings = _MAC_LANE)

def platform_floor_tests(name):
    _raised_target_test(name = name + "-raise", target_compatible_with = wuhu_platforms(["linux", "mac"]))
    wuhu_platform_floor(name = name + "-floor", macos = "26.0", tags = ["manual"])
    _mac_floor_test(name = name + "-mac", target_under_test = name + "-floor", target_compatible_with = wuhu_platforms(["mac"]))
    _triple_probe(name = name + "-exec-probe", tags = ["manual"])
    _triple_probe(name = name + "-probe", exec_probe = name + "-exec-probe", tags = ["manual"])
    _exec_minimum_test(name = name + "-exec", target_under_test = name + "-probe", target_compatible_with = wuhu_platforms(["mac"]))
    native.test_suite(name = name, tests = [name + "-raise", name + "-mac", name + "-exec"])
