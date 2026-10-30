"""Manual selection propagates through locally owned macro helper rules."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//bazel/rules:rules.bzl", "wuhu_c_library", "wuhu_macos_test", "wuhu_platforms", "wuhu_sim_test", "wuhu_swift_library", "wuhu_swift_test", "wuhu_system_library")

def _manual_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], ctx.attr.failures)
    return unittest.end(env)

_manual_tags_test = unittest.make(_manual_tags_test_impl, attrs = {"failures": attr.string_list()})

def manual_tags_tests(name):
    prefix = "manual"
    tags = ["manual", "requires-network"]
    resources = {
        "copy_resources": ["fixture.txt"],
        "resource_root": ".",
        "resource_sentinel": "fixture.txt",
    }
    wuhu_swift_library(
        name = prefix + "_library",
        srcs = [],
        deps = [],
        package_name = "Fixture",
        target_compatible_with = ["@platforms//:incompatible"],
        tags = tags,
        embedded_directories = [{"name": "data", "srcs": ["fixture.txt"], "strip_prefix": native.package_name(), "type_name": "Data", "symbol_name": "data"}],
        **resources
    )
    wuhu_swift_test(
        name = prefix + "_test",
        srcs = [],
        deps = [],
        package_name = "Fixture",
        target_compatible_with = ["@platforms//:incompatible"],
        tags = tags,
        **resources
    )
    wuhu_macos_test(
        name = prefix + "_mac",
        srcs = [],
        deps = [],
        package_name = "Fixture",
        minimum_os_version = "26.0",
        target_compatible_with = ["@platforms//:incompatible"],
        tags = tags,
        **resources
    )
    wuhu_sim_test(
        name = prefix + "_sim",
        lane = "ios",
        module_name = "Fixture",
        srcs = [],
        deps = [],
        package_name = "Fixture",
        minimum_os_version = "26.0",
        target_compatible_with = ["@platforms//:incompatible"],
        tags = tags,
        **resources
    )
    wuhu_system_library(name = prefix + "_system", hdrs = [], module_map = "fixture.txt", tags = tags, target_compatible_with = ["@platforms//:incompatible"])
    wuhu_c_library(name = prefix + "_c", srcs = [], hdrs = [], module_map = "fixture.txt", deps = [], tags = tags, target_compatible_with = ["@platforms//:incompatible"])

    failures = []
    rules = native.existing_rules()
    for rule_name, attrs in rules.items():
        if rule_name.startswith("manual_") and "manual" not in attrs.get("tags", []):
            failures.append(rule_name + " lost manual")
    _manual_tags_test(name = name, failures = failures, target_compatible_with = wuhu_platforms(["linux", "mac"]))
