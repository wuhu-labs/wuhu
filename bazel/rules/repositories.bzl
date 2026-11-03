"""Repository rules for module fragments."""

def _build_file_repository_impl(rctx):
    rctx.file("REPO.bazel", "")
    rctx.file("BUILD.bazel", rctx.attr.build_file_content)

build_file_repository = repository_rule(
    implementation = _build_file_repository_impl,
    attrs = {"build_file_content": attr.string(mandatory = True)},
    doc = "A repository holding nothing but one BUILD file, for an alias that selects among per-platform archives.",
)
