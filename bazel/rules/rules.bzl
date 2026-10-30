"""Wuhu project build rules.

Provides macros that mirror the project's custom SPM layout:

    Targets/<Name>/Sources/   →  swift_library
    Targets/<Name>/Tests/     →  swift_test
"""

load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_unit_test")
load("@build_bazel_rules_apple//apple:providers.bzl", "AppleTestRunnerInfo", "apple_provider")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("@build_bazel_rules_apple//apple:tvos.bzl", "tvos_unit_test")
load("@build_bazel_rules_apple//apple:visionos.bzl", "visionos_unit_test")
load("@build_bazel_rules_swift//swift:swift_binary.bzl", "swift_binary")
load("@build_bazel_rules_swift//swift:swift_compiler_plugin.bzl", "swift_compiler_plugin")
load("@build_bazel_rules_swift//swift:swift_interop_hint.bzl", "swift_interop_hint")
load("@build_bazel_rules_swift//swift:swift_library.bzl", "swift_library")
load("@build_bazel_rules_swift//swift:swift_test.bzl", "swift_test")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_swift_package_manager//swiftpkg:build_defs.bzl", "resource_bundle_infoplist")
load(":docc.bzl", _wuhu_docc_archive = "wuhu_docc_archive", _wuhu_docc_site = "wuhu_docc_site")
load(":sim_runner.bzl", "wuhu_sim_test_runner")

def wuhu_docc_archive(**kwargs):
    _wuhu_docc_archive(**kwargs)

def wuhu_docc_site(**kwargs):
    _wuhu_docc_site(**kwargs)

_PLATFORM_SETTINGS = {
    "linux": "//bazel/constraints:linux",
    "mac": "//bazel/constraints:mac",
    "ios": "//bazel/constraints:ios",
    "tvos": "//bazel/constraints:tvos",
    "visionos": "//bazel/constraints:visionos",
    "watchos": "//bazel/constraints:watchos",
}

# Lets every lane run `//...`: a target the lane does not check is incompatible
# rather than absent from a hand-maintained list. Generated from the `checks:`
# platforms in package.yml/target.yml — do not hand-write.
def wuhu_platforms(platforms):
    if not platforms:
        fail("wuhu_platforms requires at least one platform")
    conditions = {}
    for platform in platforms:
        if platform not in _PLATFORM_SETTINGS:
            fail("unknown check platform: {}".format(platform))
        conditions[_PLATFORM_SETTINGS[platform]] = []
    conditions["//conditions:default"] = ["@platforms//:incompatible"]
    return select(conditions)

def _bundle_module_accessor_impl(ctx):
    out = ctx.actions.declare_file("{}_BundleModule.swift".format(ctx.label.name))
    ctx.actions.write(
        output = out,
        content = """import Foundation

private class {finder_name} {{}}

extension Foundation.Bundle {{
  static let module: Bundle = {{
    let bundleName = {bundle_name}
    let resourceRoot = {resource_root}
    let sentinel = {sentinel}

    let bundleContainers = [
      Bundle.main.resourceURL,
      Bundle(for: {finder_name}.self).resourceURL,
      Bundle.main.bundleURL,
      Bundle(for: {finder_name}.self).resourceURL?.deletingLastPathComponent().deletingLastPathComponent(),
    ]

    for container in bundleContainers {{
      guard let container else {{ continue }}
      if let bundle = Bundle(url: container.appending(path: bundleName + \".bundle\")) {{
        return bundle
      }}
    }}

    let environment = ProcessInfo.processInfo.environment
    let runfileRoots = [
      environment[\"TEST_SRCDIR\"],
      environment[\"RUNFILES_DIR\"],
    ]

    let candidates = runfileRoots.flatMap {{ root -> [URL] in
      guard let root else {{ return [] }}
      let rootURL = URL(fileURLWithPath: root)
      return [
        rootURL.appending(path: \"_main\").appending(path: resourceRoot),
        rootURL.appending(path: resourceRoot),
      ]
    }} + [
      Bundle(for: {finder_name}.self).bundleURL,
      Bundle.main.bundleURL,
      URL(fileURLWithPath: resourceRoot),
    ]

    let resolvedCandidates = candidates.map {{ candidate in
      var resolved = candidate
        .appending(path: sentinel)
        .resolvingSymlinksInPath()
      for _ in sentinel.split(separator: \"/\") {{
        resolved.deleteLastPathComponent()
      }}
      return resolved
    }}

    for candidate in resolvedCandidates + candidates {{
      if let bundle = Bundle(url: candidate) {{
        return bundle
      }}
    }}

    fatalError(\"unable to find {module_name} resources\")
  }}()
}}
""".format(
            bundle_name = repr(ctx.attr.bundle_name),
            finder_name = "{}BundleFinder".format(ctx.attr.module_name.replace("-", "_")),
            module_name = ctx.attr.module_name,
            resource_root = repr(ctx.attr.resource_root),
            sentinel = repr(ctx.attr.sentinel),
        ),
    )
    return [DefaultInfo(files = depset([out]))]

