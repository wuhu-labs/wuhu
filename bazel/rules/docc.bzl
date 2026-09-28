"""Bazel-native DocC archive and merged-site rules."""

load("@build_bazel_rules_swift//swift:providers.bzl", "SwiftInfo", "SwiftSymbolGraphInfo")
load("@build_bazel_rules_swift//swift:swift_symbol_graph_aspect.bzl", "swift_symbol_graph_aspect")

WuhuDocCArchiveInfo = provider(
    fields = {
        "archive": "The generated .doccarchive tree artifact.",
        "module_name": "The documented Swift module name.",
    },
)

def _wuhu_host_tool_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.run_shell(
        command = "cp \"$1\" \"$2\" && chmod +x \"$2\"",
        arguments = [ctx.file.src.path, executable.path],
        inputs = [ctx.file.src],
        outputs = [executable],
    )
    return [DefaultInfo(
        executable = executable,
        files = depset([executable]),
        runfiles = ctx.runfiles(files = [executable]),
    )]

wuhu_host_tool = rule(
    implementation = _wuhu_host_tool_impl,
    attrs = {"src": attr.label(allow_single_file = True, mandatory = True)},
    executable = True,
)

def _wuhu_docc_archive_impl(ctx):
    graph_info = ctx.attr.target[SwiftSymbolGraphInfo]
    matching_graphs = [
        graph
        for graph in graph_info.direct_symbol_graphs
        if graph.module_name == ctx.attr.module_name
    ]
    if len(matching_graphs) != 1:
        fail("{} expected one direct symbol graph for module {}, found {}".format(
            ctx.label,
            ctx.attr.module_name,
            len(matching_graphs),
        ))

    graph = matching_graphs[0].symbol_graph_dir
    archive = ctx.actions.declare_directory("{}.doccarchive".format(ctx.label.name))
    args = ctx.actions.args()
    args.add("convert")
    args.add("{}/{}".format(ctx.label.package, ctx.attr.catalog_path))
    args.add("--additional-symbol-graph-dir")
    args.add(graph.path)
    args.add("--output-path")
    args.add(archive.path)
    args.add("--enable-experimental-external-link-support")

    dependency_archives = []
    for dependency in ctx.attr.dependencies:
        dependency_archive = dependency[WuhuDocCArchiveInfo].archive
        dependency_archives.append(dependency_archive)
        args.add("--dependency")
        args.add(dependency_archive.path)

    ctx.actions.run(
        arguments = [args],
        executable = ctx.executable._docc,
        execution_requirements = {"requires-darwin": ""},
        inputs = depset(ctx.files.catalog + [graph] + dependency_archives),
        mnemonic = "DocCConvert",
        outputs = [archive],
        progress_message = "Building DocC archive for {}".format(ctx.attr.module_name),
    )

    return [
        DefaultInfo(files = depset([archive])),
        WuhuDocCArchiveInfo(
            archive = archive,
            module_name = ctx.attr.module_name,
        ),
    ]

wuhu_docc_archive = rule(
    implementation = _wuhu_docc_archive_impl,
    attrs = {
        "catalog": attr.label_list(allow_files = True, mandatory = True),
        "catalog_path": attr.string(mandatory = True),
        "dependencies": attr.label_list(providers = [WuhuDocCArchiveInfo]),
        "emit_extension_block_symbols": attr.string(default = "1", values = ["0", "1"]),
        "minimum_access_level": attr.string(default = "public", values = [
            "fileprivate",
            "internal",
            "private",
            "public",
        ]),
        "module_name": attr.string(mandatory = True),
        "target": attr.label(
            aspects = [swift_symbol_graph_aspect],
            mandatory = True,
            providers = [[SwiftInfo]],
        ),
        "_docc": attr.label(
            cfg = "exec",
            default = "//bazel/rules:docc",
            executable = True,
        ),
    },
)

def _wuhu_docc_site_impl(ctx):
    archive = ctx.actions.declare_directory("{}.doccarchive".format(ctx.label.name))
    input_archives = [item[WuhuDocCArchiveInfo].archive for item in ctx.attr.archives]
    args = ctx.actions.args()
    args.add("merge")
    args.add_all(input_archives, expand_directories = False)
    args.add("--output-path")
    args.add(archive.path)
    args.add("--synthesized-landing-page-name")
    args.add(ctx.attr.landing_page_name)
    args.add("--synthesized-landing-page-kind")
    args.add(ctx.attr.landing_page_kind)
    args.add("--synthesized-landing-page-topics-style")
    args.add(ctx.attr.topics_style)

    ctx.actions.run(
        arguments = [args],
        executable = ctx.executable._docc,
        execution_requirements = {"requires-darwin": ""},
        inputs = depset(input_archives),
        mnemonic = "DocCMerge",
        outputs = [archive],
        progress_message = "Merging {} DocC archives".format(len(input_archives)),
    )
    return [DefaultInfo(files = depset([archive]))]

wuhu_docc_site = rule(
    implementation = _wuhu_docc_site_impl,
    attrs = {
        "archives": attr.label_list(
            allow_empty = False,
            mandatory = True,
            providers = [WuhuDocCArchiveInfo],
        ),
        "landing_page_kind": attr.string(default = "Package"),
        "landing_page_name": attr.string(default = "Documentation"),
        "topics_style": attr.string(
            default = "detailedGrid",
            values = ["list", "compactGrid", "detailedGrid", "hidden"],
        ),
        "_docc": attr.label(
            cfg = "exec",
            default = "//bazel/rules:docc",
            executable = True,
        ),
    },
)
