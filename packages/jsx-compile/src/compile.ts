import { transform } from 'sucrase'

// Sidebar and widget scripts are JSX with no build step: the server runs this
// bundle in QuickJS and serves plain JS. Elements become `h(type, props,
// ...children)` calls and fragments `Fragment`; imports, exports and the rest
// of the module stay as written.
export function compileJSX(source: string, file: string): string {
  return transform(source, {
    transforms: ['jsx'],
    jsxPragma: 'h',
    jsxFragmentPragma: 'Fragment',
    production: true,
    filePath: file,
  }).code
}

Object.assign(globalThis, { compileJSX })