bundle_module_accessor = rule(
    implementation = _bundle_module_accessor_impl,
    attrs = {
        "bundle_name": attr.string(mandatory = True),
        "module_name": attr.string(mandatory = True),
        "resource_root": attr.string(mandatory = True),
        "sentinel": attr.string(mandatory = True),
    },
)

def _embedded_directory_sources_impl(ctx):
    c_out = ctx.actions.declare_file("{}.c".format(ctx.label.name))
    swift_out = ctx.actions.declare_file("{}.swift".format(ctx.label.name))
    assembly_out = ctx.actions.declare_file("{}.S".format(ctx.label.name))
    payload_out = ctx.actions.declare_file("{}.bin".format(ctx.label.name))

    if (ctx.attr.directory == None) == (ctx.attr.strip_prefix == ""):
        fail("embedded_directory_sources needs exactly one of srcs+strip_prefix or directory")

    if ctx.attr.directory != None:
        ctx.actions.run_shell(
            inputs = depset([ctx.file.directory, ctx.file._generator]),
            outputs = [c_out, swift_out, assembly_out, payload_out],
            command = "python3 {generator} --directory-root {root} --swift-out {swift_out} --c-out {c_out} --assembly-out {assembly_out} --payload-out {payload_out} --type-name {type_name} --symbol-name {symbol_name} --section-name {section_name}".format(
                generator = ctx.file._generator.path,
                root = ctx.file.directory.path,
                swift_out = swift_out.path,
                c_out = c_out.path,
                assembly_out = assembly_out.path,
                payload_out = payload_out.path,
                type_name = ctx.attr.type_name,
                symbol_name = ctx.attr.symbol_name,
                section_name = ctx.attr.section_name,
            ),
            mnemonic = "WuhuEmbedDirectory",
        )
        return [
            DefaultInfo(files = depset([c_out, swift_out, assembly_out, payload_out])),
            OutputGroupInfo(c = depset([c_out, assembly_out]), payload = depset([payload_out]), swift = depset([swift_out])),
        ]

    manifest = ctx.actions.declare_file("{}.manifest".format(ctx.label.name))

    strip_prefix = ctx.attr.strip_prefix.strip("/")
    manifest_lines = []
    for file in sorted(ctx.files.srcs, key = lambda file: file.short_path):
        short_path = file.short_path
        prefixes = [strip_prefix]
        package_name = ctx.label.package
        if package_name:
            prefixes.append("{}/{}".format(package_name, strip_prefix))

        logical_path = None
        for prefix in prefixes:
            if short_path == prefix:
                logical_path = ""
                break
            prefix_with_slash = "{}/".format(prefix)
            if short_path.startswith(prefix_with_slash):
                logical_path = short_path[len(prefix_with_slash):]
                break

        if logical_path == None:
            fail("embedded directory input {} is not under strip_prefix {}".format(short_path, strip_prefix))
        if not logical_path:
            fail("embedded directory input {} resolves to an empty logical path".format(short_path))
        manifest_lines.append("{}\t{}".format(logical_path, file.path))

    ctx.actions.write(manifest, "\n".join(manifest_lines) + "\n")
    ctx.actions.run_shell(
        inputs = depset(ctx.files.srcs + [manifest, ctx.file._generator]),
        outputs = [c_out, swift_out, assembly_out, payload_out],
        command = "python3 {generator} --manifest {manifest} --swift-out {swift_out} --c-out {c_out} --assembly-out {assembly_out} --payload-out {payload_out} --type-name {type_name} --symbol-name {symbol_name} --section-name {section_name}".format(
            generator = ctx.file._generator.path,
            manifest = manifest.path,
            swift_out = swift_out.path,
            c_out = c_out.path,
            assembly_out = assembly_out.path,
            payload_out = payload_out.path,
            type_name = ctx.attr.type_name,
            symbol_name = ctx.attr.symbol_name,
            section_name = ctx.attr.section_name,
        ),
        mnemonic = "WuhuEmbedDirectory",
    )
    return [
        DefaultInfo(files = depset([c_out, swift_out, assembly_out, payload_out])),
        OutputGroupInfo(c = depset([c_out, assembly_out]), payload = depset([payload_out]), swift = depset([swift_out])),
    ]

