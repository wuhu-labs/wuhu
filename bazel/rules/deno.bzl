"""In-graph deno rules (repo-layout laws 4-6).

A deno package is one atomic Bazel target keyed on sources + deno.lock + the
hash-pinned toolchain from MODULE.bazel.template. Actions carry
requires-network because deno fetches npm/jsr dependencies, but every fetched
byte is integrity-pinned by the declared lockfile input (law 5).

DENO_DIR is inherited when the environment supplies one (deno task check passes
a shared path) and falls back to scratch otherwise, so a bare `bazel test` still
works. `deno install --frozen` is what keeps a warm shared cache honest: a module
missing from the lockfile is a hard error, not a silent hit.
"""

_DENO_ATTR = attr.label(
    allow_single_file = True,
    cfg = "exec",
    default = Label("//bazel/rules:deno"),
)

_GENERATED_ATTR = attr.label_keyed_string_dict(allow_files = True)

def _single_generated_file(target):
    files = target.files.to_list()
    if len(files) != 1:
        fail("generated input {} must produce exactly one file, got {}".format(target.label, len(files)))
    return files[0]

_WORKSPACE_ROOT_ATTR = attr.label_list(allow_files = True)
_WORKSPACE_MEMBER_ATTR = attr.label_list(allow_files = True)
_LINK_ATTR = attr.label_list(allow_files = True)

# A deno workspace member runs its task from its own directory inside a
# reconstructed cluster: the member's own files, the root deno.json/deno.lock/
# package.json, and every sibling member's tree, each materialized at its
# repo-relative path so `deno` walks up to the shared workspace root. `loc` is
# where the sandbox exposes an input ($PWD in a test, $ROOT in an action); a
# source file's short_path equals its exec path, so it doubles as the dest.
def _materialize_workspace(files, dest_root, loc):
    lines = []
    for f in files:
        rel = f.short_path
        lines.append('mkdir -p "$(dirname "{root}/{rel}")"'.format(root = dest_root, rel = rel))
        lines.append('cp -L "{loc}/{rel}" "{root}/{rel}"'.format(loc = loc, rel = rel, root = dest_root))
    return "\n".join(lines)

def _inject_generated(ctx, dest_root, path_of):
    lines = []
    inputs = []
    for target, dest in ctx.attr.generated.items():
        src = _single_generated_file(target)
        inputs.append(src)
        lines.append('rm -f "{root}/{dest}"'.format(root = dest_root, dest = dest))
        lines.append('mkdir -p "$(dirname "{root}/{dest}")"'.format(root = dest_root, dest = dest))
        lines.append('cp "{src}" "{root}/{dest}"'.format(src = path_of(src), root = dest_root, dest = dest))
    return "\n".join(lines), inputs

def _deno_bundle_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    if ctx.files.workspace_root_files:
        app = "$WORK/ws/" + ctx.label.package
        materialize = _materialize_workspace(
            ctx.files.srcs + ctx.files.workspace_root_files +
            ctx.files.workspace_member_srcs + ctx.files.link_srcs,
            "$WORK/ws",
            "$ROOT",
        )
        inject, gen_inputs = _inject_generated(ctx, app, lambda f: "$ROOT/" + f.path)
        setup = """mkdir -p "$WORK/ws"
{materialize}
{inject}
cd "{app}\"""".format(materialize = materialize, inject = inject, app = app)
    else:
        app = "$WORK/app"
        inject, gen_inputs = _inject_generated(ctx, app, lambda f: "$ROOT/" + f.path)
        setup = """mkdir -p "$WORK/app"
cp -RL "{pkg_dir}/." "$WORK/app/"
rm -rf "$WORK/app/node_modules" "$WORK/app/build" "$WORK/app/.react-router" "$WORK/app/BUILD.bazel"
{inject}
cd "$WORK/app\"""".format(pkg_dir = ctx.label.package, inject = inject)
    command = """set -euo pipefail
ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DENO_DIR="${{DENO_DIR:-$WORK/deno-dir}}"
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" DENO_NO_UPDATE_CHECK=1
mkdir -p "$DENO_DIR" "$HOME"
{setup}
"$ROOT/{deno}" install --frozen
"$ROOT/{deno}" task {task}
test -s "{output_dir}/index.html" || {{ echo "bundle validation failed: missing or empty {output_dir}/index.html" >&2; exit 1; }}
found=""
for asset in "{output_dir}/_/assets"/*; do
    [ -s "$asset" ] || {{ echo "bundle validation failed: empty asset $asset" >&2; exit 1; }}
    found=1
done
[ -n "$found" ] || {{ echo "bundle validation failed: {output_dir}/_/assets is missing or empty" >&2; exit 1; }}
cp -R "{output_dir}/." "$ROOT/{out}/"
""".format(
        deno = ctx.file._deno.path,
        setup = setup,
        task = ctx.attr.task,
        output_dir = ctx.attr.output_dir,
        out = out.path,
    )
    ctx.actions.run_shell(
        inputs = depset(
            ctx.files.srcs + gen_inputs + ctx.files.workspace_root_files +
            ctx.files.workspace_member_srcs + ctx.files.link_srcs +
            [ctx.file._deno],
        ),
        outputs = [out],
        command = command,
        execution_requirements = {"requires-network": ""},
        mnemonic = "DenoBundle",
        progress_message = "Building deno bundle %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

deno_bundle = rule(
    implementation = _deno_bundle_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "task": attr.string(default = "build"),
        "output_dir": attr.string(mandatory = True),
        "generated": _GENERATED_ATTR,
        "workspace_root_files": _WORKSPACE_ROOT_ATTR,
        "workspace_member_srcs": _WORKSPACE_MEMBER_ATTR,
        "link_srcs": _LINK_ATTR,
        "_deno": _DENO_ATTR,
    },
)

