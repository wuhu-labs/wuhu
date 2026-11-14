"""The dynamic frameworks a host test links, staged in one runfiles folder."""

load("@build_bazel_rules_apple//apple:providers.bzl", "AppleDynamicFrameworkInfo", "AppleFrameworkImportInfo")

_LINK_ATTRS = ["deps", "private_deps", "implementation_deps"]

_ImportedFrameworksInfo = provider(fields = ["files"])

def _imported_frameworks_aspect_impl(target, ctx):
    if AppleDynamicFrameworkInfo in target and AppleFrameworkImportInfo in target:
        return [_ImportedFrameworksInfo(files = target[AppleFrameworkImportInfo].framework_imports)]
    transitive = []
    for attr in _LINK_ATTRS:
        for dep in getattr(ctx.rule.attr, attr, []):
            if _ImportedFrameworksInfo in dep:
                transitive.append(dep[_ImportedFrameworksInfo].files)
    return [_ImportedFrameworksInfo(files = depset(transitive = transitive))]

_imported_frameworks_aspect = aspect(
    implementation = _imported_frameworks_aspect_impl,
    attr_aspects = _LINK_ATTRS,
)

def _imported_frameworks_impl(ctx):
    links = []
    for file in depset(transitive = [dep[_ImportedFrameworksInfo].files for dep in ctx.attr.deps]).to_list():
        components = file.short_path.split("/")
        bundles = [index for index, component in enumerate(components) if component.endswith(".framework")]
        if not bundles:
            fail("imported framework file outside a .framework bundle: " + file.short_path)
        link = ctx.actions.declare_file(ctx.label.name + "/" + "/".join(components[bundles[0]:]))
        ctx.actions.symlink(output = link, target_file = file)
        links.append(link)
    return [DefaultInfo(files = depset(links), runfiles = ctx.runfiles(files = links))]

_imported_frameworks = rule(
    implementation = _imported_frameworks_impl,
    attrs = {"deps": attr.label_list(aspects = [_imported_frameworks_aspect])},
)

def host_test_frameworks(test, deps, **kwargs):
    """Stages `deps`' dynamic frameworks for the host test `test`: returns its data label and linkopt."""
    name = test + ".frameworks"
    _imported_frameworks(name = name, deps = deps, testonly = True, **kwargs)
    return ":" + name, "-Wl,-rpath,@loader_path/{}.runfiles/_main/{}/{}".format(test, native.package_name(), name)