embedded_directory_sources = rule(
    implementation = _embedded_directory_sources_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "strip_prefix": attr.string(),
        "directory": attr.label(allow_single_file = True),
        "symbol_name": attr.string(mandatory = True),
        "section_name": attr.string(mandatory = True),
        "type_name": attr.string(mandatory = True),
        "_generator": attr.label(
            allow_single_file = True,
            default = Label("//bazel/tools:generate_embedded_directory.py"),
        ),
    },
)

def _manual_tags(tags):
    return ["manual"] if "manual" in (tags or []) else []

def _wuhu_embedded_directory_srcs(name, directories, tags):
    swift_srcs = []
    deps = []
    for directory in directories:
        generated_name = "{}_{}_embedded_directory_sources".format(name, directory["name"])
        c_filegroup_name = "{}_{}_embedded_directory_c".format(name, directory["name"])
        swift_filegroup_name = "{}_{}_embedded_directory_swift".format(name, directory["name"])
        payload_filegroup_name = "{}_{}_embedded_directory_payload".format(name, directory["name"])
        cc_name = "{}_{}_embedded_directory_cc".format(name, directory["name"])
        symbol_name = directory.get("symbol_name", "{}_{}".format(name, directory["name"]))
        section_name = directory.get("section_name", "__{}".format(symbol_name))
        if len(section_name) > 16:
            fail("embedded directory Mach-O section name {} is longer than 16 bytes".format(section_name))

        embedded_directory_sources(
            name = generated_name,
            tags = tags,
            srcs = directory.get("srcs"),
            strip_prefix = directory.get("strip_prefix", ""),
            directory = directory.get("directory"),
            symbol_name = symbol_name,
            section_name = section_name,
            type_name = directory["type_name"],
        )
        native.filegroup(
            name = c_filegroup_name,
            tags = tags,
            srcs = [":{}".format(generated_name)],
            output_group = "c",
        )
        native.filegroup(
            name = swift_filegroup_name,
            tags = tags,
            srcs = [":{}".format(generated_name)],
            output_group = "swift",
        )
        native.filegroup(
            name = payload_filegroup_name,
            tags = tags,
            srcs = [":{}".format(generated_name)],
            output_group = "payload",
        )
        cc_library(
            name = cc_name,
            tags = tags,
            srcs = [":{}".format(c_filegroup_name)],
            additional_compiler_inputs = [":{}".format(payload_filegroup_name)],
        )
        swift_srcs.append(":{}".format(swift_filegroup_name))
        deps.append(":{}".format(cc_name))
    return (swift_srcs, deps)

