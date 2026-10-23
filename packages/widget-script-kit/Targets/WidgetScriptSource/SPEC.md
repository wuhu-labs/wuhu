# Widget script source

The native and web clients load the same QuickJS bootstrap and catalog validator from this target's JavaScript resources. The bootstrap defines query, proxied fetch, JSX construction and result serialization. The catalog validates sidebar placements and the nine read-only widget templates. TypeScript declarations describe these JavaScript exports for the web facade. Bazel embeds the source bytes with the existing embeddedResources generator; SwiftPM uses ordinary package resources. Native clients load each source string with `WidgetScriptSource.prelude()` or `WidgetScriptSource.catalog()` and evaluate it as an ES module in a bounded QuickJS context.

The catalog's IconaMoon name set comes from tools/iconamoon/svg and aliases.json. Regenerate the embedded names when that vendored set changes. The source is canonical, not a generated copy of either client.
