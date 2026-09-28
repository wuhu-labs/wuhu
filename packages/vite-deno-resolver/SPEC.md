# @wuhu/vite-deno-resolver

Vite resolves through `node_modules`. Deno's `links` field gives a consumer the
linked package's npm dependencies, but never the linked package specifier
itself, nor another workspace member's `imports` aliases. This plugin is the
bridge for exactly those two cases and nothing else.

## Contract

`denoResolver({ root, inlinePeers })` returns a Vite plugin.

- `root` is the absolute path of the **consumer** workspace root. It is passed
  explicitly rather than discovered from `import.meta.url`, because under
  `links` and under a Bazel sandbox the plugin's own location tells you nothing
  about the consumer's.
- `inlinePeers` names peer packages that must be bundled into an SSR build
  rather than externalized. CSS is always inlined.

`resolveSpecifier(workspace, specifier, importerPath)` is the pure core.

- Returns `null` for anything that is **not ours** — relative and absolute
  paths, and bare specifiers that resolve to neither an import-map entry nor a
  peer package. Vite resolves those through `node_modules`.
- Throws only when a specifier **is** ours and is broken: an unknown export of a
  known peer, or a `jsr:` specifier.
- The distinction is load-bearing. Swallowing errors here would let a
  misresolution degrade into Vite's default resolution and produce a duplicate
  React or a doubled component library in the bundle, with no signal.

## Resolution rules

1. `npm:` prefix → not ours; the version is stripped so Vite sees a plain
   package name.
2. `jsr:` prefix → error. See below.
3. Otherwise the importer's owning package is the one whose directory is the
   **longest** prefix of the importer path. Workspace members nest inside their
   root, so a shortest-match would attribute a member's file to the root.
4. Within that package, the import map applies deno/import-map semantics: a bare
   key matches only an exact specifier, and only a trailing-slash key matches as
   a prefix. Raw prefix matching would let a key `react` capture `react-dom`.
5. An unmatched specifier is tried as a peer package name, longest name first,
   so `@wuhu/ui` cannot shadow `@wuhu/ui-icons`.

## No jsr lane

The reference implementation this was ported from resolved `jsr:` specifiers by
reading a vendored `vendor/jsr.io` tree, including reversing deno's hashed
filename scheme for uppercase filenames. That requires `"vendor": true` and a
checked-in vendor tree, which the repo's vendoring rules forbid, and no web
package here imports jsr through Vite. A `jsr:` specifier is therefore an error
rather than a silently unresolved import.

If a jsr-sourced runtime dependency ever needs to reach a bundle, the answer is
a generate step or an npm mirror, not a resolver lane.