def _deno_generate_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    command = """set -euo pipefail
ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DENO_DIR="${{DENO_DIR:-$WORK/deno-dir}}"
export HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" DENO_NO_UPDATE_CHECK=1
mkdir -p "$DENO_DIR" "$HOME"
"$ROOT/{deno}" run --allow-read --allow-write "$ROOT/{emitter}" "{fixtures_dir}" --out "$ROOT/{out}"
""".format(
        deno = ctx.file._deno.path,
        emitter = ctx.file.emitter.path,
        fixtures_dir = ctx.attr.fixtures_dir,
        out = out.path,
    )
    ctx.actions.run_shell(
        inputs = depset(ctx.files.srcs + [ctx.file.emitter, ctx.file._deno]),
        outputs = [out],
        command = command,
        mnemonic = "DenoGenerate",
        progress_message = "Generating %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

deno_generate = rule(
    implementation = _deno_generate_impl,
    attrs = {
        "emitter": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "fixtures_dir": attr.string(mandatory = True),
        "out": attr.string(mandatory = True),
        "_deno": _DENO_ATTR,
    },
)

def _deno_test_script(ctx, body, extra_runfiles = []):
    script = ctx.actions.declare_file("{}_test.sh".format(ctx.label.name))
    ctx.actions.write(
        output = script,
        content = """#!/usr/bin/env bash
set -euo pipefail
export DENO_DIR="${{DENO_DIR:-$TEST_TMPDIR/deno-dir}}"
export HOME="$TEST_TMPDIR/home" XDG_CACHE_HOME="$TEST_TMPDIR/cache" DENO_NO_UPDATE_CHECK=1
mkdir -p "$DENO_DIR" "$HOME"
DENO_BIN="$PWD/{deno}"
{body}
""".format(deno = ctx.file._deno.short_path, body = body),
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = ctx.files.srcs + extra_runfiles + [ctx.file._deno])
    return [DefaultInfo(executable = script, runfiles = runfiles)]

def _deno_task_test_impl(ctx):
    if ctx.files.workspace_root_files:
        app = "$TEST_TMPDIR/ws/" + ctx.label.package
        materialize = _materialize_workspace(
            ctx.files.srcs + ctx.files.workspace_root_files +
            ctx.files.workspace_member_srcs + ctx.files.link_srcs,
            "$TEST_TMPDIR/ws",
            "$PWD",
        )
        inject, gen_inputs = _inject_generated(ctx, app, lambda f: "$PWD/" + f.short_path)
        body = """mkdir -p "$TEST_TMPDIR/ws"
{materialize}
{inject}
cd "{app}"
"$DENO_BIN" install --frozen
"$DENO_BIN" task {task}
""".format(materialize = materialize, inject = inject, app = app, task = ctx.attr.task)
        return _deno_test_script(
            ctx,
            body,
            extra_runfiles = gen_inputs + ctx.files.workspace_root_files +
                             ctx.files.workspace_member_srcs +
                             ctx.files.link_srcs,
        )
    inject, gen_inputs = _inject_generated(ctx, "$TEST_TMPDIR/app", lambda f: "$PWD/" + f.short_path)
    body = """mkdir -p "$TEST_TMPDIR/app"
cp -RL "{pkg_dir}/." "$TEST_TMPDIR/app/"
rm -rf "$TEST_TMPDIR/app/node_modules" "$TEST_TMPDIR/app/build" "$TEST_TMPDIR/app/.react-router" "$TEST_TMPDIR/app/BUILD.bazel"
{inject}
cd "$TEST_TMPDIR/app"
"$DENO_BIN" install --frozen
"$DENO_BIN" task {task}
""".format(pkg_dir = ctx.label.package, task = ctx.attr.task, inject = inject)
    return _deno_test_script(ctx, body, extra_runfiles = gen_inputs)

deno_task_test = rule(
    implementation = _deno_task_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "task": attr.string(mandatory = True),
        "generated": _GENERATED_ATTR,
        "workspace_root_files": _WORKSPACE_ROOT_ATTR,
        "workspace_member_srcs": _WORKSPACE_MEMBER_ATTR,
        "link_srcs": _LINK_ATTR,
        "_deno": _DENO_ATTR,
    },
)

def _deno_command_test_impl(ctx):
    body = "\"$DENO_BIN\" {}\n".format(" ".join(ctx.attr.command))
    return _deno_test_script(ctx, body)

deno_command_test = rule(
    implementation = _deno_command_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "command": attr.string_list(mandatory = True),
        "_deno": _DENO_ATTR,
    },
)

def _exported_dir_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        inputs = depset(ctx.files.srcs),
        outputs = [out],
        command = 'cp -RL "{root}/." "{out}/"'.format(
            root = "{}/{}".format(ctx.label.package, ctx.attr.path),
            out = out.path,
        ),
        mnemonic = "WuhuExportDir",
        progress_message = "Exporting %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

exported_dir = rule(
    implementation = _exported_dir_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "path": attr.string(mandatory = True),
    },
)