# Generates a single `*.swift` source from the canonical OpenAPI document by
# running apple/swift-openapi-generator as a Bazel action. The generator binary
# is resolved by rules_swift_package_manager (declared via the umbrella
# `externalPackages` in packages/wuhu-contract/package.yml) and exposed as the
# executable product `@swiftpkg_swift_openapi_generator//:swift-openapi-generator`.
#
# Each OpenAPI module (ContractTypes / ContractClient / ContractServer) is one
# `wuhu_openapi_sources` target feeding one `wuhu_swift_library` via
# `srcs = [":<name>_gen"]`. A change to the document or config re-runs only the
# affected action; the produced `.swift` is input-gated and lives in the Bazel
# output tree (never in the working `Sources/`), so the disk / LAN remote cache
# serves it across fresh clones. This is the in-graph sibling of the manual
# `deno task generate-openapi` escape hatch, which resolves the *same* generator
# from the isolated tools/openapi-gen manifest and writes into `Sources/` for the
# SwiftPM path. Both derive from the same document + config, so their output is
# byte-identical.
def _wuhu_openapi_sources_impl(ctx):
    out = ctx.actions.declare_file(
        "{}/{}".format(ctx.label.name, ctx.attr.output),
    )
    args = ctx.actions.args()
    args.add("generate")
    args.add("--config", ctx.file.config)
    args.add("--output-directory", out.dirname)
    args.add(ctx.file.document)
    ctx.actions.run(
        executable = ctx.executable._generator,
        inputs = [ctx.file.config, ctx.file.document],
        outputs = [out],
        arguments = [args],
        mnemonic = "WuhuOpenAPIGen",
        progress_message = "Generating OpenAPI {} for {}".format(
            ctx.attr.output,
            ctx.label.name,
        ),
    )
    return [DefaultInfo(files = depset([out]))]

wuhu_openapi_sources = rule(
    implementation = _wuhu_openapi_sources_impl,
    attrs = {
        "document": attr.label(allow_single_file = True, mandatory = True),
        "config": attr.label(allow_single_file = True, mandatory = True),
        "output": attr.string(mandatory = True),
        "_generator": attr.label(
            default = Label("@swiftpkg_swift_openapi_generator//:swift-openapi-generator"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _wuhu_resource_bundle(name, bundle_name, resource_root, copy_resources, process_resources, tags):
    infoplist_name = "{}_resource_bundle_infoplist".format(name)
    resource_bundle_infoplist(
        name = infoplist_name,
        tags = tags,
        region = "en",
    )
    apple_resource_bundle(
        name = "{}_resource_bundle".format(name),
        tags = tags,
        bundle_name = bundle_name,
        infoplists = [":{}".format(infoplist_name)],
        resources = process_resources,
        structured_resources = copy_resources,
        strip_structured_resources_prefixes = [resource_root] if copy_resources else [],
    )

def _wuhu_resource_srcs(name, package_name, module_name, resource_root, resource_sentinel, copy_resources, process_resources, tags):
    resources = copy_resources + process_resources
    if not resources:
        return ([], [])
    if not resource_root or not resource_sentinel:
        fail("resource_root and resource_sentinel are required when resources are provided")

    bundle_name = "{}_{}".format(package_name, module_name)
    _wuhu_resource_bundle(name, bundle_name, resource_root, copy_resources, process_resources, tags)
    accessor_name = "{}_bundle_module_accessor".format(name)
    bundle_module_accessor(
        name = accessor_name,
        tags = tags,
        bundle_name = bundle_name,
        module_name = module_name,
        resource_root = "{}/{}".format(native.package_name(), resource_root),
        sentinel = resource_sentinel,
    )
    return ([":{}".format(accessor_name)], [":{}_resource_bundle".format(name)])

WUHU_SWIFT_LANGUAGE_MODE_COPTS = ["-swift-version", "6"]

# Dev-only compile define gating the controllable-clock server mode. Present in
# every non-release compilation mode (fastbuild/dbg — local `deno task check`
# and CI) and ABSENT under `-c opt`, which is exactly the tag-driven release
# build. So the controllable-clock feature (boot flag parse, dependency swap,
# loopback admin routes) does not exist in a shipped binary — it is compiled
# out, not merely toggled off.
WUHU_CONTROLLABLE_CLOCK_COPTS = select({
    "//bazel/rules:release_opt": [],
    "//conditions:default": ["-D", "WUHU_ALLOW_CONTROLLABLE_CLOCK"],
})

# Development-signing-only compile define gating the in-process UI pilot.
WUHU_UI_CONTROL_COPTS = select({
    "//bazel/signing:dev": ["-D", "BUILD_WITH_UI_CONTROL"],
    "//conditions:default": [],
})

WUHU_HMR_COPTS = select({
    "//bazel/rules:hmr_enabled": ["-D", "BUILD_WITH_HMR"],
    "//conditions:default": [],
})

# Opaque type erasure (Xcode's SWIFT_ENABLE_OPAQUE_TYPE_ERASURE) compiles every
# `some View` (each `body`, each helper) as SwiftUI's `DebugReplaceableView`.
# A hot patch swaps a body getter but not the conformance's `Body` type the app
# was compiled with, so without erasure an edit that changes the body's type
# (an added modifier, another container) hands SwiftUI a value laid out as the
# new type under the old type's metadata and crashes. Erased, `Body` is the
# same type before and after every patch. HMR builds give it to every Swift
# library and the HMR app shells (WUHU_HMR_VIEW_COPTS); HMR-only code such as
# the injection-next lab takes it unconditionally. The patch compiler refuses
# a library whose params lack it. Erasure alone is not enough: HMRRuntime also
# unmounts hot roots while it patches (see packages/hmr/Targets/HMRRuntime/SPEC.md).
WUHU_OPAQUE_TYPE_ERASURE_COPTS = ["-enable-experimental-feature", "OpaqueTypeErasure"]

WUHU_HMR_VIEW_COPTS = select({
    "//bazel/rules:hmr_enabled": WUHU_OPAQUE_TYPE_ERASURE_COPTS,
    "//conditions:default": [],
})

def _swift_6_copts(kwargs):
    return WUHU_SWIFT_LANGUAGE_MODE_COPTS + WUHU_CONTROLLABLE_CLOCK_COPTS + kwargs.pop("copts", [])

def wuhu_swift_library(name, srcs, deps, package_name, hmr = False, copy_resources = None, process_resources = None, resource_root = None, resource_sentinel = None, embedded_directories = None, **kwargs):
    copy_resources = copy_resources or []
    process_resources = process_resources or []
    embedded_directories = embedded_directories or []
    resource_srcs, data = _wuhu_resource_srcs(name, package_name, name, resource_root, resource_sentinel, copy_resources, process_resources, _manual_tags(kwargs.get("tags")))
    embedded_srcs, embedded_deps = _wuhu_embedded_directory_srcs(name, embedded_directories, _manual_tags(kwargs.get("tags")))

    swift_library(
        name = name,
        srcs = srcs + resource_srcs + embedded_srcs,
        copts = _swift_6_copts(kwargs) + WUHU_HMR_VIEW_COPTS + (WUHU_HMR_COPTS if hmr else []),
        data = data,
        deps = deps + embedded_deps + (select({
            "//bazel/rules:hmr_enabled": ["//packages/hmr:HMRRuntime"],
            "//conditions:default": [],
        }) if hmr else []),
        module_name = name,
        package_name = package_name,
        **kwargs
    )

def wuhu_c_library(name, srcs, hdrs, module_map, deps, **kwargs):
    wuhu_system_library(name, hdrs, module_map, srcs = srcs, deps = deps, **kwargs)

def wuhu_system_library(name, hdrs, module_map, linkopts = None, **kwargs):
    hint = "{}_swift_interop".format(name)
    swift_interop_hint(
        name = hint,
        tags = _manual_tags(kwargs.get("tags")),
        module_map = module_map,
        module_name = name,
    )
    cc_library(
        name = name,
        hdrs = hdrs,
        linkopts = linkopts or [],
        aspect_hints = [":{}".format(hint)],
        **kwargs
    )

def wuhu_swift_binary(name, srcs, deps, **kwargs):
    swift_binary(
        name = name,
        srcs = srcs,
        copts = _swift_6_copts(kwargs),
        deps = deps,
        **kwargs
    )

def wuhu_swift_macro(name, srcs, deps, **kwargs):
    swift_compiler_plugin(
        name = name,
        srcs = srcs,
        copts = _swift_6_copts(kwargs),
        deps = deps,
        module_name = name,
        **kwargs
    )

def wuhu_swift_test(name, srcs, deps, package_name, copy_resources = None, process_resources = None, resource_root = None, resource_sentinel = None, extra_data = None, **kwargs):
    copy_resources = copy_resources or []
    process_resources = process_resources or []
    resource_srcs, data = _wuhu_resource_srcs(name, package_name, name, resource_root, resource_sentinel, copy_resources, process_resources, _manual_tags(kwargs.get("tags")))

    swift_test(
        name = name,
        srcs = srcs + resource_srcs,
        copts = _swift_6_copts(kwargs),
        data = data + copy_resources + (extra_data or []),
        deps = deps,
        module_name = name.replace("-", "_"),
        package_name = package_name,
        # IssueReporting discovers its test bridge with dlsym; an archive dependency alone is stripped.
        linkopts = kwargs.pop("linkopts", []) + select({
            "//bazel/constraints:linux": [
                "-Wl,--undefined=$s25IssueReportingTestSupport07_recordA0ypyF",
                "-Wl,--export-dynamic",
            ],
            "//conditions:default": [],
        }),
        **kwargs
    )

def _wuhu_macos_runner_impl(ctx):
    base = ctx.attr.base[AppleTestRunnerInfo]
    environment = {}
    for key, value in ctx.attr.env.items():
        # rules_apple expands make variables in env, but not data locations.
        expanded = ctx.expand_location(
            value.replace("$(rootpaths ", "$(locations ").replace("$(rootpath ", "$(location "),
            targets = ctx.attr.data,
        )
        expanded = ctx.expand_make_variables("env", expanded, {})
        for file in sorted(ctx.files.data, key = _file_path_length, reverse = True):
            # The default runner interpolates test_env in a shell assignment before Xcode changes cwd.
            expanded = expanded.replace(file.path, "${TEST_SRCDIR}/" + ctx.workspace_name + "/" + file.short_path)
        environment[key] = expanded
    template = ctx.actions.declare_file(ctx.label.name + ".sh")
    inherited = []
    for name in ctx.attr.env_inherit:
        if not name or not (name[0].isalpha() or name[0] == "_") or not name.replace("_", "").isalnum():
            fail("invalid inherited environment name: " + name)
        if name not in environment:
            inherited.append('if [[ "${' + name + '+x}" == x ]]; then TEST_ENV="${TEST_ENV:+$TEST_ENV,}' + name + '=${' + name + '}"; fi')
    ctx.actions.run(
        executable = ctx.file._deno,
        inputs = [base.test_runner_template, ctx.file._template_adapter],
        outputs = [template],
        arguments = [
            "run", "--no-config", "--allow-read", "--allow-write", ctx.file._template_adapter.path,
            base.test_runner_template.path, template.path, json.encode(inherited),
            "true" if "WUHU_VDISPLAY_TOOL" in environment else "false",
        ],
        mnemonic = "MacTestRunnerTemplate",
    )
    runfiles = ctx.runfiles(files = ctx.files.data).merge(ctx.attr.base[DefaultInfo].default_runfiles)
    for target in ctx.attr.data:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)
    return [
        apple_provider.make_apple_test_runner_info(
            test_runner_template = template,
            execution_requirements = getattr(base, "execution_requirements", {}),
            execution_environment = dict(getattr(base, "execution_environment", {}), **environment),
            test_environment = dict(getattr(base, "test_environment", {}), **environment),
        ),
        DefaultInfo(runfiles = runfiles),
    ]

def _file_path_length(file):
    return len(file.path)

_wuhu_macos_runner = rule(
    implementation = _wuhu_macos_runner_impl,
    attrs = {
        "base": attr.label(default = Label("@build_bazel_rules_apple//apple/testing/default_runner:macos_default_runner"), providers = [AppleTestRunnerInfo]),
        "data": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
        "env_inherit": attr.string_list(),
        "_template_adapter": attr.label(default = Label("//bazel/rules:mac_runner_template.ts"), allow_single_file = True),
        "_deno": attr.label(default = Label("//bazel/rules:deno"), allow_single_file = True, cfg = "exec"),
    },
)

def wuhu_macos_test(name, srcs, deps, package_name, minimum_os_version, target_compatible_with, copy_resources = None, process_resources = None, resource_root = None, resource_sentinel = None, extra_data = None, copts = [], plugins = [], env = None, env_inherit = None, size = None, tags = None, linkopts = []):
    copy_resources = copy_resources or []
    process_resources = process_resources or []
    resource_srcs, resource_data = _wuhu_resource_srcs(name, package_name, name, resource_root, resource_sentinel, copy_resources, process_resources, _manual_tags(tags))
    library_name = "{}.library".format(name)
    swift_library(
        name = library_name,
        testonly = True,
        srcs = srcs + resource_srcs,
        copts = WUHU_SWIFT_LANGUAGE_MODE_COPTS + WUHU_CONTROLLABLE_CLOCK_COPTS + copts,
        data = copy_resources + (extra_data or []),
        deps = deps,
        module_name = name.replace("-", "_"),
        package_name = package_name,
        plugins = plugins,
        tags = ["manual"],
        target_compatible_with = target_compatible_with,
    )
    runner_name = "{}.runner".format(name)
    inherited = (env_inherit or []) + ["TEST_SRCDIR", "RUNFILES_DIR", "TEST_UNDECLARED_OUTPUTS_DIR", "TEST_TMPDIR"]
    _wuhu_macos_runner(
        name = runner_name,
        tags = _manual_tags(tags),
        testonly = True,
        data = copy_resources + (extra_data or []),
        env = env,
        env_inherit = inherited,
    )
    macos_unit_test(
        name = name,
        runner = ":" + runner_name,
        minimum_os_version = minimum_os_version,
        resources = resource_data,
        data = copy_resources + (extra_data or []),
        deps = [":" + library_name],
        linkopts = linkopts,
        env_inherit = inherited,
        size = size,
        tags = tags or [],
        target_compatible_with = target_compatible_with,
    )

_SIMULATOR_UNIT_TEST_RULES = {
    "ios": ios_unit_test,
    "tvos": tvos_unit_test,
    "visionos": visionos_unit_test,
}

# A simulator lane cannot host a bare `swift_test`: Bazel resolves no test
# toolchain for a simulator target platform. rules_apple's `*_unit_test` bundles
# the same sources into an `.xctest` and runs it on a booted simulator instead,
# so the sources compile and execute for the platform they claim.
def wuhu_sim_test(name, lane, module_name, srcs, deps, package_name, minimum_os_version, target_compatible_with, copy_resources = None, process_resources = None, resource_root = None, resource_sentinel = None, extra_data = None, copts = [], plugins = [], env = None, env_inherit = None, size = None, tags = None, test_host = None, host_arguments = None):
    copy_resources = copy_resources or []
    process_resources = process_resources or []
    resource_srcs, resource_data = _wuhu_resource_srcs(name, package_name, module_name, resource_root, resource_sentinel, copy_resources, process_resources, _manual_tags(tags))

    library_name = "{}.library".format(name)
    swift_library(
        name = library_name,
        testonly = True,
        srcs = srcs + resource_srcs,
        copts = WUHU_SWIFT_LANGUAGE_MODE_COPTS + WUHU_CONTROLLABLE_CLOCK_COPTS + copts,
        data = copy_resources + (extra_data or []),
        deps = deps,
        module_name = module_name,
        package_name = package_name,
        plugins = plugins,
        tags = ["manual"],
        target_compatible_with = target_compatible_with,
    )

    runner_name = "{}.runner".format(name)
    wuhu_sim_test_runner(
        name = runner_name,
        tags = _manual_tags(tags),
        lane = lane,
        host_arguments = host_arguments or [],
        testonly = True,
    )

    _SIMULATOR_UNIT_TEST_RULES[lane](
        name = name,
        minimum_os_version = minimum_os_version,
        runner = ":{}".format(runner_name),
        # The `.xctest` carries the resource bundle: the simulator process has
        # no runfiles tree, so `Bundle.module` must resolve inside the bundle.
        resources = resource_data,
        data = copy_resources + (extra_data or []),
        env = env,
        # A simulator process inherits nothing from the test action: simctl
        # forwards only what the runner exports. Bazel's own `--test_env=NAME`
        # reaches the runner, and this is what carries it the last hop.
        env_inherit = env_inherit,
        size = size,
        tags = tags or [],
        target_compatible_with = target_compatible_with,
        # With a host, the runner injects the bundle into that application
        # rather than spawning the bare `xctest` agent (tools/sim/runner.ts).
        test_host = test_host,
        deps = [":{}".format(library_name)],
    )

def aligned_target(name, deps = None, test_deps = None, package_name = None, include_tests = True, **kwargs):
    """Creates a swift_library + swift_test pair from the standard layout.

    Args:
        name: Target name. Sources expected at Targets/<name>/Sources/
        deps: Dependencies of the library target.
        test_deps: Additional dependencies for the test target.
        package_name: Semantic package name for `package` access control.
        include_tests: If True (default), also create a swift_test target.
        **kwargs: Additional arguments passed to swift_library.
    """
    deps = deps or []
    test_deps = test_deps or []

    if "module_name" not in kwargs:
        kwargs["module_name"] = name

    swift_library(
        name = name,
        srcs = native.glob(["Targets/{}/Sources/**/*.swift".format(name)]),
        copts = _swift_6_copts(kwargs),
        deps = deps,
        package_name = package_name,
        **kwargs
    )

    if include_tests:
        swift_test(
            name = "{}Tests".format(name),
            srcs = native.glob(
                ["Targets/{}/Tests/**/*.swift".format(name)],
                allow_empty = True,
            ),
            copts = WUHU_SWIFT_LANGUAGE_MODE_COPTS,
            deps = [":{}".format(name)] + test_deps,
            module_name = "{}Tests".format(name),
            package_name = package_name,
        )

def _hmr_transition_impl(settings, attr):
    return {
        "//bazel/rules:hmr": True,
        "//bazel/signing:variant": "dev",
    }

_hmr_transition = transition(
    implementation = _hmr_transition_impl,
    inputs = [],
    outputs = ["//bazel/rules:hmr", "//bazel/signing:variant"],
)

def _hmr_app_impl(ctx):
    return [DefaultInfo(files = ctx.attr.app[0][DefaultInfo].files)]

wuhu_hmr_app = rule(
    implementation = _hmr_app_impl,
    attrs = {
        "app": attr.label(mandatory = True, cfg = _hmr_transition),
        "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    },
)

def _hmr_plist_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".plist")
    channel = ctx.var.get("HMR_CHANNEL_URL", "") if ctx.attr.enabled else ""
    version = ctx.var.get("HMR_BUILD_VERSION", "") if ctx.attr.enabled else ""
    if bool(channel) != bool(version):
        fail("HMR_CHANNEL_URL and HMR_BUILD_VERSION must be provided together")
    if channel:
        if not channel.startswith("https://"):
            fail("HMR_CHANNEL_URL requires HTTPS")
        ctx.actions.run_shell(
            inputs = [ctx.file.src],
            outputs = [out],
            arguments = [ctx.file.src.path, out.path, channel, version],
            command = """set -eu
/usr/bin/plutil -convert xml1 -o "$2" "$1"
/usr/bin/plutil -insert HMRChannelURL -string "$3" "$2"
/usr/bin/plutil -replace CFBundleVersion -string "$4" "$2"
""",
            mnemonic = "HMRSessionPlist",
        )
    else:
        ctx.actions.symlink(output = out, target_file = ctx.file.src)
    return [DefaultInfo(files = depset([out]))]

wuhu_hmr_plist = rule(
    implementation = _hmr_plist_impl,
    attrs = {
        "src": attr.label(allow_single_file = [".plist"], mandatory = True),
        "enabled": attr.bool(default = False),
    },
)
